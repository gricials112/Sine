import SwiftUI

/// Other 轨 10 段 EQ 面板 (难点三, docs/04 §3.6)。
struct EQPanelView: View {
    @State var settings: EQSettings
    var onChange: (EQSettings) -> Void
    @Environment(\.dismiss) private var dismiss

    private let presets: [(String, EQSettings)] = [
        ("吉他增强", EQPresets.guitarBoost),
        ("钢琴增强", EQPresets.pianoBoost),
        ("中频削弱", EQPresets.midScoop),
        ("自定义", EQPresets.flat)
    ]

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            VStack(spacing: 20) {
                Text("Other 轨均衡器").font(.headline).foregroundStyle(.white)
                Picker("预设", selection: Binding(
                    get: { settings.presetName },
                    set: { name in if let p = presets.first(where: { $0.0 == name }) { settings = p.1; onChange(settings) } })) {
                    ForEach(presets, id: \.0) { Text($0.0).tag($0.0) }
                }.pickerStyle(.segmented)

                HStack(alignment: .bottom, spacing: 6) {
                    ForEach(settings.bands.indices, id: \.self) { i in
                        VStack {
                            Slider(value: Binding(
                                get: { settings.bands[i].gain },
                                set: { settings.bands[i].gain = $0; settings.presetName = "自定义"; onChange(settings) }),
                                in: -12...12)
                                .rotationEffect(.degrees(-90))
                                .frame(width: 24, height: 120)
                            Text(freqLabel(settings.bands[i].frequency))
                                .font(.system(size: 8)).foregroundStyle(.gray)
                        }
                    }
                }.frame(height: 200)

                HStack {
                    Button("复位") { settings = EQPresets.flat; onChange(settings) }.tint(.gray)
                    Spacer()
                    Button("完成") { dismiss() }.buttonStyle(.borderedProminent).tint(Theme.accent)
                }
            }.padding()
        }
    }

    private func freqLabel(_ f: Float) -> String {
        f >= 1000 ? "\(Int(f/1000))k" : "\(Int(f))"
    }
}
