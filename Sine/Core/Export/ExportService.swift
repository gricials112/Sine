import Foundation
#if canImport(AVFoundation)
import AVFoundation

public enum ExportError: Error { case noTracksSelected, insufficientDisk, renderFailed }

public enum ExportFormat { case m4a, wav }

/// 导出意图 (IR-5: 消除"套用混音"歧义)。
public enum ExportIntent {
    case stems(Set<StemKind>)                 // 分轨导出: 每轨各自成文件 (原样)
    case mixdown(Set<StemKind>, MixState)     // 混音导出: 按当前参数合成单文件
}

/// 高精度自定义导出 (UC-06)。离线渲染复用与播放一致的链路 (所见即所得), 末端防削波 (P0-5)。
public final class ExportService {

    public init() {}

    /// 离线渲染。返回输出文件 URL 列表。
    public func export(stems: [Stem],
                       intent: ExportIntent,
                       format: ExportFormat,
                       outputDir: URL,
                       progress: ((Double) -> Void)? = nil) throws -> [URL] {
        switch intent {
        case .stems(let kinds):
            guard !kinds.isEmpty else { throw ExportError.noTracksSelected }
            return try stems.filter { kinds.contains($0.kind) }.map {
                try transcode(input: $0.fileURL, format: format, outputDir: outputDir, name: $0.kind.rawValue)
            }
        case .mixdown(let kinds, let mix):
            guard !kinds.isEmpty else { throw ExportError.noTracksSelected }
            let url = try renderMixdown(stems: stems.filter { kinds.contains($0.kind) },
                                        allStems: stems,
                                        mix: mix, format: format,
                                        outputDir: outputDir, progress: progress)
            return [url]
        }
    }

    /// 用离线 AVAudioEngine 渲染混音, 末端做峰值检测 + 归一防削波。
    private func renderMixdown(stems: [Stem], allStems: [Stem], mix: MixState,
                              format: ExportFormat, outputDir: URL,
                              progress: ((Double) -> Void)?) throws -> URL {
        let engine = AVAudioEngine()
        var players: [AVAudioPlayerNode] = []
        var files: [AVAudioFile] = []
        var maxFrames: AVAudioFrameCount = 0
        var outputFormat: AVAudioFormat?

        // 计算各轨增益 (含 Solo/Mute), 仅挂载被选且发声的轨
        let kinds = stems.map { $0.kind }
        let volumes = kinds.map { k in mix.tracks.first { $0.kind == k }?.volume ?? 1 }
        let solos = allStems.map { k in mix.tracks.first { $0.kind == k.kind }?.solo ?? false }
        let mutes = allStems.map { k in mix.tracks.first { $0.kind == k.kind }?.mute ?? false }
        let maskAll = MixMath.audibleMask(solos: solos, mutes: mutes)
        let audibleKinds = Set(zip(allStems, maskAll).filter { $0.1 }.map { $0.0.kind })

        for (i, stem) in stems.enumerated() {
            guard audibleKinds.contains(stem.kind) else { continue }
            let file = try AVAudioFile(forReading: stem.fileURL)
            files.append(file)
            outputFormat = file.processingFormat
            maxFrames = max(maxFrames, AVAudioFrameCount(file.length))

            let player = AVAudioPlayerNode()
            let pitch = AVAudioUnitTimePitch()
            pitch.pitch = Float(mix.pitchSemitones) * 100
            pitch.rate = mix.speed
            engine.attach(player); engine.attach(pitch)
            engine.connect(player, to: pitch, format: file.processingFormat)

            if stem.kind == .other {
                let eq = AVAudioUnitEQ(numberOfBands: mix.otherEQ.bands.count)
                for (b, band) in mix.otherEQ.bands.enumerated() where b < eq.bands.count {
                    eq.bands[b].filterType = .parametric
                    eq.bands[b].frequency = band.frequency
                    eq.bands[b].bandwidth = band.q
                    eq.bands[b].gain = band.gain
                    eq.bands[b].bypass = false
                }
                engine.attach(eq)
                engine.connect(pitch, to: eq, format: file.processingFormat)
                engine.connect(eq, to: engine.mainMixerNode, format: file.processingFormat)
            } else {
                engine.connect(pitch, to: engine.mainMixerNode, format: file.processingFormat)
            }
            engine.mainMixerNode.outputVolume = 1.0
            player.volume = volumes[i]
            players.append(player)
        }

        guard let fmt = outputFormat, !players.isEmpty else { throw ExportError.noTracksSelected }

        // 离线渲染模式
        let renderLen = AVAudioFrameCount(Double(maxFrames) / Double(mix.speed)) + fmt.sampleRate.rounded().toFrameCount
        try engine.enableManualRenderingMode(.offline, format: fmt, maximumFrameCount: 4096)
        for (i, player) in players.enumerated() { player.scheduleFile(files[i], at: nil) }
        try engine.start()
        players.forEach { $0.play() }

        let ext = format == .m4a ? "m4a" : "wav"
        let outURL = outputDir.appendingPathComponent("mixdown.\(ext)")
        try? FileManager.default.removeItem(at: outURL)

        // 第一遍: 渲染到内存测峰值
        let buffer = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat,
                                      frameCapacity: engine.manualRenderingMaximumFrameCount)!
        var peak: Float = 0
        var collected: [[Float]] = [[], []]
        var rendered: AVAudioFramePosition = 0
        while rendered < AVAudioFramePosition(renderLen) {
            let toRender = min(buffer.frameCapacity, AVAudioFrameCount(AVAudioFramePosition(renderLen) - rendered))
            let status = try engine.renderOffline(toRender, to: buffer)
            if status == .insufficientDataFromInputNode || status == .cannotDoInCurrentContext { break }
            let n = Int(buffer.frameLength)
            if let ch = buffer.floatChannelData {
                for c in 0..<min(2, Int(buffer.format.channelCount)) {
                    for f in 0..<n {
                        let v = ch[c][f]; collected[c].append(v)
                        let a = abs(v); if a > peak { peak = a }
                    }
                }
            }
            rendered += AVAudioFramePosition(n)
            progress?(min(1.0, Double(rendered) / Double(renderLen)))
            if n == 0 { break }
        }
        engine.stop()

        // 归一防削波 (P0-5)
        let gain = MixMath.normalizeGain(peak: peak, ceilingDBFS: -0.1)
        let outFile = try AVAudioFile(forWriting: outURL, settings: fmt.settings)
        let frames = collected[0].count
        if frames > 0, let outBuf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(frames)) {
            outBuf.frameLength = AVAudioFrameCount(frames)
            if let ch = outBuf.floatChannelData {
                for c in 0..<2 {
                    let src = collected[min(c, collected.count - 1)]
                    for f in 0..<frames { ch[c][f] = src[f] * gain }
                }
            }
            try outFile.write(from: outBuf)
        }
        return outURL
    }

    private func transcode(input: URL, format: ExportFormat, outputDir: URL, name: String) throws -> URL {
        let ext = format == .m4a ? "m4a" : "wav"
        let outURL = outputDir.appendingPathComponent("\(name).\(ext)")
        try? FileManager.default.removeItem(at: outURL)
        if format == .wav {
            try FileManager.default.copyItem(at: input, to: outURL)
            return outURL
        }
        // m4a: 用 AVAudioFile 重写为 AAC
        let inFile = try AVAudioFile(forReading: input)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: inFile.processingFormat.sampleRate,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 256000
        ]
        let outFile = try AVAudioFile(forWriting: outURL, settings: settings)
        let buf = AVAudioPCMBuffer(pcmFormat: inFile.processingFormat,
                                   frameCapacity: AVAudioFrameCount(inFile.length))!
        try inFile.read(into: buf)
        try outFile.write(from: buf)
        return outURL
    }
}

private extension Double {
    var toFrameCount: AVAudioFrameCount { AVAudioFrameCount(self) }
}
#endif
