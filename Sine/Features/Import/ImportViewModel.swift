import Foundation
import SwiftUI

@MainActor
final class ImportViewModel: ObservableObject {
    enum Phase: Equatable {
        case idle
        case decoding(Double)
        case failed(String)
    }
    @Published var phase: Phase = .idle

    private let service = AudioImportService()

    func reset() { phase = .idle }
    func pickFromPhotos() { /* 由宿主用 PHPicker 呈现, 选中后调用 decode(url:) */ }

    func decode(url: URL, appState: AppState) async -> Project? {
        phase = .decoding(0)
        var project = Project(title: url.deletingPathExtension().lastPathComponent, sourceURL: url)
        let pcmURL = appState.workDir(for: project).appendingPathComponent("source.caf")
        do {
            let result = try await service.extractAudio(from: url, to: pcmURL) { [weak self] p in
                Task { @MainActor in self?.phase = .decoding(p) }
            }
            project.pcmURL = result.pcmURL
            project.duration = result.duration
            project.sampleRate = result.sampleRate
            project.state = .imported
            return project
        } catch let e as ImportError {
            phase = .failed(message(for: e))
            return nil
        } catch {
            phase = .failed("无法读取该文件")
            return nil
        }
    }

    private func message(for error: ImportError) -> String {
        switch error {
        case .noAudioTrack: return "未在该文件中检测到音频"
        case .drmProtected: return "该文件受版权保护，无法处理"
        case .decodeFailed: return "解码失败，请选择其他文件"
        case .insufficientDisk: return "存储空间不足"
        }
    }
}
