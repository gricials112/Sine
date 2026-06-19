import Foundation
#if canImport(CoreML)
import CoreML
#endif

/// 单块分离结果: 4 轨, 每轨 [channel][frame] Float32。
public struct StemChunk {
    public var vocal: [[Float]]
    public var drums: [[Float]]
    public var bass: [[Float]]
    public var other: [[Float]]

    public func channels(for kind: StemKind) -> [[Float]] {
        switch kind {
        case .vocal: return vocal
        case .drums: return drums
        case .bass: return bass
        case .other: return other
        }
    }
}

/// 分离模型抽象 (P1-1: 可插拔, HT-Demucs / Spleeter 二选一不影响上层)。
public protocol SeparationModelProvider {
    var kind: SeparationModelKind { get }
    /// 对单个 chunk (channels = [L, R], 每个长度相同) 推理出 4 轨。
    /// 实现内部应使用 autoreleasepool 并在推理后显式释放 MLMultiArray (难点一)。
    func separateChunk(_ channels: [[Float]], sampleRate: Double) throws -> StemChunk
}

#if canImport(CoreML)
/// CoreML 实现 (真实 HT-Demucs 4 轨分离核心)。computeUnits = .all (优先 ANE), 失败回落 .cpuAndGPU。
///
/// 模型契约 (见 models/manifest.json, 由 export_htdemucs_ios16.py 导出):
///   IN  mix [1,2,343980] · spectrogram [1,4,2048,336]
///   OUT spectrogram_stems [1,4,4,2048,336] · waveform_stems [1,4,2,343980]
///   源顺序 (dim1): drums(0), bass(1), other(2), vocals(3)
/// STFT/ISTFT 由 DemucsSTFT (Accelerate) 完成, 数值契约经 reference/demucs_stft.py 校验 (~1e-8)。
public final class CoreMLSeparationProvider: SeparationModelProvider {
    public let kind: SeparationModelKind
    private let model: MLModel
    private let stft = DemucsSTFT()

    private static let sourceOrder: [StemKind] = [.drums, .bass, .other, .vocal] // 模型 dim1 顺序
    private static let seg = DemucsSTFT.segment   // 343980
    private static let F = DemucsSTFT.freqBins    // 2048
    private static let T = DemucsSTFT.frames      // 336

    public init(kind: SeparationModelKind, modelURL: URL, preferANE: Bool = true) throws {
        self.kind = kind
        let config = MLModelConfiguration()
        config.computeUnits = preferANE ? .all : .cpuAndGPU
        do {
            self.model = try MLModel(contentsOf: modelURL, configuration: config)
        } catch {
            // ANE 路径失败 -> 回落 CPU/GPU (UC-02 A3)
            config.computeUnits = .cpuAndGPU
            self.model = try MLModel(contentsOf: modelURL, configuration: config)
        }
    }

    /// 输入任意长度 (≤343980) 的立体声块; 补零到固定 segment -> STFT -> 推理 -> ISTFT 重建 -> 裁回原长。
    public func separateChunk(_ channels: [[Float]], sampleRate: Double) throws -> StemChunk {
        try autoreleasepool {
            let length = channels.first?.count ?? 0
            // 1) 补零到固定 segment
            var mix: [[Float]] = []
            for c in 0..<2 {
                var ch = c < channels.count ? channels[c] : [Float](repeating: 0, count: length)
                if ch.count < Self.seg { ch.append(contentsOf: [Float](repeating: 0, count: Self.seg - ch.count)) }
                mix.append(Array(ch.prefix(Self.seg)))
            }
            // 2) mix [1,2,343980]
            let mixArr = try MLMultiArray(shape: [1, 2, NSNumber(value: Self.seg)], dataType: .float32)
            let mp = mixArr.dataPointer.bindMemory(to: Float.self, capacity: mixArr.count)
            for c in 0..<2 { for i in 0..<Self.seg { mp[c * Self.seg + i] = mix[c][i] } }
            // 3) STFT -> spectrogram [1,4,2048,336]
            let spec = stft.spectrogram(mix: mix)
            let specArr = try MLMultiArray(shape: [1, 4, NSNumber(value: Self.F), NSNumber(value: Self.T)], dataType: .float32)
            let sp = specArr.dataPointer.bindMemory(to: Float.self, capacity: specArr.count)
            for i in 0..<spec.count { sp[i] = spec[i] }
            // 4) 推理
            let input = try MLDictionaryFeatureProvider(dictionary: [
                "mix": MLFeatureValue(multiArray: mixArr),
                "spectrogram": MLFeatureValue(multiArray: specArr),
            ])
            let out = try model.prediction(from: input)
            guard let specStems = out.featureValue(for: "spectrogram_stems")?.multiArrayValue,
                  let waveStems = out.featureValue(for: "waveform_stems")?.multiArrayValue else {
                throw SeparationError.modelUnavailable
            }
            // 5) 逐源重建并裁回 length
            let specP = specStems.dataPointer.bindMemory(to: Float.self, capacity: specStems.count)
            let waveP = waveStems.dataPointer.bindMemory(to: Float.self, capacity: waveStems.count)
            let specSrcStride = 4 * Self.F * Self.T
            let specChanStride = Self.F * Self.T
            let waveSrcStride = 2 * Self.seg
            var stems: [StemKind: [[Float]]] = [:]
            for (sIdx, kind) in Self.sourceOrder.enumerated() {
                var specChannels: [[Float]] = []
                for ch in 0..<4 {
                    let base = sIdx * specSrcStride + ch * specChanStride
                    specChannels.append(Array(UnsafeBufferPointer(start: specP + base, count: specChanStride)))
                }
                var waveChannels: [[Float]] = []
                for ch in 0..<2 {
                    let base = sIdx * waveSrcStride + ch * Self.seg
                    waveChannels.append(Array(UnsafeBufferPointer(start: waveP + base, count: Self.seg)))
                }
                stems[kind] = stft.reconstructStem(specChannels: specChannels,
                                                   waveChannels: waveChannels,
                                                   length: length)
            }
            return StemChunk(vocal: stems[.vocal]!, drums: stems[.drums]!,
                             bass: stems[.bass]!, other: stems[.other]!)
        }
    }
}
#endif
