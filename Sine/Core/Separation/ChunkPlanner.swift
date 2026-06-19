import Foundation

/// 分块计划 (难点一: 抗 OOM)。纯逻辑, 与 reference/sine_core.py 等价, 由 XCTest 覆盖。
public struct ChunkPlan: Equatable {
    public let model: SeparationModelKind
    public let segmentSec: Double
    public let overlapSec: Double
    public let segmentFrames: Int
    public let overlapFrames: Int
}

public enum SeparationModelKind: String, Equatable {
    case spleeterCoreML = "spleeter-coreml"
    case htDemucsFP16 = "ht-demucs-fp16"
}

public enum ChunkPlanner {

    /// 根据物理内存选择模型与分块 (降级链, 与 select_chunk_plan 一致)。
    public static func selectPlan(physicalMemoryGB: Double, sampleRate: Double = 44100) -> ChunkPlan {
        let model: SeparationModelKind
        let segment: Double
        if physicalMemoryGB <= 4.0 {
            model = .spleeterCoreML; segment = 15.0
        } else if physicalMemoryGB <= 6.0 {
            model = .htDemucsFP16; segment = 20.0
        } else {
            model = .htDemucsFP16; segment = 30.0
        }
        let overlap = 2.0
        return ChunkPlan(
            model: model,
            segmentSec: segment,
            overlapSec: overlap,
            segmentFrames: Int((segment * sampleRate).rounded()),
            overlapFrames: Int((overlap * sampleRate).rounded())
        )
    }

    /// 切分 [0, totalFrames) 为带 overlap 的块, 返回 (start, end) 半开区间。
    /// 与 plan_chunks 等价: 覆盖全部样本, 末块对齐 totalFrames。
    public static func planChunks(totalFrames: Int, segmentFrames: Int, overlapFrames: Int) -> [Range<Int>] {
        precondition(segmentFrames > overlapFrames, "segmentFrames 必须大于 overlapFrames")
        guard totalFrames > 0 else { return [] }
        if totalFrames <= segmentFrames { return [0..<totalFrames] }

        let hop = segmentFrames - overlapFrames
        var chunks: [Range<Int>] = []
        var start = 0
        while start < totalFrames {
            let end = min(start + segmentFrames, totalFrames)
            chunks.append(start..<end)
            if end >= totalFrames { break }
            start += hop
        }
        return chunks
    }
}
