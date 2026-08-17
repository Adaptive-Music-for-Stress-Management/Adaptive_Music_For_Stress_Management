import Foundation
import AVFoundation
import Combine

/// Fingertip photoplethysmography (PPG) using the rear camera and torch.
///
/// A covered lens transmits mostly red light. The capture path samples the
/// centre of the frame, lets auto-exposure settle under the fingertip, then
/// locks exposure while a filtered, polarity-independent peak detector turns
/// the small periodic optical changes into RR intervals.
final class CameraPPGReader: NSObject, ObservableObject, AVCaptureVideoDataOutputSampleBufferDelegate {

    @Published var running = false
    @Published var permissionDenied = false
    @Published var fingerDetected = false
    @Published var errorMessage: String? = nil

    private let hub: SignalHub
    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "ppg.camera")
    private var device: AVCaptureDevice?
    private var configured = false

    // Optical filter and peak-detector state. All access happens on `queue`.
    private var dc: Double?
    private var filtered = 0.0
    private var priorFiltered = 0.0
    private var previousFiltered = 0.0
    private var envelope = 0.0
    private var positiveExtreme = 0.0
    private var negativeExtreme = 0.0
    private var polarity = 0.0
    private var lastSampleTime: CFTimeInterval?
    private var lastPeakTime: CFTimeInterval = 0
    private var fingerFrames = 0
    private var usableFrames = 0
    private var missingFingerFrames = 0
    private var exposureLockedForFinger = false
    private var frameCount = 0

    init(hub: SignalHub) {
        self.hub = hub
        super.init()
    }

    func start() {
        resetDetector()
        DispatchQueue.main.async { self.errorMessage = nil }
        AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
            guard let self else { return }
            DispatchQueue.main.async {
                self.permissionDenied = !granted
                if !granted { self.errorMessage = "Camera access is required to read your pulse." }
            }
            guard granted else { return }
            self.queue.async { self.configure() }
        }
    }

    private func configure() {
        if session.isRunning {
            if let device, !enableTorchAndAutoCapture(on: device) { return }
            publishRunning(true)
            return
        }

        session.beginConfiguration()
        // .medium gives the PPG ROI substantially more samples than .low while
        // remaining inexpensive enough for a steady 30 fps capture stream.
        session.sessionPreset = .medium

        if !configured {
            guard let camera = fingertipCamera() else {
                session.commitConfiguration()
                publishError("This device does not have a rear camera for fingertip pulse reading.")
                return
            }
            guard let input = try? AVCaptureDeviceInput(device: camera), session.canAddInput(input) else {
                session.commitConfiguration()
                publishError("The rear camera could not be prepared for pulse reading.")
                return
            }
            let output = AVCaptureVideoDataOutput()
            output.videoSettings = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
            ]
            output.alwaysDiscardsLateVideoFrames = true
            output.setSampleBufferDelegate(self, queue: queue)
            guard session.canAddOutput(output) else {
                session.commitConfiguration()
                publishError("The camera output could not be prepared for pulse reading.")
                return
            }
            session.addInput(input)
            session.addOutput(output)
            device = camera
            configured = true
        }
        session.commitConfiguration()

        guard let device else {
            publishError("The rear camera could not be prepared for pulse reading.")
            return
        }
        guard enableTorchAndAutoCapture(on: device) else { return }
        session.startRunning()
        // Starting the session can reset the torch and capture settings.
        guard enableTorchAndAutoCapture(on: device) else { return }
        publishRunning(true)
    }

    /// On a three-camera iPhone, the setup shown in the app's instructions
    /// places the fingertip over the single upper-right lens. That is the
    /// physical telephoto camera, so do not allow a virtual multi-camera
    /// device to silently switch us to a different lens. Phones without that
    /// lens use their rear 1× wide camera instead.
    private func fingertipCamera() -> AVCaptureDevice? {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInTelephotoCamera, .builtInWideAngleCamera],
            mediaType: .video,
            position: .back
        )
        return discovery.devices.first(where: {
            $0.deviceType == .builtInTelephotoCamera && $0.isTorchAvailable
        }) ?? discovery.devices.first(where: {
            $0.deviceType == .builtInWideAngleCamera && $0.isTorchAvailable
        }) ?? discovery.devices.first
    }

    /// Uses the strongest currently safe torch level, but preserves the camera's
    /// auto exposure until the covered-finger image has settled.
    private func enableTorchAndAutoCapture(on camera: AVCaptureDevice) -> Bool {
        guard camera.isTorchAvailable else {
            publishError("This device's rear flashlight is unavailable, so it cannot read a fingertip pulse.")
            return false
        }
        do {
            try camera.lockForConfiguration()
            defer { camera.unlockForConfiguration() }
            // A near-maximum torch level gives dimmer fingertips enough optical
            // contrast without forcing every device to its absolute maximum.
            let torchLevel = min(AVCaptureDevice.maxAvailableTorchLevel, 0.95)
            try camera.setTorchModeOn(level: torchLevel)
            if camera.isExposureModeSupported(.continuousAutoExposure) {
                camera.exposureMode = .continuousAutoExposure
            }
            if camera.isFocusModeSupported(.continuousAutoFocus) {
                camera.focusMode = .continuousAutoFocus
            }
            let targetFrameRate = 30.0
            if camera.activeFormat.videoSupportedFrameRateRanges.contains(where: {
                $0.minFrameRate <= targetFrameRate && $0.maxFrameRate >= targetFrameRate
            }) {
                let duration = CMTime(value: 1, timescale: 30)
                camera.activeVideoMinFrameDuration = duration
                camera.activeVideoMaxFrameDuration = duration
            }
            exposureLockedForFinger = false
            return true
        } catch {
            publishError("The camera flashlight could not be enabled for pulse reading.")
            return false
        }
    }

    func stop() {
        queue.async { [self] in
            if let device {
                do {
                    try device.lockForConfiguration()
                    if device.torchMode == .on { device.torchMode = .off }
                    device.unlockForConfiguration()
                } catch { }
            }
            session.stopRunning()
            resetDetectorState()
            publishRunning(false)
        }
    }

    /// A calibration/session must not inherit a stale threshold or peak from a
    /// prior fingertip-reading session.
    func resetDetector() {
        queue.async { [self] in resetDetectorState() }
    }

    private func resetDetectorState() {
        resetPulseFilterState()
        fingerFrames = 0
        missingFingerFrames = 0
        frameCount = 0
    }

    private func resetPulseFilterState() {
        dc = nil
        filtered = 0
        priorFiltered = 0
        previousFiltered = 0
        envelope = 0
        positiveExtreme = 0
        negativeExtreme = 0
        polarity = 0
        lastSampleTime = nil
        lastPeakTime = 0
        usableFrames = 0
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        guard let lumaBase = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0) else { return }

        let width = CVPixelBufferGetWidthOfPlane(pixelBuffer, 0)
        let height = CVPixelBufferGetHeightOfPlane(pixelBuffer, 0)
        let lumaStride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
        let luma = lumaBase.assumingMemoryBound(to: UInt8.self)
        let chromaBase = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1)
        let chroma = chromaBase?.assumingMemoryBound(to: UInt8.self)
        let chromaStride = chroma.map { _ in CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1) } ?? 0
        let chromaWidth = chroma.map { _ in CVPixelBufferGetWidthOfPlane(pixelBuffer, 1) } ?? 0
        let chromaHeight = chroma.map { _ in CVPixelBufferGetHeightOfPlane(pixelBuffer, 1) } ?? 0

        // Use only the middle half of the sensor. It is the most reliably
        // covered part of the lens and avoids uncovered edges diluting the PPG.
        let xStart = width / 4, xEnd = width * 3 / 4
        let yStart = height / 4, yEnd = height * 3 / 4
        var lumaSum = 0.0
        var crSum = 0.0
        var count = 0
        var y = yStart
        while y < yEnd {
            var x = xStart
            while x < xEnd {
                lumaSum += Double(luma[y * lumaStride + x])
                if let chroma, chromaWidth > 0, chromaHeight > 0 {
                    let chromaY = min(chromaHeight - 1, y / 2)
                    let chromaX = min(chromaWidth - 1, x / 2)
                    // Full-range bi-planar output stores chroma as Cb, Cr.
                    crSum += Double(chroma[chromaY * chromaStride + chromaX * 2 + 1])
                }
                count += 1
                x += 4
            }
            y += 4
        }
        guard count > 0 else { return }
        let meanLuma = lumaSum / Double(count)
        let meanCr = chroma == nil ? 128 : crSum / Double(count)
        // Be permissive enough for darker skin tones, thicker fingertips, and
        // camera modules where the flash sits farther from the active lens.
        let coveredFinger = meanLuma > 20 && (meanCr > 128 || meanLuma > 90)
        frameCount += 1
        if frameCount % 5 == 0 {
            DispatchQueue.main.async { self.fingerDetected = coveredFinger }
        }

        guard coveredFinger else {
            fingerFrames = 0
            missingFingerFrames += 1
            resetPulseFilterState()
            if missingFingerFrames > 15 { restoreAutoExposureIfNeeded() }
            return
        }

        missingFingerFrames = 0
        fingerFrames += 1
        if fingerFrames == 36 { lockExposureForFingerIfPossible() }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let timestamp = pts.isValid ? CMTimeGetSeconds(pts) : CACurrentMediaTime()
        detect(meanLuma, at: timestamp)
    }

    /// Lock after roughly one second with a finger covering the lens. Continuous
    /// auto exposure otherwise removes the subtle light changes caused by blood
    /// volume and makes a real pulse look flat.
    private func lockExposureForFingerIfPossible() {
        guard !exposureLockedForFinger, let device else { return }
        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }
            if device.isExposureModeSupported(.locked) { device.exposureMode = .locked }
            if device.isFocusModeSupported(.locked) { device.focusMode = .locked }
            exposureLockedForFinger = true
            // Exposure transitions alter the DC level, so start a fresh filter
            // warm-up using the stable, locked image.
            resetDetectorState()
        } catch { }
    }

    private func restoreAutoExposureIfNeeded() {
        guard exposureLockedForFinger, let device else { return }
        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }
            if device.isExposureModeSupported(.continuousAutoExposure) {
                device.exposureMode = .continuousAutoExposure
            }
            if device.isFocusModeSupported(.continuousAutoFocus) {
                device.focusMode = .continuousAutoFocus
            }
            exposureLockedForFinger = false
        } catch { }
    }

    private func detect(_ sample: Double, at time: CFTimeInterval) {
        guard let previousTime = lastSampleTime else {
            dc = sample
            lastSampleTime = time
            return
        }
        let dt = max(1.0 / 120.0, min(0.2, time - previousTime))
        lastSampleTime = time
        guard var dc else { return }

        // A slow DC tracker removes illumination drift without tracking the
        // 0.5–3.3 Hz pulse. In transmission PPG, a heartbeat normally reduces
        // brightness; polarity calibration below also handles the inverse.
        let dcAlpha = min(0.05, dt / 2.5)
        dc += (sample - dc) * dcAlpha
        self.dc = dc
        let highPass = dc - sample
        let smoothing = min(0.45, dt / 0.10)
        filtered += (highPass - filtered) * smoothing
        positiveExtreme = max(positiveExtreme, filtered)
        negativeExtreme = min(negativeExtreme, filtered)
        usableFrames += 1

        // Pick one waveform orientation after the short warm-up. Either phase
        // produces the same RR interval; selecting only one avoids counting both
        // a crest and trough from a single heartbeat.
        if polarity == 0, usableFrames >= 45 {
            polarity = positiveExtreme >= -negativeExtreme ? 1 : -1
            envelope = 0
        }
        let oriented = polarity == 0 ? 0 : polarity * filtered
        envelope = max(abs(oriented), envelope * exp(-dt / 2.5))
        let threshold = envelope * 0.28

        // A local maximum with a 300 ms refractory period yields one candidate
        // per beat (30–200 BPM). Sample-buffer timestamps keep RR stable even if
        // the capture queue has an occasional scheduling delay.
        if polarity != 0,
           previousFiltered > priorFiltered,
           previousFiltered >= oriented,
           previousFiltered > threshold,
           time - lastPeakTime >= 0.30 {
            if lastPeakTime > 0 {
                let rr = (time - lastPeakTime) * 1000.0
                if (300...2000).contains(rr) { hub.registerBeat(rrMs: rr) }
            }
            lastPeakTime = time
        }
        priorFiltered = previousFiltered
        previousFiltered = oriented
    }

    private func publishRunning(_ value: Bool) {
        DispatchQueue.main.async { self.running = value }
    }

    private func publishError(_ message: String) {
        DispatchQueue.main.async {
            self.running = false
            self.errorMessage = message
        }
    }
}
