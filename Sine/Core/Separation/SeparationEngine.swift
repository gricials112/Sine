import Foundation
#if canImport(AVFoundation)
import AVFoundation
#endif

public enum SeparationError: Error {
    case cancelled
    case modelUnavailable
    case decodeFailed
    case ioFailed
}

/// 分离引擎 (难点一编排)。切块 -> 逐块 CoreML 推理 (autoreleasepool + 显式释放) -> Overlap-Add -> 落盘 4 stem。
/// 进度可上报、可取消、支持锁屏续跑 (从 resumeFromProgress 对应的块继续)。
public final class SeparationEngine {

    public struct Callbacks {
        public var onProgress: (Double, _ eta: Double?) -> Void
        public var onModelInfo: (SeparationModelKind, _ usingANE: Bool) -> Void
        public init(onProgress: @escaping (Double, Double?) -> Void = { _, _ in },
                    onModelInfo: @escaping (SeparationModelKind, Bool) -> Void = { _, _ in }) {
            self.onProgress = onProgress
            self.onModelInfo = onModelInfo
        }
    }

    private let provider: SeparationModelProvider
    private let plan: ChunkPlan
    private var isCancelled = false

    public init(provider: SeparationModelProvider, plan: ChunkPlan) {
        self.provider = provider
        self.plan = plan
    }

    public func cancel() { isCancelled = true }

    /// 便捷工厂: 按设备内存选 provider + plan。
    public static func makePlan(physicalMemoryGB: Double, sampleRate: Double) -> ChunkPlan {
        ChunkPlanner.selectPlan(physicalMemoryGB: physicalMemoryGB, sampleRate: sampleRate)
    }

    #if canImport(AVFoundation)
    /// 主流程。pcmURL 为解码后的 WAV; 返回 4 个 stem 文件 URL。
    /// resumeFromProgress 用于锁屏续跑 (IR-1): 跳过已完成的块比例。
    public func separate(pcmURL: URL,
                         outputDir: URL,
                         sampleRate: Double,
                         callbacks: Callbacks = Callbacks(),
                         resumeFromProgress: Double = 0) throws -> [Stem] {

        let file = try AVAudioFile(forReading: pcmURL)
        let total = Int(file.length)
        // 真实 HT-Demucs 输入为固定 7.8s 段 (343980 样本)。分块用固定 segment + 2s 重叠 (hop 的整数倍),
        // 末块由 provider 内部补零, 输出按 range.count 裁回。plan.segmentFrames 仅对通用 chunker 有意义,
        // 这里被模型的固定尺寸覆盖。
        let segmentFrames = DemucsSTFT.segment
        let overlapFrames = DemucsSTFT.hop * 86   // ≈1.998s, hop 的整数倍, 便于 Overlap-Add 对齐
        let ranges = ChunkPlanner.planChunks(totalFrames: total,
                                             segmentFrames: segmentFrames,
                                             overlapFrames: overlapFrames)
        guard !ranges.isEmpty else { throw SeparationError.decodeFailed }

        callbacks.onModelInfo(plan.model, true)
        let eta = EtaEstimator(totalChunks: ranges.count)

        // 每轨每通道的拼接缓冲 (落盘前在内存; 长歌可改为分段写文件, 此处保持清晰)
        var perStem: [StemKind: [[Float]]] = [:]
        for kind in StemKind.allCases {
            perStem[kind] = [[Float](repeating: 0, count: total), [Float](repeating: 0, count: total)]
        }
        var chunkOutputs: [StemKind: [Int: [[Float]]]] = [:]
        for kind in StemKind.allCases { chunkOutputs[kind] = [:] }

        let resumeChunk = Int(Double(ranges.count) * resumeFromProgress)

        for (i, range) in ranges.enumerated() {
            if isCancelled { throw SeparationError.cancelled }
            if i < resumeChunk { continue }

            let started = Date()
            try autoreleasepool {
                // 读取该块 PCM
                let channels = try Self.readFrames(file: file, range: range)
                // 推理 (provider 内部已 autoreleasepool + 显式释放 MLMultiArray)
                let stem = try provider.separateChunk(channels, sampleRate: sampleRate)
                for kind in StemKind.allCases {
                    chunkOutputs[kind]?[i] = stem.channels(for: kind)
                }
            }

            eta.recordChunk(duration: Date().timeIntervalSince(started))
            callbacks.onProgress(eta.progress, eta.etaSeconds())
        }

        // Overlap-Add 拼接 (每轨每通道)
        var stems: [Stem] = []
        for kind in StemKind.allCases {
            var chans: [[Float]] = []
            for ch in 0..<2 {
                let outs = ranges.indices.map { chunkOutputs[kind]?[$0]?[ch] ?? [Float](repeating: 0, count: ranges[$0].count) }
                let stitched = OverlapAdd.stitch(chunkOutputs: outs,
                                                 ranges: ranges,
                                                 totalFrames: total,
                                                 overlapFrames: overlapFrames)
                chans.append(stitched)
            }
            let url = outputDir.appendingPathComponent("\(kind.rawValue).caf")
            let peak = try Self.writeWAV(channels: chans, sampleRate: sampleRate, to: url)
            stems.append(Stem(kind: kind, fileURL: url, peakLevel: peak))
        }
        return stems
    }

    /// 读取 [range] 帧, 返回 [L, R]。
    private static func readFrames(file: AVAudioFile, range: Range<Int>) throws -> [[Float]] {
        let format = file.processingFormat
        file.framePosition = AVAudioFramePosition(range.lowerBound)
        let count = AVAudioFrameCount(range.count)
        guard let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: count) else {
            throw SeparationError.ioFailed
        }
        try file.read(into: buf, frameCount: count)
        let chCount = Int(format.channelCount)
        guard let data = buf.floatChannelData else { throw SeparationError.ioFailed }
        let n = Int(buf.frameLength)
        var channels: [[Float]] = []
        for c in 0..<max(2, chCount) {
            let src = data[min(c, chCount - 1)]
            channels.append(Array(UnsafeBufferPointer(start: src, count: n)))
        }
        return Array(channels.prefix(2))
    }

    /// 写出 [L, R] 到文件, 返回真峰值。
    private static func writeWAV(channels: [[Float]], sampleRate: Double, to url: URL) throws -> Float {
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!
        let outFile = try AVAudioFile(forWriting: url, settings: format.settings)
        let frames = channels.first?.count ?? 0
        guard frames > 0, let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)) else {
            throw SeparationError.ioFailed
        }
        buf.frameLength = AVAudioFrameCount(frames)
        var peak: Float = 0
        if let data = buf.floatChannelData {
            for c in 0..<2 {
                let src = channels[min(c, channels.count - 1)]
                for f in 0..<frames {
                    let v = src[f]
                    data[c][f] = v
                    let a = abs(v); if a > peak { peak = a }
                }
            }
        }
        try outFile.write(from: buf)
        return peak
    }
    #endif
}
