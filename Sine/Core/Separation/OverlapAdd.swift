import Foundation
#if canImport(Accelerate)
import Accelerate
#endif

/// Overlap-Add 无缝拼接 (难点一)。与 reference/sine_core.py::overlap_add_stitch 等价。
///
/// 关键决策 (测试驱动): 使用**线性/三角**交叉淡化权重 (w_out + w_in = 1), 而非等功率。
/// 源分离重叠区两块输出是同一段源的两个估计 (相关信号), 线性权重既完美重建又平均误差;
/// 等功率会把相关内容放大 +3dB 产生接缝鼓包。详见 reference 注释与 docs/03。
public enum OverlapAdd {

    /// 线性交叉淡化权重: (wOut, wIn), wOut: 1->0, wIn: 0->1, 且 wOut+wIn==1。
    public static func crossfadeWeights(_ n: Int) -> (out: [Float], in_: [Float]) {
        guard n > 0 else { return ([], []) }
        var wOut = [Float](repeating: 0, count: n)
        var wIn = [Float](repeating: 0, count: n)
        let nf = Float(n)
        for i in 0..<n {
            let t = (Float(i) + 0.5) / nf
            wIn[i] = t
            wOut[i] = 1.0 - t
        }
        return (wOut, wIn)
    }

    /// 将各块输出拼回完整音轨 (单声道; 多声道按通道分别调用)。
    /// - chunkOutputs[i].count == ranges[i].count
    public static func stitch(chunkOutputs: [[Float]],
                              ranges: [Range<Int>],
                              totalFrames: Int,
                              overlapFrames: Int) -> [Float] {
        var out = [Float](repeating: 0, count: totalFrames)
        var writtenUntil = 0

        for (i, range) in ranges.enumerated() {
            let seg = chunkOutputs[i]
            precondition(seg.count == range.count, "块输出长度必须等于其区间长度")
            let start = range.lowerBound
            let end = range.upperBound

            if i == 0 {
                for k in 0..<seg.count { out[start + k] = seg[k] }
                writtenUntil = end
                continue
            }

            let ovStart = start
            let ovEnd = min(end, writtenUntil)
            let ovLen = ovEnd - ovStart

            if ovLen > 0 {
                let (wOut, wIn) = crossfadeWeights(ovLen)
                for k in 0..<ovLen {
                    out[ovStart + k] = out[ovStart + k] * wOut[k] + seg[k] * wIn[k]
                }
                // 重叠区之后直接写
                var idx = ovLen
                var dst = ovEnd
                while dst < end {
                    out[dst] = seg[idx]
                    dst += 1; idx += 1
                }
            } else {
                for k in 0..<seg.count { out[start + k] = seg[k] }
            }
            writtenUntil = max(writtenUntil, end)
        }
        return out
    }
}
