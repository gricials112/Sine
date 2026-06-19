import SwiftUI

/// 拟真旋钮 (Pitch/Speed)。垂直拖动改值 (IR-4, 比纯旋转更稳), 段落齿轮触感, 双击复位, 点击键入。
struct KnobView: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let defaultValue: Double
    var format: (Double) -> String
    let haptics: HapticsService

    @State private var lastStep: Int = .min
    @State private var editing = false
    @State private var editText = ""

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                Circle().fill(Theme.panel).frame(width: 84, height: 84)
                    .shadow(color: .black.opacity(0.6), radius: 5, x: 3, y: 3)
                    .shadow(color: Theme.highlight.opacity(0.5), radius: 4, x: -3, y: -3)
                // 指示刻痕
                Capsule().fill(Theme.accent).frame(width: 4, height: 18)
                    .offset(y: -24)
                    .rotationEffect(.degrees(angle))
            }
            .contentShape(Circle())
            .gesture(
                DragGesture().onChanged { g in
                    let delta = Double(-g.translation.height) / 150.0 * (range.upperBound - range.lowerBound)
                    setValue(value + delta * 0.15)
                }
            )
            .onTapGesture(count: 2) { setValue(defaultValue); haptics.success() }
            .onTapGesture { editText = format(value); editing = true }

            Text(title).font(.caption).foregroundStyle(.gray)
            Text(format(value)).font(.headline.monospacedDigit()).foregroundStyle(Theme.accent)
        }
        .alert("输入数值", isPresented: $editing) {
            TextField("", text: $editText).keyboardType(.numbersAndPunctuation)
            Button("确定") { if let v = Double(editText) { setValue(v) } }
            Button("取消", role: .cancel) {}
        }
    }

    private var angle: Double {
        let frac = (value - range.lowerBound) / (range.upperBound - range.lowerBound)
        return -135 + frac * 270   // -135°..+135°
    }

    private func setValue(_ raw: Double) {
        let snapped = (raw / step).rounded() * step
        let clamped = min(range.upperBound, max(range.lowerBound, snapped))
        if clamped != value {
            value = clamped
            let s = Int((clamped - range.lowerBound) / step)
            if s != lastStep { lastStep = s; haptics.tick(intensity: 0.6, sharpness: 0.9) }
        }
    }
}
