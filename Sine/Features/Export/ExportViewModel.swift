import Foundation
import SwiftUI

@MainActor
final class ExportViewModel: ObservableObject {
    enum Phase: Equatable {
        case idle, rendering(Double), done([URL]), failed(String)
    }
    @Published var phase: Phase = .idle
    var isBusy: Bool { if case .rendering = phase { return true } else { return false } }

    #if canImport(AVFoundation)
    private let service = ExportService()
    #endif

    func export(project: Project, mix: MixState, kinds: Set<StemKind>,
                intent: ExportIntentChoice, wav: Bool, outputDir: URL) {
        #if canImport(AVFoundation)
        phase = .rendering(0)
        let exportIntent: ExportIntent = intent == .mixdown ? .mixdown(kinds, mix) : .stems(kinds)
        let format: ExportFormat = wav ? .wav : .m4a
        let stems = project.stems
        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                let urls = try ExportService().export(stems: stems, intent: exportIntent,
                                                      format: format, outputDir: outputDir) { p in
                    Task { @MainActor in self?.phase = .rendering(p) }
                }
                await MainActor.run { self?.phase = .done(urls) }
            } catch {
                await MainActor.run { self?.phase = .failed(self?.message(error) ?? "导出失败") }
            }
        }
        #else
        phase = .failed("当前平台不支持导出")
        #endif
    }

    private func message(_ error: Error) -> String {
        #if canImport(AVFoundation)
        if let e = error as? ExportError {
            switch e {
            case .noTracksSelected: return "请至少选择一条音轨"
            case .insufficientDisk: return "存储空间不足"
            case .renderFailed: return "渲染失败"
            }
        }
        #endif
        return "导出失败：\(error.localizedDescription)"
    }
}
