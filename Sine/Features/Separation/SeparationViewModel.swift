import Foundation
import SwiftUI

@MainActor
final class SeparationViewModel: ObservableObject {
    @Published var progress: Double = 0
    @Published var etaText: String = ""
    @Published var stageText: String = "准备中…"
    @Published var modelText: String = ""
    @Published var failed: String?
    @Published var finished = false

    private var engine: SeparationEngine?
    private var task: Task<Void, Never>?

    func start(project: Project, appState: AppState) {
        guard let pcmURL = project.pcmURL else { failed = "缺少源音频"; return }
        var project = project
        project.state = .separating
        appState.upsert(project)

        let memGB = Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824.0
        let plan = ChunkPlanner.selectPlan(physicalMemoryGB: memGB, sampleRate: project.sampleRate)

        task = Task {
            do {
                stageText = "加载模型…"
                let provider = try Self.makeProvider(plan: plan)
                let engine = SeparationEngine(provider: provider, plan: plan)
                self.engine = engine

                let callbacks = SeparationEngine.Callbacks(
                    onProgress: { [weak self] p, eta in
                        Task { @MainActor in
                            self?.progress = p
                            self?.stageText = "分块推理中…"
                            self?.etaText = eta.map { "预计剩余 " + Self.timeString($0) } ?? ""
                            var pr = project; pr.separationProgress = p; appState.upsert(pr)
                        }
                    },
                    onModelInfo: { [weak self] kind, ane in
                        Task { @MainActor in
                            self?.modelText = (ane ? "神经网络引擎 · " : "CPU · ") + kind.rawValue
                        }
                    })

                let stems = try await Task.detached(priority: .userInitiated) {
                    try engine.separate(pcmURL: pcmURL,
                                        outputDir: appState.workDir(for: project),
                                        sampleRate: project.sampleRate,
                                        callbacks: callbacks,
                                        resumeFromProgress: project.separationProgress)
                }.value

                stageText = "拼接音轨…"
                var done = project
                done.stems = stems
                done.state = .separated
                done.separationProgress = 1
                appState.upsert(done)
                finished = true
            } catch is CancellationError {
                rollback(project, appState)
            } catch SeparationError.cancelled {
                rollback(project, appState)
            } catch {
                failed = "分离失败：\(error.localizedDescription)"
                var pr = project; pr.state = .failed; appState.upsert(pr)
            }
        }
    }

    func cancel(project: Project, appState: AppState) {
        engine?.cancel()
        task?.cancel()
        rollback(project, appState)
    }

    private func rollback(_ project: Project, _ appState: AppState) {
        var pr = project; pr.state = .imported; pr.separationProgress = 0
        appState.upsert(pr)
    }

    private static func makeProvider(plan: ChunkPlan) throws -> SeparationModelProvider {
        #if canImport(CoreML)
        let name = plan.model == .htDemucsFP16 ? "HTDemucs" : "Spleeter"
        guard let url = Bundle.main.url(forResource: name, withExtension: "mlmodelc") else {
            throw SeparationError.modelUnavailable
        }
        return try CoreMLSeparationProvider(kind: plan.model, modelURL: url)
        #else
        throw SeparationError.modelUnavailable
        #endif
    }

    static func timeString(_ s: Double) -> String {
        String(format: "%d:%02d", Int(s) / 60, Int(s) % 60)
    }
}
