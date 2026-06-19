import Foundation

/// 单轨混音状态
public struct TrackState: Codable, Equatable, Identifiable {
    public var id: StemKind { kind }
    public let kind: StemKind
    public var volume: Float    // 0~1 (线性), UI 显示转 dB
    public var solo: Bool
    public var mute: Bool

    public init(kind: StemKind, volume: Float = 1.0, solo: Bool = false, mute: Bool = false) {
        self.kind = kind
        self.volume = volume
        self.solo = solo
        self.mute = mute
    }
}

/// 10 段 EQ 单段 (Other 轨补偿, 难点三)
public struct EQBand: Codable, Equatable {
    public var frequency: Float   // Hz
    public var gain: Float        // dB
    public var q: Float
    public init(frequency: Float, gain: Float, q: Float = 1.0) {
        self.frequency = frequency
        self.gain = gain
        self.q = q
    }
}

public struct EQSettings: Codable, Equatable {
    public var bands: [EQBand]
    public var presetName: String
    public init(bands: [EQBand], presetName: String) {
        self.bands = bands
        self.presetName = presetName
    }
}

/// 全局混音参数
public struct MixState: Codable, Equatable {
    public var tracks: [TrackState]
    public var pitchSemitones: Int     // -12 ~ +12
    public var speed: Float            // 0.5 ~ 2.0
    public var otherEQ: EQSettings

    public init(tracks: [TrackState],
                pitchSemitones: Int = 0,
                speed: Float = 1.0,
                otherEQ: EQSettings = EQPresets.flat) {
        self.tracks = tracks
        self.pitchSemitones = pitchSemitones
        self.speed = speed
        self.otherEQ = otherEQ
    }

    public static func defaultState() -> MixState {
        MixState(tracks: StemKind.allCases.map { TrackState(kind: $0) })
    }

    /// 限定范围 (UC-04 边界)
    public mutating func clamp() {
        pitchSemitones = min(12, max(-12, pitchSemitones))
        speed = min(2.0, max(0.5, speed))
        for i in tracks.indices {
            tracks[i].volume = min(1.0, max(0.0, tracks[i].volume))
        }
    }
}
