import SwiftUI

/// 程序化拟物材质 (无需外部素材, docs/04 §1)。用 Canvas 绘制拉丝金属、倒角、螺丝等硬件质感。
enum Materials {
    /// 稳定伪随机 (按索引), 保证拉丝纹理每帧一致不闪烁。
    static func noise(_ i: Int) -> Double {
        let x = sin(Double(i) * 12.9898) * 43758.5453
        return x - floor(x)
    }
}

/// 拉丝金属背景: 垂直渐变 + 细密横向拉丝线 + 暗角。
struct BrushedMetal: View {
    var base: Color = Theme.panel
    var cornerRadius: CGFloat = 0

    var body: some View {
        Canvas { ctx, size in
            // 1) 垂直金属渐变
            let rect = CGRect(origin: .zero, size: size)
            let grad = Gradient(stops: [
                .init(color: Color(white: 0.26), location: 0),
                .init(color: Color(white: 0.16), location: 0.5),
                .init(color: Color(white: 0.20), location: 1),
            ])
            ctx.fill(Path(rect), with: .linearGradient(grad,
                     startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
            // 2) 横向拉丝线
            let lines = Int(size.height)
            for y in stride(from: 0, to: lines, by: 2) {
                let a = 0.04 + 0.05 * Materials.noise(y)
                let col = Materials.noise(y * 7) > 0.5 ? Color.white : Color.black
                var p = Path()
                p.move(to: CGPoint(x: 0, y: Double(y)))
                p.addLine(to: CGPoint(x: size.width, y: Double(y)))
                ctx.stroke(p, with: .color(col.opacity(a)), lineWidth: 1)
            }
            // 3) 暗角
            let vg = Gradient(colors: [.clear, .black.opacity(0.35)])
            ctx.fill(Path(rect), with: .radialGradient(vg,
                     center: CGPoint(x: size.width / 2, y: size.height / 2),
                     startRadius: size.width * 0.3, endRadius: size.width * 0.75))
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
    }
}

/// 嵌入面板: 拉丝金属 + 倒角高光(上左) + AO 内阴影(下右) + 四角螺丝。
struct InsetPanel: ViewModifier {
    var radius: CGFloat = 16
    var screws: Bool = false
    func body(content: Content) -> some View {
        content
            .background(
                ZStack {
                    BrushedMetal(cornerRadius: radius)
                    RoundedRectangle(cornerRadius: radius)
                        .stroke(Color.white.opacity(0.12), lineWidth: 1)
                        .blur(radius: 0.5)
                        .offset(x: -0.5, y: -0.5)         // 倒角高光
                    RoundedRectangle(cornerRadius: radius)
                        .stroke(Color.black.opacity(0.55), lineWidth: 1.5)
                        .blur(radius: 1)
                        .offset(x: 1, y: 1)                // AO
                        .mask(RoundedRectangle(cornerRadius: radius))
                    if screws { ScrewsOverlay(radius: radius) }
                }
            )
            .shadow(color: .black.opacity(0.5), radius: 6, x: 3, y: 4)
    }
}

/// 四角螺丝 (硬件铭牌感)。
struct ScrewsOverlay: View {
    var radius: CGFloat
    var body: some View {
        GeometryReader { geo in
            ForEach(0..<4, id: \.self) { i in
                let x = i % 2 == 0 ? 16.0 : geo.size.width - 16
                let y = i < 2 ? 16.0 : geo.size.height - 16
                Screw().frame(width: 14, height: 14).position(x: x, y: y)
            }
        }
    }
}

struct Screw: View {
    var body: some View {
        Canvas { ctx, size in
            let r = CGRect(origin: .zero, size: size)
            ctx.fill(Path(ellipseIn: r), with: .radialGradient(
                Gradient(colors: [Color(white: 0.42), Color(white: 0.12)]),
                center: CGPoint(x: size.width * 0.35, y: size.height * 0.35),
                startRadius: 0, endRadius: size.width))
            ctx.stroke(Path(ellipseIn: r.insetBy(dx: 0.5, dy: 0.5)),
                       with: .color(.black.opacity(0.6)), lineWidth: 1)
            // 一字槽
            var slot = Path()
            slot.move(to: CGPoint(x: size.width * 0.22, y: size.height * 0.5))
            slot.addLine(to: CGPoint(x: size.width * 0.78, y: size.height * 0.5))
            ctx.stroke(slot, with: .color(.black.opacity(0.7)), lineWidth: 1.5)
        }
    }
}

extension View {
    func insetPanel(radius: CGFloat = 16, screws: Bool = false) -> some View {
        modifier(InsetPanel(radius: radius, screws: screws))
    }
}

/// 硬件按钮 (Solo/Mute/播放): 凸起倒角, 激活时 LED 辉光。
struct HardwareButton: View {
    let label: String
    var systemImage: String? = nil
    var isOn: Bool
    var onColor: Color
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                RoundedRectangle(cornerRadius: 6)
                    .fill(LinearGradient(colors: isOn
                        ? [onColor, onColor.opacity(0.75)]
                        : [Color(white: 0.28), Color(white: 0.18)],
                        startPoint: .top, endPoint: .bottom))
                    .overlay(RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.white.opacity(0.15), lineWidth: 1).offset(y: -0.5))
                    .shadow(color: isOn ? onColor.opacity(0.7) : .clear, radius: isOn ? 8 : 0)
                    .shadow(color: .black.opacity(0.5), radius: 2, y: 1)
                Group {
                    if let s = systemImage { Image(systemName: s) }
                    else { Text(label).font(.caption2.bold()) }
                }
                .foregroundStyle(isOn ? Color.black : Color(white: 0.6))
            }
        }
        .buttonStyle(.plain)
    }
}
