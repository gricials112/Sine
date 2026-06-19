import SwiftUI

/// 现代拟真工业风设计令牌 (docs/04 §1)。
enum Theme {
    static let background = Color(red: 0x1A/255, green: 0x1B/255, blue: 0x1E/255)
    static let panel      = Color(red: 0x26/255, green: 0x28/255, blue: 0x2C/255)
    static let highlight  = Color(red: 0x3A/255, green: 0x3D/255, blue: 0x42/255)
    static let accent     = Color(red: 0xFF/255, green: 0x6A/255, blue: 0x2B/255) // 信号橙

    static func trackColor(_ kind: StemKind) -> Color {
        switch kind {
        case .vocal: return Color(red: 1.0, green: 0.55, blue: 0.25)   // 暖橙
        case .drums: return Color(red: 0.25, green: 0.78, blue: 0.82)  // 青
        case .bass:  return Color(red: 0.85, green: 0.25, blue: 0.65)  // 品红
        case .other: return Color(red: 0.65, green: 0.82, blue: 0.30)  // 黄绿
        }
    }

    static let monoFont = Font.system(.body, design: .monospaced)
}

/// 拟真"陷入面板"内阴影 + 凸起高光修饰器。
struct Skeuomorphic: ViewModifier {
    var radius: CGFloat = 12
    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: radius)
                    .fill(Theme.panel)
                    .shadow(color: .black.opacity(0.6), radius: 6, x: 4, y: 4)        // AO
                    .shadow(color: Theme.highlight.opacity(0.5), radius: 4, x: -3, y: -3) // 高光
            )
    }
}

extension View {
    func skeuomorphic(radius: CGFloat = 12) -> some View { modifier(Skeuomorphic(radius: radius)) }
}
