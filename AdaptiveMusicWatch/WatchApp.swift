import SwiftUI
import WatchKit
import HealthKit

/// Watch companion: launched by the iPhone's "Activate workout session" button
/// (HKHealthStore.startWatchApp), runs the workout, and streams live heart data
/// back to the phone.
@main
struct AdaptuneWatchApp: App {
    @WKApplicationDelegateAdaptor(WatchAppDelegate.self) var delegate

    var body: some Scene {
        WindowGroup {
            WatchContentView()
                .environmentObject(delegate.workout)
        }
    }
}

final class WatchAppDelegate: NSObject, WKApplicationDelegate, ObservableObject {
    let workout = WorkoutManager()

    /// Called when the iPhone starts the watch app with a workout configuration.
    func handle(_ workoutConfiguration: HKWorkoutConfiguration) {
        workout.start(configuration: workoutConfiguration)
    }
}

struct WatchContentView: View {
    @EnvironmentObject var workout: WorkoutManager

    var body: some View {
        VStack(spacing: 10) {
            Text("ADAPTUNE")
                .font(.caption2.weight(.semibold))
                .tracking(2)
            Image(systemName: "heart.fill")
                .font(.system(size: 30))
                .foregroundStyle(.red)
                .symbolEffect(.pulse, isActive: workout.running)
            Text(workout.bpm.map { String(format: "%.0f BPM", $0) } ?? "--")
                .font(.system(size: 28, weight: .semibold, design: .rounded))
            Text(workout.running ? "Streaming to iPhone" : "Waiting for the iPhone app…")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if workout.running {
                Button("End session") { workout.stop() }
                    .tint(.red)
            } else {
                Button("Start workout") { workout.start(configuration: nil) }
            }
        }
        .padding()
    }
}
