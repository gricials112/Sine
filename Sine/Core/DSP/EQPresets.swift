import Foundation

/// Other 轨 10 段 EQ 预设 (难点三)。与 docs/03 附录 A 及 reference EQ_PRESETS 一致。
public enum EQPresets {
    public static let frequencies: [Float] = [31, 62, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]

    private static func make(_ name: String, _ gains: [Float]) -> EQSettings {
        precondition(gains.count == frequencies.count)
        let bands = zip(frequencies, gains).map { EQBand(frequency: $0, gain: $1) }
        return EQSettings(bands: bands, presetName: name)
    }

    public static let flat        = make("自定义", [0, 0, 0, 0, 0, 0, 0, 0, 0, 0])
    public static let guitarBoost = make("吉他增强", [0, 0, 1, 2, 3, 4, 3, 2, 1, 0])
    public static let pianoBoost  = make("钢琴增强", [0, 1, 2, 2, 1, 2, 3, 2, 1, 0])
    public static let midScoop    = make("中频削弱", [0, 0, 0, -2, -4, -5, -3, 0, 1, 2])

    public static let all: [EQSettings] = [guitarBoost, pianoBoost, midScoop, flat]
}
