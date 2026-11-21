import DesignSystem
import SwiftUI
import UIKit

/// 键盘弹起时把当前步主按钮带进可视区（FU-LOGIN-KEYBOARD-AVOID-ios，D10-2458；视觉验收 §2.4：最大字号与最小宽度下
/// 键盘弹起时主按钮整块可见可点、与键盘顶余量 ≥ 12pt）。登录页、绑手机页共用。
enum KeyboardPrimary {
    /// 锚点比主按钮下沿多出的高度：滚到锚点底边对齐可视区底边后，按钮下沿与键盘顶（或钉底栏上沿）留 16pt（≥ 12）。
    static let margin: CGFloat = CouliSpacing.s4
}

extension View {
    /// 给主按钮挂一个滚动锚点：透明、不占布局（放在 background 里，用负的底部留白向下伸出 `margin`），键盘收起时布局不变。
    func keyboardPrimaryAnchor(_ id: String) -> some View {
        background(alignment: .top) {
            Color.clear
                .id(id)
                .padding(.bottom, -KeyboardPrimary.margin)
                .accessibilityHidden(true)
        }
    }

    /// 目标锚点非空时，在 `trigger` 变化（输入框获得焦点、输入内容变化）与键盘弹起 / 尺寸变化后，把锚点滚到可视区底部。
    /// 可视区已由键盘安全区（绑手机页另有钉底栏的 safeAreaInset）收窄；内容不够滚时停在最底，按钮位置只会更高。
    func keyboardPrimaryScroll(
        _ proxy: ScrollViewProxy,
        target: String?,
        trigger: some Equatable
    ) -> some View {
        modifier(KeyboardPrimaryScroll(proxy: proxy, target: target, trigger: trigger))
    }
}

private struct KeyboardPrimaryScroll<Trigger: Equatable>: ViewModifier {
    let proxy: ScrollViewProxy
    let target: String?
    let trigger: Trigger

    func body(content: Content) -> some View {
        content
            .onChange(of: trigger) { _ in scroll() }
            // 聚焦当刻键盘尚未弹起、可视区还没收窄；弹起完成与尺寸变化（换输入法、联想栏）后再滚一次
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardDidShowNotification)) { _ in
                scroll()
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardDidChangeFrameNotification)) { _ in
                scroll()
            }
    }

    private func scroll() {
        guard let target else { return }
        withAnimation { proxy.scrollTo(target, anchor: .bottom) }
    }
}
