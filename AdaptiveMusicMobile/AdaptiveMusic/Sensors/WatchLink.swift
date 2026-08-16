import Foundation
import HealthKit
import WatchConnectivity

/// "Stream data live from apple watch": the Activate-workout-session button asks HealthKit
/// to launch the watch companion app with a workout configuration; the watch app runs an
/// HKWorkoutSession and streams live heart-rate (and derived RR) back over WatchConnectivity.
final class WatchLink: NSObject, ObservableObject, WCSessionDelegate {

    static let notConnectedMessage =
        "I apologize, but you  must first connect your apple watch to your apple mobile device."

    @Published var workoutActive = false
    @Published var starting = false
    @Published var errorMessage: String? = nil

    private let hub: SignalHub
    private let healthStore = HKHealthStore()

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
        guard HKHealthStore.isHealthDataAvailable(), WCSession.isSupported() else {
            errorMessage = WatchLink.notConnectedMessage; return
        }
        let wc = WCSession.default
        guard wc.activationState == .activated, wc.isPaired, wc.isWatchAppInstalled else {
            errorMessage = WatchLink.notConnectedMessage; return
        }
        starting = true
        let read: Set<HKObjectType> = [HKQuantityType.quantityType(forIdentifier: .heartRate)!,
                                       HKQuantityType.quantityType(forIdentifier: .heartRateVariabilitySDNN)!]
        let share: Set<HKSampleType> = [HKObjectType.workoutType()]
        healthStore.requestAuthorization(toShare: share, read: read) { [weak self] ok, _ in
            guard let self else { return }
            guard ok else {
                DispatchQueue.main.async { self.starting = false
                                           self.errorMessage = WatchLink.notConnectedMessage }
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
                        self.errorMessage = WatchLink.notConnectedMessage
                    }
                }
            }
        }
    }

    func endWorkoutSession() {
        workoutActive = false
        if WCSession.default.isReachable {
            WCSession.default.sendMessage(["command": "stop"], replyHandler: nil, errorHandler: nil)
        }
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
        if let rrs = message["rr"] as? [Double] {
            for rr in rrs { hub.registerBeat(rrMs: rr, skipZeroDiff: true) }
        } else if let bpmValue = message["bpm"] as? Double {
            hub.registerBPM(bpmValue)
        }
        if let state = message["workout"] as? String {
            DispatchQueue.main.async { self.workoutActive = (state == "running") }
        }
    }
}
