import DesignSystem
import SwiftUI
import UIKit

/// 键盘弹起时主按钮与正在输入的框整块可见（FU-LOGIN-KEYBOARD-AVOID-ios，D10-2458；视觉验收 §2.4）。登录页：主按钮钉底，
/// 输入框按需滚到底栏上沿以上；绑手机页：【获取验证码】按需滚到钉底提交栏上沿以上。位置一律用全局坐标实测，
/// 「挡住的上沿」取钉底栏实测上沿与可视区底边中较高者（r4：可视区底边与栏上沿实测差约 8pt，不能只靠可视区）。
enum KeyboardPrimary {
    /// 余量：钉底栏按钮下沿到键盘顶、按需滚动时目标下沿到栏上沿都至少留 16pt（≥ 12，给取整留余地；review-r1 S3）。
    static let margin: CGFloat = CouliSpacing.s4
}

extension View {
    /// 钉底栏外观（留白、限宽、底色照绑手机页 bottomBar；底部留白 16pt），并上报栏的实测上沿。
    func keyboardPinnedBar() -> some View {
        padding(.horizontal, CouliSpacing.s4)
            .padding(.top, CouliSpacing.s3)
            .padding(.bottom, KeyboardPrimary.margin)
            .frame(maxWidth: LoginView.maxContentWidth)
            .frame(maxWidth: .infinity)
            .keyboardBarTop()
            .background(CouliColor.backgroundCanvas.ignoresSafeArea())
    }

    /// 上报钉底栏上沿（全局坐标），读取方用 `onPreferenceChange(KeyboardBarTopKey.self)`。
    func keyboardBarTop() -> some View {
        background {
            GeometryReader { geo in
                Color.clear.preference(key: KeyboardBarTopKey.self, value: geo.frame(in: .global).minY)
            }
            .accessibilityHidden(true)
        }
    }

    /// 滚动目标的锚点与位置上报：透明、不占布局（放在 background 里），键盘收起时布局不变。锚点用负的底部留白向下
    /// 伸出 `extends`，`scrollTo(.bottom)` 后目标下沿离可视区底边 `extends`；内容不够滚时停在最底。
    func keyboardPrimaryAnchor(_ id: String, extends: CGFloat) -> some View {
        background(alignment: .top) {
            GeometryReader { geo in
                Color.clear.preference(key: PrimaryFrameKey.self, value: geo.frame(in: .global))
            }
            .accessibilityHidden(true)
        }
        .background(alignment: .top) {
            Color.clear
                .id(id)
                .padding(.bottom, -extends)
                .accessibilityHidden(true)
        }
    }

    /// 滚动内容顶部锚点与位置上报（挂在内容最外层；不占布局）：键盘收起时滚回这里。
    func keyboardContentTop(_ id: String) -> some View {
        background(alignment: .top) {
            GeometryReader { geo in
                Color.clear.preference(key: ContentTopKey.self, value: geo.frame(in: .global).minY)
            }
            .accessibilityHidden(true)
        }
        .background(alignment: .top) {
            Color.clear.frame(height: 1).id(id).accessibilityHidden(true)
        }
    }

    /// 按需滚动（挂在 ScrollView 上）：`active` 且键盘弹起时，目标已整块在可视区内、下沿离「栏上沿 `barTop` 与可视区底边
    /// 较高者」≥ 16pt 就不滚；否则滚到锚点。键盘收起时，若弹起前内容在顶部而现在不在（本修饰器或系统滚过），滚回顶部。
    func keyboardPrimaryScroll(
        _ proxy: ScrollViewProxy, target: String, top: String, active: Bool, barTop: CGFloat?
    ) -> some View {
        modifier(KeyboardPrimaryScroll(proxy: proxy, target: target, top: top, active: active, barTop: barTop))
    }
}

struct KeyboardBarTopKey: PreferenceKey {
    static let defaultValue: CGFloat? = nil
    static func reduce(value: inout CGFloat?, nextValue: () -> CGFloat?) {
        value = value ?? nextValue()
    }
}

/// 可视区在全局坐标里的上下沿（扣掉安全区：键盘、safeAreaInset）。
private struct VisibleBand: Equatable {
    var top: CGFloat
    var bottom: CGFloat
}

private struct PrimaryFrameKey: PreferenceKey {
    static let defaultValue: CGRect? = nil
    static func reduce(value: inout CGRect?, nextValue: () -> CGRect?) {
        value = value ?? nextValue()
    }
}

private struct ContentTopKey: PreferenceKey {
    static let defaultValue: CGFloat? = nil
    static func reduce(value: inout CGFloat?, nextValue: () -> CGFloat?) {
        value = value ?? nextValue()
    }
}

private struct VisibleBandKey: PreferenceKey {
    static let defaultValue: VisibleBand? = nil
    static func reduce(value: inout VisibleBand?, nextValue: () -> VisibleBand?) {
        value = value ?? nextValue()
    }
}

private struct KeyboardPrimaryScroll: ViewModifier {
    let proxy: ScrollViewProxy
    let target: String
    let top: String
    let active: Bool
    let barTop: CGFloat?
    @State private var keyboardUp = false
    @State private var band: VisibleBand?
    @State private var primary: CGRect?
    @State private var contentTop: CGFloat?
    /// 键盘弹起前内容是否在顶部（每次弹起记一次）。
    @State private var topBeforeKeyboard: Bool?

    func body(content: Content) -> some View {
        content
            .background {
                GeometryReader { geo in
                    let frame = geo.frame(in: .global)
                    Color.clear.preference(
                        key: VisibleBandKey.self,
                        value: VisibleBand(top: frame.minY + geo.safeAreaInsets.top,
                                           bottom: frame.maxY - geo.safeAreaInsets.bottom)
                    )
                }
                .accessibilityHidden(true)
            }
            .onPreferenceChange(PrimaryFrameKey.self) { primary = $0 }
            .onPreferenceChange(ContentTopKey.self) { contentTop = $0 }
            .onPreferenceChange(VisibleBandKey.self) { band = $0 }
            // 触发：可视区或钉底栏上沿变化、键盘弹起、键盘已在时换到本输入框，以及键盘弹起动画结束（系统把聚焦框滚进
            // 可视区的动画也在此前结束，r4：320 档系统滚动盖掉了先前那次）。只做判断，够了不滚；输入途中不触发。
            .onChange(of: band) { _ in bringIntoView() }
            .onChange(of: barTop) { _ in bringIntoView() }
            .onChange(of: active) { _ in bringIntoView() }
            .onChange(of: keyboardUp) { _ in bringIntoView() }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
                if topBeforeKeyboard == nil, let band, let contentTop {
                    topBeforeKeyboard = contentTop >= band.top - 1
                }
                keyboardUp = true
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardDidShowNotification)) { _ in
                bringIntoView()
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
                keyboardUp = false
                restoreTop()
            }
    }

    private func bringIntoView() {
        guard active, keyboardUp, let band, let primary else { return }
        let bottom = min(band.bottom, barTop ?? band.bottom)
        let fits = primary.minY >= band.top && primary.maxY <= bottom - KeyboardPrimary.margin
        guard !fits else { return }
        withAnimation { proxy.scrollTo(target, anchor: .bottom) }
    }

    private func restoreTop() {
        defer { topBeforeKeyboard = nil }
        guard topBeforeKeyboard == true, let band, let contentTop, contentTop < band.top - 1 else { return }
        withAnimation { proxy.scrollTo(top, anchor: .top) }
    }
}
