import DesignSystem
import SwiftUI
import UIKit

/// 键盘弹起时主按钮钉到键盘上方、正在输入的框不被底栏挡住（FU-LOGIN-KEYBOARD-AVOID-ios，D10-2458；视觉验收 §2.4）。
/// 登录页（手机号步、验证码步）与绑手机页共用：`keyboardPinState` 判断是否钉底，`keyboardInputScroll` 只在底栏出现或
/// 尺寸变化后、输入框被挡时把它滚到栏上沿以上。主按钮本身不滚动（r5：320 + AXXXL 下滚动方案物理上放不下）。
enum KeyboardPrimary {
    /// 余量：登录钉底栏按钮下沿到键盘顶、输入框下沿到栏上沿都留 16pt（≥ 12，给取整留余地；review-r1 S3）。
    static let margin: CGFloat = CouliSpacing.s4
}

extension View {
    /// 维护「是否钉底」= 软键盘弹起（keyboardWillShow / keyboardWillHide）且读屏未开启（进页读一次，之后
    /// voiceOverStatusDidChange 实时更新；读屏开启时不钉底，保持原读屏顺序，review-r1 S2-2）。
    func keyboardPinState(_ pinned: Binding<Bool>) -> some View {
        modifier(KeyboardPinState(pinned: pinned))
    }

    /// 登录页钉底栏外观（留白、限宽、底色照绑手机页 bottomBar；底部留白 16pt），并上报栏的实测上沿。
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

    /// 输入框的滚动锚点与位置上报：透明、不占布局（放在 background 里），键盘收起时布局不变。锚点用负的底部留白向下
    /// 伸出 16pt，`scrollTo(.bottom)` 后输入框下沿离可视区底边 16pt。
    func keyboardInputAnchor(_ id: String) -> some View {
        background(alignment: .top) {
            GeometryReader { geo in
                Color.clear.preference(key: InputFrameKey.self, value: geo.frame(in: .global))
            }
            .accessibilityHidden(true)
        }
        .background(alignment: .top) {
            Color.clear
                .id(id)
                .padding(.bottom, -KeyboardPrimary.margin)
                .accessibilityHidden(true)
        }
    }

    /// 滚动内容顶部锚点与位置上报（挂在内容最外层；不占布局）：登录页键盘收起时滚回这里。
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

    /// 输入框按需滚动（挂在 ScrollView 上）：`active`（钉底期间且该输入框聚焦）时，在底栏出现或尺寸变化、可视区变化、
    /// 键盘弹起动画结束后检查一次；输入框已整块在可视区内、下沿离「栏上沿 `barTop` 与可视区底边较高者」≥ 16pt 就不滚，
    /// 否则滚到锚点。按键不触发。`top` 非空时，键盘收起若弹起前内容在顶部而现在不在，滚回顶部锚点。
    func keyboardInputScroll(
        _ proxy: ScrollViewProxy, target: String, top: String?, active: Bool, barTop: CGFloat?
    ) -> some View {
        modifier(KeyboardInputScroll(proxy: proxy, target: target, top: top, active: active, barTop: barTop))
    }
}

struct KeyboardBarTopKey: PreferenceKey {
    static let defaultValue: CGFloat? = nil
    static func reduce(value: inout CGFloat?, nextValue: () -> CGFloat?) {
        value = value ?? nextValue()
    }
}

private struct KeyboardPinState: ViewModifier {
    @Binding var pinned: Bool
    @State private var keyboardUp = false
    @State private var voiceOver = false

    func body(content: Content) -> some View {
        content
            .onAppear {
                voiceOver = UIAccessibility.isVoiceOverRunning
                update()
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
                keyboardUp = true
                update()
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
                keyboardUp = false
                update()
            }
            .onReceive(NotificationCenter.default.publisher(
                for: UIAccessibility.voiceOverStatusDidChangeNotification
            )) { _ in
                voiceOver = UIAccessibility.isVoiceOverRunning
                update()
            }
    }

    private func update() {
        pinned = keyboardUp && !voiceOver
    }
}

/// 可视区在全局坐标里的上下沿（扣掉安全区：键盘、safeAreaInset）。
private struct VisibleBand: Equatable {
    var top: CGFloat
    var bottom: CGFloat
}

private struct InputFrameKey: PreferenceKey {
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

private struct KeyboardInputScroll: ViewModifier {
    let proxy: ScrollViewProxy
    let target: String
    let top: String?
    let active: Bool
    let barTop: CGFloat?
    @State private var band: VisibleBand?
    @State private var input: CGRect?
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
            .onPreferenceChange(InputFrameKey.self) { input = $0 }
            .onPreferenceChange(ContentTopKey.self) { contentTop = $0 }
            .onPreferenceChange(VisibleBandKey.self) { band = $0 }
            // 触发：底栏出现 / 尺寸变化（栏上沿）、可视区变化、开始钉底，以及键盘弹起动画结束（系统把聚焦框滚进可视区的
            // 动画也在此前结束）。只做判断，够了不滚；输入途中不触发。
            .onChange(of: barTop) { _ in bringIntoView() }
            .onChange(of: band) { _ in bringIntoView() }
            .onChange(of: active) { _ in bringIntoView() }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
                if topBeforeKeyboard == nil, let band, let contentTop {
                    topBeforeKeyboard = contentTop >= band.top - 1
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardDidShowNotification)) { _ in
                bringIntoView()
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
                restoreTop()
            }
    }

    private func bringIntoView() {
        guard active, let band, let input else { return }
        let bottom = min(band.bottom, barTop ?? band.bottom)
        let fits = input.minY >= band.top && input.maxY <= bottom - KeyboardPrimary.margin
        guard !fits else { return }
        withAnimation { proxy.scrollTo(target, anchor: .bottom) }
    }

    private func restoreTop() {
        defer { topBeforeKeyboard = nil }
        guard let top, topBeforeKeyboard == true, let band, let contentTop, contentTop < band.top - 1 else { return }
        withAnimation { proxy.scrollTo(top, anchor: .top) }
    }
}
