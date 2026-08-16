import Foundation
import Combine

enum PersonalizeMode: String, CaseIterable, Identifiable {
    case vibe = "Vibe", artist = "Artist", playlist = "Playlist", song = "Song"
    var id: String { rawValue }

    var placeholder: String {
        switch self {
        case .vibe:     return "What's your vibe?"
        case .artist:   return "Enter your favorite artist"
        case .playlist: return "Enter your playlist's name"
        case .song:     return "Enter your favorite song"
        }
    }
}

struct KaraokePackage {
    let instrumental: SpotifyTrack
    let lyrics: [LyricLine]
    let sourceName: String
    let sourceArtist: String
}

enum AudioSource { case suno, spotify }

/// Orchestrates the whole Personalize + Karaoke pipeline on-device, mirroring the
/// computer edition's server logic: Claude names songs -> Spotify Search resolves
/// them -> the user's Spotify app plays them (Premium required). Karaoke pairs an
/// instrumental version with LRCLIB lyrics.
@MainActor
final class PersonalizeEngine: ObservableObject {

    // messages (verbatim from the spec)
    static let premiumMessage = "I apologize, but you need Spotify premium to access this feature."
    static let initMessage = "I apologize, but you must first initialize the personalized music feature."
    static let chooseMessage = "I apologize, but you must first choose a vibe, artist, playlist, or song to play"
    static let songFailMessage = "I apologize, but we couldn’t find the lyrics or instrumental version of that song."
    static let playlistFailMessage = "I apologize, but we couldn’t find any song within your playlist that has both an instrumental version and lyrics."

    @Published var mode: PersonalizeMode? = nil
    @Published var value: String = ""
    @Published var currentTrack: SpotifyTrack? = nil
    @Published var isPlaying = false
    @Published var busy = false
    @Published var message: String? = nil
    @Published var positionMs = 0
    @Published var durationMs = 0
    @Published var playlistName: String? = nil
    @Published var playlistIndex = 0
    @Published var playlistCount = 0

    // karaoke
    @Published var karaoke: KaraokePackage? = nil
    @Published var karaokeMessage: String? = nil
    @Published var karaokeBusy = false

    /// Which system currently owns the speakers.
    @Published var audioSource: AudioSource = .suno

    let spotify: SpotifyService
    let claude: ClaudeService
    let suno: SunoPlayer
    let hub: SignalHub

    private var history: Set<String> = []
    private var karaokeTried: Set<String> = []
    private var playlistTracks: [SpotifyTrack] = []
    private var deviceID: String? = nil
    private var poller: AnyCancellable?
    private var lastPos = 0

    var initialized: Bool { claude.keySet && spotify.connected && spotify.premium }

    init(hub: SignalHub, suno: SunoPlayer, spotify: SpotifyService, claude: ClaudeService) {
        self.hub = hub; self.suno = suno; self.spotify = spotify; self.claude = claude
        poller = Timer.publish(every: 1.0, on: .main, in: .common).autoconnect().sink { [weak self] _ in
            Task { await self?.poll() }
        }
    }

    func claimAudio(_ source: AudioSource) {
        guard audioSource != source else { return }
        audioSource = source
        if source == .spotify {
            suno.pause()
        } else {
            Task { await spotify.pause() }
            isPlaying = false
        }
    }

    private var stressLabel: StressLabel { hub.stressLabel ?? .mild }

    // MARK: - choosing / transport

    /// The Confirm button under a tab.
    func confirm(mode: PersonalizeMode, value: String) async {
        guard initialized else { message = PersonalizeEngine.initMessage; return }
        let changed = mode != self.mode || value != self.value
        self.mode = mode; self.value = value
        if changed { history = []; karaokeTried = []; playlistTracks = []; playlistName = nil }
        if karaoke != nil || karaokeMessage != nil {           // karaoke open -> feed karaoke instead
            await fetchKaraoke(current: nil)
            return
        }
        await request(direction: 0)
    }

    /// « / » — direction -1 / +1; 0 = initial confirm.
    func skip(_ direction: Int) async {
        if karaoke != nil { await fetchKaraoke(current: nil); return }
        await request(direction: direction)
    }

    private func request(direction: Int) async {
        guard let mode else { message = PersonalizeEngine.chooseMessage; return }
        busy = true; message = nil
        defer { busy = false }
        switch mode {
        case .playlist:
            if playlistTracks.isEmpty {
                guard let pl = await spotify.playlistTracks(named: value) else {
                    message = "Couldn't find a playlist with that name in your library."
                    return
                }
                playlistTracks = pl.tracks; playlistName = pl.name
                playlistIndex = 0; playlistCount = pl.tracks.count
            } else if direction != 0 {
                playlistIndex = ((playlistIndex + direction) % playlistCount + playlistCount) % playlistCount
            }
            await play(track: playlistTracks[playlistIndex])
        case .song where direction == 0:
            guard let track = await spotify.searchTrack(value, limit: 1).first else {
                message = "Couldn't find that song on Spotify."
                return
            }
            await play(track: track)
        default:
            do {
                let suggestions = try await claude.pickSongs(mode: mode, value: value,
                                                             label: stressLabel,
                                                             exclude: Array(history))
                var fallback: SpotifyTrack? = nil
                for s in suggestions.shuffled() {
                    guard let track = await spotify.search(artist: s.artist, title: s.title) else { continue }
                    let key = "\(track.artist) — \(track.name)".lowercased()
                    if history.contains(key) { fallback = fallback ?? track; continue }
                    await play(track: track)
                    return
                }
                if let fallback { await play(track: fallback) }
                else { message = "Claude couldn't find a matching song — try different wording." }
            } catch ClaudeService.ClaudeError.noKey {
                message = PersonalizeEngine.initMessage
            } catch {
                message = "Claude request failed: \(error.localizedDescription)"
            }
        }
    }

    func play(track: SpotifyTrack) async {
        claimAudio(.spotify)
        if deviceID == nil { deviceID = await spotify.activeDeviceID() }
        guard deviceID != nil else {
            message = "Open the Spotify app once, then try again."
            return
        }
        let ok = await spotify.play(uri: track.uri, deviceID: deviceID)
        if ok {
            currentTrack = track
            durationMs = track.durationMs
            positionMs = 0
            isPlaying = true
            history.insert("\(track.artist) — \(track.name)".lowercased())
        } else {
            deviceID = nil
            message = "Playback failed — make sure the Spotify app is open."
        }
    }

    func togglePlay() async {
        guard currentTrack != nil else { return }
        if isPlaying { await spotify.pause(); isPlaying = false }     // pausing also pauses lyrics
        else { claimAudio(.spotify); await spotify.resume(); isPlaying = true }
    }

    func seek(toMs ms: Int) async {
        await spotify.seek(ms: ms)
        positionMs = ms
    }

    private func poll() async {
        guard audioSource == .spotify, currentTrack != nil else { return }
        guard let st = await spotify.playerState() else { return }
        positionMs = st.0
        if st.1 > 0 { durationMs = st.1 }
        isPlaying = st.2
        // track finished -> continue the loop (karaoke keeps fetching karaoke packages)
        if !st.2 && st.0 == 0 && lastPos > durationMs - 3000 && durationMs > 0 {
            lastPos = 0
            await skip(+1)
            return
        }
        if st.2 { lastPos = st.0 }
    }

    // MARK: - karaoke

    /// Entered from the Relief card. Gating messages exactly per spec.
    func startKaraoke() async {
        karaokeMessage = nil; karaoke = nil
        guard initialized else { karaokeMessage = PersonalizeEngine.initMessage; return }
        guard mode != nil else { karaokeMessage = PersonalizeEngine.chooseMessage; return }
        // a song already playing? fetch THAT song's instrumental + lyrics
        let current = (audioSource == .spotify) ? currentTrack : nil
        await fetchKaraoke(current: current)
    }

    func stopKaraoke() {
        karaoke = nil; karaokeMessage = nil; karaokeBusy = false
    }

    private func fetchKaraoke(current: SpotifyTrack?) async {
        guard let mode else { karaokeMessage = PersonalizeEngine.chooseMessage; return }
        karaokeBusy = true; karaokeMessage = nil
        defer { karaokeBusy = false }

        if let current {
            if let pkg = await package(for: current) {
                karaokeTried.insert(key(current))
                await present(pkg)
                return
            }
            if mode == .song || mode == .playlist {
                // the spec's message for a failing CURRENT song is the song one, in every mode
                karaokeMessage = PersonalizeEngine.songFailMessage
                return
            }
            // vibe / artist: fall through to find another in-category song that works
        }

        switch mode {
        case .song:
            // the exact favorite song plays first; afterwards the loop continues with
            // other songs by that artist (Claude round below), like « / » in song mode
            let exactKey = "exact:" + value.lowercased()
            if !karaokeTried.contains(exactKey) {
                karaokeTried.insert(exactKey)
                guard let track = await spotify.searchTrack(value, limit: 1).first,
                      let pkg = await package(for: track) else {
                    karaokeMessage = PersonalizeEngine.songFailMessage
                    return
                }
                karaokeTried.insert(key(track))
                await present(pkg)
                return
            }
            await claudeKaraokeRound()
        case .playlist:
            if playlistTracks.isEmpty {
                if let pl = await spotify.playlistTracks(named: value) {
                    playlistTracks = pl.tracks; playlistName = pl.name; playlistCount = pl.tracks.count
                }
            }
            let start = playlistTracks.isEmpty ? 0 : min(max(0, playlistIndex), playlistTracks.count - 1)
            let rotated = playlistTracks.isEmpty ? [] :
                Array(playlistTracks[start...] + playlistTracks[..<start])
            var attempted = false
            for track in rotated.prefix(25) where !karaokeTried.contains(key(track)) {
                attempted = true
                karaokeTried.insert(key(track))
                if let pkg = await package(for: track) { await present(pkg); return }
            }
            if !attempted { karaokeTried = [] }        // whole window tried -> a retry starts over
            karaokeMessage = PersonalizeEngine.playlistFailMessage
        case .vibe, .artist:
            await claudeKaraokeRound()
        }
    }

    /// Keep asking Claude for in-category songs until one has BOTH an instrumental
    /// version and lyrics (vibe/artist always; song mode = other songs by the artist).
    private func claudeKaraokeRound() async {
        guard let mode else { return }
        for _ in 0..<3 {
            guard let suggestions = try? await claude.pickSongs(mode: mode, value: value,
                                                                label: stressLabel,
                                                                exclude: Array(karaokeTried)) else { break }
            for s in suggestions {
                let k = "\(s.artist) — \(s.title)".lowercased()
                if karaokeTried.contains(k) { continue }
                karaokeTried.insert(k)
                guard let track = await spotify.search(artist: s.artist, title: s.title) else { continue }
                if let pkg = await package(for: track) { await present(pkg); return }
            }
        }
        karaokeMessage = PersonalizeEngine.songFailMessage
    }

    private func key(_ t: SpotifyTrack) -> String { "\(t.artist) — \(t.name)".lowercased() }

    /// Both karaoke halves for one song: LRCLIB lyrics AND a Spotify instrumental version.
    private func package(for track: SpotifyTrack) async -> KaraokePackage? {
        guard let lyrics = await LyricsService.fetch(track: track.name, artist: track.artist,
                                                    durationMs: track.durationMs) else { return nil }
        var candidates: [SpotifyTrack] = []
        for q in ["track:\"\(track.name)\" instrumental",
                  "\(track.name) \(track.artist) instrumental",
                  "\(track.name) \(track.artist) karaoke"] {
            for t in await spotify.searchTrack(q, limit: 5) {
                let n = (t.name + " " + t.artist).lowercased()
                if n.contains("instrumental") || n.contains("karaoke") || n.contains("backing") {
                    if !candidates.contains(t) { candidates.append(t) }
                }
            }
        }
        guard !candidates.isEmpty else { return nil }
        let idx = await claude.pickInstrumental(of: track.name, by: track.artist, candidates: candidates)
        guard idx >= 0 else { return nil }
        return KaraokePackage(instrumental: candidates[idx], lyrics: lyrics,
                              sourceName: track.name, sourceArtist: track.artist)
    }

    /// Play the instrumental — the track name and timeline switch to the instrumental's data.
    private func present(_ pkg: KaraokePackage) async {
        karaoke = pkg
        await play(track: pkg.instrumental)
    }
}
