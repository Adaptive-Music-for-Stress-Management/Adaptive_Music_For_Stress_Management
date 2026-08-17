import SwiftUI

/// Personalize modal: the SUNO AI player (song name, adjustable timeline, « ▶ » ),
/// then the Spotify + Claude section — Anthropic key + Confirm, Connect Spotify
/// (Premium required), and the Vibe / Artist / Playlist / Song tabs.
struct PersonalizeCard: View {
    @EnvironmentObject var hub: SignalHub
    @EnvironmentObject var suno: SunoPlayer
    @EnvironmentObject var spotify: SpotifyService
    @EnvironmentObject var claude: ClaudeService
    @EnvironmentObject var engine: PersonalizeEngine

    @State private var keyField = ""
    @State private var tab: PersonalizeMode? = nil
    @State private var prefField = ""
    @State private var sunoScrub: Double? = nil
    @State private var spScrub: Double? = nil

    var body: some View {
        Card {
            CardTitle("Personalize")
            sunoPlayer
            Divider().background(Theme.line)
            if engine.initialized { spotifyFull } else { spotifySetup }
        }
    }

    // MARK: - SUNO player

    private var sunoPlayer: some View {
        VStack(spacing: 8) {
            Text(suno.songName ?? "no song loaded")
                .font(.system(size: 14, weight: .semibold))
                .frame(maxWidth: .infinity, alignment: .leading)
                .lineLimit(1)
            timeline(current: sunoScrub ?? suno.currentTime, total: suno.duration,
                     scrub: $sunoScrub) { t in
                suno.seek(to: t)
            }
            HStack(spacing: 22) {
                transportButton("chevron.backward.2") { Task { await engine.skipSuno() } }
                transportButton(suno.playing && engine.audioSource == .suno ? "pause.fill" : "play.fill",
                                big: true) {
                    Task { await engine.toggleSuno() }
                }
                transportButton("chevron.forward.2") { Task { await engine.skipSuno() } }
            }
            .frame(maxWidth: .infinity)
            if let bucket = suno.bucket {
                Text("\(bucket) BPM folder")
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundStyle(Theme.faint)
            }
        }
        .padding(12)
        .background(Theme.panel2, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.line))
    }

    // MARK: - Spotify setup steps

    private var spotifySetup: some View {
        VStack(spacing: 10) {
            if !claude.keySet {
                HStack(spacing: 8) {
                    SecureField("Anthropic API key (sk-ant-…)", text: $keyField)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12.5, design: .monospaced))
                        .padding(10)
                        .background(Color.white.opacity(0.03), in: RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.line))
                    Button("Confirm") {
                        claude.apiKey = keyField.trimmingCharacters(in: .whitespaces)
                        keyField = ""
                    }
                    .buttonStyle(.bordered)
                }
                Text("Step 1 — enter your Anthropic API key.")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Theme.muted)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else if !spotify.connected {
                connectButton
                Text(SpotifyService.clientID.isEmpty
                     ? "Add your Spotify Client ID to Info.plist (SpotifyClientID) first."
                     : "Step 2 — connect your Spotify account.")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(SpotifyService.clientID.isEmpty ? StressLabel.stressed.color : Theme.muted)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else if !spotify.premium {
                Text(PersonalizeEngine.premiumMessage)
                    .font(.system(size: 12.5))
                    .foregroundStyle(StressLabel.stressed.color)
                Button("Re-check account") { Task { await spotify.checkPremium() } }
                    .font(.system(size: 12))
            }
        }
    }

    private var connectButton: some View {
        Button {
            spotify.connect()
        } label: {
            Text("Connect Spotify")
                .font(.system(size: 13, weight: .semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 11)
                .overlay(RoundedRectangle(cornerRadius: 9).stroke(Theme.spotifyGreen))
                .foregroundStyle(Theme.spotifyGreen)
        }
        .buttonStyle(.plain)
        .disabled(SpotifyService.clientID.isEmpty)
    }

    // MARK: - the full personalization UI

    private var spotifyFull: some View {
        VStack(spacing: 10) {
            if let track = engine.currentTrack {
                VStack(spacing: 8) {
                    Text("\(track.name) — \(track.artist)")
                        .font(.system(size: 14, weight: .semibold))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .lineLimit(1)
                    timeline(current: spScrub ?? Double(engine.positionMs) / 1000.0,
                             total: Double(engine.durationMs) / 1000.0,
                             scrub: $spScrub) { t in
                        Task { await engine.seek(toMs: Int(t * 1000)) }
                    }
                    HStack(spacing: 22) {
                        transportButton("chevron.backward.2") { Task { await engine.skip(-1) } }
                        transportButton(engine.isPlaying ? "pause.fill" : "play.fill", big: true) {
                            Task { await engine.togglePlay() }
                        }
                        transportButton("chevron.forward.2") { Task { await engine.skip(+1) } }
                    }
                    .frame(maxWidth: .infinity)
                    if let name = engine.playlistName, engine.mode == .playlist {
                        Text("playlist · \(name) · \(engine.playlistIndex + 1)/\(engine.playlistCount)")
                            .font(.system(size: 9.5, design: .monospaced))
                            .foregroundStyle(Theme.faint)
                    }
                }
                .padding(12)
                .background(Theme.panel2, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.line))
            }

            HStack(spacing: 6) {
                ForEach(PersonalizeMode.allCases) { mode in
                    Button(mode.rawValue) {
                        withAnimation { tab = mode }
                        prefField = ""
                        if mode == .playlist {
                            Task { await engine.loadPlaylists() }
                        } else {
                            engine.beginNewTextPreference()
                        }
                    }
                    .font(.system(size: 12, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 9)
                    .overlay(RoundedRectangle(cornerRadius: 8)
                        .stroke(tab == mode ? Theme.accent : Theme.line))
                    .foregroundStyle(tab == mode ? Theme.accent : Theme.muted)
                    .buttonStyle(.plain)
                }
            }

            if let tab {
                if tab == .playlist {
                    playlistPicker
                } else {
                    HStack(spacing: 8) {
                        TextField(tab.placeholder, text: $prefField)
                            .textFieldStyle(.plain)
                            .font(.system(size: 12.5))
                            .padding(10)
                            .background(Color.white.opacity(0.03), in: RoundedRectangle(cornerRadius: 8))
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.line))
                            .autocorrectionDisabled()
                            .onChange(of: prefField) { _, _ in
                                engine.beginNewTextPreference()
                            }
                        Button("Confirm") {
                            let v = prefField.trimmingCharacters(in: .whitespaces)
                            guard !v.isEmpty else { return }
                            Task { await engine.confirm(mode: tab, value: v) }
                        }
                        .buttonStyle(.bordered)
                    }
                    .transition(.opacity)
                }
            }

            if engine.busy && engine.mode != .playlist {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("asking Claude…")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Theme.muted)
                }
                .transition(.opacity)
            }
            if let msg = engine.message {
                Text(msg)
                    .font(.system(size: 11.5))
                    .foregroundStyle(StressLabel.stressed.color)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .animation(.easeOut(duration: 0.25), value: engine.busy)
    }

    private var playlistPicker: some View {
        Group {
            if engine.playlistsLoading {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("loading your playlists…")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Theme.muted)
                }
            } else if engine.playlists.isEmpty {
                Text("No playlists were found in this Spotify account.")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Theme.muted)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(engine.playlists) { playlist in
                            Button {
                                Task { await engine.selectPlaylist(playlist) }
                            } label: {
                                Text(playlist.name)
                                    .font(.system(size: 12.5, weight: .medium))
                                    .foregroundStyle(Theme.ink)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 9)
                                    .background(
                                        engine.selectedPlaylistID == playlist.id
                                            ? Theme.spotifyGreen.opacity(0.10)
                                            : Theme.panel2,
                                        in: RoundedRectangle(cornerRadius: 8)
                                    )
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 8)
                                            .stroke(engine.selectedPlaylistID == playlist.id
                                                    ? Theme.spotifyGreen : Theme.line)
                                    )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .frame(maxHeight: 185)
            }
        }
        .transition(.opacity)
    }

    // MARK: - shared bits

    private func timeline(current: Double, total: Double, scrub: Binding<Double?>,
                          onSeek: @escaping (Double) -> Void) -> some View {
        HStack(spacing: 8) {
            Text(Self.fmt(current))
                .font(.system(size: 10.5, design: .monospaced)).foregroundStyle(Theme.muted)
            Slider(value: Binding(
                get: { total > 0 ? (scrub.wrappedValue ?? current) / total : 0 },
                set: { scrub.wrappedValue = $0 * total }
            ), in: 0...1) { editing in
                if !editing, let t = scrub.wrappedValue {
                    onSeek(t)
                    scrub.wrappedValue = nil
                }
            }
            .tint(Theme.accent)
            Text(Self.fmt(total))
                .font(.system(size: 10.5, design: .monospaced)).foregroundStyle(Theme.muted)
        }
    }

    private func transportButton(_ icon: String, big: Bool = false,
                                 action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: big ? 17 : 14, weight: .semibold))
                .frame(width: big ? 46 : 38, height: big ? 46 : 38)
                .background(Theme.panel, in: Circle())
                .overlay(Circle().stroke(Theme.line))
                .foregroundStyle(Theme.ink)
        }
        .buttonStyle(.plain)
    }

    static func fmt(_ s: Double) -> String {
        guard s.isFinite, s >= 0 else { return "00:00" }
        return String(format: "%02d:%02d", Int(s) / 60, Int(s) % 60)
    }
}
