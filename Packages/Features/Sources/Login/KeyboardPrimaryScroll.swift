import DesignSystem
import SwiftUI
import UIKit

/// 键盘弹起时主按钮整块可见可点、与键盘顶（或钉底栏上沿）余量 ≥ 12pt（FU-LOGIN-KEYBOARD-AVOID-ios，D10-2458；
/// 视觉验收 §2.4）。登录页用钉底栏，绑手机页用按需滚动。
enum KeyboardPrimary {
    /// 余量：钉底栏按钮下沿到键盘顶、滚动后按钮下沿到可视区底边都留 16pt（≥ 12，给取整留余地；review-r1 S3）。
    static let margin: CGFloat = CouliSpacing.s4
    /// 滚动可视区的坐标系名（ScrollView 自身；内容在其中的 frame 即相对可视区的位置）。
    static let space = "keyboardPrimary.viewport"
}

extension View {
    /// 钉底栏外观（留白、限宽、底色照绑手机页 bottomBar；底部留白 16pt，见 `KeyboardPrimary.margin`）。
    func keyboardPinnedBar() -> some View {
        padding(.horizontal, CouliSpacing.s4)
            .padding(.top, CouliSpacing.s3)
            .padding(.bottom, KeyboardPrimary.margin)
            .frame(maxWidth: LoginView.maxContentWidth)
            .frame(maxWidth: .infinity)
            .background(CouliColor.backgroundCanvas.ignoresSafeArea())
    }

    /// 主按钮的滚动锚点与位置上报：透明、不占布局（放在 background 里），键盘收起时布局不变。锚点用负的底部留白
    /// 向下伸出 `margin`，滚到锚点底边对齐可视区底边后，按钮下沿离可视区底边 16pt。
    func keyboardPrimaryAnchor(_ id: String) -> some View {
        background(alignment: .top) {
            GeometryReader { geo in
                Color.clear.preference(key: PrimaryFrameKey.self, value: geo.frame(in: .named(KeyboardPrimary.space)))
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

    /// 滚动内容顶部锚点与位置上报（挂在内容最外层；不占布局）：键盘收起时滚回这里。
    func keyboardContentTop(_ id: String) -> some View {
        background(alignment: .top) {
            GeometryReader { geo in
                let minY = geo.frame(in: .named(KeyboardPrimary.space)).minY
                Color.clear.preference(key: ContentTopKey.self, value: minY)
            }
            .accessibilityHidden(true)
        }
        .background(alignment: .top) {
            Color.clear.frame(height: 1).id(id).accessibilityHidden(true)
        }
    }

    /// 按需滚动（挂在 ScrollView 上，review-r1 S2-1 / S2-4）：`active`（输入框聚焦）且键盘弹起时，主按钮已整块在可视区内、
    /// 下沿离可视区底边 ≥ 16pt 就不滚；否则滚到锚点。键盘收起时，若是本修饰器滚过且滚前内容在顶部，滚回顶部锚点。
    func keyboardPrimaryScroll(_ proxy: ScrollViewProxy, target: String, top: String, active: Bool) -> some View {
        modifier(KeyboardPrimaryScroll(proxy: proxy, target: target, top: top, active: active))
    }
}

/// 可视区在 ScrollView 坐标里的上下沿（扣掉安全区：键盘、钉底栏 safeAreaInset）。
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
    @State private var keyboardUp = false
    @State private var band: VisibleBand?
    @State private var primary: CGRect?
    @State private var contentTop: CGFloat?
    /// 本修饰器滚过、且滚前内容在顶部：键盘收起时滚回顶部。
    @State private var restoresTop = false

    func body(content: Content) -> some View {
        content
            .coordinateSpace(name: KeyboardPrimary.space)
            .background {
                GeometryReader { geo in
                    Color.clear.preference(
                        key: VisibleBandKey.self,
                        value: VisibleBand(top: geo.safeAreaInsets.top,
                                           bottom: geo.size.height - geo.safeAreaInsets.bottom)
                    )
                }
                .accessibilityHidden(true)
            }
            .onPreferenceChange(PrimaryFrameKey.self) { primary = $0 }
            .onPreferenceChange(ContentTopKey.self) { contentTop = $0 }
            .onPreferenceChange(VisibleBandKey.self) { band = $0 }
            // 触发：可视区因键盘收窄 / 变化、键盘弹起、键盘已在时换到本输入框；输入途中不滚（review-r1 S1-1、S3-3）
            .onChange(of: band) { _ in bringIntoView() }
            .onChange(of: active) { _ in bringIntoView() }
            .onChange(of: keyboardUp) { _ in bringIntoView() }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
                keyboardUp = true
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
                keyboardUp = false
                guard restoresTop else { return }
                restoresTop = false
                withAnimation { proxy.scrollTo(top, anchor: .top) }
            }
    }

    private func bringIntoView() {
        guard active, keyboardUp, let band, let primary else { return }
        let fits = primary.minY >= band.top && primary.maxY <= band.bottom - KeyboardPrimary.margin
        guard !fits else { return }
        if let contentTop, contentTop >= band.top - 1 {
            restoresTop = true
        }
        withAnimation { proxy.scrollTo(target, anchor: .bottom) }
    }
}
