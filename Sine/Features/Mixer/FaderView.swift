import SwiftUI

/// 实体质感垂直推子 — 程序化拟物 (无素材, docs/04 §3.4)。
/// Canvas 绘制: 凹陷沟槽(内阴影) + 刻度 + 发光填充 + 3D 推子帽(渐变+握纹+倒角)。
/// 拖动有阻尼触感, 过 0dB 强反馈。
struct FaderView: View {
    let kind: StemKind
    @Binding var volume: Float       // 0~1
    var dimmed: Bool                 // Solo 模式下非发声轨暗化 (IR-2)
    var onChange: (Float) -> Void
    let haptics: HapticsService

    @State private var lastTick: Int = -1
    private let trackHeight: CGFloat = 188
    private let capH: CGFloat = 30

    var body: some View {
        VStack(spacing: 6) {
            Canvas { ctx, sz in
                let cx = sz.width / 2
                let top = capH / 2, bottom = sz.height - capH / 2
                let usable = bottom - top
                let trackColor = uiColor(kind)

                // 沟槽 (凹陷内阴影)
                let groove = CGRect(x: cx - 5, y: top, width: 10, height: usable)
                ctx.fill(Path(roundedRect: groove, cornerRadius: 5), with: .linearGradient(
                    Gradient(colors: [Color(white: 0.08), Color(white: 0.18)]),
                    startPoint: CGPoint(x: groove.minX, y: 0), endPoint: CGPoint(x: groove.maxX, y: 0)))
                ctx.stroke(Path(roundedRect: groove, cornerRadius: 5),
                           with: .color(.black.opacity(0.6)), lineWidth: 1)

                // 刻度 (左侧, 0dB 在 ~80%)
                for i in 0...10 {
                    let y = top + usable * CGFloat(i) / 10
                    let major = i % 5 == 0
                    var p = Path()
                    p.move(to: CGPoint(x: cx - 14, y: y))
                    p.addLine(to: CGPoint(x: cx - (major ? 22 : 18), y: y))
                    ctx.stroke(p, with: .color(Color(white: major ? 0.5 : 0.32)), lineWidth: 1)
                }

                // 发光填充
                let capY = bottom - usable * CGFloat(volume)
                let fill = CGRect(x: cx - 3, y: capY, width: 6, height: bottom - capY)
                ctx.fill(Path(roundedRect: fill, cornerRadius: 3), with: .color(trackColor))
                ctx.addFilter(.blur(radius: 4))
                ctx.fill(Path(roundedRect: fill, cornerRadius: 3), with: .color(trackColor.opacity(0.5)))
                ctx.addFilter(.blur(radius: 0))

                // 推子帽 (3D)
                let cap = CGRect(x: cx - 18, y: capY - capH / 2, width: 36, height: capH)
                ctx.fill(Path(roundedRect: cap, cornerRadius: 6), with: .linearGradient(
                    Gradient(colors: [Color(white: 0.40), Color(white: 0.16)]),
                    startPoint: CGPoint(x: 0, y: cap.minY), endPoint: CGPoint(x: 0, y: cap.maxY)))
                ctx.stroke(Path(roundedRect: cap, cornerRadius: 6),
                           with: .color(.black.opacity(0.55)), lineWidth: 1)
                // 中央彩色指示线 + 握纹
                var center = Path()
                center.move(to: CGPoint(x: cap.minX + 4, y: capY))
                center.addLine(to: CGPoint(x: cap.maxX - 4, y: capY))
                ctx.stroke(center, with: .color(trackColor), lineWidth: 2)
                for dy in [-7.0, 7.0] {
                    var g = Path()
                    g.move(to: CGPoint(x: cap.minX + 6, y: capY + dy))
                    g.addLine(to: CGPoint(x: cap.maxX - 6, y: capY + dy))
                    ctx.stroke(g, with: .color(.white.opacity(0.12)), lineWidth: 1)
                }
            }
            .frame(height: trackHeight)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                let v = Float(max(0, min(1, 1 - (g.location.y - capH / 2) / (trackHeight - capH))))
                update(v)
            })

            Text(dbString(volume)).font(.caption2.monospacedDigit()).foregroundStyle(.gray)
        }
        .opacity(dimmed ? 0.4 : 1.0)
        .animation(.easeInOut(duration: 0.15), value: dimmed)
    }

    private func uiColor(_ kind: StemKind) -> Color { Theme.trackColor(kind) }

    private func update(_ v: Float) {
        volume = v
        onChange(v)
        let tick = Int(v * 20)
        if tick != lastTick {
            lastTick = tick
            let strongAtUnity = abs(v - 1.0) < 0.03
            haptics.tick(intensity: strongAtUnity ? 1.0 : 0.5,
                         sharpness: strongAtUnity ? 0.5 : 0.85)
        }
    }

    private func dbString(_ v: Float) -> String {
        if v <= 0.0001 { return "-∞" }
        return String(format: "%.1f dB", 20 * log10f(v))
    }
}
