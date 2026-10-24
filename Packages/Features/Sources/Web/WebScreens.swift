import BridgeHost
import DesignSystem
import Generated
import SwiftUI
import WebKit

/// 把容器的 WKWebView 放进 SwiftUI。WebView 只由两个容器封装创建（CSB-03），这里只承载。
struct WebViewHost: UIViewRepresentable {
    let webView: WKWebView

    func makeUIView(context _: Context) -> WKWebView {
        webView
    }

    func updateUIView(_: WKWebView, context _: Context) {}
}

/// 返回按钮的读屏名称。TODO(N-21)：文案字典还没有通用「返回」键，先用英文占位。
private let backLabel = "Back"

private func text(_ key: String) -> String {
    DefaultTexts.text(key) ?? ""
}

/// 原生错误页（BR-TEXT-14 external_page.load_failed +【重试】【关闭】；不显示系统错误页，也不显示出错的 URL）。
struct WebErrorView: View {
    let onRetry: () -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: CouliSpacing.s4) {
            Text(verbatim: text("external_page.load_failed"))
                .couliFont(.body)
                .foregroundColor(CouliColor.textPrimary)
                .multilineTextAlignment(.center)
                .accessibilityIdentifier("web.error.message")
            HStack(spacing: CouliSpacing.s4) {
                Button(action: onRetry) {
                    Text(verbatim: text("external_page.retry"))
                        .frame(minWidth: CouliHitTarget.minimum, minHeight: CouliHitTarget.minimum)
                }
                .accessibilityIdentifier("web.error.retry")
                Button(action: onClose) {
                    Text(verbatim: text("external_page.close"))
                        .frame(minWidth: CouliHitTarget.minimum, minHeight: CouliHitTarget.minimum)
                }
                .accessibilityIdentifier("web.error.close")
            }
        }
        .padding(CouliSpacing.s6)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(CouliColor.backgroundCanvas.ignoresSafeArea())
    }
}

/// WebPage（可信容器）页面：原生标题栏（03 §8.3）+ WebView + 桥的界面能力（toast、loading、ui.setNavBar 的全部样式）。
public struct TrustedWebScreen: View {
    @ObservedObject private var controller: TrustedWebController
    @State private var toastMessage: CouliToastMessage?

    public init(controller: TrustedWebController) {
        self.controller = controller
    }

    public var body: some View {
        let style = controller.navStyle
        // WebView 始终在同一个组合位置（VStack 的第二项）：切换 immersive 只改布局与覆盖层，不重建承载 WebView 的视图
        // （三端共性第 36 条）。沉浸式时页面延伸到标题栏与状态栏下面，标题栏作为覆盖层浮在页面上（背景只用页面给的，缺省透明）。
        VStack(spacing: 0) {
            if !style.immersive {
                navBar(style, defaultBackground: true)
            }
            content
                .ignoresSafeArea(.container, edges: style.immersive ? .top : [])
        }
        .overlay(alignment: .top) {
            if style.immersive {
                navBar(style, defaultBackground: false)
            }
        }
        .ignoresSafeArea(.container, edges: style.hideBottomSafeArea ? .bottom : [])
        .couliToast($toastMessage)
        .onChange(of: controller.toast) { value in
            toastMessage = value.map(CouliToastMessage.init)
        }
        .toolbar(.hidden, for: .navigationBar)
        .navigationBarBackButtonHidden(true)
        .onAppear {
            controller.pageVisible(true)
        }
        .onDisappear {
            controller.pageVisible(false)
        }
    }

    @ViewBuilder private func navBar(_ style: TrustedNavStyle, defaultBackground: Bool) -> some View {
        if controller.navBarVisible {
            let foreground = style.text.map(Color.init(bridge:)) ?? CouliColor.textPrimary
            NavBar(
                title: controller.navTitle ?? "", backLabel: backLabel, foreground: foreground,
                onBack: controller.goBack
            ) {
                if !controller.hideClose {
                    Button(action: controller.close) {
                        Text(verbatim: text("external_page.close"))
                            .couliFont(.footnote)
                            .foregroundColor(foreground)
                    }
                    .accessibilityIdentifier("web.trusted.close")
                }
            }
            .background(NavBackground(style: style, fallback: defaultBackground).ignoresSafeArea(edges: .top))
        }
    }

    private var content: some View {
        ZStack {
            // 切号恢复时容器换了新的 WKWebView（F-X-25）：按它的身份重建承载视图。
            WebViewHost(webView: controller.webView)
                .id(ObjectIdentifier(controller.webView))
                .accessibilityIdentifier("web.trusted.webview")
            if controller.loadFailed {
                WebErrorView(onRetry: controller.retry, onClose: controller.close)
            }
            if controller.isLoadingOverlay {
                VStack(spacing: CouliSpacing.s2) {
                    ProgressView()
                    if let loading = controller.loadingText {
                        Text(verbatim: loading)
                            .couliFont(.footnote)
                            .foregroundColor(CouliColor.textSecondary)
                    }
                }
                .padding(CouliSpacing.s4)
                .background(CouliColor.backgroundSurface.opacity(0.95))
                .accessibilityIdentifier("web.trusted.loading")
            }
        }
    }
}

/// 标题栏背景：图片 > 渐变 > 纯色；都没有时用设计稿的表面色（沉浸式下为透明）。
private struct NavBackground: View {
    let style: TrustedNavStyle
    let fallback: Bool

    var body: some View {
        ZStack {
            if let colors = style.gradient, colors.count >= 2 {
                LinearGradient(colors: colors.map(Color.init(bridge:)), startPoint: .leading, endPoint: .trailing)
            } else if let color = style.background {
                Color(bridge: color)
            } else if fallback {
                CouliColor.backgroundSurface
            } else {
                Color.clear
            }
            if let image = style.image {
                AsyncImage(url: image) { picture in
                    picture.resizable().scaledToFill()
                } placeholder: {
                    Color.clear
                }
                .clipped()
            }
        }
    }
}

extension Color {
    init(bridge color: BridgeColor) {
        self.init(.sRGB, red: color.red, green: color.green, blue: color.blue, opacity: color.alpha)
    }
}

/// ExternalPage 标题栏配色（路由参数 nav_style，缺省 light；03 §5.1）。不能隐藏标题栏、主机名、返回与关闭按钮。
public enum ExternalNavStyle: String, Sendable {
    case light
    case dark

    var background: Color {
        self == .dark ? CouliColor.textPrimary : CouliColor.backgroundSurface
    }

    var foreground: Color {
        self == .dark ? CouliColor.textInverse : CouliColor.textPrimary
    }

    var secondary: Color {
        self == .dark ? CouliColor.textInverse.opacity(0.8) : CouliColor.textSecondary
    }
}

/// ExternalPage（第三方页容器）页面：标题栏固定显示当前主框架页面的主机名，主机名下方是路由参数 title 的副标题（不能代替
/// 主机名），左侧返回、右侧【关闭】，配色按 nav_style；拦下时在容器内出提示层，原页面不动（03 §5.1）。
/// 页面里的视频进入全屏时隐藏原生标题栏、WebView 铺满窗口，退出全屏后恢复（三端共性第 25 条）。
public struct ExternalWebScreen: View {
    @ObservedObject private var controller: ExternalWebController
    let subtitle: String?
    let navStyle: ExternalNavStyle

    public init(controller: ExternalWebController, subtitle: String?, navStyle: ExternalNavStyle = .light) {
        self.controller = controller
        self.subtitle = subtitle
        self.navStyle = navStyle
    }

    public var body: some View {
        VStack(spacing: 0) {
            if !controller.isFullscreen {
                VStack(spacing: 0) {
                    NavBar(
                        title: controller.host ?? "", backLabel: backLabel, foreground: navStyle.foreground,
                        onBack: controller.goBack
                    ) {
                        Button(action: controller.close) {
                            Text(verbatim: text("external_page.close"))
                                .couliFont(.footnote)
                                .foregroundColor(navStyle.foreground)
                        }
                        .accessibilityIdentifier("web.external.close")
                    }
                    if let subtitle, !subtitle.isEmpty {
                        Text(verbatim: subtitle)
                            .couliFont(.caption)
                            .foregroundColor(navStyle.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.bottom, CouliSpacing.s1)
                            .accessibilityIdentifier("web.external.subtitle")
                    }
                }
                .background(navStyle.background.ignoresSafeArea(edges: .top))
                .accessibilityIdentifier("web.external.navbar")
            }
            ZStack(alignment: .bottom) {
                WebViewHost(webView: controller.webView)
                    .accessibilityIdentifier("web.external.webview")
                if controller.loadFailed || controller.unavailable {
                    WebErrorView(onRetry: controller.retry, onClose: controller.close)
                }
                if let notice = controller.notice, !controller.isFullscreen {
                    noticeView(notice)
                }
            }
        }
        .ignoresSafeArea(.container, edges: controller.isFullscreen ? .all : [])
        .statusBarHidden(controller.isFullscreen)
        .toolbar(.hidden, for: .navigationBar)
        .navigationBarBackButtonHidden(true)
    }

    private func noticeView(_ notice: ExternalWebNotice) -> some View {
        HStack(spacing: CouliSpacing.s3) {
            Text(verbatim: text(notice.textKey))
                .couliFont(.footnote)
                .foregroundColor(CouliColor.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("web.external.notice")
            if notice == .blocked {
                Button(action: controller.goSearch) {
                    Text(verbatim: controller.searchLabel)
                        .couliFont(.footnote)
                        .frame(minWidth: CouliHitTarget.minimum, minHeight: CouliHitTarget.minimum)
                }
                .accessibilityIdentifier("web.external.search")
            }
            Button(action: controller.dismissNotice) {
                Text(verbatim: text("external_page.close"))
                    .couliFont(.footnote)
                    .frame(minWidth: CouliHitTarget.minimum, minHeight: CouliHitTarget.minimum)
            }
        }
        .padding(CouliSpacing.s4)
        .background(CouliColor.backgroundSurface)
    }
}
