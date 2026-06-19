import Foundation
#if canImport(AVFoundation)
import AVFoundation

/// 实时多轨混音引擎 (难点二)。
///
/// 节点图: 每轨 PlayerNode -> [Other 轨: EQ] -> TimePitch -> trackMixer -> mainMixer -> output
/// - 单例 AVAudioEngine, 统一主时钟。
/// - seek/play 时 4 轨用同一 AVAudioTime (anchor) scheduleSegment, 采样级对齐 (见 SyncClock)。
/// - Solo/Mute 只改 trackMixer.outputVolume, 绝不 stop/pause PlayerNode (P0-4, 防失步)。
/// - 变速 (TimePitch.rate) 改变不重排时间轴, 仅 seek 才重排。
public final class PlaybackEngine {

    private let engine = AVAudioEngine()
    private var players: [StemKind: AVAudioPlayerNode] = [:]
    private var timePitches: [StemKind: AVAudioUnitTimePitch] = [:]
    private var trackMixers: [StemKind: AVAudioMixerNode] = [:]
    private var files: [StemKind: AVAudioFile] = [:]
    private var otherEQ: AVAudioUnitEQ?

    private let bufferSec: Double = 0.1   // 启动锚点缓冲 (SyncClock)
    public private(set) var sampleRate: Double = 44100
    public private(set) var totalFrames: Int = 0
    private(set) var mixState = MixState.defaultState()

    /// 波形数据源 tap 回调 (主混音输出, 与听感一致 — IR-6)。
    public var onMainMixTap: ((_ samples: [Float]) -> Void)?

    public init() {}

    // MARK: - 装载

    public func load(stems: [Stem]) throws {
        stop()
        detachAll()

        for stem in stems {
            let file = try AVAudioFile(forReading: stem.fileURL)
            files[stem.kind] = file
            sampleRate = file.processingFormat.sampleRate
            totalFrames = max(totalFrames, Int(file.length))

            let player = AVAudioPlayerNode()
            let pitch = AVAudioUnitTimePitch()
            let mixer = AVAudioMixerNode()
            players[stem.kind] = player
            timePitches[stem.kind] = pitch
            trackMixers[stem.kind] = mixer

            engine.attach(player)
            engine.attach(pitch)
            engine.attach(mixer)

            let fmt = file.processingFormat
            if stem.kind == .other {
                let eq = AVAudioUnitEQ(numberOfBands: EQPresets.frequencies.count)
                otherEQ = eq
                engine.attach(eq)
                engine.connect(player, to: eq, format: fmt)
                engine.connect(eq, to: pitch, format: fmt)
            } else {
                engine.connect(player, to: pitch, format: fmt)
            }
            engine.connect(pitch, to: mixer, format: fmt)
            engine.connect(mixer, to: engine.mainMixerNode, format: fmt)
        }

        installMainTap()
        applyMixState(mixState)
        engine.prepare()
    }

    private func installMainTap() {
        let mixer = engine.mainMixerNode
        mixer.removeTap(onBus: 0)
        mixer.installTap(onBus: 0, bufferSize: 1024, format: mixer.outputFormat(forBus: 0)) { [weak self] buf, _ in
            guard let self, let ch = buf.floatChannelData else { return }
            let n = Int(buf.frameLength)
            // 仅拷贝, 不在音频线程做重活 (P1-7); FFT/Metal 在别处消费
            let samples = Array(UnsafeBufferPointer(start: ch[0], count: n))
            self.onMainMixTap?(samples)
        }
    }

    // MARK: - 播放控制 (统一时钟重排协议 — P0-3)

    public func play(fromFrame seekFrame: Int = 0) {
        do {
            if !engine.isRunning { try engine.start() }
        } catch { return }

        let nowFrame = currentRenderFrame()
        let anchor = SyncClock.computeAnchor(nowFrame: nowFrame, bufferSec: bufferSec, sampleRate: sampleRate)
        let schedule = SyncClock.segmentSchedule(seekFrame: seekFrame,
                                                 totalFrames: totalFrames,
                                                 anchorFrame: anchor,
                                                 numTracks: StemKind.allCases.count)
        let atTime = AVAudioTime(sampleTime: AVAudioFramePosition(anchor), atRate: sampleRate)

        for (i, kind) in StemKind.allCases.enumerated() {
            guard let player = players[kind], let file = files[kind] else { continue }
            let sched = schedule[i]
            player.stop()   // 仅重排时 stop, 不用于 Solo/Mute
            if sched.frameCount > 0 {
                player.scheduleSegment(file,
                                       startingFrame: AVAudioFramePosition(sched.startingFrame),
                                       frameCount: AVAudioFrameCount(sched.frameCount),
                                       at: atTime)
            }
        }
        for kind in StemKind.allCases { players[kind]?.play(at: atTime) }
    }

    /// seek: 拖动中节流, 松手才调用 (IR-3, 交叉淡化由 UI/渐变增益掩盖间隙)。
    public func seek(toFrame frame: Int) { play(fromFrame: max(0, min(frame, totalFrames))) }

    public func pause() { players.values.forEach { $0.pause() } }

    public func stop() {
        players.values.forEach { $0.stop() }
        if engine.isRunning { engine.stop() }
    }

    private func currentRenderFrame() -> Int {
        if let node = players.values.first,
           let lastRender = node.lastRenderTime,
           lastRender.isSampleTimeValid {
            return Int(lastRender.sampleTime)
        }
        return 0
    }

    // MARK: - 混音参数

    public func applyMixState(_ state: MixState) {
        mixState = state
        let kinds = StemKind.allCases
        let volumes = kinds.map { k in state.tracks.first { $0.kind == k }?.volume ?? 1 }
        let solos = kinds.map { k in state.tracks.first { $0.kind == k }?.solo ?? false }
        let mutes = kinds.map { k in state.tracks.first { $0.kind == k }?.mute ?? false }
        let gains = MixMath.trackGains(volumes: volumes, solos: solos, mutes: mutes)

        for (i, kind) in kinds.enumerated() {
            // 增益式 Solo/Mute (P0-4); AVAudioMixerNode 自带短渐变防爆音
            trackMixers[kind]?.outputVolume = gains[i]
            timePitches[kind]?.pitch = Float(state.pitchSemitones) * 100   // cents
            timePitches[kind]?.rate = state.speed
        }
        applyEQ(state.otherEQ)
    }

    public func applyEQ(_ settings: EQSettings) {
        guard let eq = otherEQ else { return }
        for (i, band) in settings.bands.enumerated() where i < eq.bands.count {
            let p = eq.bands[i]
            p.filterType = .parametric
            p.frequency = band.frequency
            p.bandwidth = band.q
            p.gain = band.gain
            p.bypass = false
        }
    }

    private func detachAll() {
        engine.mainMixerNode.removeTap(onBus: 0)
        [players.values.map { $0 as AVAudioNode },
         timePitches.values.map { $0 as AVAudioNode },
         trackMixers.values.map { $0 as AVAudioNode },
         otherEQ.map { [$0 as AVAudioNode] } ?? []].flatMap { $0 }
            .forEach { engine.detach($0) }
        players.removeAll(); timePitches.removeAll(); trackMixers.removeAll()
        files.removeAll(); otherEQ = nil; totalFrames = 0
    }
}
#endif
