import SwiftUI
import UniformTypeIdentifiers

/// 导入来源选择 + 解码 (UC-01, docs/04 §3.2)。
struct ImportView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @StateObject private var vm = ImportViewModel()
    @State private var showFilePicker = false

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            VStack(spacing: 24) {
                switch vm.phase {
                case .idle:
                    Text("选择来源").font(.title2.bold()).foregroundStyle(.white)
                    sourceButton("从文件导入", "folder") { showFilePicker = true }
                    sourceButton("从相册导入", "photo.on.rectangle") { vm.pickFromPhotos() }
                    Text("微信分享：在微信中选择“用其他应用打开 → Sine”")
                        .font(.footnote).foregroundStyle(.gray).multilineTextAlignment(.center)
                case .decoding(let p):
                    ProgressView(value: p) { Text("正在提取音频…").foregroundStyle(.white) }
                        .tint(Theme.accent).padding()
                case .failed(let msg):
                    ErrorCard(title: "导入失败", message: msg) { vm.reset() }
                }
            }
            .padding()
        }
        .fileImporter(isPresented: $showFilePicker,
                      allowedContentTypes: [.audio, .movie, .mpeg4Movie, .mp3, .wav]) { result in
            if case .success(let url) = result {
                Task { await importURL(url) }
            }
        }
    }

    private func sourceButton(_ title: String, _ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon).font(.headline)
                .frame(maxWidth: .infinity).padding().skeuomorphic()
        }.foregroundStyle(.white)
    }

    private func importURL(_ url: URL) async {
        if let project = await vm.decode(url: url, appState: appState) {
            appState.upsert(project)
            appState.activeProject = project
            dismiss()
        }
    }
}

struct ErrorCard: View {
    let title: String; let message: String; var action: () -> Void
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill").font(.largeTitle).foregroundStyle(.red)
            Text(title).font(.headline).foregroundStyle(.white)
            Text(message).font(.subheadline).foregroundStyle(.gray).multilineTextAlignment(.center)
            Button("好的", action: action).buttonStyle(.borderedProminent).tint(Theme.accent)
        }.padding().skeuomorphic()
    }
}
