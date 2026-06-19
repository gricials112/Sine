// swift-tools-version:5.9
import PackageDescription

// SineCore: 平台无关的纯逻辑核心 (分块/Overlap-Add/时钟对齐/Solo-Mute/归一/ETA/EQ)。
// 与 reference/ 的 Python 实现等价, 由 XCTest 覆盖 -> macOS 上 `swift test` 可运行。
// 平台相关代码 (AVAudioEngine/CoreML/Metal/CoreHaptics/SwiftUI) 不在此 SPM target 内,
// 它们随 Xcode App target 一起编译 (见 docs/README 工程接入说明)。
let package = Package(
    name: "Sine",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [
        .library(name: "SineCore", targets: ["SineCore"])
    ],
    targets: [
        .target(
            name: "SineCore",
            path: "Sine/Core",
            exclude: [
                "Separation/SeparationEngine.swift",
                "Separation/SeparationModelProvider.swift",
                "Audio/PlaybackEngine.swift",
                "Import/AudioImportService.swift",
                "Export/ExportService.swift",
                "Haptics/HapticsService.swift",
                "MetalFFT/FFTProcessor.swift",
                "MetalFFT/MetalFFTView.swift",
                "MetalFFT/Shaders.metal"
            ]
        ),
        .testTarget(
            name: "SineCoreTests",
            dependencies: ["SineCore"],
            path: "Tests/SineCoreTests"
        )
    ]
)
