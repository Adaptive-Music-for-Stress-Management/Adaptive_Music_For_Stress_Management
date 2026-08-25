import SwiftUI

/// The setup flow: choose the mobile input (camera reader or Apple Watch),
/// activate it, then answer "Are you stressed?".
struct FlowView: View {
    @EnvironmentObject var hub: SignalHub
    @EnvironmentObject var camera: CameraPPGReader
    @EnvironmentObject var watch: WatchLink

    enum Step { case input, camera, watch, stressed }
    @State private var step: Step = .input

    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            VStack(spacing: 8) {
                Text("Adaptune")
                    .font(.system(size: 30, weight: .bold))
                Text("TUNE YOUR STATE. FIND YOUR CALM.")
                    .font(.system(size: 11, weight: .medium))
                    .tracking(4)
                    .foregroundStyle(Theme.muted)
            }
            Group {
                switch step {
                case .input:    inputStep
                case .camera:   cameraStep
                case .watch:    watchStep
                case .stressed: stressedStep
                }
            }
            .transition(.opacity)
            Spacer()
            Spacer()
        }
        .padding(24)
        .animation(.easeInOut(duration: 0.4), value: step)
    }

    // MARK: steps

    private var inputStep: some View {
        VStack(spacing: 12) {
            Text("How should we read your heart?")
                .foregroundStyle(Theme.muted)
            flowButton("Read data from mobile",
                       subtitle: "Camera + flashlight measure your pulse from your fingertip") {
                hub.inputMode = .camera
                camera.start()          // permission prompt + flashlight ON the moment they pick it
                step = .camera
            }
            flowButton("Stream data live from Apple Watch",
                       subtitle: "A workout session streams live BPM and HRV") {
                hub.inputMode = .watch
                step = .watch
            }
        }
    }

    private var cameraStep: some View {
        VStack(spacing: 14) {
            Text("Cover the main 1× rear lens and the flashlight with your fingertip. Hold still with light, even pressure.")
                .multilineTextAlignment(.center)
                .foregroundStyle(Theme.muted)
            if !camera.activeCameraName.isEmpty {
                Text("Using \(camera.activeCameraName)")
                    .font(.caption2.monospaced())
                    .foregroundStyle(Theme.faint)
            }
            if camera.permissionDenied {
                Text("Camera access is required — enable it in Settings → Privacy → Camera.")
                    .font(.footnote)
                    .foregroundStyle(StressLabel.stressed.color)
                    .multilineTextAlignment(.center)
            }
            if let error = camera.errorMessage {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(StressLabel.stressed.color)
                    .multilineTextAlignment(.center)
            } else if camera.running, camera.fingerDetected, hub.bpm == nil {
                Text("Finger detected — hold still while the camera learns your pulse.")
                    .font(.footnote)
                    .foregroundStyle(Theme.accent)
                    .multilineTextAlignment(.center)
            }
            flowButton(camera.running ? (hub.bpm != nil ? "Pulse detected — continue" : "Reading…")
                                      : "Start mobile reader",
                       subtitle: camera.running ? (camera.fingerDetected ? "signal OK" : "cover the lens fully")
                                                : "turns on the flashlight and camera") {
                if camera.running, hub.bpm != nil { step = .stressed }
                else { camera.start() }
            }
            backButton
        }
    }

    private var watchStep: some View {
        VStack(spacing: 14) {
            Text("Your Apple Watch will start a workout session and stream live heart data.")
                .multilineTextAlignment(.center)
                .foregroundStyle(Theme.muted)
            flowButton(watch.starting ? "Activating…" :
                       watch.workoutActive ? "Workout active — continue" : "Activate workout session",
                       subtitle: "starts the watch app via HealthKit") {
                if watch.workoutActive { step = .stressed }
                else { watch.activateWorkoutSession() }
            }
            if let err = watch.errorMessage {
                Text(err)
                    .font(.footnote)
                    .foregroundStyle(StressLabel.stressed.color)
                    .multilineTextAlignment(.center)
            }
            if watch.workoutActive {
                Text("Receiving heart data…").font(.footnote).foregroundStyle(Theme.accent)
            }
            backButton
        }
        .onChange(of: watch.workoutActive) { _, active in
            if active { step = .stressed }
        }
    }

    private var stressedStep: some View {
        VStack(spacing: 16) {
            Text("Are you stressed?")
                .font(.system(size: 24, weight: .semibold))
            HStack(spacing: 12) {
                flowButton("Yes", subtitle: "Resting norms · 60 BPM · 20 ms") {
                    camera.resetDetector()
                    hub.startSession(stressed: true)
                }
                flowButton("No", subtitle: "Calibrate from your first 30 s") {
                    camera.resetDetector()
                    hub.startSession(stressed: false)
                }
            }
        }
    }

    private var backButton: some View {
        Button("← Back") {
            camera.stop()
            watch.endWorkoutSession()      // stop the watch stream so inputs never mix
            step = .input
        }
        .font(.footnote)
        .foregroundStyle(Theme.muted)
    }

    private func flowButton(_ title: String, subtitle: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 16, weight: .semibold))
                Text(subtitle).font(.system(size: 11)).foregroundStyle(Theme.muted)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(Theme.panel, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.line))
        }
        .buttonStyle(.plain)
    }
}
