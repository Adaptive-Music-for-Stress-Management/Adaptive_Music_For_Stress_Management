import Foundation
import Combine
import AVFoundation

enum PersonalizeMode: String, CaseIterable, Identifiable {
    case vibe = "Vibe", artist = "Artist", playlist = "Playlist", song = "Song"
    var id: String { rawValue }
    var placeholder: String { "Enter your \(rawValue.lowercased()) preference" }
}
enum AudioSource { case suno, spotify, karaoke }

@MainActor
final class PersonalizeEngine: ObservableObject {
    static let premiumMessage = "Spotify Premium is required."
    static let initMessage = "Enter your Anthropic key and connect Spotify first."
    static let chooseMessage = "Choose a vibe, artist, playlist or song."
    @Published var mode: PersonalizeMode?
    @Published var value = ""
    @Published var currentTrack: SpotifyTrack?
    @Published var isPlaying = false
    @Published var busy = false
    @Published var message: String?
    @Published var positionMs = 0
    @Published var durationMs = 0
    @Published var playlistName: String?
    @Published var playlistIndex = 0
    @Published var playlistCount = 0
    @Published var playlists: [SpotifyPlaylist] = []
    @Published var playlistsLoading = false
    @Published var selectedPlaylistID: String?
    @Published var karaoke: CatalogSong?
    @Published var karaokeMessage: String?
    @Published var karaokeBusy = false
    @Published var karaokePlaying = false
    @Published var audioSource: AudioSource = .suno
    let spotify: SpotifyService
    let claude: ClaudeService
    let suno: SunoPlayer
    let hub: SignalHub
    private var history = Set<String>()
    private var typedPreference = ""
    private var selectedPlaylist: SpotifyPlaylist?
    private var deviceID: String?
    private var poller: AnyCancellable?
    private var lastPos = 0
    private var polling = false
    private var stressLabelSeen: StressLabel?
    private var lastAutomatic = Date.distantPast
    private var generation = 0
    private var audioHandoffID = 0
    private var karaokePlayer: AVAudioPlayer?
    var initialized: Bool { claude.keySet && spotify.connected && spotify.premium }
    var playAlongBlocked: Bool { audioSource == .spotify }
    private var stressLabel: StressLabel { hub.stressLabel ?? .mild }

    init(hub: SignalHub, suno: SunoPlayer, spotify: SpotifyService, claude: ClaudeService) {
        self.hub = hub; self.suno = suno; self.spotify = spotify; self.claude = claude
        poller = Timer.publish(every: 1, on: .main, in: .common).autoconnect().sink { [weak self] _ in
            Task { await self?.poll() }
        }
    }
    private func takeAudio(_ source: AudioSource) async -> Bool {
        audioHandoffID &+= 1
        let handoff = audioHandoffID
        audioSource = source
        InstrumentEngine.spotifyOwnsAudio = source == .spotify
        InstrumentEngine.stopAllInstruments()
        karaokePlayer?.stop(); karaokePlaying = false
        if source != .suno { await suno.pauseForAudioHandoff() }
        if source != .spotify {
            guard await spotify.pause() else {
                if handoff == audioHandoffID { audioSource = .spotify; InstrumentEngine.spotifyOwnsAudio = true }
                message = "Could not pause Spotify. Pause it in Spotify before starting local audio."
                return false
            }
            isPlaying = false
        }
        return handoff == audioHandoffID && source == audioSource
    }
    func toggleSuno() async {
        if audioSource == .suno { suno.togglePlay() }
        else if await takeAudio(.suno) { suno.play() }
    }
    func skipSuno() async {
        if audioSource != .suno, !(await takeAudio(.suno)) { return }
        suno.skip()
    }
    func stopSessionAudio() async {
        generation &+= 1; audioHandoffID &+= 1
        suno.stopAll(); karaokePlayer?.stop(); karaokePlayer = nil
        InstrumentEngine.stopAllInstruments()
        await spotify.pause()
        isPlaying = false; karaokePlaying = false; currentTrack = nil
        positionMs = 0; durationMs = 0; lastPos = 0
        karaoke = nil; karaokeMessage = nil
    }
    func disconnectSpotify() async {
        // Cancel credentials immediately, then use only the captured token to pause remotely.
        generation &+= 1; audioHandoffID &+= 1
        spotify.disconnect()
        currentTrack = nil; isPlaying = false; deviceID = nil
        positionMs = 0; durationMs = 0; lastPos = 0
        history = []; playlists = []; selectedPlaylist = nil; selectedPlaylistID = nil
        playlistName = nil; playlistIndex = 0; playlistCount = 0
        mode = nil; value = ""; typedPreference = ""; message = nil; stressLabelSeen = nil
        if audioSource == .spotify { audioSource = .suno }
        InstrumentEngine.spotifyOwnsAudio = false
    }
    func loadPlaylists() async {
        guard spotify.connected, !playlistsLoading else { return }
        let revision = generation
        playlistsLoading = true
        defer { playlistsLoading = false }
        let result = await spotify.playlists()
        if revision == generation { playlists = result }
    }
    func selectPlaylist(_ playlist: SpotifyPlaylist) async {
        guard !busy, initialized else { return }
        mode = .playlist; value = "" // The playlist name must never become an AI preference.
        selectedPlaylist = playlist; selectedPlaylistID = playlist.id
        playlistName = playlist.name; playlistIndex = 0; playlistCount = playlist.trackCount
        history = []; stressLabelSeen = stressLabel
        await request(direction: 0)
    }
    func beginNewTextPreference() { message = nil; selectedPlaylistID = nil }
    func confirm(mode: PersonalizeMode, value: String) async {
        guard !busy, initialized, mode != .playlist else { return }
        self.mode = mode; self.value = String(value.prefix(500)); typedPreference = self.value
        selectedPlaylist = nil; selectedPlaylistID = nil; playlistName = nil
        playlistIndex = 0; playlistCount = 0; history = []; stressLabelSeen = stressLabel
        await request(direction: 0)
    }
    func skip(_ direction: Int) async { await request(direction: direction) }

    private func request(direction: Int, adaptToStress: Bool = false) async {
        guard !busy, !karaokeBusy, initialized, let mode else { return }
        let revision = generation
        busy = true; message = nil
        defer { busy = false }
        do {
            var chosen: SpotifyTrack?
            if mode == .playlist, let playlist = selectedPlaylist, playlist.trackCount > 0 {
                if adaptToStress {
                    // Suggestions first; membership matching remains local.
                    let suggestions = try await claude.pickSongs(mode: .vibe, value: typedPreference,
                                                                label: stressLabel, score: hub.stress)
                    guard revision == generation else { return }
                    let candidates = await spotify.playlistStressCandidates(
                        playlistID: playlist.id, count: playlist.trackCount, around: playlistIndex)
                    guard revision == generation else { return }
                    for suggestion in suggestions {
                        if let candidate = candidates.first(where: {
                            SpotifyService.matches(artist: suggestion.artist, title: suggestion.title, track: $0.track)
                        }) {
                            chosen = candidate.track; playlistIndex = candidate.position; break
                        }
                    }
                } else {
                    playlistIndex = (playlistIndex + direction + playlist.trackCount) % playlist.trackCount
                    chosen = await spotify.playlistTrack(playlistID: playlist.id, at: playlistIndex)
                }
            } else {
                var suggestions: [ClaudeService.Suggestion] = []
                do {
                    suggestions = try await claude.pickSongs(mode: mode, value: value,
                                                             label: stressLabel, score: hub.stress)
                } catch {
                    // Keep artist requests useful even when Claude returns an
                    // invalid/unknown artist response; Spotify remains the
                    // deterministic source of truth for the artist credit.
                    if mode != .artist { throw error }
                }
                guard revision == generation else { return }
                for suggestion in suggestions {
                    guard let track = await spotify.search(artist: suggestion.artist, title: suggestion.title) else { continue }
                    guard revision == generation else { return }
                    if !history.contains(track.uri) { chosen = track; break }
                }
                // If Claude cannot name a song for an uncommon or stylized
                // artist, search Spotify with the original typed artist and
                // keep the same deterministic artist-credit check.
                if chosen == nil, mode == .artist {
                    let fallback = await spotify.searchArtistTrack(artist: typedPreference)
                    guard revision == generation else { return }
                    if let fallback, !history.contains(fallback.uri) { chosen = fallback }
                }
            }
            guard revision == generation else { return }
            if let chosen { await play(track: chosen) }
            else { message = "No reliable matching song found. Your current song will continue." }
        } catch {
            if revision == generation { message = (error as? ClaudeService.ClaudeError)?.localizedDescription ?? "Song request failed." }
        }
    }
    func play(track: SpotifyTrack) async {
        guard track.imageURL != nil else { message = "This track has no artwork available."; return }
        guard await takeAudio(.spotify) else { return }
        let handoff = audioHandoffID
        if deviceID == nil { deviceID = await spotify.activeDeviceID() }
        guard handoff == audioHandoffID, deviceID != nil else { return }
        // Metadata and artwork are visible before playback begins.
        currentTrack = track
        let ok = await spotify.play(uri: track.uri, deviceID: deviceID)
        guard handoff == audioHandoffID else { if ok { await spotify.pause() }; return }
        if ok {
            durationMs = track.durationMs; positionMs = 0; isPlaying = true
            history.insert(track.uri)
        } else { deviceID = nil; message = "Open Spotify and try playback again." }
    }
    func togglePlay() async {
        guard let track = currentTrack else { return }
        if audioSource == .spotify && isPlaying {
            if await spotify.pause() { isPlaying = false }
        } else { await play(track: track) }
    }
    func seek(toMs ms: Int) async { await spotify.seek(ms: ms); positionMs = ms }

    private func poll() async {
        if let player = karaokePlayer { karaokePlaying = player.isPlaying }
        guard !polling, audioSource == .spotify, currentTrack != nil else { return }
        polling = true
        defer { polling = false }
        let revision = generation
        guard let state = await spotify.playerState(), revision == generation else { return }
        if let track = state.3 { currentTrack = track }
        positionMs = state.0; durationMs = state.1; isPlaying = state.2
        if let label = hub.stressLabel, label != stressLabelSeen, !busy, !claude.busy,
           Date().timeIntervalSince(lastAutomatic) >= 10 {
            stressLabelSeen = label; lastAutomatic = Date()
            await request(direction: 0, adaptToStress: true)
        }
        if !state.2 && state.0 == 0 && lastPos > durationMs - 3000 && durationMs > 0 {
            lastPos = 0; await skip(1)
        } else if state.2 { lastPos = state.0 }
    }
    func startKaraoke() async {
        guard !karaokeBusy else { return }
        generation &+= 1 // In-flight Spotify recommendations cannot reclaim playback.
        let revision = generation
        karaokeBusy = true; karaokeMessage = nil
        defer { karaokeBusy = false }
        guard let song = KaraokeCatalog.load().first, let url = song.recordingURL else {
            karaokeMessage = "The bundled karaoke recording could not be found."; return
        }
        do {
            guard await takeAudio(.karaoke), revision == generation else {
                if revision == generation { karaokeMessage = "Pause Spotify before starting karaoke." }
                return
            }
            let player = try AVAudioPlayer(contentsOf: url)
            karaokePlayer = player; karaoke = song; suno.songName = song.title; suno.bucket = nil
            player.prepareToPlay(); karaokePlaying = player.play()
        } catch {
            if revision == generation { karaokeMessage = "Could not load karaoke audio." }
        }
    }
    func toggleKaraoke() {
        guard audioSource == .karaoke, let player = karaokePlayer else { return }
        if player.isPlaying { player.pause(); karaokePlaying = false }
        else { karaokePlaying = player.play() }
    }
    func stopKaraoke() {
        generation &+= 1
        karaokePlayer?.stop(); karaokePlayer = nil
        karaoke = nil; karaokeMessage = nil; karaokePlaying = false
    }
}
