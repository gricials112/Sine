import SwiftUI
#if canImport(UIKit)
import UIKit

/// 系统分享面板 (UIActivityViewController) 的 SwiftUI 封装。
/// 覆盖"分享到其他 App"以及"存储到文件 (本地)"、"存储图像/视频" 等系统动作 (UC-06)。
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    var onComplete: (() -> Void)? = nil

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let vc = UIActivityViewController(activityItems: items, applicationActivities: nil)
        vc.completionWithItemsHandler = { _, _, _, _ in onComplete?() }
        return vc
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}
#endif
