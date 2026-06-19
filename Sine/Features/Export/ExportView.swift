import SwiftUI

/// 导出面板 (UC-06, IR-5 分轨/混音消歧)。
struct ExportView: View {
    let project: Project
    let mix: MixState
    @EnvironmentObject var appState: AppState
    @StateObject private var vm = ExportViewModel()
    @Environment(\.dismiss) private var dismiss

    @State private var mode: Mode = .mixdown
    @State private var selected: Set<StemKind> = Set(StemKind.allCases)
    @State private var format: ExportFormatChoice = .m4a

    enum Mode: String, CaseIterable { case stems = "分轨导出", mixdown = "混音导出" }
    enum ExportFormatChoice: String, CaseIterable { case m4a = "m4a", wav = "wav (无损)" }

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            VStack(spacing: 20) {
                Text("导出").font(.headline).foregroundStyle(.white)

                Picker("模式", selection: $mode) {
                    ForEach(Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.segmented)

                Text(mode == .mixdown ? "按当前音量/Solo/Speed/Key/EQ 合成单个文件" : "选中的音轨各自原样导出")
                    .font(.caption).foregroundStyle(.gray)

                ForEach(StemKind.allCases) { kind in
                    Toggle(isOn: Binding(
                        get: { selected.contains(kind) },
                        set: { on in if on { selected.insert(kind) } else { selected.remove(kind) } })) {
                        Text(kind.displayName).foregroundStyle(Theme.trackColor(kind))
                    }.tint(Theme.accent)
                }

                Picker("格式", selection: $format) {
                    ForEach(ExportFormatChoice.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.segmented)

                if case .rendering(let p) = vm.phase {
                    ProgressView(value: p).tint(Theme.accent)
                }
                if case .done = vm.phase {
                    Label("导出完成", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                }
                if case .failed(let m) = vm.phase {
                    Text(m).foregroundStyle(.red).font(.caption)
                }

                Button("导出") { export() }
                    .buttonStyle(.borderedProminent).tint(Theme.accent)
                    .disabled(selected.isEmpty || vm.isBusy)
            }.padding()
        }
    }

    private func export() {
        let intent: ExportIntentChoice = mode == .mixdown ? .mixdown : .stems
        vm.export(project: project, mix: mix, kinds: selected,
                  intent: intent, wav: format == .wav,
                  outputDir: appState.workDir(for: project))
    }
}

enum ExportIntentChoice { case stems, mixdown }
