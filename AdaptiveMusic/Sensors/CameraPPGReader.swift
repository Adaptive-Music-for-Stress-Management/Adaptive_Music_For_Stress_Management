import Foundation
import AVFoundation
import Combine

/// Fingertip pulse (PPG) using the rear camera and torch.
///
/// With a finger over the lens the torch light passing through the tissue is
/// almost entirely red, and its intensity dips slightly on each heartbeat.
/// This reader averages the red level of the frame centre, removes the slow
/// baseline, and times the peaks to produce RR intervals and a BPM estimate.
final class CameraPPGReader: NSObject, ObservableObject, AVCaptureVideoDataOutputSampleBufferDelegate {

    @Published var running = false
    @Published var permissionDenied = false
    @Published var fingerDetected = false
    @Published var errorMessage: String? = nil
    @Published private(set) var activeCameraName = ""
    @Published private(set) var signalQuality = 0.0
    @Published private(set) var activeOpticalChannel = ""

    private let hub: SignalHub
    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "ppg.camera")
    private var device: AVCaptureDevice?
    private var configured = false

    // Detector state. All access happens on `queue`.
    private var detector = PulseDetector()
    private var frameCount = 0
    private var fingerFrames = 0
    private var contactScore = 0
    private var fingerPresent = false
    private var exposureLocked = false
    private var lastBeat: CFTimeInterval = 0
    private var lastBPMReport: CFTimeInterval = 0

    private static let fps = 30.0
    private static let contactAcquire = 4     // frames of red needed to acquire
    private static let contactMax = 12        // hysteresis ceiling
    private static let exposureSettleFrames = 30

    init(hub: SignalHub) {
        self.hub = hub
        super.init()
    }

    // MARK: - Lifecycle

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

    func stop() {
        queue.async { [self] in
            if let device, (try? device.lockForConfiguration()) != nil {
                if device.torchMode == .on { device.torchMode = .off }
                device.unlockForConfiguration()
            }
            session.stopRunning()
            resetState()
            publishRunning(false)
        }
    }

    func resetDetector() {
        queue.async { [self] in resetState() }
    }

    private func resetState() {
        detector.reset()
        frameCount = 0
        fingerFrames = 0
        contactScore = 0
        fingerPresent = false
        lastBeat = 0
        lastBPMReport = 0
        DispatchQueue.main.async {
            self.fingerDetected = false
            self.signalQuality = 0
            self.activeOpticalChannel = ""
        }
    }

    // MARK: - Capture setup

    private func configure() {
        if session.isRunning {
            if let device, enableTorch(on: device) { publishRunning(true) }
            return
        }

        if !configured {
            session.beginConfiguration()
            session.sessionPreset = .medium
            guard let camera = rearCamera() else {
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
            session.commitConfiguration()
            device = camera
            configured = true
        }

        guard let device else {
            publishError("The rear camera could not be prepared for pulse reading.")
            return
        }
        session.startRunning()
        // Starting the session can reset torch/exposure, so apply afterwards.
        guard enableTorch(on: device) else { return }
        publishRunning(true)
    }

    /// The main 1× wide camera sits next to the torch and cannot silently
    /// switch lenses the way a virtual multi-camera device can.
    private func rearCamera() -> AVCaptureDevice? {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera],
            mediaType: .video,
            position: .back
        )
        return discovery.devices.first
    }

    private func enableTorch(on camera: AVCaptureDevice) -> Bool {
        guard camera.isTorchAvailable else {
            publishError("This device's rear flashlight is unavailable, so it cannot read a fingertip pulse.")
            return false
        }
        do {
            try camera.lockForConfiguration()
            defer { camera.unlockForConfiguration() }
            try camera.setTorchModeOn(level: AVCaptureDevice.maxAvailableTorchLevel)
            setAutoExposure(camera, enabled: true)
            let duration = CMTime(value: 1, timescale: CMTimeScale(Self.fps))
            if camera.activeFormat.videoSupportedFrameRateRanges.contains(where: {
                $0.minFrameRate <= Self.fps && $0.maxFrameRate >= Self.fps
            }) {
                camera.activeVideoMinFrameDuration = duration
                camera.activeVideoMaxFrameDuration = duration
            }
            exposureLocked = false
            DispatchQueue.main.async { self.activeCameraName = "rear camera · \(Int(Self.fps)) fps" }
            return true
        } catch {
            publishError("The camera flashlight could not be enabled for pulse reading.")
            return false
        }
    }

    /// Auto exposure fights the pulse signal once a finger is on the lens, so
    /// it is locked after the image has settled and released when the finger
    /// leaves. Caller must hold `lockForConfiguration`.
    private func setAutoExposure(_ camera: AVCaptureDevice, enabled: Bool) {
        let exposure: AVCaptureDevice.ExposureMode = enabled ? .continuousAutoExposure : .locked
        let focus: AVCaptureDevice.FocusMode = enabled ? .continuousAutoFocus : .locked
        if camera.isExposureModeSupported(exposure) { camera.exposureMode = exposure }
        if camera.isFocusModeSupported(focus) { camera.focusMode = focus }
    }

    private func setExposureLocked(_ locked: Bool) {
        guard locked != exposureLocked, let device,
              (try? device.lockForConfiguration()) != nil else { return }
        setAutoExposure(device, enabled: !locked)
        device.unlockForConfiguration()
        exposureLocked = locked
        if locked {
            // Exposure change shifts the baseline; restart the filter.
            detector.reset()
        }
    }

    // MARK: - Frames

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        guard let (red, green, blue) = centreRGB(of: pixelBuffer) else { return }
        frameCount += 1

        // Finger contact: strongly red-dominant and not black.
        let redFrame = red > 30 && red > green * 1.2 && red > blue * 1.2
        contactScore = redFrame ? min(Self.contactMax, contactScore + 2) : max(0, contactScore - 1)
        if fingerPresent {
            if contactScore == 0 { fingerPresent = false }
        } else if contactScore >= Self.contactAcquire {
            fingerPresent = true
        }
        if frameCount % 5 == 0 {
            let present = fingerPresent
            DispatchQueue.main.async { self.fingerDetected = present }
        }

        guard fingerPresent else {
            fingerFrames = 0
            detector.reset()
            setExposureLocked(false)
            return
        }

        fingerFrames += 1
        if fingerFrames == Self.exposureSettleFrames { setExposureLocked(true) }

        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let t = pts.isValid ? CMTimeGetSeconds(pts) : CACurrentMediaTime()

        if let rr = detector.add(sample: red, at: t) {
            lastBeat = t
            hub.registerBeat(rrMs: rr)
        }
        // Fallback BPM estimate about once a second when beats are not being timed.
        if let bpm = detector.bpm, t - lastBeat > 2.2, t - lastBPMReport > 1.0 {
            lastBPMReport = t
            hub.registerCameraBPMEstimate(bpm)
        }
        if frameCount % 10 == 0 {
            let quality = detector.quality
            DispatchQueue.main.async {
                self.signalQuality = quality
                self.activeOpticalChannel = "red"
            }
        }
    }

    /// Mean R, G, B over the middle half of the frame (the part of the sensor
    /// most reliably covered by the finger), sampled every 4th pixel.
    private func centreRGB(of buffer: CVPixelBuffer) -> (Double, Double, Double)? {
        guard let lumaBase = CVPixelBufferGetBaseAddressOfPlane(buffer, 0),
              let chromaBase = CVPixelBufferGetBaseAddressOfPlane(buffer, 1) else { return nil }
        let luma = lumaBase.assumingMemoryBound(to: UInt8.self)
        let chroma = chromaBase.assumingMemoryBound(to: UInt8.self)
        let width = CVPixelBufferGetWidthOfPlane(buffer, 0)
        let height = CVPixelBufferGetHeightOfPlane(buffer, 0)
        let lumaStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        let chromaStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1)

        var r = 0.0, g = 0.0, b = 0.0
        var n = 0
        var y = height / 4
        while y < height * 3 / 4 {
            var x = width / 4
            while x < width * 3 / 4 {
                let yy = Double(luma[y * lumaStride + x])
                let c = (y / 2) * chromaStride + (x / 2) * 2
                let cb = Double(chroma[c]) - 128
                let cr = Double(chroma[c + 1]) - 128
                r += yy + 1.402 * cr
                g += yy - 0.344136 * cb - 0.714136 * cr
                b += yy + 1.772 * cb
                n += 1
                x += 4
            }
            y += 4
        }
        guard n > 0 else { return nil }
        let d = Double(n)
        return (r / d, g / d, b / d)
    }

    // MARK: - Publishing

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

// MARK: - Pulse detector

/// Simple peak detector on a single PPG channel:
/// baseline removal (moving average) → light smoothing → local-maximum peaks
/// above an adaptive threshold with a refractory period → RR intervals.
private struct PulseDetector {
    private static let baselineWindow = 45      // ~1.5 s at 30 fps
    private static let smoothWindow = 5
    private static let warmupSamples = 60       // ignore first 2 s after reset
    private static let minRR = 0.33             // 180 bpm
    private static let maxRR = 2.0              // 30 bpm
    private static let rrHistory = 8

    private var raw: [Double] = []
    private var filtered: [Double] = []
    private var samples = 0
    private var peakAmplitude = 0.0
    private var lastPeakTime: CFTimeInterval = 0
    private var rrs: [Double] = []

    /// Median-based BPM over recent beats, or nil until a few beats exist.
    var bpm: Double? {
        guard rrs.count >= 3 else { return nil }
        return 60 / rrs.sorted()[rrs.count / 2]
    }

    /// 0…1: how regular the recent RR intervals are.
    var quality: Double {
        guard rrs.count >= 3 else { return 0 }
        let mean = rrs.reduce(0, +) / Double(rrs.count)
        let sd = (rrs.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(rrs.count)).squareRoot()
        return max(0, min(1, 1 - (sd / mean) / 0.25))
    }

    mutating func reset() {
        raw.removeAll(keepingCapacity: true)
        filtered.removeAll(keepingCapacity: true)
        samples = 0
        peakAmplitude = 0
        lastPeakTime = 0
        rrs.removeAll(keepingCapacity: true)
    }

    /// Feed one sample. Returns an RR interval in ms when a beat is detected.
    mutating func add(sample: Double, at t: CFTimeInterval) -> Double? {
        samples += 1
        raw.append(sample)
        if raw.count > Self.baselineWindow { raw.removeFirst() }
        let baseline = raw.reduce(0, +) / Double(raw.count)

        // Blood inflow darkens the image, so invert: a beat becomes a peak.
        filtered.append(baseline - sample)
        if filtered.count > Self.smoothWindow { filtered.removeFirst() }
        guard samples > Self.warmupSamples, filtered.count == Self.smoothWindow else { return nil }

        // Look at the centre of the smoothing window so we can see both sides.
        let mid = Self.smoothWindow / 2
        let v = filtered[mid]
        let isLocalMax = (0..<Self.smoothWindow).allSatisfy { $0 == mid || filtered[$0] <= v }

        // Adaptive threshold tracks recent peak height and decays slowly.
        peakAmplitude *= 0.995
        guard isLocalMax, v > 0.15, v > peakAmplitude * 0.4 else { return nil }
        peakAmplitude = max(peakAmplitude, v)

        let peakTime = t - Double(mid) / 30.0
        let rr = peakTime - lastPeakTime
        guard rr >= Self.minRR else { return nil }
        lastPeakTime = peakTime
        guard rr <= Self.maxRR else { return nil }      // first beat / lost signal

        rrs.append(rr)
        if rrs.count > Self.rrHistory { rrs.removeFirst() }
        return rr * 1000
    }
}
