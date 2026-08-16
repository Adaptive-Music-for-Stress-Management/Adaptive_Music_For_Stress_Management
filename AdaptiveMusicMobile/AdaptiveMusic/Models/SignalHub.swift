import Foundation
import Combine
import SwiftUI

/// Which sensor feeds the dashboard.
enum InputMode: String {
    case camera   // iPhone camera + flashlight PPG
    case watch    // Apple Watch workout session
}

enum StressLabel: String {
    case calm = "Calm"
    case mild = "Mild-stress"
    case stressed = "Stressed"

    var color: Color {
        switch self {
        case .calm:     return Color(red: 0.20, green: 0.83, blue: 0.60)   // green
        case .mild:     return Color(red: 0.98, green: 0.75, blue: 0.14)   // yellow
        case .stressed: return Color(red: 0.97, green: 0.44, blue: 0.44)   // red
        }
    }

    static func from(_ value: Double) -> StressLabel {
        if value < 33 { return .calm }
        if value < 66 { return .mild }
        return .stressed
    }
}

/// Central biosignal hub: beats in -> BPM + HRV differential + baseline + 0-100 stress meter.
/// Mirrors the computer edition's scoring exactly:
///   stressed at start  -> population baseline 60 BPM / 20 ms
///   not stressed       -> average of the first 30 s
///   score = mean( clamp((bpm-base)/40), clamp((baseHRVd-hrvdEMA)/15) ) * 100, EMA-smoothed
final class SignalHub: ObservableObject {

    // MARK: session flow
    @Published var inputMode: InputMode? = nil
    @Published var stressedAtStart: Bool? = nil

    // MARK: live readings
    @Published var bpm: Double? = nil
    @Published var hrvDiff: Double? = nil          // ms, |RR(n) - RR(n-1)|, needs 3 beats
    @Published var beatSeq: Int = 0                // increments once per beat (drives the glow)
    @Published var bpmHistory: [Double] = []       // per-beat samples for the graph
    @Published var hrvHistory: [Double] = []

    // MARK: baseline + score
    @Published var baseline: (bpm: Double, hrvDiff: Double)? = nil
    @Published var calibrating = false
    @Published var calibrationLeft: Double? = nil
    @Published var stress: Double? = nil
    @Published var stressLabel: StressLabel? = nil

    // MARK: constants (identical to the computer edition)
    static let stressedBaseline = (bpm: 60.0, hrvDiff: 20.0)
    static let baselineSec = 30.0
    static let bpmScale = 40.0
    static let hrvdScale = 15.0
    static let emaAlpha = 0.30
    static let hrvdEmaAlpha = 0.25
    static let maxPoints = 140

    private var rrPrev: Double? = nil
    private var hrvdEMA: Double? = nil
    private var baseT0: Date? = nil
    private var baseBpmSum = 0.0, baseBpmN = 0
    private var baseHrvdSum = 0.0, baseHrvdN = 0
    private var lastBeatDate = Date.distantPast
    private var staleTimer: Timer?

    var beatFresh: Bool { Date().timeIntervalSince(lastBeatDate) < 6.0 }

    func startSession(stressed: Bool) {
        resetReadings()
        stressedAtStart = stressed
        if stressed {
            baseline = SignalHub.stressedBaseline
            calibrating = false
        } else {
            baseline = nil
            calibrating = true
            calibrationLeft = SignalHub.baselineSec
        }
        staleTimer?.invalidate()
        staleTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            if !self.beatFresh { self.objectWillChange.send() }
            if self.calibrating, let t0 = self.baseT0 {
                self.calibrationLeft = max(0, SignalHub.baselineSec - Date().timeIntervalSince(t0))
            }
        }
    }

    func resetReadings() {
        bpm = nil; hrvDiff = nil; beatSeq = 0
        bpmHistory = []; hrvHistory = []
        rrPrev = nil; hrvdEMA = nil
        baseT0 = nil; baseBpmSum = 0; baseBpmN = 0; baseHrvdSum = 0; baseHrvdN = 0
        stress = nil; stressLabel = nil
        baseline = nil; calibrating = false; calibrationLeft = nil
    }

    /// One heartbeat, described by its RR interval in milliseconds.
    /// skipZeroDiff: the Apple Watch path derives RR from smoothed HealthKit samples,
    /// where repeated identical readings would fabricate 0 ms "HRV differentials" and
    /// falsely max out the stress score — those zero diffs are dropped instead.
    func registerBeat(rrMs: Double, skipZeroDiff: Bool = false) {
        guard (300...2000).contains(rrMs) else { return }        // 30-200 bpm sanity window
        DispatchQueue.main.async { [self] in
            let now = Date()
            bpm = 60000.0 / rrMs
            if let prev = rrPrev {
                let d = abs(rrMs - prev)
                if !(skipZeroDiff && d < 0.5) {
                    hrvDiff = d
                    hrvdEMA = hrvdEMA == nil ? d
                            : SignalHub.hrvdEmaAlpha * d + (1 - SignalHub.hrvdEmaAlpha) * hrvdEMA!
                    hrvHistory.append(d)
                    if hrvHistory.count > SignalHub.maxPoints { hrvHistory.removeFirst() }
                }
            }
            rrPrev = rrMs
            lastBeatDate = now
            beatSeq += 1
            bpmHistory.append(bpm!)
            if bpmHistory.count > SignalHub.maxPoints { bpmHistory.removeFirst() }
            feedBaseline(now: now)
            updateScore()
        }
    }

    /// A direct BPM sample (Apple Watch HealthKit path) — converted to a pseudo-RR beat.
    func registerBPM(_ value: Double) {
        guard value > 0 else { return }
        registerBeat(rrMs: 60000.0 / value, skipZeroDiff: true)
    }

    private func feedBaseline(now: Date) {
        guard baseline == nil, stressedAtStart == false, let bpm else { return }
        if baseT0 == nil { baseT0 = now }
        baseBpmSum += bpm; baseBpmN += 1
        if let d = hrvDiff { baseHrvdSum += d; baseHrvdN += 1 }
        if now.timeIntervalSince(baseT0!) >= SignalHub.baselineSec, baseBpmN > 0 {
            baseline = (bpm: baseBpmSum / Double(baseBpmN),
                        hrvDiff: baseHrvdN > 0 ? baseHrvdSum / Double(baseHrvdN) : 20.0)
            calibrating = false
            calibrationLeft = nil
        }
    }

    private func updateScore() {
        guard let baseline, let bpm else { return }
        var terms = [max(0, min(1, (bpm - baseline.bpm) / SignalHub.bpmScale))]
        if let e = hrvdEMA {
            terms.append(max(0, min(1, (baseline.hrvDiff - e) / SignalHub.hrvdScale)))
        }
        let raw = 100.0 * terms.reduce(0, +) / Double(terms.count)
        stress = stress == nil ? raw : SignalHub.emaAlpha * raw + (1 - SignalHub.emaAlpha) * stress!
        stressLabel = StressLabel.from(stress!)
    }

    /// BPM bucket for the SUNO library: clamp((bpm // 10) * 10, 60, 150).
    var bucket: Int? {
        guard let bpm, beatFresh else { return nil }
        return min(150, max(60, Int(bpm / 10) * 10))
    }

    var baselineBucket: Int {
        guard let baseline else { return 60 }
        return min(150, max(60, Int(baseline.bpm / 10) * 10))
    }
}
