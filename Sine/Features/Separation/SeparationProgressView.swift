import SwiftUI

/// 分离进度页 (难点一可视化, docs/04 §3.3, IR-1 支持锁屏续跑)。
struct SeparationProgressView: View {
    let project: Project
    @EnvironmentObject var appState: AppState
    @StateObject private var vm = SeparationViewModel()
    @Environment(\.dismiss) private var dismiss
    @State private var confirmCancel = false

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            VStack(spacing: 28) {
                if project.state == .imported && vm.progress == 0 && !vm.finished {
                    startCard
                } else {
                    progressRing
                    Text(vm.stageText).foregroundStyle(.white)
                    Text(vm.modelText).font(.caption).foregroundStyle(Theme.accent)
                    Text(vm.etaText).font(.caption).foregroundStyle(.gray)
                    Text("可锁屏，回来自动继续").font(.caption2).foregroundStyle(.gray)
                    Button("取消") { confirmCancel = true }.tint(.red)
                }
                if let err = vm.failed { ErrorCard(title: "出错了", message: err) { dismiss() } }
            }.padding()
        }
        .navigationTitle(project.title)
        .navigationBarBackButtonHidden(vm.progress > 0 && !vm.finished)
        .onChange(of: vm.finished) { _, done in if done { appState.activeProject = appState.projects.first { $0.id == project.id } } }
        .alert("取消分离？", isPresented: $confirmCancel) {
            Button("继续分离", role: .cancel) {}
            Button("取消", role: .destructive) { vm.cancel(project: project, appState: appState); dismiss() }
        } message: { Text("已完成的进度将被丢弃。") }
    }

    private var startCard: some View {
        VStack(spacing: 16) {
            Image(systemName: "waveform.path.ecg").font(.system(size: 48)).foregroundStyle(Theme.accent)
            Text("开始分离为 4 条音轨").foregroundStyle(.white)
            Button("开始分离") { vm.start(project: project, appState: appState) }
                .buttonStyle(.borderedProminent).tint(Theme.accent)
        }.padding().skeuomorphic()
    }

    private var progressRing: some View {
        ZStack {
            Circle().stroke(Theme.highlight, lineWidth: 14).frame(width: 180, height: 180)
            Circle().trim(from: 0, to: vm.progress)
                .stroke(Theme.accent, style: StrokeStyle(lineWidth: 14, lineCap: .round))
                .rotationEffect(.degrees(-90)).frame(width: 180, height: 180)
                .animation(.easeOut, value: vm.progress)
            Text("\(Int(vm.progress * 100))%").font(.largeTitle.monospacedDigit().bold()).foregroundStyle(.white)
        }
    }
}
