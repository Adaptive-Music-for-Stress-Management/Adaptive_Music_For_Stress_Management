import SwiftUI
import Combine

/// Breathe: an expanding / contracting circle locked to the actual beats of the
/// SUNO song. The target tempo is ((BPM // 10) * 10) - 10 — one folder below the
/// user's current bucket — and the song is switched to that folder. Beats are found
/// by watching the live waveform for amplitude spikes (the engine tap's RMS energy);
/// the moment a spike lands, the circle snaps to expand. As the user's heart slows,
/// the target re-computes until it reaches the baseline.
@MainActor
final class BreatheController: ObservableObject {

    @Published var active = false
    @Published var buffering = true
    @Published var expanded = false
    @Published var targetBucket: Int? = nil
    @Published var blocked = false                       // Spotify is the audio source

    static let blockedMessage = "I apologize, but you must enable the AI-generated songs to use the breathe feature"

    private let hub: SignalHub
    private let suno: SunoPlayer
    private let engine: PersonalizeEngine
    private var timer: AnyCancellable?
    private var energyHistory: [Float] = []
    private var lastBeat = Date.distantPast
    private var contractWork: DispatchWorkItem?

    init(hub: SignalHub, suno: SunoPlayer, engine: PersonalizeEngine) {
        self.hub = hub; self.suno = suno; self.engine = engine
        suno.onSongChange = { [weak self] in               // every song change: wait for the next beat
            Task { @MainActor in self?.buffering = true }
        }
    }

    func start() {
        active = true
        buffering = true
        retarget(force: true)
        timer = Timer.publish(every: 1.0 / 30.0, on: .main, in: .common).autoconnect()
            .sink { [weak self] _ in self?.tick() }
    }

    func stop() {
        active = false
        timer?.cancel(); timer = nil
        suno.bucketOverride = nil
        contractWork?.cancel()
    }

    private func retarget(force: Bool) {
        // ((BPM // 10) * 10) - 10, clamped to the library and never below the baseline
        let bpm = hub.bpm ?? 60
        let raw = Int(bpm / 10) * 10 - 10
        let target = max(hub.baselineBucket, min(150, max(60, raw)))
        if force || target != targetBucket {
            targetBucket = target
            suno.bucketOverride = target                   // the song maps to that BPM folder
            buffering = true
            if !suno.playing {
                engine.claimAudio(.suno)
                suno.switchSong(to: target)
            }
        }
    }

    private func tick() {
        guard active else { return }
        blocked = engine.audioSource == .spotify
        if blocked { return }
        retarget(force: false)                             // re-calculate as BPM comes down

        // --- amplitude-spike beat detection over the engine tap's RMS energy ---
        let energy = suno.currentEnergy
        energyHistory.append(energy)
        if energyHistory.count > 22 { energyHistory.removeFirst() }   // ~0.7 s at 30 Hz
        guard suno.playing, energyHistory.count > 6 else { return }
        let avg = energyHistory.reduce(0, +) / Float(energyHistory.count)
        let interval = 60.0 / Double(targetBucket ?? 60)
        if energy > max(0.02, avg * 1.35), Date().timeIntervalSince(lastBeat) > interval * 0.55 {
            lastBeat = Date()
            onBeat(interval: interval)
        }
    }

    private func onBeat(interval: Double) {
        if buffering { buffering = false }
        contractWork?.cancel()
        withAnimation(.easeOut(duration: 0.13)) { expanded = true }     // expand ON the spike
        let work = DispatchWorkItem { [weak self] in
            withAnimation(.easeIn(duration: interval * 0.8)) { self?.expanded = false }
        }
        contractWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }
}

struct BreatheView: View {
    @EnvironmentObject var breathe: BreatheController
    @EnvironmentObject var suno: SunoPlayer
    @EnvironmentObject var hub: SignalHub

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
                    Text(breathe.buffering ? "BUFFERING · WAITING FOR THE BEAT…" : "BREATHE WITH THE CIRCLE")
                        .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                        .tracking(1.5)
                        .foregroundStyle(Theme.muted)
                    Circle()
                        .fill(RadialGradient(colors: [Theme.accent.opacity(0.9), Theme.accent.opacity(0.25)],
                                             center: .init(x: 0.38, y: 0.38),
                                             startRadius: 4, endRadius: 90))
                        .shadow(color: Theme.accent.opacity(0.4), radius: 26)
                        .scaleEffect(breathe.expanded ? 1.0 : 0.55)
                        .opacity(breathe.buffering ? 0.35 : 1)
                        .frame(width: 150, height: 150)
                        .frame(maxHeight: .infinity)
                    WaveformView()
                        .frame(height: 38)
                    if let t = breathe.targetBucket {
                        Text("target \(t) BPM · baseline \(hub.baselineBucket) BPM")
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
