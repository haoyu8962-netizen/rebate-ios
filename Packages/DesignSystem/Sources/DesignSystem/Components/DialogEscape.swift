import SwiftUI

/// 弹窗的读屏「返回」手势：没有回调时原样返回。
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
