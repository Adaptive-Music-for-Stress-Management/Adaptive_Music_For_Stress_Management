import SwiftUI
import Combine

/// Breathe is driven solely by the user's live BPM. Neither waveform peaks nor
/// music selection affect the circle's phase. Its cadence is 5 × log₂(user BPM).
@MainActor
final class BreatheController: ObservableObject {

    @Published var active = false
    @Published var buffering = true
    @Published var circleBPM: Double? = nil
    @Published var userBPM: Double? = nil
    @Published var blocked = false                       // Spotify is the audio source

    static let blockedMessage = "I apologize, but you must enable the AI-generated songs to use the breathe feature"

    private let hub: SignalHub
    private let suno: SunoPlayer
    private let engine: PersonalizeEngine
    private var timer: AnyCancellable?
    private var bpmObserver: AnyCancellable?
    private var cycleStart = Date()

    init(hub: SignalHub, suno: SunoPlayer, engine: PersonalizeEngine) {
        self.hub = hub; self.suno = suno; self.engine = engine
        bpmObserver = hub.$bpm
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.retarget(force: false) }
    }

    func start() {
        active = true
        blocked = engine.audioSource == .spotify
        if !blocked {
            retarget(force: true)     // never touch Spotify playback — blocked mode shows the message
        } else {
            buffering = true
        }
        timer = Timer.publish(every: 1.0 / 30.0, on: .main, in: .common).autoconnect()
            .sink { [weak self] _ in self?.tick() }
    }

    func stop() {
        active = false
        timer?.cancel(); timer = nil
        circleBPM = nil
    }

    private func retarget(force: Bool) {
        guard active else { return }
        let bpm = hub.bpm ?? 60
        guard bpm.isFinite, bpm > 0 else { return }
        userBPM = bpm

        let nextCircleBPM = 5 * log2(bpm)
        if force || buffering || nextCircleBPM != circleBPM {
            let now = Date()
            if let oldCircleBPM = circleBPM, oldCircleBPM > 0 {
                let oldCycle = 60.0 / oldCircleBPM
                let phase = now.timeIntervalSince(cycleStart)
                    .truncatingRemainder(dividingBy: oldCycle) / oldCycle
                cycleStart = now.addingTimeInterval(-phase * (60.0 / nextCircleBPM))
            } else {
                cycleStart = now
            }
            circleBPM = nextCircleBPM
            buffering = false
        }
    }

    private func tick() {
        guard active else { return }
        let nowBlocked = engine.audioSource == .spotify
        if nowBlocked {
            blocked = true
            buffering = true
            return
        }
        let resumed = blocked
        blocked = false
        retarget(force: resumed)                           // run after every live BPM update
    }

    /// A cosine yields equal contraction and expansion phases: full expansion
    /// at circle-BPM ticks and full contraction halfway between them.
    func scale(at date: Date) -> CGFloat {
        guard active, !buffering, let circleBPM, circleBPM > 0 else { return 0.55 }
        let cycle = 60.0 / circleBPM
        let phase = date.timeIntervalSince(cycleStart)
            .truncatingRemainder(dividingBy: cycle) / cycle
        let amount = (1 + cos(2 * .pi * phase)) / 2
        return 0.55 + 0.45 * amount
    }
}

struct BreatheView: View {
    @EnvironmentObject var breathe: BreatheController
    @EnvironmentObject var suno: SunoPlayer

    var body: some View {
        Group {
            if breathe.blocked {
                VStack(spacing: 12) {
                    ProgressView()
                    Text(BreatheController.blockedMessage)
                        .font(.system(size: 13.5))
                        .foregroundStyle(StressLabel.stressed.color)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 8)
                }
            } else {
                VStack(spacing: 8) {
                    Text(breathe.buffering ? "BUFFERING · READING YOUR BPM…" : "BREATHE WITH THE CIRCLE")
                        .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                        .tracking(1.5)
                        .foregroundStyle(Theme.muted)
                    TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
                        Circle()
                            .fill(RadialGradient(colors: [Theme.accent.opacity(0.9), Theme.accent.opacity(0.25)],
                                                 center: .init(x: 0.38, y: 0.38),
                                                 startRadius: 4, endRadius: 90))
                            .shadow(color: Theme.accent.opacity(0.4), radius: 26)
                            .scaleEffect(breathe.scale(at: timeline.date))
                            .opacity(breathe.buffering ? 0.35 : 1)
                            .frame(width: 150, height: 150)
                            .frame(maxHeight: .infinity)
                    }
                    WaveformView()
                        .frame(height: 38)
                    if let circleBPM = breathe.circleBPM, let userBPM = breathe.userBPM {
                        Text("circle \(circleBPM, specifier: "%.1f") BPM · user \(userBPM, specifier: "%.1f") BPM")
                            .font(.system(size: 9.5, design: .monospaced))
                            .foregroundStyle(Theme.faint)
                    }
                }
            }
        }
    }
}

/// A visually-nice waveform that follows the song's amplitudes, fed by the engine tap.
struct WaveformView: View {
    @EnvironmentObject var suno: SunoPlayer

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { _ in
            Canvas { ctx, size in
                let samples = suno.waveform
                guard !samples.isEmpty else { return }
                var path = Path()
                let n = samples.count
                for i in 0..<n {
                    let x = size.width * CGFloat(i) / CGFloat(n - 1)
                    let y = size.height / 2 + CGFloat(samples[i]) * size.height * 0.48
                    i == 0 ? path.move(to: CGPoint(x: x, y: y)) : path.addLine(to: CGPoint(x: x, y: y))
                }
                ctx.stroke(path, with: .color(Theme.accent),
                           style: StrokeStyle(lineWidth: 1.6, lineJoin: .round))
            }
        }
    }
}
