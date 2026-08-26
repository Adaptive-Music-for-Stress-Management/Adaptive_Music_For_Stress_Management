import Foundation

/// Output from one camera-PPG frame. BPM is produced by rolling periodicity
/// analysis; RR is produced only by an individually timed, quality-checked beat.
struct CameraPPGResult {
    let bpm: Double?
    let rrMs: Double?
    let quality: Double
    let channelName: String?
}

/// Device-independent signal processing for contact camera PPG.
///
/// The camera supplies spatially averaged RGB values. Each channel is
/// normalized, high-pass filtered to remove exposure drift, and low-pass
/// filtered twice to reject frame noise. A rolling autocorrelation chooses the
/// channel with the clearest periodic pulse and supplies a robust BPM fallback;
/// local, sub-frame-interpolated peaks supply the RR intervals needed for HRV.
struct PPGSignalProcessor {
    private static let minimumPulseQuality = 0.32

    private enum Channel: Int, CaseIterable {
        case red, green, blue

        var name: String {
            switch self {
            case .red: return "red"
            case .green: return "green"
            case .blue: return "blue"
            }
        }
    }

    private struct ChannelFilter {
        var baseline: Double?
        var lowPass1 = 0.0
        var lowPass2 = 0.0

        mutating func append(_ value: Double, dt: Double) -> Double {
            guard var baseline else {
                self.baseline = value
                return 0
            }

            // Roughly 0.35–4 Hz retains 21–240 BPM while removing exposure
            // drift and high-frequency sensor noise. Cascading the low-pass
            // section gives a steeper, second-order roll-off.
            let highPassAlpha = 1 - exp(-dt / 0.45)
            baseline += (value - baseline) * highPassAlpha
            self.baseline = baseline
            let normalized = (baseline - value) / max(1, baseline)
            let lowPassAlpha = 1 - exp(-dt / 0.040)
            lowPass1 += (normalized - lowPass1) * lowPassAlpha
            lowPass2 += (lowPass1 - lowPass2) * lowPassAlpha
            return lowPass2
        }
    }

    private struct Sample {
        let time: CFTimeInterval
        let values: [Double]
    }

    private struct Candidate {
        let channel: Channel
        let bpm: Double
        let quality: Double
    }

    private var filters = [ChannelFilter(), ChannelFilter(), ChannelFilter()]
    private var samples: [Sample] = []
    private var rawLevels = [0.0, 0.0, 0.0]
    private var lastTime: CFTimeInterval?
    private var lastAnalysisTime: CFTimeInterval = 0
    private var selectedChannel: Channel?
    private var smoothedBPM: Double?
    private var pendingBPM: Double?
    private var pendingBPMCount = 0
    private var quality = 0.0

    // Peak timing state for true beat-to-beat intervals.
    private var selectedFrames = 0
    private var polarity = 0.0
    private var positiveExtreme = 0.0
    private var negativeExtreme = 0.0
    private var envelope = 0.0
    private var point0: (time: CFTimeInterval, value: Double)?
    private var point1: (time: CFTimeInterval, value: Double)?
    private var lastBeatTime: CFTimeInterval?

    mutating func reset() {
        self = PPGSignalProcessor()
    }

    mutating func append(red: Double, green: Double, blue: Double,
                         at time: CFTimeInterval) -> CameraPPGResult {
        guard let previousTime = lastTime else {
            lastTime = time
            rawLevels = [red, green, blue]
            return CameraPPGResult(bpm: nil, rrMs: nil, quality: 0, channelName: nil)
        }

        let dt = max(1.0 / 240.0, min(0.20, time - previousTime))
        lastTime = time
        let raw = [red, green, blue]
        var filtered = [Double](repeating: 0, count: Channel.allCases.count)
        for channel in Channel.allCases {
            let index = channel.rawValue
            rawLevels[index] += (raw[index] - rawLevels[index]) * min(1, dt / 0.5)
            filtered[index] = filters[index].append(raw[index], dt: dt)
        }

        samples.append(Sample(time: time, values: filtered))
        let oldestAllowed = time - 8.0
        if let firstValid = samples.firstIndex(where: { $0.time >= oldestAllowed }), firstValid > 0 {
            samples.removeFirst(firstValid)
        }

        var bpmUpdate: Double?
        if time - lastAnalysisTime >= 0.5 {
            lastAnalysisTime = time
            bpmUpdate = analyzePeriodicity(at: time)
        }

        let rr = detectBeat(filtered, at: time, dt: dt)
        return CameraPPGResult(
            bpm: bpmUpdate,
            rrMs: rr,
            quality: quality,
            channelName: selectedChannel?.name
        )
    }

    private mutating func analyzePeriodicity(at time: CFTimeInterval) -> Double? {
        let window = samples.filter { $0.time >= time - 6.0 }
        guard window.count >= 80,
              let first = window.first,
              let last = window.last,
              last.time - first.time >= 3.0 else { return nil }

        let sampleRate = Double(window.count - 1) / (last.time - first.time)
        guard (18...120).contains(sampleRate) else { return nil }

        var candidates: [Candidate] = []
        for channel in Channel.allCases {
            if let candidate = periodicityCandidate(channel: channel,
                                                    window: window,
                                                    sampleRate: sampleRate) {
                candidates.append(candidate)
            }
        }
        guard let strongest = candidates.max(by: { $0.quality < $1.quality }) else {
            quality *= 0.8
            return nil
        }

        // Channel hysteresis prevents a tiny score difference from changing
        // waveform phase and invalidating an otherwise good RR sequence.
        var chosen = strongest
        if let selectedChannel,
           let current = candidates.first(where: { $0.channel == selectedChannel }),
           current.quality >= strongest.quality * 0.82 {
            chosen = current
        }
        if selectedChannel != chosen.channel {
            selectedChannel = chosen.channel
            resetPeakTiming()
        }
        quality = chosen.quality

        guard chosen.quality >= Self.minimumPulseQuality else { return nil }
        let accepted = stabilize(chosen.bpm)
        guard let accepted else { return nil }
        smoothedBPM = smoothedBPM == nil ? accepted : 0.35 * accepted + 0.65 * smoothedBPM!
        return smoothedBPM
    }

    private func periodicityCandidate(channel: Channel, window: [Sample],
                                      sampleRate: Double) -> Candidate? {
        let index = channel.rawValue
        let values = window.map { $0.values[index] }
        let mean = values.reduce(0, +) / Double(values.count)
        let centered = values.map { $0 - mean }
        let rms = sqrt(centered.reduce(0) { $0 + $1 * $1 } / Double(centered.count))
        guard rms > 0.000008 else { return nil }

        // Search slightly beyond the reported 40–200 BPM range so valid edge
        // frequencies are local peaks rather than excluded array boundaries.
        let minLag = max(2, Int((sampleRate * 60 / 220).rounded()))
        let maxLag = min(centered.count / 2, Int((sampleRate * 60 / 35).rounded()))
        guard maxLag > minLag + 2 else { return nil }

        func normalizedCorrelation(at lag: Int) -> Double {
            guard lag > 0, lag < centered.count else { return -1 }
            var numerator = 0.0
            var leftEnergy = 0.0
            var rightEnergy = 0.0
            for i in lag..<centered.count {
                let left = centered[i]
                let right = centered[i - lag]
                numerator += left * right
                leftEnergy += left * left
                rightEnergy += right * right
            }
            return numerator / max(1e-12, sqrt(leftEnergy * rightEnergy))
        }

        var correlations = [Double](repeating: -1, count: maxLag + 1)
        for lag in minLag...maxLag {
            correlations[lag] = normalizedCorrelation(at: lag)
        }

        var peaks: [(lag: Int, correlation: Double)] = []
        if minLag + 1 < maxLag {
            for lag in (minLag + 1)..<maxLag where
                correlations[lag] > correlations[lag - 1] &&
                correlations[lag] >= correlations[lag + 1] &&
                correlations[lag] > 0 {
                peaks.append((lag, correlations[lag]))
            }
        }
        guard let highest = peaks.max(by: { $0.correlation < $1.correlation }) else { return nil }

        // Autocorrelation also peaks at two and three pulse periods. Select the
        // earliest local peak that is nearly as coherent as the strongest one.
        let selected = peaks
            .filter { $0.correlation >= highest.correlation * 0.88 }
            .min(by: { $0.lag < $1.lag }) ?? highest
        let lag = selected.lag
        let y0 = correlations[lag - 1]
        let y1 = correlations[lag]
        let y2 = correlations[lag + 1]
        let denominator = y0 - 2 * y1 + y2
        let offset = abs(denominator) > 1e-9
            ? max(-0.5, min(0.5, 0.5 * (y0 - y2) / denominator))
            : 0
        let refinedLag = Double(lag) + offset
        let bpm = 60 * sampleRate / refinedLag
        guard (40...200).contains(bpm) else { return nil }

        // Reject saturated channels and channels with only quantization noise.
        let level = rawLevels[index]
        let rangeScore: Double
        if level <= 2 || level >= 253 {
            rangeScore = 0.12
        } else if level <= 6 || level >= 248 {
            rangeScore = 0.55
        } else {
            rangeScore = 1
        }
        let amplitudeScore = min(1, rms / 0.00012)
        let correlationScore = max(0, min(1, (selected.correlation - 0.12) / 0.70))
        // A true pulse repeats at both one and two beat periods. Requiring that
        // second recurrence suppresses narrow, chance autocorrelation peaks
        // from filtered camera noise without raising the amplitude threshold.
        let repeatCorrelation = normalizedCorrelation(at: min(centered.count - 1, lag * 2))
        let repeatScore = max(0, min(1, (repeatCorrelation - 0.02) / 0.65))
        let greenPreference = channel == .green ? 1.05 : (channel == .blue ? 0.90 : 1.0)
        let quality = max(0, min(1, correlationScore * sqrt(repeatScore) *
            amplitudeScore * rangeScore * greenPreference))
        return Candidate(channel: channel, bpm: bpm, quality: quality)
    }

    private mutating func stabilize(_ candidate: Double) -> Double? {
        guard let current = smoothedBPM else {
            pendingBPM = nil
            pendingBPMCount = 0
            return candidate
        }
        let allowedJump = max(12, current * 0.20)
        if abs(candidate - current) <= allowedJump {
            pendingBPM = nil
            pendingBPMCount = 0
            return candidate
        }

        if let pendingBPM, abs(candidate - pendingBPM) <= max(8, pendingBPM * 0.12) {
            self.pendingBPM = 0.5 * candidate + 0.5 * pendingBPM
            pendingBPMCount += 1
        } else {
            pendingBPM = candidate
            pendingBPMCount = 1
        }
        guard pendingBPMCount >= 2 else { return nil }
        let accepted = pendingBPM
        self.pendingBPM = nil
        pendingBPMCount = 0
        return accepted
    }

    private mutating func detectBeat(_ filtered: [Double], at time: CFTimeInterval,
                                     dt: Double) -> Double? {
        guard let selectedChannel else { return nil }
        let rawWave = filtered[selectedChannel.rawValue]
        selectedFrames += 1
        positiveExtreme = max(positiveExtreme, rawWave)
        negativeExtreme = min(negativeExtreme, rawWave)
        if polarity == 0, selectedFrames >= 30 {
            polarity = positiveExtreme >= -negativeExtreme ? 1 : -1
            point0 = nil
            point1 = nil
        }
        guard polarity != 0 else { return nil }

        let wave = polarity * rawWave
        envelope = max(abs(wave), envelope * exp(-dt / 1.5))
        defer {
            point0 = point1
            point1 = (time, wave)
        }
        guard quality >= Self.minimumPulseQuality,
              selectedFrames >= 45,
              let p0 = point0,
              let p1 = point1,
              p1.value > p0.value,
              p1.value >= wave,
              p1.value > max(0.000008, envelope * 0.18) else { return nil }

        // Parabolic interpolation recovers sub-frame peak timing, which is
        // particularly valuable for HRV at 30–60 camera frames per second.
        let denominator = p0.value - 2 * p1.value + wave
        let offset = abs(denominator) > 1e-12
            ? max(-0.5, min(0.5, 0.5 * (p0.value - wave) / denominator))
            : 0
        let averageFrameTime = (time - p0.time) / 2
        let peakTime = p1.time + offset * averageFrameTime

        let expectedPeriod = smoothedBPM.map { 60 / $0 }
        let refractory = max(0.26, min(0.75, (expectedPeriod ?? 0.65) * 0.42))
        if let lastBeatTime, peakTime - lastBeatTime < refractory { return nil }
        guard let lastBeatTime else {
            self.lastBeatTime = peakTime
            return nil
        }

        let rrSeconds = peakTime - lastBeatTime
        if let expectedPeriod,
           !(expectedPeriod * 0.55...expectedPeriod * 1.55).contains(rrSeconds) {
            // A long gap is normally a missed optical peak. Re-anchor without
            // feeding that artifact into HRV; a short gap is usually a dicrotic
            // notch, so retain the previous true beat.
            if rrSeconds > expectedPeriod * 1.55 { self.lastBeatTime = peakTime }
            return nil
        }
        guard (0.30...2.0).contains(rrSeconds) else {
            if rrSeconds > 2.0 { self.lastBeatTime = peakTime }
            return nil
        }
        self.lastBeatTime = peakTime
        return rrSeconds * 1000
    }

    private mutating func resetPeakTiming() {
        selectedFrames = 0
        polarity = 0
        positiveExtreme = 0
        negativeExtreme = 0
        envelope = 0
        point0 = nil
        point1 = nil
        lastBeatTime = nil
    }
}
