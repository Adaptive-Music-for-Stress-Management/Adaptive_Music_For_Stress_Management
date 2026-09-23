import Foundation
import AVFoundation
import Combine

/// Fingertip photoplethysmography (PPG) using the rear camera and torch.
///
/// A covered lens transmits mostly red light. The capture path samples the
/// centre of the frame, lets auto-exposure settle under the fingertip, then
/// locks exposure while a multi-channel filtered detector estimates BPM and
/// turns quality-checked optical peaks into RR intervals.
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

    // Optical processing state. All access happens on `queue`.
    private var processor = PPGSignalProcessor()
    private var lastTimedBeat: CFTimeInterval = 0
    private var fingerFrames = 0
    private var missingFingerFrames = 0
    private var exposureLockedForFinger = false
    private var frameCount = 0
    private var contactConfidence = 0
    private var opticalFingerPresent = false
    private var captureFormatConfigured = false
    private var captureFPS = 30.0

    // Contact acquisition is intentionally faster than contact release. Two
    // convincingly red frames acquire a finger, while brief dim frames caused
    // by exposure settling do not discard the pulse filter.
    private static let contactAcquireScore = 4
    private static let contactMaximumScore = 12

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

    /// PPG needs the physical camera that receives the strongest illumination
    /// from the adjacent torch. Prefer the main 1× wide camera on every iPhone;
    /// unlike a virtual multi-camera device it cannot silently switch lenses.
    /// Telephoto remains a fallback for unusual devices where it is the only
    /// torch-capable rear camera.
    private func fingertipCamera() -> AVCaptureDevice? {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInTelephotoCamera, .builtInWideAngleCamera],
            mediaType: .video,
            position: .back
        )
        return discovery.devices.first(where: {
            $0.deviceType == .builtInWideAngleCamera && $0.isTorchAvailable
        }) ?? discovery.devices.first(where: {
            $0.deviceType == .builtInTelephotoCamera && $0.isTorchAvailable
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
            configureCaptureFormat(on: camera)
            // Maximum illumination improves transmission through darker or
            // thicker fingertips; AVFoundation applies the device-safe limit.
            try camera.setTorchModeOn(level: AVCaptureDevice.maxAvailableTorchLevel)
            if camera.isExposureModeSupported(.continuousAutoExposure) {
                camera.exposureMode = .continuousAutoExposure
            }
            if camera.isFocusModeSupported(.continuousAutoFocus) {
                camera.focusMode = .continuousAutoFocus
            }
            if camera.activeFormat.videoSupportedFrameRateRanges.contains(where: {
                $0.minFrameRate <= captureFPS && $0.maxFrameRate >= captureFPS
            }) {
                let duration = CMTime(value: 1, timescale: CMTimeScale(captureFPS.rounded()))
                camera.activeVideoMinFrameDuration = duration
                camera.activeVideoMaxFrameDuration = duration
            }
            exposureLockedForFinger = false
            let cameraName = camera.deviceType == .builtInWideAngleCamera
                ? "main 1× rear camera"
                : camera.localizedName
            let name = "\(cameraName) · \(Int(captureFPS.rounded())) fps"
            DispatchQueue.main.async { self.activeCameraName = name }
            return true
        } catch {
            publishError("The camera flashlight could not be enabled for pulse reading.")
            return false
        }
    }

    /// Use the lowest-resolution physical format that can sustain 60 fps. That
    /// doubles RR timing resolution compared with the old 30 fps path without
    /// wasting CPU on pixels that will only be spatially averaged. Older
    /// devices fall back to the same strategy at 30 fps.
    private func configureCaptureFormat(on camera: AVCaptureDevice) {
        guard !captureFormatConfigured else { return }
        struct FormatChoice {
            let format: AVCaptureDevice.Format
            let fps: Double
            let area: Int64
        }

        var choice: FormatChoice?
        for desiredFPS in [60.0, 30.0] where choice == nil {
            let candidates = camera.formats.compactMap { format -> FormatChoice? in
                let supportsRate = format.videoSupportedFrameRateRanges.contains {
                    $0.minFrameRate <= desiredFPS && $0.maxFrameRate >= desiredFPS
                }
                guard supportsRate else { return nil }
                let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
                guard dimensions.width >= 320, dimensions.height >= 240 else { return nil }
                return FormatChoice(
                    format: format,
                    fps: desiredFPS,
                    area: Int64(dimensions.width) * Int64(dimensions.height)
                )
            }
            choice = candidates.min(by: { $0.area < $1.area })
        }
        if let choice {
            camera.activeFormat = choice.format
            captureFPS = choice.fps
        } else if let range = camera.activeFormat.videoSupportedFrameRateRanges.first {
            captureFPS = min(30, range.maxFrameRate)
        }
        captureFormatConfigured = true
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
        contactConfidence = 0
        opticalFingerPresent = false
        DispatchQueue.main.async {
            self.fingerDetected = false
            self.signalQuality = 0
            self.activeOpticalChannel = ""
        }
    }

    private func resetPulseFilterState() {
        processor.reset()
        lastTimedBeat = 0
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
        var cbSum = 0.0
        var crSum = 0.0
        var redSum = 0.0
        var greenSum = 0.0
        var blueSum = 0.0
        var count = 0
        var y = yStart
        while y < yEnd {
            var x = xStart
            while x < xEnd {
                let luminance = Double(luma[y * lumaStride + x])
                lumaSum += luminance
                var cb = 128.0
                var cr = 128.0
                if let chroma, chromaWidth > 0, chromaHeight > 0 {
                    let chromaY = min(chromaHeight - 1, y / 2)
                    let chromaX = min(chromaWidth - 1, x / 2)
                    // Full-range bi-planar output stores chroma as Cb, Cr.
                    cb = Double(chroma[chromaY * chromaStride + chromaX * 2])
                    cr = Double(chroma[chromaY * chromaStride + chromaX * 2 + 1])
                    cbSum += cb
                    crSum += cr
                }
                // Full-range BT.601 YCbCr conversion. Spatial averaging before
                // temporal processing suppresses sensor noise at very low cost.
                let red = luminance + 1.402 * (cr - 128)
                let green = luminance - 0.344136 * (cb - 128) - 0.714136 * (cr - 128)
                let blue = luminance + 1.772 * (cb - 128)
                redSum += max(0, min(255, red))
                greenSum += max(0, min(255, green))
                blueSum += max(0, min(255, blue))
                count += 1
                x += 4
            }
            y += 4
        }
        guard count > 0 else { return }
        let meanLuma = lumaSum / Double(count)
        let meanCb = chroma == nil ? 128 : cbSum / Double(count)
        let meanCr = chroma == nil ? 128 : crSum / Double(count)
        let redChroma = meanCr - meanCb
        let meanRed = redSum / Double(count)
        let meanGreen = greenSum / Double(count)
        let meanBlue = blueSum / Double(count)

        // A torch-lit fingertip is red/orange even when its luma is very low.
        // Accept either YCbCr redness or RGB red dominance so camera-specific
        // color conversion and darker/thicker fingertips do not block contact.
        let chromaContact = meanCr > 124 && redChroma > 0.5
        let rgbContact = meanRed > 8 &&
            meanRed > meanGreen * 1.035 && meanRed > meanBlue * 1.035
        let opticalCandidate = meanLuma > 3 && (chromaContact || rgbContact)
        if opticalCandidate {
            contactConfidence = min(Self.contactMaximumScore, contactConfidence + 2)
        } else {
            contactConfidence = max(0, contactConfidence - 1)
        }
        if opticalFingerPresent {
            if contactConfidence == 0 { opticalFingerPresent = false }
        } else if contactConfidence >= Self.contactAcquireScore {
            opticalFingerPresent = true
        }
        let coveredFinger = opticalFingerPresent
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
        let exposureSettleFrames = max(30, Int(captureFPS.rounded()))
        if fingerFrames == exposureSettleFrames { lockExposureForFingerIfPossible() }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let timestamp = pts.isValid ? CMTimeGetSeconds(pts) : CACurrentMediaTime()
        let result = processor.append(red: meanRed, green: meanGreen, blue: meanBlue,
                                      at: timestamp)
        if let rr = result.rrMs {
            lastTimedBeat = timestamp
            hub.registerBeat(rrMs: rr)
        }
        if let bpm = result.bpm, timestamp - lastTimedBeat > 2.2 {
            hub.registerCameraBPMEstimate(bpm)
        }
        if frameCount % 10 == 0 {
            DispatchQueue.main.async {
                self.signalQuality = result.quality
                self.activeOpticalChannel = result.channelName ?? ""
            }
        }
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
            // warm-up using the stable, locked image without forgetting that a
            // finger is still present.
            resetPulseFilterState()
            fingerFrames = 0
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
