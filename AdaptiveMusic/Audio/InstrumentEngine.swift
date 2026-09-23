import Foundation
import AVFoundation

/// Play-along synthesizer: a one-octave piano and an eight-pad drum kit,
/// all synthesized into PCM buffers at init (no samples needed) and fired
/// through a small pool of player nodes so taps can overlap.
final class InstrumentEngine {
    private class WeakInstrument {
        weak var value: InstrumentEngine?
        init(_ value: InstrumentEngine) { self.value = value }
    }
    private static var instances: [WeakInstrument] = []
    static var spotifyOwnsAudio = false
    static func stopAllInstruments() {
        instances = instances.filter { $0.value != nil }
        for entry in instances { entry.value?.pool.forEach { $0.stop() } }
    }

    enum Drum: String, CaseIterable, Identifiable {
        case kick = "Kick", hihat = "Hi-hat", snare = "Snare"
        case lowTom = "Low-tom", midTom = "Mid-tom", highTom = "High-tom"
        case crash = "Crash", ride = "Ride"
        var id: String { rawValue }
    }

    private let engine = AVAudioEngine()
    private let format: AVAudioFormat
    private var pool: [AVAudioPlayerNode] = []
    private var poolIndex = 0
    private var noteBuffers: [Int: AVAudioPCMBuffer] = [:]      // midi -> buffer
    private var drumBuffers: [Drum: AVAudioPCMBuffer] = [:]

    static let sampleRate = 44_100.0

    init() {
        format = AVAudioFormat(standardFormatWithSampleRate: InstrumentEngine.sampleRate, channels: 1)!
        for _ in 0..<10 {
            let node = AVAudioPlayerNode()
            engine.attach(node)
            engine.connect(node, to: engine.mainMixerNode, format: format)
            pool.append(node)
        }
        for midi in 60...71 { noteBuffers[midi] = InstrumentEngine.makeNote(midi: midi, format: format) }
        for drum in Drum.allCases { drumBuffers[drum] = InstrumentEngine.makeDrum(drum, format: format) }
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [.mixWithOthers])
        try? AVAudioSession.sharedInstance().setActive(true)
        try? engine.start()
        Self.instances.append(WeakInstrument(self))
    }

    func playNote(midi: Int)   { fire(noteBuffers[midi]) }
    func playDrum(_ drum: Drum){ fire(drumBuffers[drum]) }

    private func fire(_ buffer: AVAudioPCMBuffer?) {
        guard !Self.spotifyOwnsAudio else { return }
        guard let buffer else { return }
        if !engine.isRunning { try? engine.start() }
        let node = pool[poolIndex]; poolIndex = (poolIndex + 1) % pool.count
        node.stop()
        node.scheduleBuffer(buffer, at: nil)
        node.play()
    }

    // MARK: - synthesis

    private static func buffer(seconds: Double, format: AVAudioFormat,
                               fill: (Int, Double) -> Double) -> AVAudioPCMBuffer {
        let frames = AVAudioFrameCount(seconds * sampleRate)
        let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buf.frameLength = frames
        let data = buf.floatChannelData![0]
        for i in 0..<Int(frames) {
            data[i] = Float(fill(i, Double(i) / sampleRate))
        }
        return buf
    }

    /// Piano-ish voice: triangle fundamental + sine octave with a plucked envelope.
    private static func makeNote(midi: Int, format: AVAudioFormat) -> AVAudioPCMBuffer {
        let f = 440.0 * pow(2.0, Double(midi - 69) / 12.0)
        return buffer(seconds: 1.4, format: format) { _, t in
            let env = t < 0.012 ? t / 0.012 : exp(-3.2 * (t - 0.012))
            let phase = 2 * .pi * f * t
            let tri = 2.0 / .pi * asin(sin(phase))                       // triangle
            let oct = 0.25 * sin(2 * phase)
            return 0.42 * env * (tri + oct)
        }
    }

    private static func makeDrum(_ drum: Drum, format: AVAudioFormat) -> AVAudioPCMBuffer {
        var seed: UInt64 = 0x9E3779B97F4A7C15
        func noise() -> Double {                                        // fast deterministic white noise
            seed ^= seed << 13; seed ^= seed >> 7; seed ^= seed << 17
            return Double(Int64(bitPattern: seed)) / Double(Int64.max)
        }
        func sweep(_ f0: Double, _ f1: Double, _ dur: Double, _ vol: Double) -> AVAudioPCMBuffer {
            buffer(seconds: dur, format: format) { _, t in
                let k = t / dur
                let f = f0 * pow(f1 / f0, k)                            // exponential glide
                let env = exp(-6.0 * k)
                return vol * env * sin(2 * .pi * f * t)
            }
        }
        func noiseBurst(_ dur: Double, _ vol: Double, lowpass: Double = 1.0) -> AVAudioPCMBuffer {
            var y = 0.0
            return buffer(seconds: dur, format: format) { _, t in
                let env = exp(-8.0 * t / dur)
                let n = noise()
                y += lowpass * (n - y)                                  // crude 1-pole filter
                return vol * env * (lowpass >= 1.0 ? n : n - y)         // hp-ish for cymbals
            }
        }
        switch drum {
        case .kick:    return sweep(150, 42, 0.45, 0.95)
        case .lowTom:  return sweep(120, 70, 0.40, 0.85)
        case .midTom:  return sweep(170, 100, 0.35, 0.85)
        case .highTom: return sweep(230, 140, 0.30, 0.85)
        case .snare:
            let tone = sweep(210, 160, 0.16, 0.5)
            let nz = noiseBurst(0.18, 0.7, lowpass: 0.55)
            return mix(tone, nz, format: format)
        case .hihat:   return noiseBurst(0.07, 0.5, lowpass: 0.15)
        case .crash:   return noiseBurst(1.1, 0.5, lowpass: 0.35)
        case .ride:    return noiseBurst(0.7, 0.35, lowpass: 0.25)
        }
    }

    private static func mix(_ a: AVAudioPCMBuffer, _ b: AVAudioPCMBuffer,
                            format: AVAudioFormat) -> AVAudioPCMBuffer {
        let frames = max(a.frameLength, b.frameLength)
        let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        out.frameLength = frames
        let o = out.floatChannelData![0], pa = a.floatChannelData![0], pb = b.floatChannelData![0]
        for i in 0..<Int(frames) {
            let va = i < Int(a.frameLength) ? pa[i] : 0
            let vb = i < Int(b.frameLength) ? pb[i] : 0
            o[i] = va + vb
        }
        return out
    }
}
