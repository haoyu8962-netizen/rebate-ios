import BridgeHost
import Foundation
import Generated
import WebKit

/// ExternalWebView 的外部依赖（App 接线）：规则表、开关、埋点、商品回流。
public struct ExternalWebDependencies {
    /// 判定器（包内快照已注入）。
    public let policy: ExternalNavPolicy
    /// 当前 link_patterns（ConfigStore：current → 上一次成功 → 包内；JSON 文本）。
    public let linkPatterns: @MainActor () -> String?
    /// 隐私已同意（商品回流的识别前提，rule-gaps：基本模式下商品页只拦下）。
    public let consented: @MainActor () -> Bool
    /// features.flags.external_page.product_intercept。
    public let productIntercept: @MainActor () -> Bool
    /// external_page.nav_host_sample_bp（万分比）。
    public let navHostSampleBp: @MainActor () -> Int
    public let track: @MainActor (TrackEvent) -> Void
    /// 商品回流：向 Router 发出商品意图（去片段 URL、平台）。Router 没有打开商品页时返回 false，容器提示「暂无法查返利」。
    public let onProductIntent: @MainActor (_ url: String, _ platform: String) -> Bool
    /// 0..<10000 的随机数（抽样用；测试可注入）。
    public let roll: @MainActor () -> Int
    /// 平台页面被拦时提示里的「去搜索」（经 Router 打开搜索页；BR-ATTR-29 ②b，三端共性第 21 条）与按钮文字。
    public let onSearch: @MainActor () -> Void
    public let searchLabel: String

    public init(
        policy: ExternalNavPolicy,
        linkPatterns: @escaping @MainActor () -> String?,
        consented: @escaping @MainActor () -> Bool,
        productIntercept: @escaping @MainActor () -> Bool,
        navHostSampleBp: @escaping @MainActor () -> Int,
        track: @escaping @MainActor (TrackEvent) -> Void,
        onProductIntent: @escaping @MainActor (_ url: String, _ platform: String) -> Bool,
        onSearch: @escaping @MainActor () -> Void,
        searchLabel: String,
        roll: @escaping @MainActor () -> Int = { Int.random(in: 0..<NavHostSample.rollBound) }
    ) {
        self.onSearch = onSearch
        self.searchLabel = searchLabel
        self.policy = policy
        self.linkPatterns = linkPatterns
        self.consented = consented
        self.productIntercept = productIntercept
        self.navHostSampleBp = navHostSampleBp
        self.track = track
        self.onProductIntent = onProductIntent
        self.roll = roll
    }
}

/// 容器内的提示层（画在原生界面上，不画进页面）。
public enum ExternalWebNotice: Equatable, Sendable {
    /// 联盟平台页面（或授权页）不在这里打开：BR-ATTR-29 ②(b)。
    case blocked
    /// 商品回流没能打开商品页。
    case productUnresolved
    /// 下载被取消（iOS 没有系统浏览器出口，提示「这里不支持下载」）。
    case downloadUnsupported

    /// 文案键（BR-TEXT-14）。
    public var textKey: String {
        switch self {
        case .blocked: "external_page.union_host_blocked"
        case .productUnresolved: "external_page.product_unresolved"
        case .downloadUnsupported: "external_page.download_unsupported"
        }
    }
}

/// ExternalWebView（第三方页容器，03 §5.1；判定规则在 BR-ATTR-29，判定函数是 BridgeHost 的 `ExternalNavPolicy`）。
///
/// - 不注入任何东西：不加用户脚本、文档启动脚本、样式，不注册脚本消息通道，不执行脚本，不改写页面（CSB-10）。
///   页面里的 http / ws 子资源由内容规则拦下（CSB-03 禁止混合内容；规则只拦加载，不改页面）。
/// - 不共享 Cookie：非持久化的独立数据存储（`WKWebsiteDataStore.nonPersistent()`）。
/// - 判定点：`decidePolicyFor navigationAction` 覆盖主框架导航、子框架文档导航、新窗口请求（targetFrame == nil）与重定向的
///   每一跳（WebKit 对每一跳都做导航策略检查）。第一个 URL 也先过同一判定。授权页一律不进容器（三端共性第 7 条）。
/// - 只放行 https；非 https（含 intent://、应用市场、tel、blob、data）取消并上报 external_page_blocked_nav。下载（附件、
///   不可渲染的响应）取消并上报。
/// - 规则表为空（包内快照为空、又没有服务端配置）时不在 App 内打开第三方页面（保守降级，与 Android 相同）；已打开的容器
///   在运行中遇到规则表变空或损坏，同样取消加载并显示降级页（每次导航都核对）。
/// - 不让通用链接拉起其他 App：跨域主框架导航与新窗口请求先取消，再由容器以 `load(URLRequest)` 程序方式发起（不用私有 API）。
/// - 系统浏览器出口：iOS 上 `UIApplication.open` 打开 https 地址时，系统会把命中通用链接的地址直接交给对应 App，
///   无法保证只在系统浏览器里打开（三端共性第 9 条），所以本端不提供这个出口（见 capability-ios.md）。
@MainActor
public final class ExternalWebController: NSObject, ObservableObject {
    public static let page = "ExternalPage"

    @Published public internal(set) var host: String?
    @Published public private(set) var notice: ExternalWebNotice?
    @Published public internal(set) var loadFailed = false
    /// 规则表为空或第一个 URL 不能在容器里打开：整个容器不加载页面。
    @Published public private(set) var unavailable = false
    @Published public internal(set) var canGoBack = false
    /// WebView 报告正在进入或处于元素全屏：界面隐藏原生标题栏、WebView 铺满窗口（三端共性第 25 条）。元素全屏已关闭
    /// （第 42 条），普通元素进不了全屏，这里保持为假；系统视频播放器的全屏由系统另起界面盖住标题栏，不经过这里。
    @Published public private(set) var isFullscreen = false

    public let webView: WKWebView
    private let initialURL: URL?
    private var started = false
    let deps: ExternalWebDependencies
    private let onClose: @MainActor () -> Void
    private var fullscreenObservation: NSKeyValueObservation?
    var urlObservation: NSKeyValueObservation?
    var backObservation: NSKeyValueObservation?
    /// 路由已出栈（`teardown`）：之后的一切导航都取消。
    private(set) var tornDown = false
    /// 容器以程序方式重新发起、还没轮到判定的那次导航的地址（见 `reissue`）。
    private var pendingReissue: URL?
    /// 最近的导航判定（诊断与测试用：证明跨域点击是先取消、再由程序发起的；只留最近 50 条，只在内存）。
    private(set) var navigationTrace: [NavigationTrace] = []

    public init(url: URL?, appVersion: String, deps: ExternalWebDependencies,
                onClose: @escaping @MainActor () -> Void) {
        initialURL = url
        self.deps = deps
        self.onClose = onClose
        let configuration = WKWebViewConfiguration()
        WebContainerSupport.applyCommonSettings(configuration)
        WebContainerSupport.applyUserAgent(configuration, appVersion: appVersion)
        configuration.websiteDataStore = .nonPersistent()
        // 关闭任意元素的 Fullscreen API（三端共性第 42 条，03 §5.1）：只有系统视频全屏能盖住标题栏，canvas、div 等普通元素
        // 请求全屏一律不生效，第三方页面不能借此隐藏主机名、返回与关闭。视频照常用系统播放器全屏（iPhone 上 <video> 的全屏按钮
        // 与 webkitEnterFullscreen 走 AVKit 的原生播放器，不经元素全屏）。不注入脚本限制页面。
        if #available(iOS 16.4, *) {
            configuration.preferences.isElementFullscreenEnabled = false
        }
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsLinkPreview = false
        observePageState()
        fullscreenObservation = webView.observe(\.fullscreenState, options: [.initial, .new]) { [weak self] view, _ in
            let state = view.fullscreenState
            MainActor.assumeIsolated {
                self?.fullscreenChanged(state)
            }
        }
    }

    /// WKWebView.fullscreenState 的变化（KVO）：进入中 / 全屏中隐藏标题栏，退出中 / 不在全屏恢复。
    func fullscreenChanged(_ state: WKWebView.FullscreenState) {
        let full = state == .enteringFullscreen || state == .inFullscreen
        if isFullscreen != full {
            isFullscreen = full
        }
    }

    /// 打开第一个 URL：先过授权页与导航判定（与之后每一次导航同一套），规则表为空时整个容器不打开。
    public func start() {
        guard !started else { return }
        started = true
        guard let url = initialURL else {
            unavailable = true
            return
        }
        let table = deps.policy.table(json: deps.linkPatterns())
        guard !table.isEmpty else {
            // TODO(N-21)：包内快照的 link_patterns.rules 目前为空；没有规则时无法判定平台页面，不在 App 内打开。
            unavailable = true
            return
        }
        guard decide(url: url.absoluteString, frame: .initial, isMainFrame: true, isNewWindow: false, table: table)
        else {
            unavailable = notice == nil
            return
        }
        WebContainerSupport.httpsOnlyRules { [weak self] rules in
            guard let self else { return }
            guard let rules else {
                loadFailed = true
                return
            }
            webView.configuration.userContentController.add(rules)
            // 外链原样打开：不替换占位、不追加用户或设备参数（BR-ID-33 细则）。
            webView.load(URLRequest(url: url))
        }
    }

    /// 路由真正出栈（关闭、清栈、被替换、强更替换导航栈）时调用：停止加载，之后不再放行任何导航（三端共性第 28 条）。
    public func teardown() {
        tornDown = true
        pendingReissue = nil
        webView.stopLoading()
    }

    public func retry() {
        guard !tornDown else { return }
        loadFailed = false
        unavailable = false
        if webView.url == nil {
            started = false
            start()
        } else {
            webView.reload()
        }
    }

    public func dismissNotice() {
        notice = nil
    }

    /// 返回：页面有历史时先后退网页，没有历史才关闭容器（三端共性第 11 条）。
    public func goBack() {
        if webView.canGoBack {
            webView.goBack()
        } else {
            onClose()
        }
    }

    public func close() {
        onClose()
    }

    /// 被拦提示里的「去搜索」。页内被拦时原页面保持不动；初始地址被拦时同样给出这个去向。
    public func goSearch() {
        notice = nil
        deps.onSearch()
    }

    public var searchLabel: String {
        deps.searchLabel
    }

    /// 统一判定入口（第一个 URL、主框架、子框架、新窗口、每一跳重定向都经过这里）：返回是否放行加载。
    @discardableResult
    func decide(
        url: String,
        frame: TrackerEvents.ExternalPageNavHost.FrameValue,
        isMainFrame: Bool,
        isNewWindow: Bool,
        table: LinkPatterns,
        sample: Bool = true
    ) -> Bool {
        // 被拦时的提示（含「去搜索」）主框架、新窗口、子框架都出（BR-ATTR-29：内嵌框架被拦时出同样提示；三端共性第 31 条）。
        // 提示只有一个槽位，连续多次被拦合并成一条；原页面不动。
        if AuthPages.isAuthPage(url) {
            // 授权与登录页不进容器（03 §5.1）；登记表未补齐前宁可多拦（TODO(N-22)）。
            notice = .blocked
            return false
        }
        let decision = deps.policy.decide(url: url, isMainFrame: isMainFrame, isNewWindow: isNewWindow, table: table)
        // external_page_nav_host 抽样覆盖全部文档导航：点击、表单、脚本跳转、服务器重定向、iframe 自动加载（三端共性第 32 条）。
        // hit 只表示「是否命中规则表」（任一类别，含被放行的 promo），与导航动作分开记（三端共性第 49 条）。
        if sample, decision.actionRaw != ExternalNavAction.cancelReport {
            let hit = NormalizedURL.parse(url).map { !table.matches($0).isEmpty } ?? false
            sampleNavHost(url: url, frame: frame, hit: hit)
        }
        switch decision.actionRaw {
        case ExternalNavAction.load:
            return true
        case ExternalNavAction.toNativeProduct:
            let outcome = productReflow(url: url, decision: decision)
            reportUnionHit(decision.match, frame: frame, outcome: outcome)
        case ExternalNavAction.cancelReport:
            reportCancelled(decision, frame: frame)
        default:
            notice = .blocked
            reportUnionHit(decision.match, frame: frame, outcome: .block)
        }
        return false
    }

    /// 运行中生效规则表变空或损坏：停止加载，整个容器显示降级页（与首次打开时没有规则相同）。
    func degradeForMissingRules() {
        pendingReissue = nil
        webView.stopLoading()
        unavailable = true
    }

    /// 需要改由程序发起的主框架导航：页面已有文档（WebKit 只在跨域时尝试通用链接，按当前文档的主机比较），目标主机与当前
    /// 主机不同，且不是前进后退（WebKit 对前进后退不尝试通用链接）。同主机导航（含片段跳转）原样放行。
    func needsProgrammaticLoad(_ action: WKNavigationAction, url: URL?, in webView: WKWebView) -> Bool {
        guard action.navigationType != .backForward, let current = webView.url?.host?.lowercased() else {
            return false
        }
        return url?.host?.lowercased() != current
    }

    /// 取消原导航后以程序方式重新发起（同一请求：方法、请求体、请求头不变）。
    func reissue(_ request: URLRequest, in webView: WKWebView) {
        guard !tornDown else { return }
        pendingReissue = request.url
        webView.load(request)
    }

    /// 这次导航是不是刚才由 `reissue` 发起的那次（程序发起的导航类型是 other）；是则消费掉标记。
    func consumeReissue(_ url: URL?, _ action: WKNavigationAction) -> Bool {
        guard let pending = pendingReissue, action.navigationType == .other, action.targetFrame?.isMainFrame == true,
              url == pending
        else { return false }
        pendingReissue = nil
        return true
    }

    func record(
        url: URL?,
        type: WKNavigationType,
        frame: TrackerEvents.ExternalPageNavHost.FrameValue,
        policy: NavigationTrace.Policy
    ) {
        navigationTrace.append(NavigationTrace(
            url: url?.absoluteString ?? "",
            type: type,
            frame: frame,
            policy: policy
        ))
        if navigationTrace.count > 50 {
            navigationTrace.removeFirst(navigationTrace.count - 50)
        }
    }

    /// external_page_union_host（BR-ATTR-29 ②，每次命中一条）：只记平台、类别、框架类型与结果。
    private func reportUnionHit(
        _ match: LinkMatch?,
        frame: TrackerEvents.ExternalPageNavHost.FrameValue,
        outcome: TrackerEvents.ExternalPageUnionHost.OutcomeValue
    ) {
        guard let match,
              let platform = TrackerEvents.ExternalPageUnionHost.UnionPlatformValue(rawValue: match.platform),
              let category = TrackerEvents.ExternalPageUnionHost.CategoryValue(rawValue: match.category),
              let hitFrame = TrackerEvents.ExternalPageUnionHost.FrameValue(rawValue: frame.rawValue)
        else { return }
        deps.track(TrackerEvents.externalPageUnionHost(
            page: Self.page, unionPlatform: platform, category: category, frame: hitFrame, outcome: outcome
        ))
    }

    /// 商品回流：前提是已同意隐私、product_intercept 开启（rule-gaps）；否则只拦下。向 Router 发出去片段的商品意图，
    /// 打不开时提示「暂无法查返利」并留在原页（三端共性第 8 条）。
    private func productReflow(
        url: String,
        decision: ExternalNavDecision
    ) -> TrackerEvents.ExternalPageUnionHost.OutcomeValue {
        guard deps.consented(), deps.productIntercept(), let platform = decision.match?.platform else {
            notice = .blocked
            return .block
        }
        guard deps.onProductIntent(ProductIntentURL.withoutFragment(url), platform) else {
            notice = .productUnresolved
            return .parseFailed
        }
        return .parseOk
    }

    /// 非 https、intent:// 等：取消并上报 external_page_blocked_nav（新窗口单独记为 new_window）。
    private func reportCancelled(_ decision: ExternalNavDecision, frame: TrackerEvents.ExternalPageNavHost.FrameValue) {
        let kind = TrackerEvents.ExternalPageBlockedNav.KindValue(rawValue: decision.reason ?? "") ?? .otherScheme
        let blockedFrame = TrackerEvents.ExternalPageBlockedNav.FrameValue(rawValue: frame.rawValue) ?? .main
        deps.track(TrackerEvents.externalPageBlockedNav(page: Self.page, kind: kind, frame: blockedFrame))
    }

    /// external_page_nav_host 抽样（三端共性第 12 条）：只记注册域、框架类型、是否命中规则；不记路径与参数。
    private func sampleNavHost(url: String, frame: TrackerEvents.ExternalPageNavHost.FrameValue, hit: Bool) {
        guard NavHostSample.sampled(bp: deps.navHostSampleBp(), roll: deps.roll()),
              let domain = NavHostSample.registeredDomain(URLComponents(string: url)?.host)
        else { return }
        deps.track(TrackerEvents.externalPageNavHost(page: Self.page, registeredDomain: domain, frame: frame, hit: hit))
    }

    func reportDownload(frame: TrackerEvents.ExternalPageBlockedNav.FrameValue) {
        deps.track(TrackerEvents.externalPageBlockedNav(page: Self.page, kind: .download, frame: frame))
        notice = .downloadUnsupported
    }
}

/// 一次导航判定的记录（诊断与测试用）。
public struct NavigationTrace: Equatable {
    public enum Policy: Equatable {
        case allow
        case cancel
        /// 取消原导航，改由容器以程序方式重新发起（不触发通用链接）。
        case reissue
    }

    public let url: String
    public let type: WKNavigationType
    public let frame: TrackerEvents.ExternalPageNavHost.FrameValue
    public let policy: Policy
}
