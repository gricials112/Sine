import SwiftUI

/// 拟物旋钮 (Pitch/Speed) — 程序化金属质感 (无素材)。
/// Canvas 绘制: 圆顶径向渐变 + 高光 + 刻度环 + 数值弧 + 指针凹槽。
/// 交互: 垂直拖动改值 (IR-4, 比纯旋转稳), 段落齿轮触感, 双击复位, 点击键入。
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
    private let size: CGFloat = 92

    var body: some View {
        VStack(spacing: 8) {
            Canvas { ctx, sz in
                let c = CGPoint(x: sz.width / 2, y: sz.height / 2)
                let R = min(sz.width, sz.height) / 2
                let frac = (value - range.lowerBound) / (range.upperBound - range.lowerBound)
                let startA = Angle(degrees: 135), endA = Angle(degrees: 405) // 270° 弧

                // 刻度环 (21 格)
                for i in 0...20 {
                    let a = startA.radians + (endA.radians - startA.radians) * Double(i) / 20
                    let on = Double(i) / 20 <= frac
                    let r0 = R * 0.96, r1 = R * (i % 5 == 0 ? 0.80 : 0.86)
                    var p = Path()
                    p.move(to: CGPoint(x: c.x + cos(a) * r0, y: c.y + sin(a) * r0))
                    p.addLine(to: CGPoint(x: c.x + cos(a) * r1, y: c.y + sin(a) * r1))
                    ctx.stroke(p, with: .color(on ? Theme.accent : Color(white: 0.35)),
                               lineWidth: i % 5 == 0 ? 2.5 : 1.5)
                }
                // 数值弧 (辉光)
                var arc = Path()
                arc.addArc(center: c, radius: R * 0.9, startAngle: startA,
                           endAngle: Angle(radians: startA.radians + (endA.radians - startA.radians) * frac),
                           clockwise: false)
                ctx.stroke(arc, with: .color(Theme.accent.opacity(0.9)),
                           style: StrokeStyle(lineWidth: 3, lineCap: .round))

                // 旋钮本体 (圆顶金属)
                let bodyR = R * 0.72
                let body = Path(ellipseIn: CGRect(x: c.x - bodyR, y: c.y - bodyR, width: bodyR * 2, height: bodyR * 2))
                ctx.fill(body, with: .radialGradient(
                    Gradient(colors: [Color(white: 0.34), Color(white: 0.14)]),
                    center: CGPoint(x: c.x - bodyR * 0.3, y: c.y - bodyR * 0.4),
                    startRadius: 0, endRadius: bodyR * 1.5))
                ctx.stroke(body, with: .color(.black.opacity(0.6)), lineWidth: 1.5)
                // 顶部高光
                let hi = Path(ellipseIn: CGRect(x: c.x - bodyR * 0.55, y: c.y - bodyR * 0.7,
                                                width: bodyR * 1.1, height: bodyR * 0.7))
                ctx.fill(hi, with: .radialGradient(
                    Gradient(colors: [.white.opacity(0.25), .clear]),
                    center: CGPoint(x: c.x, y: c.y - bodyR * 0.4), startRadius: 0, endRadius: bodyR))

                // 指针凹槽
                let a = startA.radians + (endA.radians - startA.radians) * frac
                var pin = Path()
                pin.move(to: CGPoint(x: c.x + cos(a) * bodyR * 0.35, y: c.y + sin(a) * bodyR * 0.35))
                pin.addLine(to: CGPoint(x: c.x + cos(a) * bodyR * 0.88, y: c.y + sin(a) * bodyR * 0.88))
                ctx.stroke(pin, with: .color(Theme.accent), style: StrokeStyle(lineWidth: 4, lineCap: .round))
            }
            .frame(width: size, height: size)
            .contentShape(Circle())
            .gesture(DragGesture().onChanged { g in
                let delta = Double(-g.translation.height) / 150.0 * (range.upperBound - range.lowerBound)
                setValue(value + delta * 0.15)
            })
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
