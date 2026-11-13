import SwiftUI

/// 弹窗的读屏「返回」手势：没有回调时原样返回。
/// 半屏 `CouliSheet` 也挂在面板根上（FU-IOS-A11Y-02）：与关闭键同一出口，焦点在正文、按钮上也接得住，不冒泡到导航把底下一页退掉。
struct DialogEscape: ViewModifier {
    let action: (() -> Void)?

    func body(content: Content) -> some View {
        if let action {
            content.accessibilityAction(.escape, action)
        } else {
            content
        }
    }
}
