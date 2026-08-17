import Foundation
import AVFoundation
import Combine

/// SUNO AI library player.
///   bucket = clamp((BPM // 10) * 10 - 10, 60, 150)  -> BPM_folder/<bucket>/song_*.mp3
///   random song per bucket, no repeats until the whole folder (cycle of 3) has played,
///   fade OUT - fade IN on every switch, and an AVAudioEngine tap for the waveform visualizer.
final class SunoPlayer: NSObject, ObservableObject {

    @Published var playing = false
    @Published var songName: String? = nil
    @Published var bucket: Int? = nil               // bucket of the audible song
    @Published var currentTime: Double = 0
    @Published var duration: Double = 0
    @Published var bucketOverride: Int? = nil       // Breathe forces the target bucket

    /// Most recent waveform samples for the visualizer.
    private(set) var waveform: [Float] = Array(repeating: 0, count: 256)

    private let hub: SignalHub
    private let engine = AVAudioEngine()
    private let nodeA = AVAudioPlayerNode()
    private let nodeB = AVAudioPlayerNode()
    private var activeIsA = true
    private var fileA: AVAudioFile?
    private var fileB: AVAudioFile?
    private var offsetA: Double = 0                 // seek offset in seconds for each node
    private var offsetB: Double = 0
    private var switching = false
    private var playedPerBucket: [Int: Set<String>] = [:]
    private var ticker: AnyCancellable?

    private var activeNode: AVAudioPlayerNode { activeIsA ? nodeA : nodeB }
    private var activeFile: AVAudioFile? { activeIsA ? fileA : fileB }
    private var activeOffset: Double {
        get { activeIsA ? offsetA : offsetB }
        set { if activeIsA { offsetA = newValue } else { offsetB = newValue } }
    }

    init(hub: SignalHub) {
        self.hub = hub
        super.init()
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
        try? AVAudioSession.sharedInstance().setActive(true)
        engine.attach(nodeA)
        engine.attach(nodeB)
        engine.connect(nodeA, to: engine.mainMixerNode, format: nil)
        engine.connect(nodeB, to: engine.mainMixerNode, format: nil)
        installTap()
        try? engine.start()
        ticker = Timer.publish(every: 0.25, on: .main, in: .common).autoconnect().sink { [weak self] _ in
            self?.tick()
        }
    }

    private func installTap() {
        let format = engine.mainMixerNode.outputFormat(forBus: 0)
        engine.mainMixerNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            guard let self, let data = buffer.floatChannelData?[0] else { return }
            let n = Int(buffer.frameLength)
            guard n > 0 else { return }
            var wf = [Float](repeating: 0, count: 256)
            let step = max(1, n / 256)
            for i in 0..<n {
                let slot = i / step
                if slot < 256 { wf[slot] = data[i] }
            }
            DispatchQueue.main.async {                 // render thread must not race main-thread readers
                self.waveform = wf
            }
        }
    }

    // MARK: - library

    static func libraryURL() -> URL? {
        if let url = Bundle.main.resourceURL?.appendingPathComponent("BPM_folder"),
           FileManager.default.fileExists(atPath: url.path) { return url }
        return nil
    }

    private func tracks(in bucket: Int) -> [URL] {
        guard let lib = SunoPlayer.libraryURL() else { return [] }
        let folder = lib.appendingPathComponent(String(bucket))
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return files.filter { ["mp3", "wav", "m4a", "flac"].contains($0.pathExtension.lowercased()) }
                    .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Random unplayed song from the bucket's folder — a song never repeats within a cycle.
    private func nextTrack(bucket: Int) -> URL? {
        let all = tracks(in: bucket)
        guard !all.isEmpty else { return nil }
        var played = playedPerBucket[bucket, default: []].intersection(all.map(\.lastPathComponent))
        var pool = all.filter { !played.contains($0.lastPathComponent) }
        if pool.isEmpty {                              // cycle complete -> start a fresh one
            played = []
            pool = all.filter { $0.lastPathComponent != songName } .nilIfEmpty ?? all
        }
        let pick = pool.randomElement()!
        played.insert(pick.lastPathComponent)
        playedPerBucket[bucket] = played
        return pick
    }

    // MARK: - target following

    var targetBucket: Int {
        if let o = bucketOverride { return o }
        return hub.bucket ?? bucket ?? 60
    }

    private func tick() {
        // timeline
        if let file = activeFile, playing {
            duration = Double(file.length) / file.processingFormat.sampleRate
            if let t = activeNode.lastRenderTime, let pt = activeNode.playerTime(forNodeTime: t) {
                currentTime = min(duration, activeOffset + Double(pt.sampleTime) / pt.sampleRate)
            }
            if duration > 0, currentTime >= duration - 0.3, !switching {   // song over -> next in bucket
                switchSong(to: targetBucket)
            }
        }
        // follow the live BPM bucket (or the Breathe override) with a fade-out / fade-in
        if playing, !switching, let cur = self.bucket, targetBucket != cur {
            switchSong(to: targetBucket)
        }
    }

    // MARK: - transport

    /// Start a node only when the engine is actually running — play() on a stopped
    /// engine raises an uncatchable NSException.
    private func startNode(_ node: AVAudioPlayerNode) {
        if !engine.isRunning { try? engine.start() }
        guard engine.isRunning else { return }
        node.play()
    }

    func play() {
        if activeFile == nil { switchSong(to: targetBucket); return }
        playing = true
        startNode(activeNode)
        ramp(node: activeNode, to: 1.0, over: 0.7)
    }

    func pause() {
        playing = false
        ramp(node: activeNode, to: 0.0, over: 0.4) { [weak self] in self?.activeNode.pause() }
    }

    func togglePlay() { playing ? pause() : play() }

    /// « and » — another song from the current target bucket.
    func skip() { switchSong(to: targetBucket) }

    func seek(to time: Double) {
        guard let file = activeFile, duration > 0 else { return }
        let node = activeNode
        let t = max(0, min(duration - 0.2, time))
        let sr = file.processingFormat.sampleRate
        let startFrame = AVAudioFramePosition(t * sr)
        let frames = AVAudioFrameCount(max(0, file.length - startFrame))
        node.stop()
        guard frames > 0 else { return }
        file.framePosition = startFrame
        node.scheduleSegment(file, startingFrame: startFrame, frameCount: frames, at: nil)
        activeOffset = t
        currentTime = t
        if playing { startNode(node) }
    }

    /// Fade the current song out completely, then fade the next one in (spec: fade out - fade in).
    func switchSong(to newBucket: Int) {
        guard !switching else { return }
        guard let url = nextTrack(bucket: newBucket) else { return }
        switching = true
        let oldNode = activeNode
        let fadeOut = activeFile != nil && playing ? 1.1 : 0.0
        ramp(node: oldNode, to: 0.0, over: fadeOut) { [weak self] in
            guard let self else { return }
            oldNode.stop()
            self.activeIsA.toggle()
            let node = self.activeNode
            do {
                let file = try AVAudioFile(forReading: url)
                if self.activeIsA { self.fileA = file; self.offsetA = 0 } else { self.fileB = file; self.offsetB = 0 }
                node.stop()
                node.scheduleFile(file, at: nil)
                node.volume = 0
                self.songName = url.lastPathComponent
                self.bucket = newBucket
                self.duration = Double(file.length) / file.processingFormat.sampleRate
                self.currentTime = 0
                self.playing = true
                self.startNode(node)
                self.ramp(node: node, to: 1.0, over: 1.1)
            } catch {
                print("[suno] could not open \(url.lastPathComponent): \(error)")
            }
            self.switching = false
        }
    }

    func stopAll() {
        playing = false
        nodeA.stop(); nodeB.stop()
    }

    private var rampTimers: [ObjectIdentifier: Timer] = [:]

    private func ramp(node: AVAudioPlayerNode, to target: Float, over seconds: Double,
                      completion: (() -> Void)? = nil) {
        // one ramp per node: a new ramp cancels the old one INCLUDING its completion,
        // so a pause-fade superseded by play() can never pause the node afterwards
        let key = ObjectIdentifier(node)
        rampTimers[key]?.invalidate()
        guard seconds > 0.01 else { node.volume = target; completion?(); return }
        let steps = 24
        let start = node.volume
        var i = 0
        let timer = Timer.scheduledTimer(withTimeInterval: seconds / Double(steps), repeats: true) { t in
            i += 1
            node.volume = start + (target - start) * Float(i) / Float(steps)
            if i >= steps { t.invalidate(); completion?() }
        }
        rampTimers[key] = timer
    }
}

private extension Array {
    var nilIfEmpty: [Element]? { isEmpty ? nil : self }
}
