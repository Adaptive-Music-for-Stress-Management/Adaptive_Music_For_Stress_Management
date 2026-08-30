import Foundation
import HealthKit
import WatchConnectivity

/// "Stream data live from apple watch": the Activate-workout-session button asks HealthKit
/// to launch the watch companion app with a workout configuration; the watch app runs an
/// HKWorkoutSession and streams live heart-rate (and derived RR) back over WatchConnectivity.
final class WatchLink: NSObject, ObservableObject, WCSessionDelegate {
    @Published var workoutActive = false
    @Published var starting = false
    @Published var errorMessage: String? = nil
    @Published private(set) var usingDemoData = false

    private let hub: SignalHub
    private let healthStore = HKHealthStore()
    private var demoBeatWorkItem: DispatchWorkItem?
    private var demoBeatIndex = 0
    private var acceptingHeartData = false

    init(hub: SignalHub) {
        self.hub = hub
        super.init()
        if WCSession.isSupported() {
            WCSession.default.delegate = self
            WCSession.default.activate()
        }
    }

    /// The one button the user presses before any dashboard UI appears.
    func activateWorkoutSession() {
        errorMessage = nil
        acceptingHeartData = true
        // Continue immediately even when the Watch is missing or HealthKit
        // fails. If real Watch samples arrive later, handle(_:) replaces this
        // heart-only fallback without mixing the two sources.
        startHeartDemo()
        guard HKHealthStore.isHealthDataAvailable(), WCSession.isSupported() else {
            print("[watch] HealthKit or WatchConnectivity unavailable; using heart demo")
            return
        }
        let wc = WCSession.default
        guard wc.activationState == .activated, wc.isPaired, wc.isWatchAppInstalled else {
            print("[watch] Watch unavailable or companion not installed; using heart demo")
            return
        }
        starting = true
        let read: Set<HKObjectType> = [HKQuantityType.quantityType(forIdentifier: .heartRate)!,
                                       HKQuantityType.quantityType(forIdentifier: .heartRateVariabilitySDNN)!]
        let share: Set<HKSampleType> = [HKObjectType.workoutType()]
        healthStore.requestAuthorization(toShare: share, read: read) { [weak self] ok, _ in
            guard let self else { return }
            guard ok else {
                DispatchQueue.main.async {
                    self.starting = false
                    print("[watch] HealthKit authorization failed; continuing with heart demo")
                }
                return
            }
            let config = HKWorkoutConfiguration()
            config.activityType = .mindAndBody
            config.locationType = .indoor
            self.healthStore.startWatchApp(with: config) { started, error in
                DispatchQueue.main.async {
                    self.starting = false
                    if started {
                        self.workoutActive = true
                    } else {
                        print("[watch] startWatchApp failed: \(String(describing: error))")
                    }
                }
            }
        }
    }

    func endWorkoutSession() {
        acceptingHeartData = false
        stopHeartDemo()
        starting = false
        workoutActive = false
        if WCSession.default.isReachable {
            WCSession.default.sendMessage(["command": "stop"], replyHandler: nil, errorHandler: nil)
        }
    }

    /// Deterministic, gently varying beat intervals around 75 BPM. Successive
    /// RR differences remain around 10–20 ms, which keeps the requested demo
    /// in the calm-to-mild range even with the population baseline. No EEG or
    /// other sensor channel is synthesized.
    private func startHeartDemo() {
        stopHeartDemo()
        usingDemoData = true
        workoutActive = true
        demoBeatIndex = 0
        scheduleDemoBeat(after: 0.20)
    }

    private func scheduleDemoBeat(after delay: TimeInterval) {
        guard usingDemoData else { return }
        let item = DispatchWorkItem { [weak self] in
            guard let self, self.usingDemoData else { return }
            let slowPhase = Double(self.demoBeatIndex) * 0.16
            let amplitude = 7.5 + 2.5 * sin(slowPhase)
            let rrMs = 800.0 + (self.demoBeatIndex.isMultiple(of: 2) ? amplitude : -amplitude)
            self.demoBeatIndex += 1
            self.hub.registerBeat(rrMs: rrMs, skipZeroDiff: true)
            self.scheduleDemoBeat(after: rrMs / 1000.0)
        }
        demoBeatWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    private func stopHeartDemo() {
        usingDemoData = false
        demoBeatWorkItem?.cancel()
        demoBeatWorkItem = nil
    }

    // MARK: - WCSessionDelegate

    func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState,
                 error: Error?) {}
    func sessionDidBecomeInactive(_ session: WCSession) {}
    func sessionDidDeactivate(_ session: WCSession) { session.activate() }

    /// Watch messages: {"rr": [ms, ...]} beat-to-beat intervals, or {"bpm": value} samples.
    func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        handle(message)
    }
    func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        handle(userInfo)
    }

    private func handle(_ message: [String: Any]) {
        let rrs = message["rr"] as? [Double]
        let bpmValue = message["bpm"] as? Double
        let state = message["workout"] as? String
        DispatchQueue.main.async {
            guard self.acceptingHeartData else { return }
            if rrs != nil || bpmValue != nil {
                self.stopHeartDemo()
                self.workoutActive = true
                if let rrs {
                    for rr in rrs { self.hub.registerBeat(rrMs: rr, skipZeroDiff: true) }
                } else if let bpmValue {
                    self.hub.registerBPM(bpmValue)
                }
            }
            if let state {
                if state == "running" {
                    self.workoutActive = true
                } else if !self.usingDemoData {
                    self.workoutActive = false
                }
            }
        }
    }
}
