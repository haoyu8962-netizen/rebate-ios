import BridgeHost
import Combine
import Foundation
import UIKit
import WebKit

/// TrustedWebView（可信容器，03 §5.1、§5.2）：只加载可信源（BridgeHost 的白名单：bridge_origins；Debug 构建另加的本机一致性
/// 测试源由 App 的调试源码注入），注入桥启动脚本与传输通道，origin 与框架检查在原生。
///
/// - 传输层：`WKScriptMessageHandlerWithReply`（`window.webkit.messageHandlers.rebate.postMessage` 返回 Promise）；
///   每条消息的 origin 取 `WKScriptMessage.frameInfo.securityOrigin`，是否主框架取 `frameInfo.isMainFrame`——都是 WebKit 给出的
///   真实框架身份，不按 URL 比较（APP-04 三端共性第 1 条）；同地址子框架、sandbox 子框架、跨源子框架一律 90403。
/// - 导航：主框架（含新窗口请求）只放行可信源；白名单外的 https 交 `onOpenExternal`（Router 打开新的 ExternalWebView，原容器不变），
///   其余 scheme 一律取消。子框架见 `allowsSubframe`（指向可信源的子框架不加载）。授权页一律不进容器。下载一律取消。
/// - 证书错误一律取消并显示原生错误页（CSB-02）；客户端证书、HTTP 认证一律取消。
/// - UA 只追加 ` Couli/<版本号>`；页面里的 http / ws 子资源不加载（CSB-03；只有 Debug 本机一致性页本身是 http，那时不装此规则）。
/// - 用户手势：原生点击识别（`WebTapRecorder`）；主框架开始新导航、提交新文档时清除手势，并作废在途桥调用（三端共性第 4、5 条）。
@MainActor
public final class TrustedWebController: NSObject, ObservableObject {
    @Published public private(set) var navTitle: String?
    @Published public private(set) var navBarVisible = true
    @Published public private(set) var hideClose = false
    /// ui.setNavBar 的样式（三端共性第 23 条）：背景（纯色 / 渐变 / 图片）、文字颜色、沉浸式、底部安全区。
    @Published public private(set) var navStyle = TrustedNavStyle()
    @Published public private(set) var toast: String?
    @Published public private(set) var loadingText: String?
    @Published public private(set) var isLoadingOverlay = false
    @Published public private(set) var loadFailed = false
    @Published public private(set) var canGoBack = false

    public let webView: WKWebView
    public private(set) var host: BridgeHost?
    private var initialURL: URL?
    private var started = false
    private let onOpenExternal: @MainActor (URL) -> Void
    private let onClose: @MainActor () -> Void
    /// 原生点击识别（传输层取手势资格）。
    let tap = WebTapRecorder()
    private var scriptHandler: WeakScriptHandler?
    /// 声明给 H5 的方法列表的同步（令牌、版本、文档身份；F-X-24）。
    var methodsSync = DeclaredMethodsSync(methods: [])
    private var declaredSubscription: AnyCancellable?
    private var toastTask: Task<Void, Never>?
    /// 被取消的子框架文档导航次数（诊断与测试用：证明同源子框架确实没有载入）。
    private(set) var blockedSubframeCount = 0

    /// H5 路由的地址来源（APP-08 共性第 22、29 条）：首次加载与首次未加载成后的【重试】都重新取（读生效配置、生成地址）。
    public var urlProvider: (@MainActor () -> URL?)?

    /// - Parameters:
    ///   - url: 要打开的地址（Router 已按 bridge_origins 放行；容器加载前再判一次）。
    ///   - hostFactory: 用本容器作界面能力创建 BridgeHost（App 接业务能力、调用方状态与可信源）。
    ///   - onOpenExternal: 主框架跳到白名单外的 https 地址时调用（Router 打开 ExternalPage）。
    ///   - declaredMethodsChanges: 声明的方法列表可能变化时发一次（生效配置更新，F-X-24 方法远程禁用），在主线程上发；
    ///     收到后按宿主此刻的 `declaredMethods` 更新已加载页面与之后新文档的列表（`refreshDeclaredMethods`）。
    public init(
        url: URL?,
        appVersion: String,
        hostFactory: @MainActor (any BridgeUI) -> BridgeHost,
        onOpenExternal: @escaping @MainActor (URL) -> Void,
        onClose: @escaping @MainActor () -> Void,
        declaredMethodsChanges: AnyPublisher<Void, Never>? = nil
    ) {
        initialURL = url
        self.onOpenExternal = onOpenExternal
        self.onClose = onClose
        let configuration = WKWebViewConfiguration()
        WebContainerSupport.applyCommonSettings(configuration)
        WebContainerSupport.applyUserAgent(configuration, appVersion: appVersion)
        configuration.websiteDataStore = .default()
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        let host = hostFactory(self)
        self.host = host
        methodsSync = DeclaredMethodsSync(methods: host.declaredMethods)
        configuration.userContentController.addUserScript(methodsSync.userScript(bridgeVersion: host.bridgeVersion))
        let handler = WeakScriptHandler(self)
        scriptHandler = handler
        configuration.userContentController.addScriptMessageHandler(
            handler, contentWorld: .page, name: BridgeBootstrapScript.handlerName
        )
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsLinkPreview = false
        tap.attach(to: webView)
        observeAppLifecycle()
        declaredSubscription = declaredMethodsChanges?.sink { [weak self] in
            MainActor.assumeIsolated {
                self?.refreshDeclaredMethods()
            }
        }
    }

    /// 容器离开界面（销毁）时调用：作废并拒收之后的桥调用，摘掉传输通道。
    public func teardown() {
        declaredSubscription = nil
        host?.dispose()
        webView.stopLoading()
        webView.configuration.userContentController.removeAllScriptMessageHandlers()
    }

    /// 开始加载初始地址：不是可信源的不加载（显示错误页）；https 页面先装好「只放行 https 子资源」的规则再加载。
    public func start() {
        guard !started else { return }
        started = true
        initialURL = urlProvider?() ?? initialURL
        guard let url = initialURL, isTrustedDocument(url), !AuthPages.isAuthPage(url.absoluteString) else {
            loadFailed = true
            return
        }
        guard url.scheme?.lowercased() == "https" else {
            // 只有 Debug 构建注入的本机一致性测试源会走到这里（http 本机源本身就是 http 页面）。
            webView.load(URLRequest(url: url))
            return
        }
        WebContainerSupport.httpsOnlyRules { [weak self] rules in
            guard let self else { return }
            guard let rules else {
                loadFailed = true
                return
            }
            webView.configuration.userContentController.add(rules)
            webView.load(URLRequest(url: url))
        }
    }

    public func retry() {
        loadFailed = false
        if webView.url == nil {
            started = false
            start()
        } else {
            webView.reload()
        }
    }

    /// 返回：页面有历史时先后退网页，没有历史才关闭容器（APP-04 三端共性第 11 条）。
    public func goBack() {
        if webView.canGoBack {
            webView.goBack()
        } else {
            close()
        }
    }

    /// 页面可见性变化：下发 page.visible。离开界面（被其他页面盖住、切走）时清除手势资格（三端共性第 5 条）。
    public func pageVisible(_ visible: Bool) {
        if !visible {
            tap.reset()
        }
        sendEvent(name: "page.visible", data: ["visible": visible])
    }

    /// 原生 → H5 事件：只下发契约 events 白名单里的事件，只发给主框架、且主框架当前是可信源。
    public func sendEvent(name: String, data: [String: Any] = [:]) {
        guard let body = BridgeProtocol.event(name: name, data: data),
              let url = webView.url, isTrustedDocument(url),
              let literal = Self.jsStringLiteral(body)
        else { return }
        let receive = BridgeBootstrapScript.receiveFunction
        webView.evaluateJavaScript(
            "window.\(receive) && window.\(receive)(\(literal));", in: nil, in: .page
        ) { _ in }
    }

    /// 子框架文档能不能加载（编排者三端裁定「同源子框架」，三端共性第 13 条）：
    /// - 指向可信 bridge origin 的子框架一律不加载——同源、未加 sandbox 的子框架能经 `parent.eval` 以主框架身份调用桥，
    ///   原生（frameInfo.isMainFrame）分不出来，所以不让它载入独立内容；
    /// - about:blank、about:srcdoc 的内容由父页面写入，与主页面同一主体，放行（它们直接调用传输通道时 isMainFrame 为假，仍 90403）；
    /// - 其他 https 子框架（跨源）放行加载，但调用桥一律 90403；非 https 一律不加载。
    public static func allowsSubframe(_ url: URL, isTrustedOrigin: Bool) -> Bool {
        if WebContainerSupport.isBlankDocument(url) {
            return true
        }
        if isTrustedOrigin {
            return false
        }
        return url.scheme?.lowercased() == "https"
    }

    func isTrustedDocument(_ url: URL) -> Bool {
        guard let origin = WebContainerSupport.origin(of: url) else { return false }
        return host?.acceptsOrigin(origin) ?? false
    }

    /// 回到前台 / 进入后台：下发 app.resume / app.pause（data 为空对象）。选择器式观察者随本对象释放自动摘除。
    private func observeAppLifecycle() {
        let center = NotificationCenter.default
        center.addObserver(
            self, selector: #selector(appWillEnterForeground), name: UIApplication.willEnterForegroundNotification,
            object: nil
        )
        center.addObserver(
            self, selector: #selector(appDidEnterBackground), name: UIApplication.didEnterBackgroundNotification,
            object: nil
        )
    }

    @objc private func appWillEnterForeground() {
        sendEvent(name: "app.resume")
    }

    @objc private func appDidEnterBackground() {
        tap.reset()
        sendEvent(name: "app.pause")
    }

    private static func jsStringLiteral(_ text: String) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: text, options: [.fragmentsAllowed]) else {
            return nil
        }
        return String(bytes: data, encoding: .utf8)
    }

    /// 主框架开始导航或换了文档：清除手势资格，作废在途桥调用（结果不交回新页面）。
    private func mainFrameChanged() {
        tap.reset()
        host?.invalidate()
        canGoBack = webView.canGoBack
    }
}

// MARK: - BridgeUI

extension TrustedWebController: BridgeUI {
    public func toast(text: String, long: Bool) {
        toast = text
        toastTask?.cancel()
        toastTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: long ? 3_500_000_000 : 2_000_000_000)
            guard !Task.isCancelled else { return }
            self?.toast = nil
        }
    }

    public func showLoading(text: String?) {
        loadingText = text
        isLoadingOverlay = true
    }

    public func hideLoading() {
        isLoadingOverlay = false
        loadingText = nil
    }

    /// 全部字段都生效才返回 true。status_bar_style=light（浅色状态栏文字）本端做不到：App 固定浅色界面，SwiftUI 宿主的状态栏
    /// 样式不能按页面改（capability-ios.md）；这时整次调用什么都不改、返回 false（宿主回 90001）。dark 就是本端状态栏的现状。
    public func setNavBar(_ bar: BridgeNavBar) -> Bool {
        if let style = bar.statusBarStyle, style != TrustedNavStyle.statusBarDark {
            return false
        }
        if let visible = bar.visible {
            navBarVisible = visible
        }
        if let title = bar.title {
            navTitle = title
        }
        if let hide = bar.hideClose {
            hideClose = hide
        }
        if let bounce = bar.bounce {
            webView.scrollView.bounces = bounce
            webView.scrollView.alwaysBounceVertical = bounce
        }
        navStyle = navStyle.applying(bar)
        return true
    }

    /// 关闭容器。来自 nav.close 时，先让这次调用把成功响应交回页面（结算在本轮主线程任务里完成），下一轮再作废其余在途调用并关闭。
    public func close() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            host?.invalidate()
            onClose()
        }
    }
}

// MARK: - 导航

extension TrustedWebController: WKNavigationDelegate, WKUIDelegate {
    public func webView(
        _ webView: WKWebView,
        decidePolicyFor action: WKNavigationAction,
        decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
    ) {
        guard !action.shouldPerformDownload, let url = action.request.url else {
            decisionHandler(.cancel)
            return
        }
        let isNewWindow = action.targetFrame == nil
        let isMainFrame = action.targetFrame?.isMainFrame ?? true
        // 授权与登录页不进容器（03 §5.1；三端共性第 16 条）：初始地址与每一次文档导航（含子框架）都查，不转交第三方页容器。
        if !WebContainerSupport.isBlankDocument(url), AuthPages.isAuthPage(url.absoluteString) {
            decisionHandler(.cancel)
            return
        }
        if !isMainFrame {
            // 子框架按目标地址的 origin 判（编排者裁定：非主框架且目标属于可信 origin → .cancel）。调用桥时的框架身份另由
            // WKScriptMessage.frameInfo 判，不靠这里。
            let allowed = Self.allowsSubframe(url, isTrustedOrigin: isTrustedDocument(url))
            if !allowed {
                blockedSubframeCount += 1
            }
            decisionHandler(allowed ? .allow : .cancel)
            return
        }
        if isTrustedDocument(url) {
            if isNewWindow {
                // 新窗口请求在当前容器里打开（不另开窗口）。
                decisionHandler(.cancel)
                webView.load(action.request)
            } else {
                decisionHandler(.allow)
            }
            return
        }
        decisionHandler(.cancel)
        if url.scheme?.lowercased() == "https" {
            onOpenExternal(url)
        }
    }

    public func webView(
        _: WKWebView,
        decidePolicyFor response: WKNavigationResponse,
        decisionHandler: @escaping @MainActor @Sendable (WKNavigationResponsePolicy) -> Void
    ) {
        decisionHandler(WebContainerSupport.isDownload(response) ? .cancel : .allow)
    }

    public func webView(
        _: WKWebView,
        respondTo challenge: URLAuthenticationChallenge
    ) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        (WebContainerSupport.disposition(for: challenge), nil)
    }

    /// 主框架开始导航（WKNavigationDelegate 的这个回调只报主框架，不含同文档内的片段 / history 跳转）：立即作废旧页面的
    /// 在途桥调用，不等新文档提交——新页面加载很慢或失败时，旧调用也不能再发请求或继续权限流程（三端共性第 29 条）。
    /// 提交新文档时（didCommit）再作废一次，保持新旧文档隔离。
    public func webView(_: WKWebView, didStartProvisionalNavigation _: WKNavigation!) {
        methodsSync.navigationStarted()
        loadFailed = false
        tap.reset()
        host?.invalidate()
    }

    /// 提交新文档（含前进后退从页面缓存恢复）、加载完成：按当前版本补同步方法列表（F-X-24）。
    public func webView(_: WKWebView, didCommit _: WKNavigation!) {
        mainFrameChanged()
        methodsSync.documentCommitted()
        pushDeclaredMethods()
    }

    public func webView(_: WKWebView, didFinish _: WKNavigation!) {
        canGoBack = webView.canGoBack
        pushDeclaredMethods()
    }

    public func webView(_: WKWebView, didFailProvisionalNavigation _: WKNavigation!, withError error: Error) {
        methodsSync.navigationEnded()
        if !WebContainerSupport.isCancellation(error) {
            loadFailed = true
        }
    }

    public func webView(_: WKWebView, didFail _: WKNavigation!, withError error: Error) {
        if !WebContainerSupport.isCancellation(error) {
            loadFailed = true
        }
    }

    public func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        mainFrameChanged()
        webView.reload()
    }

    public func webView(
        _: WKWebView,
        createWebViewWith _: WKWebViewConfiguration,
        for _: WKNavigationAction,
        windowFeatures _: WKWindowFeatures
    ) -> WKWebView? {
        // 新窗口请求已在 decidePolicyFor（targetFrame == nil）里按主框架判定，这里不创建新 WebView。
        nil
    }
}
