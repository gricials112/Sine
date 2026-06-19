import Foundation
#if canImport(CoreHaptics)
import CoreHaptics

/// 阻尼触感反馈 (设计规范 §3)。推子/旋钮跨刻度时触发齿轮段落感。
/// 优雅降级: 无 Taptic / 引擎被系统回收时自动重启或静默。
public final class HapticsService {

    private var engine: CHHapticEngine?
    private let supported = CHHapticEngine.capabilitiesForHardware().supportsHaptics

    public init() { prepare() }

    private func prepare() {
        guard supported else { return }
        do {
            let engine = try CHHapticEngine()
            engine.isAutoShutdownEnabled = true
            // 被系统回收后自动重启 (UC: 引擎健壮性)
            engine.resetHandler = { [weak self] in try? self?.engine?.start() }
            engine.stoppedHandler = { _ in }
            try engine.start()
            self.engine = engine
        } catch { self.engine = nil }
    }

    /// 跨刻度的瞬态反馈; intensity 随拖动速度变化, sharpness 控制"齿轮"清脆度。
    public func tick(intensity: Float = 0.6, sharpness: Float = 0.8) {
        guard supported, let engine else { return }
        let event = CHHapticEvent(eventType: .hapticTransient, parameters: [
            CHHapticEventParameter(parameterID: .hapticIntensity, value: max(0, min(1, intensity))),
            CHHapticEventParameter(parameterID: .hapticSharpness, value: max(0, min(1, sharpness)))
        ], relativeTime: 0)
        do {
            let pattern = try CHHapticPattern(events: [event], parameters: [])
            let player = try engine.makePlayer(with: pattern)
            try player.start(atTime: 0)
        } catch {
            // 引擎可能被回收, 尝试重启一次
            prepare()
        }
    }

    /// 0dB / 复位 / 导出成功等强反馈。
    public func success() { tick(intensity: 1.0, sharpness: 0.5) }
}
#else
public final class HapticsService {
    public init() {}
    public func tick(intensity: Float = 0.6, sharpness: Float = 0.8) {}
    public func success() {}
}
#endif
