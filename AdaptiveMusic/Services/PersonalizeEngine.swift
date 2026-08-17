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
    @Published var playlists: [SpotifyPlaylist] = []
    @Published var playlistsLoading = false
    @Published var selectedPlaylistID: String? = nil

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
    private var selectedPlaylist: SpotifyPlaylist? = nil
    private var seedArtist: String? = nil
    private var deviceID: String? = nil
    private var poller: AnyCancellable?
    private var lastPos = 0
    private var stressLabelSeen: StressLabel? = nil
    private var audioHandoffID = 0

    var initialized: Bool { claude.keySet && spotify.connected && spotify.premium }

    init(hub: SignalHub, suno: SunoPlayer, spotify: SpotifyService, claude: ClaudeService) {
        self.hub = hub; self.suno = suno; self.spotify = spotify; self.claude = claude
        poller = Timer.publish(every: 1.0, on: .main, in: .common).autoconnect().sink { [weak self] _ in
            Task { await self?.poll() }
        }
    }

    private func beginAudioHandoff(to source: AudioSource) -> Int {
        audioHandoffID &+= 1
        audioSource = source
        if source == .spotify { isPlaying = false }
        return audioHandoffID
    }

    private func ownsAudioHandoff(_ id: Int, source: AudioSource) -> Bool {
        id == audioHandoffID && audioSource == source
    }

    /// Spotify's remote pause is acknowledged before an AI track starts. This
    /// avoids overlap between the Connect player and the local AVAudioEngine.
    private func moveToSuno() async -> Bool {
        let id = beginAudioHandoff(to: .suno)
        await spotify.pause()
        guard ownsAudioHandoff(id, source: .suno) else { return false }
        isPlaying = false
        return true
    }

    func toggleSuno() async {
        if audioSource == .suno {
            suno.togglePlay()
        } else if await moveToSuno() {
            suno.play()
        }
    }

    func skipSuno() async {
        if audioSource != .suno {
            guard await moveToSuno() else { return }
        }
        suno.skip()
    }

    private var stressLabel: StressLabel { hub.stressLabel ?? .mild }

    // MARK: - choosing / transport

    /// Fetch picker metadata only; playlist tracks remain on Spotify until needed.
    func loadPlaylists() async {
        guard initialized, !playlistsLoading else { return }
        playlistsLoading = true
        defer { playlistsLoading = false }
        playlists = await spotify.playlists()
    }

    /// The user chose a visible playlist button rather than typing an ambiguous name.
    func selectPlaylist(_ playlist: SpotifyPlaylist) async {
        guard initialized else { message = PersonalizeEngine.initMessage; return }
        let changed = mode != .playlist || selectedPlaylist?.id != playlist.id
        mode = .playlist
        value = playlist.name
        stressLabelSeen = stressLabel
        selectedPlaylist = playlist
        selectedPlaylistID = playlist.id
        playlistName = playlist.name
        playlistIndex = 0
        playlistCount = playlist.trackCount
        if changed { resetChoiceState(keepingPlaylist: true) }
        if karaoke != nil || karaokeMessage != nil {
            await fetchKaraoke(current: nil)
        } else {
            await request(direction: 0)
        }
    }

    /// Clearing the picker presentation must not leave a stale playlist error
    /// or selected-button effect behind while a new text preference is entered.
    func beginNewTextPreference() {
        message = nil
        selectedPlaylistID = nil
    }

    /// The Confirm button under a tab.
    func confirm(mode: PersonalizeMode, value: String) async {
        guard initialized else { message = PersonalizeEngine.initMessage; return }
        let changed = mode != self.mode || value != self.value
        self.mode = mode; self.value = value
        stressLabelSeen = stressLabel
        if mode != .playlist {
            selectedPlaylist = nil
            selectedPlaylistID = nil
            playlistName = nil
            playlistIndex = 0
            playlistCount = 0
        }
        if changed { resetChoiceState(keepingPlaylist: mode == .playlist) }
        if karaoke != nil || karaokeMessage != nil {           // karaoke open -> feed karaoke instead
            await fetchKaraoke(current: nil)
            return
        }
        await request(direction: 0)
    }

    /// « / » — direction -1 / +1; 0 = initial confirm.
    func skip(_ direction: Int) async {
        if karaoke != nil || karaokeMessage != nil {
            await fetchKaraoke(current: nil, direction: direction)
            return
        }
        await request(direction: direction)
    }

    private func request(direction: Int, adaptToStress: Bool = false) async {
        guard let mode else { message = PersonalizeEngine.chooseMessage; return }
        busy = true; message = nil
        defer { busy = false }
        switch mode {
        case .playlist:
            guard let track = await playlistTrack(direction: direction, adaptToStress: adaptToStress) else {
                if message == nil { message = "That playlist song is unavailable to play." }
                return
            }
            await play(track: track)
        case .song where direction == 0 && !adaptToStress:
            guard let track = await spotify.searchTrack(value, limit: 10)
                .first(where: { matchesPersonalization(.song, value: value, track: $0) }) else {
                message = "Couldn't find that song on Spotify."
                return
            }
            seedArtist = track.artist
            await play(track: track)
        default:
            do {
                let suggestionMode: PersonalizeMode = mode == .song ? .artist : mode
                let suggestionValue = mode == .song ? (seedArtist ?? value) : value
                let suggestions = try await claude.pickSongs(mode: suggestionMode, value: suggestionValue,
                                                             label: stressLabel,
                                                             exclude: Array(history))
                var fallback: SpotifyTrack? = nil
                for s in suggestions.shuffled() {
                    guard let track = await spotify.search(artist: s.artist, title: s.title) else { continue }
                    guard matchesPersonalization(.artist, value: s.artist, track: track) else { continue }
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

    private func resetChoiceState(keepingPlaylist: Bool = false) {
        history = []
        karaokeTried = []
        seedArtist = nil
        if !keepingPlaylist {
            selectedPlaylist = nil
            selectedPlaylistID = nil
            playlistName = nil
            playlistIndex = 0
            playlistCount = 0
        }
    }

    /// Resolves one exact sequential item, or asks Claude to choose from one
    /// bounded real-track sample when the stress label changes.
    private func playlistTrack(direction: Int, adaptToStress: Bool) async -> SpotifyTrack? {
        guard let playlist = selectedPlaylist else {
            message = "Choose a playlist first."
            return nil
        }
        guard playlist.trackCount > 0 else {
            message = "That playlist has no playable songs."
            return nil
        }
        playlistCount = playlist.trackCount
        if adaptToStress {
            let candidates = await spotify.playlistStressCandidates(
                playlistID: playlist.id, count: playlist.trackCount, around: playlistIndex)
            guard let position = await claude.pickPlaylistPosition(candidates: candidates, label: stressLabel),
                  let candidate = candidates.first(where: { $0.position == position }) else {
                message = "Couldn't choose a suitable song from that playlist — try again."
                return nil
            }
            playlistIndex = position
            return candidate.track
        }
        if direction != 0 {
            playlistIndex = ((playlistIndex + direction) % playlist.trackCount + playlist.trackCount)
                % playlist.trackCount
        }
        return await spotify.playlistTrack(playlistID: playlist.id, at: playlistIndex)
    }

    private func adaptToStressIfNeeded() async {
        guard let latestLabel = hub.stressLabel else { return }
        guard let previousLabel = stressLabelSeen else {
            stressLabelSeen = latestLabel
            return
        }
        guard latestLabel != previousLabel else { return }
        stressLabelSeen = latestLabel
        guard !busy, !karaokeBusy, mode != nil else { return }
        if karaoke != nil {
            await fetchKaraoke(current: nil, adaptToStress: true)
        } else {
            await request(direction: 0, adaptToStress: true)
        }
    }

    private func normalised(_ value: String) -> String {
        let folded = value.folding(options: [.caseInsensitive, .diacriticInsensitive],
                                   locale: .current)
        return folded.components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private func artistsMatch(_ expected: String, _ candidate: String) -> Bool {
        let wanted = normalised(expected)
        let actual = normalised(candidate)
        return !wanted.isEmpty && !actual.isEmpty &&
            (wanted == actual || actual.contains(wanted) || wanted.contains(actual))
    }

    private func matchesPersonalization(_ mode: PersonalizeMode, value: String,
                                        track: SpotifyTrack) -> Bool {
        switch mode {
        case .artist:
            return artistsMatch(value, track.artist)
        case .song:
            let wanted = normalised(value)
            let actual = normalised(track.name)
            if wanted.isEmpty || actual.isEmpty { return false }
            if actual.contains(wanted) { return true }
            return wanted.split(separator: " ").contains {
                $0.count > 1 && actual.contains(String($0))
            }
        case .vibe, .playlist:
            return true
        }
    }

    func play(track: SpotifyTrack, positionMs: Int = 0, autoplay: Bool = true) async {
        let handoffID = beginAudioHandoff(to: .spotify)
        await suno.pauseForAudioHandoff()
        guard ownsAudioHandoff(handoffID, source: .spotify) else { return }
        if deviceID == nil { deviceID = await spotify.activeDeviceID() }
        guard ownsAudioHandoff(handoffID, source: .spotify), deviceID != nil else {
            message = "Open the Spotify app once, then try again."
            return
        }
        let safePosition = max(0, min(positionMs, max(0, track.durationMs - 250)))
        let ok = await spotify.play(uri: track.uri, deviceID: deviceID, positionMs: safePosition)
        guard ownsAudioHandoff(handoffID, source: .spotify) else {
            if ok { await spotify.pause() }
            return
        }
        if ok {
            currentTrack = track
            durationMs = track.durationMs
            self.positionMs = safePosition
            isPlaying = autoplay
            if !autoplay { await spotify.pause() }
            history.insert("\(track.artist) — \(track.name)".lowercased())
        } else {
            deviceID = nil
            message = "Playback failed — make sure the Spotify app is open."
        }
    }

    func togglePlay() async {
        guard currentTrack != nil else { return }
        let wasPlaying = audioSource == .spotify && isPlaying
        let handoffID = beginAudioHandoff(to: .spotify)
        if wasPlaying {
            await spotify.pause()                                    // pausing also pauses lyrics
            if ownsAudioHandoff(handoffID, source: .spotify) { isPlaying = false }
            return
        }
        await suno.pauseForAudioHandoff()
        guard ownsAudioHandoff(handoffID, source: .spotify) else { return }
        await spotify.resume()
        if ownsAudioHandoff(handoffID, source: .spotify) { isPlaying = true }
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
        await adaptToStressIfNeeded()
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

    private func fetchKaraoke(current: SpotifyTrack?, direction: Int = 0,
                              adaptToStress: Bool = false) async {
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
                guard let track = await spotify.searchTrack(value, limit: 10)
                    .first(where: { matchesPersonalization(.song, value: value, track: $0) }),
                      let pkg = await package(for: track) else {
                    karaokeMessage = PersonalizeEngine.songFailMessage
                    return
                }
                seedArtist = track.artist
                karaokeTried.insert(key(track))
                await present(pkg)
                return
            }
            await claudeKaraokeRound()
        case .playlist:
            guard let playlist = selectedPlaylist, playlist.trackCount > 0,
                  let firstTrack = await playlistTrack(direction: direction,
                                                       adaptToStress: adaptToStress) else {
                karaokeMessage = PersonalizeEngine.playlistFailMessage
                return
            }
            // An unavailable instrumental/lyrics pair can require a few tries,
            // but every retry is an exact one-item playlist read, never a preload.
            let positions = (0..<min(25, playlist.trackCount)).map {
                (playlistIndex + $0) % playlist.trackCount
            }
            var attempted = false
            for position in positions {
                let candidate: SpotifyTrack?
                if position == playlistIndex {
                    candidate = firstTrack
                } else {
                    candidate = await spotify.playlistTrack(playlistID: playlist.id, at: position)
                }
                guard let track = candidate else { continue }
                guard !karaokeTried.contains(key(track)) else { continue }
                attempted = true
                karaokeTried.insert(key(track))
                if let pkg = await package(for: track) {
                    playlistIndex = position
                    await present(pkg)
                    return
                }
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
        let suggestionMode: PersonalizeMode = mode == .song ? .artist : mode
        let suggestionValue = mode == .song ? (seedArtist ?? value) : value
        for _ in 0..<3 {
            guard let suggestions = try? await claude.pickSongs(mode: suggestionMode, value: suggestionValue,
                                                                label: stressLabel,
                                                                exclude: Array(karaokeTried)) else { break }
            for s in suggestions {
                let k = "\(s.artist) — \(s.title)".lowercased()
                if karaokeTried.contains(k) { continue }
                karaokeTried.insert(k)
                guard let track = await spotify.search(artist: s.artist, title: s.title) else { continue }
                guard matchesPersonalization(.artist, value: s.artist, track: track) else { continue }
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
                if (n.contains("instrumental") || n.contains("karaoke") || n.contains("backing"))
                    && artistsMatch(track.artist, t.artist) {
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

    /// Keep the original track playing during lookup, then move to the matching
    /// instrumental timestamp once both karaoke resources are ready.
    private func present(_ pkg: KaraokePackage) async {
        let source = currentTrack
        let matchesSource = source?.name == pkg.sourceName && source?.artist == pkg.sourceArtist
        let state = matchesSource ? await spotify.playerState() : nil
        let position = state?.0 ?? 0
        let wasPlaying = state?.2 ?? true
        karaoke = pkg
        await play(track: pkg.instrumental, positionMs: position, autoplay: wasPlaying)
    }
}
