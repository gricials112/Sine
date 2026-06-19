import Foundation

/// 多轨采样级时钟对齐 (难点二)。与 reference/sine_core.py 的 compute_sync_anchor / segment_schedule 等价。
///
/// 不变量: 4 轨共享同一 anchorFrame 与 startingFrame -> 不会产生相位漂移。
public struct TrackSchedule: Equatable {
    public let track: Int
    public let startingFrame: Int
    public let frameCount: Int
    public let atFrame: Int
}

public enum SyncClock {

    /// 计算共同启动锚点 (帧号)。buffer ~0.1s 保证所有轨来得及调度。
    public static func computeAnchor(nowFrame: Int, bufferSec: Double, sampleRate: Double) -> Int {
        nowFrame + Int((bufferSec * sampleRate).rounded())
    }

    /// 为 numTracks 条轨生成 scheduleSegment 参数, 全部共享 anchorFrame 与 seekFrame。
    public static func segmentSchedule(seekFrame: Int,
                                       totalFrames: Int,
                                       anchorFrame: Int,
                                       numTracks: Int = 4) -> [TrackSchedule] {
        let clampedSeek = max(0, min(seekFrame, totalFrames))
        let frameCount = totalFrames - clampedSeek
        return (0..<numTracks).map {
            TrackSchedule(track: $0,
                          startingFrame: clampedSeek,
                          frameCount: frameCount,
                          atFrame: anchorFrame)
        }
    }
}
