import SwiftUI

/// 工程列表 / 空态 (docs/04 §3.1)。
struct ProjectListView: View {
    @EnvironmentObject var appState: AppState
    @State private var showImporter = false

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.background.ignoresSafeArea()
                if appState.projects.isEmpty {
                    emptyState
                } else {
                    list
                }
            }
            .navigationTitle("Sine")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("清缓存") { appState.clearCaches() }
                }
            }
            .sheet(isPresented: $showImporter) { ImportView() }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 20) {
            Button { showImporter = true } label: {
                Image(systemName: "power")
                    .font(.system(size: 56, weight: .bold))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 140, height: 140)
                    .skeuomorphic(radius: 70)
            }
            Text("导入音乐").font(.title3.bold()).foregroundStyle(.white)
            Text("全程本地处理，不上传云端").font(.footnote).foregroundStyle(.gray)
        }
    }

    private var list: some View {
        List {
            ForEach(appState.projects) { project in
                NavigationLink(value: project.id) {
                    ProjectRow(project: project)
                }
                .listRowBackground(Theme.panel)
            }
            .onDelete { idx in idx.map { appState.projects[$0] }.forEach(appState.delete) }
        }
        .scrollContentBackground(.hidden)
        .navigationDestination(for: UUID.self) { id in
            if let p = appState.projects.first(where: { $0.id == id }) {
                destination(for: p)
            }
        }
        .safeAreaInset(edge: .bottom) {
            Button { showImporter = true } label: {
                Label("导入", systemImage: "plus.circle.fill")
                    .font(.headline).frame(maxWidth: .infinity).padding()
            }
            .background(Theme.accent).foregroundStyle(.black).clipShape(Capsule())
            .padding()
        }
    }

    @ViewBuilder
    private func destination(for project: Project) -> some View {
        switch project.state {
        case .separated: MixerView(project: project)
        default:         SeparationProgressView(project: project)
        }
    }
}

struct ProjectRow: View {
    let project: Project
    var body: some View {
        HStack {
            Image(systemName: "waveform").foregroundStyle(Theme.accent)
            VStack(alignment: .leading) {
                Text(project.title).foregroundStyle(.white)
                Text(timeString(project.duration)).font(.caption).foregroundStyle(.gray)
            }
            Spacer()
            StateBadge(state: project.state)
        }
    }
    private func timeString(_ t: TimeInterval) -> String {
        String(format: "%d:%02d", Int(t) / 60, Int(t) % 60)
    }
}

struct StateBadge: View {
    let state: ProjectState
    var body: some View {
        Text(label).font(.caption2.bold())
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(color.opacity(0.2)).foregroundStyle(color).clipShape(Capsule())
    }
    private var label: String {
        switch state {
        case .imported: return "待分离"
        case .separating: return "分离中"
        case .separated: return "已分离"
        case .failed: return "失败"
        case .cancelled: return "已取消"
        }
    }
    private var color: Color { state == .separated ? .green : (state == .failed ? .red : Theme.accent) }
}
