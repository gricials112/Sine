import Foundation
import SwiftUI

/// 调音台 (UC-03/04/05)。桥接 UI 与 PlaybackEngine, 维护 MixState 并下发 (增益式 Solo/Mute)。
@MainActor
final class MixerViewModel: ObservableObject {
    @Published var mix = MixState.defaultState()
    @Published var isPlaying = false
    @Published var spectrum: [Float] = []
    @Published var energy: Float = 0
    @Published var currentFrame: Int = 0

    let haptics = HapticsService()
    #if canImport(AVFoundation)
    private let engine = PlaybackEngine()
    #endif

    func load(project: Project) {
        #if canImport(AVFoundation)
        do {
            try engine.load(stems: project.stems)
            engine.onMainMixTap = { [weak self] samples in
                self?.consumeAudio(samples)
            }
        } catch { /* 上层展示错误 */ }
        #endif
    }

    private func consumeAudio(_ samples: [Float]) {
        // FFT 在独立队列计算, 主线程仅更新发布属性 (P1-7)
        var sum: Float = 0; for s in samples { sum += s * s }
        let rms = (samples.isEmpty ? 0 : (sum / Float(samples.count)).squareRoot())
        Task { @MainActor in self.energy = min(1, rms * 4) }
        #if canImport(Accelerate)
        DispatchQueue.global(qos: .userInteractive).async { [weak self] in
            guard let self else { return }
            let mags = Self.sharedFFT.magnitudes(samples)
            if !mags.isEmpty {
                let down = stride(from: 0, to: mags.count, by: max(1, mags.count / 96)).map { mags[$0] }
                Task { @MainActor in self.spectrum = down }
            }
        }
        #endif
    }

    #if canImport(Accelerate)
    private static let sharedFFT = FFTProcessor(size: 1024)
    #endif

    // MARK: - 播放控制
    func togglePlay() {
        #if canImport(AVFoundation)
        if isPlaying { engine.pause() } else { engine.play(fromFrame: currentFrame) }
        isPlaying.toggle()
        #endif
    }

    func seek(toFrame frame: Int) {
        currentFrame = frame
        #if canImport(AVFoundation)
        if isPlaying { engine.seek(toFrame: frame) }
        #endif
    }

    // MARK: - 导出内联预览 (IR-8)
    /// 并行预览: 播放当前勾选的所有轨 (solo=nil); 单独预览: 仅播放某一轨 (solo=该轨)。
    /// 用各轨原始音量, 不改动已保存的 MixState。
    func previewExport(selection: Set<StemKind>, solo: StemKind? = nil) {
        #if canImport(AVFoundation)
        var gains: [StemKind: Float] = [:]
        for k in StemKind.allCases {
            let vol = mix.tracks.first { $0.kind == k }?.volume ?? 1
            if let s = solo { gains[k] = (k == s) ? vol : 0 }
            else { gains[k] = selection.contains(k) ? vol : 0 }
        }
        engine.setTrackGainsDirect(gains)
        if !isPlaying { engine.play(fromFrame: currentFrame); isPlaying = true }
        #endif
    }

    /// 结束预览: 暂停并恢复调音台增益。
    func endPreview() {
        #if canImport(AVFoundation)
        engine.pause(); isPlaying = false
        engine.restoreMixGains()
        #endif
    }

    // MARK: - 混音参数变更 -> 下发引擎
    func setVolume(_ v: Float, for kind: StemKind) { mutate { idx in mix.tracks[idx].volume = v } kind: kind }
    func toggleSolo(_ kind: StemKind) { mutate { idx in mix.tracks[idx].solo.toggle() } kind: kind }
    func toggleMute(_ kind: StemKind) { mutate { idx in mix.tracks[idx].mute.toggle() } kind: kind }

    func setPitch(_ semitones: Int) { mix.pitchSemitones = semitones; apply() }
    func setSpeed(_ speed: Float) { mix.speed = speed; apply() }
    func setEQ(_ settings: EQSettings) { mix.otherEQ = settings; apply() }

    /// 各轨是否发声 (用于 UI 暗化, IR-2)。
    func isAudible(_ kind: StemKind) -> Bool {
        let solos = mix.tracks.map { $0.solo }
        let mutes = mix.tracks.map { $0.mute }
        let mask = MixMath.audibleMask(solos: solos, mutes: mutes)
        guard let idx = mix.tracks.firstIndex(where: { $0.kind == kind }) else { return true }
        return mask[idx]
    }

    var soloActive: Bool { mix.tracks.contains { $0.solo } }

    private func mutate(_ change: (Int) -> Void, kind: StemKind) {
        guard let idx = mix.tracks.firstIndex(where: { $0.kind == kind }) else { return }
        change(idx)
        apply()
    }

    private func apply() {
        mix.clamp()
        #if canImport(AVFoundation)
        engine.applyMixState(mix)
        #endif
    }
}
