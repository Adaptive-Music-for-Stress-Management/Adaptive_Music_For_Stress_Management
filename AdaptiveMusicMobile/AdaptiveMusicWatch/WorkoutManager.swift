import Foundation
import HealthKit
import WatchConnectivity

/// Runs the HKWorkoutSession and streams every live heart-rate sample to the
/// iPhone over WatchConnectivity as {"bpm": value} (plus a derived RR interval
/// so the phone can compute the HRV differential).
final class WorkoutManager: NSObject, ObservableObject,
                            HKWorkoutSessionDelegate, HKLiveWorkoutBuilderDelegate,
                            WCSessionDelegate {

    @Published var running = false
    @Published var bpm: Double? = nil

    private let healthStore = HKHealthStore()
    private var session: HKWorkoutSession?
    private var builder: HKLiveWorkoutBuilder?

    override init() {
        super.init()
        if WCSession.isSupported() {
            WCSession.default.delegate = self
            WCSession.default.activate()
        }
    }

    func start(configuration: HKWorkoutConfiguration?) {
        guard session == nil else { return }
        let config = configuration ?? {
            let c = HKWorkoutConfiguration()
            c.activityType = .mindAndBody
            c.locationType = .indoor
            return c
        }()
        let read: Set<HKObjectType> = [HKQuantityType.quantityType(forIdentifier: .heartRate)!]
        let share: Set<HKSampleType> = [HKObjectType.workoutType()]
        healthStore.requestAuthorization(toShare: share, read: read) { [weak self] ok, _ in
            guard let self, ok else { return }
            do {
                let session = try HKWorkoutSession(healthStore: self.healthStore, configuration: config)
                let builder = session.associatedWorkoutBuilder()
                builder.dataSource = HKLiveWorkoutDataSource(healthStore: self.healthStore,
                                                             workoutConfiguration: config)
                session.delegate = self
                builder.delegate = self
                self.session = session
                self.builder = builder
                session.startActivity(with: Date())
                builder.beginCollection(withStart: Date()) { _, _ in }
            } catch {
                print("[watch] workout start failed: \(error)")
            }
        }
    }

    func stop() {
        session?.end()
        let finishing = builder                       // keep the builder alive through both callbacks
        finishing?.endCollection(withEnd: Date()) { _, _ in
            finishing?.finishWorkout { _, _ in }
        }
        session = nil; builder = nil
        DispatchQueue.main.async { self.running = false }
        send(["workout": "stopped"])
    }

    // MARK: - HKWorkoutSessionDelegate

    func workoutSession(_ workoutSession: HKWorkoutSession, didChangeTo toState: HKWorkoutSessionState,
                        from fromState: HKWorkoutSessionState, date: Date) {
        DispatchQueue.main.async { self.running = (toState == .running) }
        if toState == .running { send(["workout": "running"]) }
    }

    func workoutSession(_ workoutSession: HKWorkoutSession, didFailWithError error: Error) {
        print("[watch] session error: \(error)")
    }

    // MARK: - HKLiveWorkoutBuilderDelegate

    func workoutBuilder(_ workoutBuilder: HKLiveWorkoutBuilder,
                        didCollectDataOf collectedTypes: Set<HKSampleType>) {
        guard let hrType = HKQuantityType.quantityType(forIdentifier: .heartRate),
              collectedTypes.contains(hrType),
              let stats = workoutBuilder.statistics(for: hrType),
              let quantity = stats.mostRecentQuantity() else { return }
        let unit = HKUnit.count().unitDivided(by: .minute())
        let value = quantity.doubleValue(for: unit)
        DispatchQueue.main.async { self.bpm = value }
        // stream to the phone: the bpm plus its RR-interval equivalent
        send(["bpm": value, "rr": [60000.0 / max(value, 1)]])
    }

    func workoutBuilderDidCollectEvent(_ workoutBuilder: HKLiveWorkoutBuilder) {}

    // MARK: - WCSession

    private func send(_ payload: [String: Any]) {
        let wc = WCSession.default
        guard wc.activationState == .activated else { return }
        if wc.isReachable {
            wc.sendMessage(payload, replyHandler: nil, errorHandler: nil)
        } else {
            wc.transferUserInfo(payload)
        }
    }

    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState,
                 error: Error?) {}

    func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        if (message["command"] as? String) == "stop" { stop() }
    }
}
