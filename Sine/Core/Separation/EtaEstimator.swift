import Foundation

/// 进度 ETA 估算 (P1-3)。基于已完成块的滑动平均速度; 首块完成后才给估计 (避免冷启动乱跳)。
public final class EtaEstimator {
    private let totalChunks: Int
    private let window: Int
    private var durations: [Double] = []

    public init(totalChunks: Int, window: Int = 4) {
        self.totalChunks = totalChunks
        self.window = window
    }

    public func recordChunk(duration: Double) {
        durations.append(duration)
    }

    public var completed: Int { durations.count }

    /// 返回剩余秒数; 尚无数据返回 nil。
    public func etaSeconds() -> Double? {
        guard !durations.isEmpty else { return nil }
        let recent = durations.suffix(window)
        let avg = recent.reduce(0, +) / Double(recent.count)
        let remaining = totalChunks - completed
        return max(0, avg * Double(remaining))
    }

    public var progress: Double {
        guard totalChunks > 0 else { return 1.0 }
        return min(1.0, Double(completed) / Double(totalChunks))
    }
}
