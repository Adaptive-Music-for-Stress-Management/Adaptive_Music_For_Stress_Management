import Foundation
import AVFoundation

/// "Read data from mobile": the flashlight illuminates the fingertip on the back camera,
/// each heartbeat brightens/darkens the frame, and an adaptive-threshold peak detector
/// turns the brightness wave into beats. Beats arrive at the user's own heart rate —
/// i.e. one reading every 60/BPM seconds — exactly the sampling the dashboard graphs use.
final class CameraPPGReader: NSObject, ObservableObject, AVCaptureVideoDataOutputSampleBufferDelegate {

    @Published var running = false
    @Published var permissionDenied = false
    @Published var fingerDetected = false

    private let hub: SignalHub
    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "ppg.camera")
    private var device: AVCaptureDevice?

    // peak-detector state (same shape as the computer edition's PPG detector)
    private var dc: Double? = nil
    private var env: Double = 1.0
    private var prev: Double = 0
    private var above = false
    private var lastPeak: CFTimeInterval = 0

    init(hub: SignalHub) {
        self.hub = hub
        super.init()
    }

    func start() {
        AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
            guard let self else { return }
            DispatchQueue.main.async { self.permissionDenied = !granted }
            guard granted else { return }
            self.queue.async { self.configure() }
        }
    }

    private func configure() {
        guard !session.isRunning else { return }
        session.beginConfiguration()
        session.sessionPreset = .low                       // brightness average needs no resolution
        guard let cam = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              let input = try? AVCaptureDeviceInput(device: cam) else {
            session.commitConfiguration(); return
        }
        device = cam
        if session.canAddInput(input) { session.addInput(input) }
        let out = AVCaptureVideoDataOutput()
        out.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange]
        out.alwaysDiscardsLateVideoFrames = true
        out.setSampleBufferDelegate(self, queue: queue)
        if session.canAddOutput(out) { session.addOutput(out) }
        try? cam.lockForConfiguration()
        if cam.isTorchAvailable { try? cam.setTorchModeOn(level: 0.6) }   // flashlight ON the moment the reader starts
        cam.unlockForConfiguration()
        session.commitConfiguration()
        session.startRunning()
        // the torch drops when startRunning reconfigures — re-assert it
        try? cam.lockForConfiguration()
        if cam.isTorchAvailable { try? cam.setTorchModeOn(level: 0.6) }
        cam.unlockForConfiguration()
        DispatchQueue.main.async { self.running = true }
    }

    func stop() {
        queue.async { [self] in
            if let cam = device {
                try? cam.lockForConfiguration()
                if cam.torchMode == .on { cam.torchMode = .off }
                cam.unlockForConfiguration()
            }
            session.stopRunning()
            DispatchQueue.main.async { self.running = false }
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        // luma plane average = frame brightness (the PPG signal)
        guard let base = CVPixelBufferGetBaseAddressOfPlane(pb, 0) else { return }
        let w = CVPixelBufferGetWidthOfPlane(pb, 0)
        let h = CVPixelBufferGetHeightOfPlane(pb, 0)
        let stride = CVPixelBufferGetBytesPerRowOfPlane(pb, 0)
        let ptr = base.assumingMemoryBound(to: UInt8.self)
        var sum = 0
        var count = 0
        var y = 0
        while y < h {                                     // sample every 4th row/col — plenty
            var x = 0
            while x < w { sum += Int(ptr[y * stride + x]); count += 1; x += 4 }
            y += 4
        }
        let brightness = Double(sum) / Double(max(count, 1))
        // a covered lens (finger on camera+flash) is strongly red-lit: luma sits high
        DispatchQueue.main.async { self.fingerDetected = brightness > 40 }
        detect(brightness, at: CACurrentMediaTime())
    }

    private func detect(_ v: Double, at t: CFTimeInterval) {
        dc = dc == nil ? v : 0.96 * dc! + 0.04 * v
        let x = v - dc!
        env = max(abs(x), max(env * 0.995, 0.05))
        let thresh = 0.45 * env
        if !above && x > thresh && prev <= thresh {
            above = true
            if lastPeak > 0 {
                let rr = (t - lastPeak) * 1000.0
                if (300...2000).contains(rr) { hub.registerBeat(rrMs: rr) }
            }
            lastPeak = t
        } else if above && x < 0.1 * env {
            above = false
        }
        prev = x
    }
}
