import Foundation

/// 分离出的音轨类型 (4 轨)
public enum StemKind: String, CaseIterable, Codable, Identifiable {
    case vocal, drums, bass, other
    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .vocal: return "人声"
        case .drums: return "鼓"
        case .bass: return "贝斯"
        case .other: return "其他"
        }
    }
}

/// 单条音轨文件
public struct Stem: Codable, Identifiable, Equatable {
    public var id: StemKind { kind }
    public let kind: StemKind
    public var fileURL: URL
    public var peakLevel: Float   // 真峰值 (0~1), 用于导出归一与电平显示

    public init(kind: StemKind, fileURL: URL, peakLevel: Float = 1.0) {
        self.kind = kind
        self.fileURL = fileURL
        self.peakLevel = peakLevel
    }
}

/// 工程状态机 (见 FRD §6)
public enum ProjectState: String, Codable {
    case imported       // 已导入待分离
    case separating     // 分离中
    case separated      // 已分离可编辑
    case failed
    case cancelled
}

/// 一次导入产生的工程
public struct Project: Codable, Identifiable, Equatable {
    public let id: UUID
    public var title: String
    public var sourceURL: URL
    public var pcmURL: URL?            // 解码后的临时 WAV
    public var duration: TimeInterval
    public var sampleRate: Double
    public var createdAt: Date
    public var state: ProjectState
    public var stems: [Stem]
    public var separationProgress: Double   // 0~1, 支持锁屏续跑恢复 (IR-1)

    public init(id: UUID = UUID(),
                title: String,
                sourceURL: URL,
                pcmURL: URL? = nil,
                duration: TimeInterval = 0,
                sampleRate: Double = 44100,
                createdAt: Date = Date(),
                state: ProjectState = .imported,
                stems: [Stem] = [],
                separationProgress: Double = 0) {
        self.id = id
        self.title = title
        self.sourceURL = sourceURL
        self.pcmURL = pcmURL
        self.duration = duration
        self.sampleRate = sampleRate
        self.createdAt = createdAt
        self.state = state
        self.stems = stems
        self.separationProgress = separationProgress
    }
}
