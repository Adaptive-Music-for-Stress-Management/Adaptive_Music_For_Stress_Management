import SwiftUI

struct LandingView: View {
    @EnvironmentObject var account: SupabaseService
    @State private var email = ""
    @State private var password = ""
    @State private var createAccount = false

    var body: some View {
        ScrollView {
            VStack(spacing: 32) {
                VStack(spacing: 8) {
                    Text("ADAPTUNE").font(.system(size: 32, weight: .bold)).tracking(6)
                    Text("Tune your state. Find your calm.").foregroundStyle(Theme.muted)
                }
                .padding(.top, 34)

                VStack(alignment: .leading, spacing: 14) {
                    Text("Music that listens before it plays.")
                        .font(.system(size: 38, weight: .bold))
                    Text("Live heart and brain signals become a personal stress picture, then shape the music around the state you are in.")
                        .foregroundStyle(Theme.muted).lineSpacing(5)
                    Picker("Account", selection: $createAccount) {
                        Text("Log in").tag(false)
                        Text("Create account").tag(true)
                    }
                    .pickerStyle(.segmented)
                    TextField("Email", text: $email)
                        .textInputAutocapitalization(.never).keyboardType(.emailAddress)
                        .portalField()
                    SecureField("Password · at least 6 characters", text: $password)
                        .portalField()
                    Button(account.busy ? "Please wait…" : (createAccount ? "Create account" : "Log in")) {
                        Task {
                            if createAccount { await account.signUp(email: email, password: password) }
                            else { await account.signIn(email: email, password: password) }
                        }
                    }
                    .buttonStyle(PrimaryPortalButton())
                    .disabled(account.busy || email.isEmpty || password.count < 6 || !account.configured)
                    if !account.configured {
                        Text("Add SupabaseURL and SupabaseAnonKey to AdaptiveMusic/Info.plist.")
                            .font(.caption.monospaced()).foregroundStyle(StressLabel.stressed.color)
                    } else if let message = account.message {
                        Text(message).font(.caption.monospaced()).foregroundStyle(Theme.muted)
                    }
                }
                .marketingCard()

                LandingSignalCard()
                LandingAnalysisCard()
                LandingMusicCard()
                LandingPlayCard()
                LandingSpotifyCard()

                VStack(spacing: 14) {
                    Text("SUPPORTED DEVICES").font(.caption.monospaced()).tracking(3).foregroundStyle(Theme.accent)
                    Text("Use the sensors already around you.").font(.system(size: 28, weight: .bold)).multilineTextAlignment(.center)
                    Text("Adaptune supports Muse 2, Apple Watch, or direct pulse sensing from the iPhone camera and flashlight.")
                        .foregroundStyle(Theme.muted).multilineTextAlignment(.center).lineSpacing(4)
                    HStack { devicePill("Muse 2"); devicePill("Apple Watch"); devicePill("iPhone") }
                }
                .padding(.vertical, 30)
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 40)
        }
        .background(Theme.bg)
    }

    private func devicePill(_ text: String) -> some View {
        Text(text).font(.caption.weight(.semibold)).padding(.horizontal, 12).padding(.vertical, 8)
            .overlay(Capsule().stroke(Theme.line))
    }
}

private struct LandingSignalCard: View {
    private let signals = ["BPM", "HRV differential", "EEG right brain", "EEG left brain", "EEG right ear", "EEG left ear"]
    @State private var index = 0
    var body: some View {
        FeatureCard(number: "01", title: "Live data streaming",
                    detail: "Flip through six clearly labeled channels streaming BPM, HRV, and all four EEG locations live.") {
            CarouselShell(index: $index, count: signals.count) {
                VStack(alignment: .leading) {
                    Text(signals[index].uppercased()).font(.caption.monospaced()).foregroundStyle(Theme.muted)
                    DemoSignalChart(seed: index, color: signalColor(index)).frame(height: 150)
                }
            }
        }
    }
}

private struct LandingAnalysisCard: View {
    @State private var index = 0
    var body: some View {
        FeatureCard(number: "02", title: "Live analysis",
                    detail: "Deep learning and algorithmic heart metrics visualize stress against your baseline, with breathing guidance beside it.") {
            CarouselShell(index: $index, count: 2) {
                if index == 0 {
                    VStack(spacing: 14) {
                        Text("42.8").font(.system(size: 48, weight: .bold, design: .monospaced)).foregroundStyle(StressLabel.mild.color)
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                LinearGradient(colors: [.green, .yellow, .red], startPoint: .leading, endPoint: .trailing).clipShape(Capsule())
                                Capsule().fill(.white).frame(width: 4).offset(x: geo.size.width * 0.428)
                            }
                        }.frame(height: 16)
                    }
                } else {
                    VStack(spacing: 18) {
                        Circle().fill(Theme.accent.opacity(0.65)).frame(width: 130, height: 130).shadow(color: Theme.accent.opacity(0.45), radius: 28)
                        Text("BREATHE WITH THE CIRCLE").font(.caption.monospaced()).foregroundStyle(Theme.muted)
                    }
                }
            }
        }
    }
}

private struct LandingMusicCard: View {
    @State private var playing = false
    @State private var song = 0
    let songs = ["A calmer track is ready", "Breathe between the notes", "Slow light, steady pulse"]
    var body: some View {
        FeatureCard(number: "03", title: "Adaptive music",
                    detail: "Music follows the inverse of your live BPM and is curated to guide your listening toward calm.") {
            VStack(spacing: 16) {
                Image(systemName: "music.note").font(.system(size: 54)).foregroundStyle(Theme.accent)
                Text(songs[song]).font(.headline).lineLimit(1)
                HStack(spacing: 24) {
                    Button { song = (song + songs.count - 1) % songs.count } label: { Image(systemName: "backward.end.fill") }
                    Button { playing.toggle() } label: { Image(systemName: playing ? "pause.fill" : "play.fill").font(.title2) }
                    Button { song = (song + 1) % songs.count } label: { Image(systemName: "forward.end.fill") }
                }.foregroundStyle(Theme.ink)
            }.frame(maxWidth: .infinity)
        }
    }
}

private struct LandingPlayCard: View {
    @State private var index = 0
    var body: some View {
        FeatureCard(number: "04", title: "Play/sing along",
                    detail: "Play piano or drums with local audio, or open karaoke to play the included recording with its full transcript.") {
            CarouselShell(index: $index, count: 3) {
                if index == 0 { demoPiano }
                else if index == 1 { demoDrums }
                else { VStack { Text("KARAOKE").font(.caption.monospaced()).foregroundStyle(Theme.muted); Text("follow the feeling").foregroundStyle(Theme.faint); Text("sing into the calm").font(.headline); Text("full lyrics, no timing").foregroundStyle(Theme.faint) }.lineSpacing(8) }
            }
        }
    }
    private var demoPiano: some View { HStack(spacing: 3) { ForEach(["C","D","E","F","G","A","B"], id: \.self) { note in Button(note) {}.foregroundStyle(.black).frame(maxWidth: .infinity, minHeight: 120, alignment: .bottom).padding(.bottom, 8).background(.white, in: UnevenRoundedRectangle(bottomLeadingRadius: 6, bottomTrailingRadius: 6)) } } }
    private var demoDrums: some View { LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 3), spacing: 12) { ForEach(["Kick","Hat","Snare","Tom","Crash","Ride"], id: \.self) { name in Button(name) {}.font(.caption).frame(width: 70, height: 70).overlay(Circle().stroke(Theme.line)) } } }
}

private struct LandingSpotifyCard: View {
    var body: some View {
        FeatureCard(number: "05", title: "Connect your Spotify",
                    detail: "Pull songs from your Spotify account through a vibe, artist, playlist, or specific song.") {
            VStack(spacing: 16) {
                Image(systemName: "dot.radiowaves.left.and.right").font(.system(size: 50)).foregroundStyle(Theme.spotifyGreen)
                HStack { ForEach(["Vibe","Artist","Playlists","Song"], id: \.self) { Text($0).font(.caption).padding(7).overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.line)) } }
                Text("What do you want to hear?").foregroundStyle(Theme.faint).frame(maxWidth: .infinity, alignment: .leading).padding(11).overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.line))
            }
        }
    }
}

private struct FeatureCard<Preview: View>: View {
    let number: String, title: String, detail: String
    @ViewBuilder let preview: Preview
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            preview.frame(maxWidth: .infinity, minHeight: 190)
            Text(number).font(.caption.monospaced()).foregroundStyle(Theme.accent)
            Text(title).font(.system(size: 27, weight: .bold))
            Text(detail).foregroundStyle(Theme.muted).lineSpacing(4)
        }.marketingCard()
    }
}

private struct CarouselShell<Content: View>: View {
    @Binding var index: Int
    let count: Int
    @ViewBuilder let content: Content
    var body: some View {
        HStack(spacing: 10) {
            Button { index = (index + count - 1) % count } label: { Image(systemName: "chevron.left") }
            content
                .frame(maxWidth: .infinity)
                .id(index)
                .transition(.opacity.combined(with: .scale(scale: 0.98)))
            Button { index = (index + 1) % count } label: { Image(systemName: "chevron.right") }
        }
        .foregroundStyle(Theme.ink)
        .animation(.easeInOut(duration: 0.3), value: index)
    }
}

private struct DemoSignalChart: View {
    let seed: Int
    let color: Color
    var body: some View {
        Canvas { context, size in
            for line in 1...3 { var grid = Path(); let y = size.height * CGFloat(line) / 4; grid.move(to: .init(x: 0, y: y)); grid.addLine(to: .init(x: size.width, y: y)); context.stroke(grid, with: .color(Theme.line)) }
            let series = seed < 2 ? 1 : 5
            for band in 0..<series {
                var path = Path()
                for point in 0..<80 { let x = size.width * CGFloat(point) / 79; let y = size.height * (0.5 + 0.14 * sin(Double(point) * 0.16 + Double(seed + band))); point == 0 ? path.move(to: .init(x: x, y: y)) : path.addLine(to: .init(x: x, y: y)) }
                context.stroke(path, with: .color(series == 1 ? color : [Color.blue,.cyan,.green,.yellow,.purple][band]), lineWidth: 2)
            }
        }
    }
}

private func signalColor(_ index: Int) -> Color { [Theme.cBPM,Theme.cHRV,Theme.cRB,Theme.cLB,Theme.cRE,Theme.cLE][index] }

private extension View {
    func marketingCard() -> some View {
        self.padding(20)
            .background(Theme.panel, in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(Theme.line))
            .hoverEffect(.lift)
    }
    func portalField() -> some View { self.padding(12).background(Theme.panel2, in: RoundedRectangle(cornerRadius: 9)).overlay(RoundedRectangle(cornerRadius: 9).stroke(Theme.line)) }
}

private struct PrimaryPortalButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundStyle(Theme.bg)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 13)
            .background(Theme.accent.opacity(configuration.isPressed ? 0.7 : 1), in: RoundedRectangle(cornerRadius: 9))
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.16), value: configuration.isPressed)
    }
}
