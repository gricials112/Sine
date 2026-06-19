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
/// CoreML 实现。加载 .mlmodelc, computeUnits = .all (优先 ANE), 失败回落 .cpuAndGPU。
public final class CoreMLSeparationProvider: SeparationModelProvider {
    public let kind: SeparationModelKind
    private let model: MLModel

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

    public func separateChunk(_ channels: [[Float]], sampleRate: Double) throws -> StemChunk {
        try autoreleasepool {
            // 1) channels -> MLMultiArray [1, 2, frames]
            let frames = channels.first?.count ?? 0
            let input = try MLMultiArray(shape: [1, 2, NSNumber(value: frames)], dataType: .float32)
            let ptr = input.dataPointer.bindMemory(to: Float.self, capacity: input.count)
            for c in 0..<min(2, channels.count) {
                let ch = channels[c]
                for f in 0..<frames { ptr[c * frames + f] = ch[f] }
            }
            // 2) 推理 (模型 IO 名以实际转换为准, 此处为约定名)
            let provider = try MLDictionaryFeatureProvider(dictionary: ["mix": MLFeatureValue(multiArray: input)])
            let out = try model.prediction(from: provider)
            // 3) 取 4 轨输出并立即拷成 Swift 数组, 让 MLMultiArray 在 pool 结束时释放
            func extract(_ name: String) -> [[Float]] {
                guard let arr = out.featureValue(for: name)?.multiArrayValue else {
                    return [[Float](repeating: 0, count: frames), [Float](repeating: 0, count: frames)]
                }
                let p = arr.dataPointer.bindMemory(to: Float.self, capacity: arr.count)
                var l = [Float](repeating: 0, count: frames)
                var r = [Float](repeating: 0, count: frames)
                for f in 0..<frames { l[f] = p[f]; r[f] = p[frames + f] }
                return [l, r]
            }
            return StemChunk(vocal: extract("vocals"),
                             drums: extract("drums"),
                             bass: extract("bass"),
                             other: extract("other"))
        }
    }
}
#endif
