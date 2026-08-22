import SwiftUI

@main
struct AdaptuneApp: App {
    @StateObject private var hub: SignalHub
    @StateObject private var suno: SunoPlayer
    @StateObject private var spotify: SpotifyService
    @StateObject private var claude: ClaudeService
    @StateObject private var engine: PersonalizeEngine
    @StateObject private var camera: CameraPPGReader
    @StateObject private var watch: WatchLink
    @StateObject private var relief: ReliefState
    @StateObject private var breathe: BreatheController
    @StateObject private var account: SupabaseService

    init() {
        let hub = SignalHub()
        let suno = SunoPlayer(hub: hub)
        let spotify = SpotifyService()
        let claude = ClaudeService()
        let engine = PersonalizeEngine(hub: hub, suno: suno, spotify: spotify, claude: claude)
        _hub = StateObject(wrappedValue: hub)
        _suno = StateObject(wrappedValue: suno)
        _spotify = StateObject(wrappedValue: spotify)
        _claude = StateObject(wrappedValue: claude)
        _engine = StateObject(wrappedValue: engine)
        _camera = StateObject(wrappedValue: CameraPPGReader(hub: hub))
        _watch = StateObject(wrappedValue: WatchLink(hub: hub))
        _relief = StateObject(wrappedValue: ReliefState())
        _breathe = StateObject(wrappedValue: BreatheController(hub: hub, suno: suno, engine: engine))
        _account = StateObject(wrappedValue: SupabaseService())
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(hub)
                .environmentObject(suno)
                .environmentObject(spotify)
                .environmentObject(claude)
                .environmentObject(engine)
                .environmentObject(camera)
                .environmentObject(watch)
                .environmentObject(relief)
                .environmentObject(breathe)
                .environmentObject(account)
                .preferredColorScheme(.dark)
        }
    }
}

struct Theme {
    static let bg = Color(red: 0.043, green: 0.059, blue: 0.078)
    static let panel = Color(red: 0.063, green: 0.090, blue: 0.125)
    static let panel2 = Color(red: 0.051, green: 0.075, blue: 0.106)
    static let line = Color(red: 0.110, green: 0.153, blue: 0.200)
    static let ink = Color(red: 0.863, green: 0.902, blue: 0.941)
    static let muted = Color(red: 0.392, green: 0.471, blue: 0.549)
    static let faint = Color(red: 0.231, green: 0.298, blue: 0.369)
    // trace palette (validated against the dark surface)
    static let cBPM = Color(red: 0.176, green: 0.831, blue: 0.561)
    static let cHRV = Color(red: 0.910, green: 0.627, blue: 0.298)
    static let cRB  = Color(red: 0.310, green: 0.639, blue: 0.878)
    static let cLB  = Color(red: 0.910, green: 0.478, blue: 0.608)
    static let cRE  = Color(red: 0.227, green: 0.753, blue: 0.788)
    static let cLE  = Color(red: 0.694, green: 0.549, blue: 0.949)
    static let accent = cBPM
    static let spotifyGreen = Color(red: 0.114, green: 0.725, blue: 0.329)
}

struct RootView: View {
    @EnvironmentObject var hub: SignalHub
    @EnvironmentObject var account: SupabaseService

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()
            if !account.restored {
                ProgressView("Opening Adaptune…")
                    .tint(Theme.accent)
            } else if account.user == nil {
                LandingView().transition(.opacity.combined(with: .scale(scale: 0.985)))
            } else if !account.showLiveSession {
                SessionHistoryView().transition(.opacity.combined(with: .scale(scale: 0.985)))
            } else if hub.stressedAtStart == nil {
                FlowView().transition(.opacity.combined(with: .scale(scale: 0.985)))
            } else {
                DashboardView().transition(.opacity.combined(with: .scale(scale: 0.985)))
            }
        }
        .animation(.easeInOut(duration: 0.45), value: account.user != nil)
        .animation(.easeInOut(duration: 0.45), value: account.showLiveSession)
        .animation(.easeInOut(duration: 0.45), value: hub.stressedAtStart)
        .task { await account.restore() }
    }
}
