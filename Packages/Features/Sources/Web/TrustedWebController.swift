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
/// - 数据存储：可信容器专用的独立 store（`TrustedWebDataStore`，不是 default，也不是外部容器的 store；F-X-25 I6）。
/// - 切号（F-X-25，`TrustedWebAuthCoordinator`）：隔离期间（`isAuthIsolated`）桥调用一律 90500、不补发方法列表与事件（受控的
///   auth.changed 除外）、导航与加载一律取消、开始加载 / 重试都不加载；清理成功后换一个新的 WKWebView（新宿主、新令牌、
///   新浏览上下文）重新加载当前入口，旧 WebView 退役。
@MainActor
public final class TrustedWebController: NSObject, ObservableObject {
    @Published public internal(set) var navTitle: String?
    @Published public internal(set) var navBarVisible = true
    @Published public internal(set) var hideClose = false
    /// ui.setNavBar 的样式（三端共性第 23 条）：背景（纯色 / 渐变 / 图片）、文字颜色、沉浸式、底部安全区。
    @Published public internal(set) var navStyle = TrustedNavStyle()
    @Published public internal(set) var toast: String?
    @Published public internal(set) var loadingText: String?
    @Published public internal(set) var isLoadingOverlay = false
    @Published public internal(set) var loadFailed = false
    @Published public internal(set) var canGoBack = false
    /// 切号隔离中（F-X-25 I1）：只读，界面与测试观察用。
    @Published public internal(set) var isAuthIsolated = false

    /// 当前承载页面的 WKWebView。切号恢复时整体换新（旧的退役），界面按它的身份重建承载视图。
    @Published public internal(set) var webView: WKWebView
    public private(set) var host: BridgeHost?
    private var initialURL: URL?
    var started = false
    let appVersion: String
    /// 当前的可信 store（切号后换新，评审 r2 S0-R2-01；新 WebView 一律建在它上面）。
    var dataStore: WKWebsiteDataStore {
        auth?.currentStore ?? TrustedWebDataStore.current
    }

    private let hostFactory: @MainActor (any BridgeUI) -> BridgeHost
    let auth: TrustedWebAuthCoordinator?
    let onOpenExternal: @MainActor (URL) -> Void
    let onClose: @MainActor () -> Void
    /// 已 teardown（不再登记切号、不再投递）。
    private(set) var isTornDown = false
    /// 当前 WebView 发起过加载（有过文档或在途导航；退役时据此决定要不要换新 WebView）。
    var loadIssued = false
    /// 当前 WebView 的主框架文档编号（每次提交 +1；0 = 还没有文档）与提交时的地址（切号恢复时重新加载的「当前入口」）。
    var documentSerial = 0
    var committedURL: URL?
    /// 切号隔离时记下的恢复地址（隔离那一刻已提交文档的地址；没有文档为 nil）。
    var restoreURL: URL?
    /// 隔离后、恢复前要换新 WebView（隔离已 dispose 当前宿主）。
    var needsFreshView = false
    /// 切号恢复的加载已发出、新文档还没提交（`whenAuthSettled` 等它）。
    var awaitingAuthCommit = false
    /// 原生点击识别（传输层取手势资格）。
    let tap = WebTapRecorder()
    private var scriptHandler: WeakScriptHandler?
    /// 声明给 H5 的方法列表的同步（令牌、版本、文档身份；F-X-24）。
    var methodsSync = DeclaredMethodsSync(methods: [])
    private var declaredSubscription: AnyCancellable?
    var toastTask: Task<Void, Never>?
    /// 被取消的子框架文档导航次数（诊断与测试用：证明同源子框架确实没有载入）。
    var blockedSubframeCount = 0

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
        hostFactory: @escaping @MainActor (any BridgeUI) -> BridgeHost,
        onOpenExternal: @escaping @MainActor (URL) -> Void,
        onClose: @escaping @MainActor () -> Void,
        declaredMethodsChanges: AnyPublisher<Void, Never>? = nil,
        auth: TrustedWebAuthCoordinator? = nil
    ) {
        initialURL = url
        self.appVersion = appVersion
        self.hostFactory = hostFactory
        self.auth = auth
        self.onOpenExternal = onOpenExternal
        self.onClose = onClose
        webView = Self.makeWebView(
            appVersion: appVersion, dataStore: auth?.currentStore ?? TrustedWebDataStore.current
        )
        super.init()
        bind(webView)
        observeAppLifecycle()
        declaredSubscription = declaredMethodsChanges?.sink { [weak self] in
            MainActor.assumeIsolated {
                self?.refreshDeclaredMethods()
            }
        }
        auth?.dependencies.configureWebView(webView)
        auth?.register(self)
    }

    /// 新建一个可信 WKWebView（共同设置、UA、可信专用数据存储）。只建不装桥。
    static func makeWebView(appVersion: String, dataStore: WKWebsiteDataStore) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        WebContainerSupport.applyCommonSettings(configuration)
        WebContainerSupport.applyUserAgent(configuration, appVersion: appVersion)
        configuration.websiteDataStore = dataStore
        return WKWebView(frame: .zero, configuration: configuration)
    }

    /// 给 WebView 装上新宿主（新世代的桥绑定）、新的方法列表令牌与启动脚本、传输通道、导航代理与手势识别。
    func bind(_ view: WKWebView) {
        let host = hostFactory(self)
        self.host = host
        methodsSync = DeclaredMethodsSync(methods: host.declaredMethods)
        let content = view.configuration.userContentController
        content.addUserScript(methodsSync.userScript(bridgeVersion: host.bridgeVersion))
        let handler = WeakScriptHandler(self)
        scriptHandler = handler
        content.addScriptMessageHandler(handler, contentWorld: .page, name: BridgeBootstrapScript.handlerName)
        view.navigationDelegate = self
        view.uiDelegate = self
        view.allowsBackForwardNavigationGestures = true
        view.allowsLinkPreview = false
        tap.attach(to: view)
    }

    /// 容器离开界面（销毁）时调用：作废并拒收之后的桥调用，摘掉传输通道。
    public func teardown() {
        isTornDown = true
        awaitingAuthCommit = false
        declaredSubscription = nil
        host?.dispose()
        webView.stopLoading()
        webView.configuration.userContentController.removeAllScriptMessageHandlers()
        // 立即退役并强持有到确认卸载（评审 r2 S1-R2-01）：界面随后释放 WebView 也不会让页面在没人等的情况下关闭；
        // 下一次切号清理的最后一遍一定在它卸载之后。不移出界面（路由出栈自行移除）。
        auth?.trackRetirement(TrustedWebRetirement.retire(webView, hadDocument: loadIssued, detach: false))
        auth?.commitSettled()
    }

    /// 开始加载初始地址：不是可信源的不加载（显示错误页）；https 页面先装好「只放行 https 子资源」的规则再加载。
    /// 切号隔离中（清理进行中或失败）只记下「要加载」，清理成功后与其他容器一并加载（F-X-25 I4）。
    public func start() {
        guard !started else { return }
        started = true
        auth?.catchUp()
        guard !isAuthIsolated else { return }
        loadInitial()
    }

    func loadInitial() {
        initialURL = urlProvider?() ?? initialURL
        guard let url = initialURL, isTrustedDocument(url), !AuthPages.isAuthPage(url.absoluteString) else {
            loadFailed = true
            return
        }
        load(url)
    }

    /// 加载一个可信地址：https 页面先装好「只放行 https 子资源」的规则再加载。
    func load(_ url: URL, onFailure: @escaping @MainActor () -> Void = {}) {
        let view = webView
        loadIssued = true
        guard url.scheme?.lowercased() == "https" else {
            // 只有 Debug 构建注入的本机一致性测试源（及测试的本机源）会走到这里（http 本机源本身就是 http 页面）。
            view.load(URLRequest(url: url))
            return
        }
        WebContainerSupport.httpsOnlyRules { [weak self] rules in
            guard let self, view === webView, !isAuthIsolated else { return }
            guard let rules else {
                loadFailed = true
                onFailure()
                return
            }
            view.configuration.userContentController.add(rules)
            view.load(URLRequest(url: url))
        }
    }

    public func retry() {
        if isAuthIsolated {
            // 切号清理失败后的【重试】：重新清理，成功时恢复全部受影响的容器（不只本页）。
            auth?.retry()
            return
        }
        loadFailed = false
        if webView.url == nil {
            started = false
            start()
        } else {
            webView.reload()
        }
    }

    /// 返回：页面有历史时先后退网页，没有历史才关闭容器（APP-04 三端共性第 11 条）。隔离中不后退（不恢复旧文档）。
    public func goBack() {
        if webView.canGoBack, !isAuthIsolated {
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

    /// 原生 → H5 事件：只下发契约 events 白名单里的事件，只发给主框架、且主框架当前是可信源。切号隔离中不下发。
    public func sendEvent(name: String, data: [String: Any] = [:]) {
        guard !isAuthIsolated, let body = BridgeProtocol.event(name: name, data: data),
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

    static func jsStringLiteral(_ text: String) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: text, options: [.fragmentsAllowed]) else {
            return nil
        }
        return String(bytes: data, encoding: .utf8)
    }

    /// 主框架开始导航或换了文档：清除手势资格，作废在途桥调用（结果不交回新页面）。
    func mainFrameChanged() {
        tap.reset()
        host?.invalidate()
        canGoBack = webView.canGoBack
    }
}
