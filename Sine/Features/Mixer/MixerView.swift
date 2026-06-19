import SwiftUI

/// 调音台主页 (docs/04 §3.4)。顶部 Metal FFT 波形, 中部 4 推子, 底部旋钮 + 导出。
struct MixerView: View {
    let project: Project
    @EnvironmentObject var appState: AppState
    @StateObject private var vm = MixerViewModel()
    @State private var showExport = false
    @State private var showEQ = false

    private var pitchBinding: Binding<Double> {
        Binding(get: { Double(vm.mix.pitchSemitones) }, set: { vm.setPitch(Int($0)) })
    }
    private var speedBinding: Binding<Double> {
        Binding(get: { Double(vm.mix.speed) }, set: { vm.setSpeed(Float($0)) })
    }

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            VStack(spacing: 16) {
                waveform
                faders
                Divider().overlay(Theme.highlight)
                controls
            }.padding()
        }
        .navigationTitle(project.title)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showExport = true } label: { Image(systemName: "square.and.arrow.up") }
            }
        }
        .onAppear { vm.load(project: project) }
        .sheet(isPresented: $showExport) { ExportView(project: project, mix: vm.mix) }
        .sheet(isPresented: $showEQ) {
            EQPanelView(settings: vm.mix.otherEQ) { vm.setEQ($0) }
        }
    }

    private var waveform: some View {
        Group {
            #if canImport(MetalKit)
            MetalFFTView(spectrum: $vm.spectrum, energy: vm.energy)
            #else
            Rectangle().fill(Theme.panel)
            #endif
        }
        .frame(height: 160).clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(alignment: .bottomLeading) {
            HStack {
                Button { vm.togglePlay() } label: {
                    Image(systemName: vm.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title2).foregroundStyle(Theme.accent)
                }
            }.padding(8)
        }
    }

    private var faders: some View {
        HStack(spacing: 12) {
            ForEach(StemKind.allCases) { kind in
                VStack(spacing: 8) {
                    Text(kind.displayName).font(.caption.bold()).foregroundStyle(Theme.trackColor(kind))
                    FaderView(
                        kind: kind,
                        volume: Binding(
                            get: { vm.mix.tracks.first { $0.kind == kind }?.volume ?? 1 },
                            set: { vm.setVolume($0, for: kind) }),
                        dimmed: vm.soloActive && !vm.isAudible(kind),
                        onChange: { vm.setVolume($0, for: kind) },
                        haptics: vm.haptics)
                    soloMute(kind)
                    if kind == .other {
                        Button { showEQ = true } label: { Image(systemName: "slider.vertical.3") }
                            .foregroundStyle(Theme.accent)
                    }
                }
            }
        }
    }

    private func soloMute(_ kind: StemKind) -> some View {
        let track = vm.mix.tracks.first { $0.kind == kind }
        return HStack(spacing: 6) {
            toggle("S", on: track?.solo ?? false, color: Theme.accent) { vm.toggleSolo(kind); vm.haptics.tick() }
            toggle("M", on: track?.mute ?? false, color: .red) { vm.toggleMute(kind); vm.haptics.tick() }
        }
    }

    private func toggle(_ label: String, on: Bool, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label).font(.caption2.bold())
                .frame(width: 26, height: 22)
                .background(on ? color : Theme.highlight)
                .foregroundStyle(on ? .black : .gray)
                .clipShape(RoundedRectangle(cornerRadius: 5))
        }
    }

    private var controls: some View {
        HStack(spacing: 28) {
            KnobView(title: "Pitch", value: pitchBinding, range: -12...12, step: 1, defaultValue: 0,
                     format: { String(format: "%+d st", Int($0)) }, haptics: vm.haptics)
            KnobView(title: "Speed", value: speedBinding, range: 0.5...2.0, step: 0.05, defaultValue: 1.0,
                     format: { String(format: "%.2fx", $0) }, haptics: vm.haptics)
            Spacer()
            Button { showExport = true } label: {
                Label("导出", systemImage: "square.and.arrow.up").font(.headline)
                    .padding(.horizontal, 18).padding(.vertical, 12)
            }.background(Theme.accent).foregroundStyle(.black).clipShape(Capsule())
        }
    }
}
