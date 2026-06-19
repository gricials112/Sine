import Foundation

/// Solo/Mute 真值表与混音/归一化纯逻辑。与 reference/sine_core.py 等价, XCTest 覆盖。
public enum MixMath {

    /// FRD §4 真值表: 计算各轨是否发声。
    /// 规则: Mute 永远优先; 有 solo 激活 -> 仅"被 solo 且未被 mute"发声; 无 solo -> 未被 mute 即发声。
    public static func audibleMask(solos: [Bool], mutes: [Bool]) -> [Bool] {
        precondition(solos.count == mutes.count)
        let soloActive = solos.contains(true)
        return zip(solos, mutes).map { s, m in
            if m { return false }
            if soloActive { return s }
            return true
        }
    }

    /// 各轨增益 (用于 mixer input volume; 增益式 Solo/Mute, 不 stop PlayerNode — P0-4)。
    public static func trackGains(volumes: [Float], solos: [Bool], mutes: [Bool]) -> [Float] {
        let mask = audibleMask(solos: solos, mutes: mutes)
        return zip(volumes, mask).map { v, audible in audible ? v : 0.0 }
    }

    /// 导出前防削波: 真峰值超过 ceiling 时整体线性衰减 (不放大)。返回应用增益。
    public static func normalizeGain(peak: Float, ceilingDBFS: Float = -0.1) -> Float {
        guard peak > 0 else { return 1.0 }
        let ceiling = powf(10.0, ceilingDBFS / 20.0)
        return peak <= ceiling ? 1.0 : ceiling / peak
    }
}
