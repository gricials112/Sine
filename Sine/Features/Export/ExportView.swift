import SwiftUI

/// 导出面板 (UC-06, IR-5 分轨/混音消歧, IR-8 内联预览)。
struct ExportView: View {
    let project: Project
    @ObservedObject var mixer: MixerViewModel          // 复用调音台引擎做预览
    @EnvironmentObject var appState: AppState
    @StateObject private var vm = ExportViewModel()
    @Environment(\.dismiss) private var dismiss

    @State private var mode: Mode = .mixdown
    @State private var selected: Set<StemKind> = Set(StemKind.allCases)
    @State private var format: ExportFormatChoice = .m4a
    @State private var parallelPreview = false
    @State private var soloPreview: StemKind? = nil
    @State private var shareURLs: [URL] = []
    @State private var showShare = false

    enum Mode: String, CaseIterable { case stems = "分轨导出", mixdown = "混音导出" }
    enum ExportFormatChoice: String, CaseIterable { case m4a = "m4a", wav = "wav (无损)" }

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            VStack(spacing: 18) {
                Text("导出").font(.headline).foregroundStyle(.white)

                Picker("模式", selection: $mode) {
                    ForEach(Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.segmented)

                Text(mode == .mixdown ? "按当前音量/Solo/Speed/Key/EQ 合成单个文件" : "选中的音轨各自原样导出")
                    .font(.caption).foregroundStyle(.gray)

                // 并行预览 (听当前勾选的合成)
                HStack {
                    HardwareButton(label: "", systemImage: parallelPreview ? "pause.fill" : "play.fill",
                                   isOn: parallelPreview, onColor: Theme.accent) { toggleParallel() }
                        .frame(width: 44, height: 30)
                    Text("试听选中 (并行)").font(.caption).foregroundStyle(.gray)
                    Spacer()
                }

                // 每轨: 勾选导出 + 单独试听 (该 stem = 单源)
                ForEach(StemKind.allCases) { kind in
                    HStack {
                        Toggle(isOn: Binding(
                            get: { selected.contains(kind) },
                            set: { on in
                                if on { selected.insert(kind) } else { selected.remove(kind) }
                                if parallelPreview { mixer.previewExport(selection: selected) }
                            })) {
                            Text(kind.displayName).foregroundStyle(Theme.trackColor(kind))
                        }.tint(Theme.accent)
                        HardwareButton(label: "",
                                       systemImage: soloPreview == kind ? "speaker.wave.2.fill" : "speaker.fill",
                                       isOn: soloPreview == kind, onColor: Theme.trackColor(kind)) {
                            toggleSolo(kind)
                        }.frame(width: 36, height: 26)
                    }
                }

                Picker("格式", selection: $format) {
                    ForEach(ExportFormatChoice.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.segmented)

                if case .rendering(let p) = vm.phase { ProgressView(value: p).tint(Theme.accent) }
                if case .failed(let m) = vm.phase { Text(m).foregroundStyle(.red).font(.caption) }

                if case .done(let urls) = vm.phase {
                    Label("导出完成", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    Button {
                        shareURLs = urls; showShare = true
                    } label: {
                        Label("分享 / 存到文件", systemImage: "square.and.arrow.up")
                            .font(.headline).frame(maxWidth: .infinity).padding(.vertical, 10)
                    }.background(Theme.accent).foregroundStyle(.black).clipShape(Capsule())
                } else {
                    Button("导出") { stopPreview(); export() }
                        .buttonStyle(.borderedProminent).tint(Theme.accent)
                        .disabled(selected.isEmpty || vm.isBusy)
                }
            }.padding()
        }
        .onDisappear { stopPreview() }
        #if canImport(UIKit)
        .sheet(isPresented: $showShare) { ShareSheet(items: shareURLs) }
        #endif
    }

    // MARK: - 预览控制
    private func toggleParallel() {
        soloPreview = nil
        parallelPreview.toggle()
        if parallelPreview { mixer.previewExport(selection: selected) } else { mixer.endPreview() }
    }

    private func toggleSolo(_ kind: StemKind) {
        parallelPreview = false
        if soloPreview == kind { soloPreview = nil; mixer.endPreview() }
        else { soloPreview = kind; mixer.previewExport(selection: selected, solo: kind) }
    }

    private func stopPreview() {
        if parallelPreview || soloPreview != nil {
            parallelPreview = false; soloPreview = nil; mixer.endPreview()
        }
    }

    private func export() {
        let intent: ExportIntentChoice = mode == .mixdown ? .mixdown : .stems
        vm.export(project: project, mix: mixer.mix, kinds: selected,
                  intent: intent, wav: format == .wav,
                  outputDir: appState.workDir(for: project))
    }
}

enum ExportIntentChoice { case stems, mixdown }
