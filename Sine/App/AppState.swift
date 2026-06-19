import Foundation
import Combine

/// 全局状态 + 工程仓库 (UC-07)。工程元数据持久化到 Application Support, 媒体落临时/文档目录。
@MainActor
final class AppState: ObservableObject {
    @Published var projects: [Project] = []
    @Published var activeProject: Project?

    private let storeURL: URL

    init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        storeURL = dir.appendingPathComponent("projects.json")
        load()
    }

    func workDir(for project: Project) -> URL {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Projects/\(project.id.uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func upsert(_ project: Project) {
        if let idx = projects.firstIndex(where: { $0.id == project.id }) {
            projects[idx] = project
        } else {
            projects.insert(project, at: 0)
        }
        if activeProject?.id == project.id { activeProject = project }
        save()
    }

    func delete(_ project: Project) {
        projects.removeAll { $0.id == project.id }
        try? FileManager.default.removeItem(at: workDir(for: project))
        if let pcm = project.pcmURL { try? FileManager.default.removeItem(at: pcm) }
        save()
    }

    /// 清缓存: 删除临时 PCM 与孤立文件, 保留"已分离"工程的 stem (UC-07 AC)。
    func clearCaches() {
        let tmp = FileManager.default.temporaryDirectory
        if let items = try? FileManager.default.contentsOfDirectory(at: tmp, includingPropertiesForKeys: nil) {
            items.forEach { try? FileManager.default.removeItem(at: $0) }
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: storeURL),
              let decoded = try? JSONDecoder().decode([Project].self, from: data) else { return }
        projects = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(projects) else { return }
        try? data.write(to: storeURL, options: .atomic)
    }
}
