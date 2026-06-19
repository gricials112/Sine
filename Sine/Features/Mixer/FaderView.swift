import SwiftUI

/// 实体质感垂直推子 (docs/04 §3.4)。拖动有阻尼触感, 过 0dB 强反馈。
struct FaderView: View {
    let kind: StemKind
    @Binding var volume: Float       // 0~1
    var dimmed: Bool                 // Solo 模式下非发声轨暗化 (IR-2)
    var onChange: (Float) -> Void
    let haptics: HapticsService

    @State private var lastTick: Int = -1
    private let trackHeight: CGFloat = 180

    var body: some View {
        VStack(spacing: 6) {
            GeometryReader { geo in
                ZStack(alignment: .bottom) {
                    Capsule().fill(Theme.highlight).frame(width: 8)            // 滑轨
                    Capsule().fill(Theme.trackColor(kind))                      // 已填充
                        .frame(width: 8, height: geo.size.height * CGFloat(volume))
                    Circle().fill(Theme.panel)                                   // 推子帽
                        .frame(width: 34, height: 34)
                        .overlay(Circle().stroke(Theme.trackColor(kind), lineWidth: 2))
                        .shadow(color: .black.opacity(0.6), radius: 4, y: 3)
                        .offset(y: -(geo.size.height - 34) * CGFloat(volume))
                }
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0).onChanged { g in
                        let h = geo.size.height
                        let v = Float(max(0, min(1, 1 - (g.location.y / h))))
                        update(v)
                    }
                )
            }
            .frame(height: trackHeight)
            Text(dbString(volume)).font(.caption2.monospacedDigit()).foregroundStyle(.gray)
        }
        .opacity(dimmed ? 0.4 : 1.0)
        .animation(.easeInOut(duration: 0.15), value: dimmed)
    }

    private func update(_ v: Float) {
        volume = v
        onChange(v)
        // 跨刻度触感 (每 5% 一格); 0dB(=1.0) 处更强
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
