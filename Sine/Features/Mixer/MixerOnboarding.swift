import SwiftUI

/// 首次进入调音台的手势引导 (IR-7)。一次性, 可跳过, 不打断后续使用。
/// 标记存于 UserDefaults (已在 PrivacyInfo.xcprivacy 声明 CA92.1)。
enum OnboardingStore {
    private static let key = "hasSeenMixerOnboarding"
    static var hasSeenMixer: Bool {
        get { UserDefaults.standard.bool(forKey: key) }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }
}

struct MixerCoachMarks: View {
    var onDismiss: () -> Void

    private struct Tip: Identifiable { let id = UUID(); let icon: String; let title: String; let desc: String }
    private let tips: [Tip] = [
        .init(icon: "slider.vertical.3", title: "推子", desc: "上下拖动调节每条音轨音量，过 0dB 有更强触感反馈。"),
        .init(icon: "s.circle", title: "Solo / Mute", desc: "点 S 独奏（仅听该轨）、M 静音；可多轨同时 Solo。"),
        .init(icon: "dial.min", title: "旋钮", desc: "拖动 Pitch / Speed 调变调变速，双击复位，点按可键入数值。"),
        .init(icon: "waveform.path", title: "Other-EQ", desc: "“其他”轨可挂 10 段 EQ（吉他/钢琴/中频削弱）补偿杂音。"),
    ]

    var body: some View {
        ZStack {
            Color.black.opacity(0.78).ignoresSafeArea()
            VStack(spacing: 18) {
                Text("快速上手").font(.title2.bold()).foregroundStyle(.white)
                ForEach(tips) { tip in
                    HStack(alignment: .top, spacing: 14) {
                        Image(systemName: tip.icon)
                            .font(.title2).foregroundStyle(Theme.accent)
                            .frame(width: 36)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(tip.title).font(.headline).foregroundStyle(.white)
                            Text(tip.desc).font(.subheadline).foregroundStyle(Color(white: 0.75))
                        }
                        Spacer()
                    }
                }
                Button {
                    OnboardingStore.hasSeenMixer = true
                    onDismiss()
                } label: {
                    Text("开始使用").font(.headline).frame(maxWidth: .infinity).padding(.vertical, 12)
                }
                .background(Theme.accent).foregroundStyle(.black).clipShape(Capsule())
                .padding(.top, 6)
            }
            .padding(24)
            .insetPanel(radius: 20)
            .padding(28)
        }
        .transition(.opacity)
    }
}
