import BridgeHost
import ClientCore
@testable import Couli
import Foundation
import Generated
import Router
@testable import Web
import WebKit
import XCTest

/// APP-04 验收 §5.2（第三方页容器部分）：真实 WKWebView 里 ExternalWebView 不注入桥、拦得住平台域的主框架与子框架导航、
/// 非 https 取消并上报。页面用 loadHTMLString + https baseURL 加载，不连任何网络；规则只用保留测试域。
@MainActor
final class ExternalWebContainerTests: WebViewTestCase {
    func testExternalWebViewInjectsNothingAndBlocksPlatformNavigation() async throws {
        let recorder = ExternalRecorder()
        let deps = recorder.deps()
        let controller = ExternalWebController(url: nil, appVersion: AppWeb.appVersion, deps: deps) {}
        host(controller.webView)
        try await load(controller.webView, html: "external-page", base: "https://shop.example.test/")

        let probe = try await evaluate(controller.webView, "JSON.stringify(window.__E)") as? String ?? "{}"
        let page = AppWeb.object(probe) ?? [:]
        XCTAssertEqual(page["bridge"] as? String, "undefined", "第三方页里不得有 __REBATE_BRIDGE__")
        XCTAssertEqual(page["handler"] as? String, "undefined", "第三方页里不得有传输通道")
        XCTAssertEqual(page["receive"] as? String, "undefined")
        XCTAssertEqual(controller.webView.configuration.userContentController.userScripts.count, 0)
        XCTAssertFalse(controller.webView.configuration.websiteDataStore.isPersistent, "不共享 Cookie")

        // 平台网页域名（union_host）：取消，原页面不动，出提示层。
        _ = try await evaluate(controller.webView, "window.__go('https://shop.taobao.example.test/'); true")
        try await waitUntil { controller.notice == .blocked }
        XCTAssertEqual(controller.webView.url?.host, "shop.example.test")
        // 提示里的「去搜索」经 Router 打开搜索页（三端共性第 21 条）。
        controller.goSearch()
        XCTAssertEqual(recorder.searches, 1)
        XCTAssertNil(controller.notice)

        // 商品页：取消原导航，向 Router 发出去片段的商品意图。
        _ = try await evaluate(controller.webView, "window.__go('https://item.taobao.example.test/item?id=1#x'); true")
        try await waitUntil { !recorder.products.isEmpty }
        XCTAssertEqual(recorder.products.first?.0, "https://item.taobao.example.test/item?id=1")
        XCTAssertEqual(recorder.products.first?.1, "taobao")
        XCTAssertEqual(controller.webView.url?.host, "shop.example.test")

        // 非 https（自定义 scheme）：取消并上报 external_page_blocked_nav。
        _ = try await evaluate(controller.webView, "window.__go('example-app://buy/42'); true")
        try await waitUntil { recorder.tracked.contains { $0.name == "external_page_blocked_nav" } }
        XCTAssertEqual(
            recorder.tracked.first { $0.name == "external_page_blocked_nav" }?.fields["kind"], .string("app_scheme")
        )
        XCTAssertEqual(controller.webView.url?.host, "shop.example.test")
    }

    /// 第三方页容器的子框架：去往平台域名的子框架文档同样取消、原页面不动，按 subframe 记 external_page_union_host，
    /// 并出与主框架相同的提示和「去搜索」（BR-ATTR-29：内嵌框架被拦时出同样提示；第 1 轮评审 R1-06，三端共性第 31 条）。
    func testExternalWebViewBlocksPlatformSubframes() async throws {
        let recorder = ExternalRecorder()
        let controller = ExternalWebController(url: nil, appVersion: AppWeb.appVersion, deps: recorder.deps()) {}
        host(controller.webView)
        try await load(controller.webView, html: "external-page", base: "https://shop.example.test/")
        _ = try await evaluate(
            controller.webView,
            "window.__addFrame('plat', 'https://m.taobao.example.test/a', false); true"
        )
        try await waitUntil {
            recorder.tracked
                .contains { $0.name == "external_page_union_host" && $0.fields["frame"] == .string("subframe") }
        }
        let hit = recorder.tracked.first { $0.name == "external_page_union_host" }
        XCTAssertEqual(hit?.fields["outcome"], .string("block"))
        XCTAssertEqual(hit?.fields["category"], .string("union_host"))
        let href = try await evaluate(controller.webView, "window.__frameHref('plat')") as? String
        XCTAssertEqual(href, "about:blank")
        XCTAssertEqual(controller.notice, .blocked, "子框架被拦同样出提示层")
        XCTAssertEqual(controller.webView.url?.host, "shop.example.test")
        controller.goSearch()
        XCTAssertEqual(recorder.searches, 1, "提示里的「去搜索」经 Router 打开搜索页")
        XCTAssertNil(controller.notice)
        // 再拦两个子框架：提示合并为一条（只有一个槽位）。
        _ = try await evaluate(
            controller.webView,
            "window.__addFrame('p2', 'https://m.taobao.example.test/b', false); "
                + "window.__addFrame('p3', 'https://m.taobao.example.test/c', false); true"
        )
        try await waitUntil { controller.notice == .blocked }
    }

    // MARK: - 第 1 轮评审

    /// R1-01（三端共性第 26 条）：用户点击的跨域主框架导航不能原样放行（WebKit 会先尝试按通用链接拉起登记了该域名的 App）。
    /// 真实 WKWebView：点击 → 判定先取消（reissue），随后同一地址以程序方式发起（navigationType = other）才放行；新窗口同样。
    /// 同主机的点击原样放行。目标用本机回环地址的空闲端口（连接被拒，不连任何网络）。
    func testCrossHostClickIsCancelledThenLoadedProgrammatically() async throws {
        let recorder = ExternalRecorder()
        let controller = ExternalWebController(url: nil, appVersion: AppWeb.appVersion, deps: recorder.deps()) {}
        host(controller.webView)
        try await load(controller.webView, html: "external-page", base: "https://shop.example.test/")
        let webView = controller.webView

        // 同主机点击（片段跳转）：原样放行，不改由程序发起。
        _ = try await evaluate(webView, "window.__click('https://shop.example.test/#same'); true")
        try await waitUntil { controller.navigationTrace.contains { $0.url == "https://shop.example.test/#same" } }
        let same = controller.navigationTrace.filter { $0.url == "https://shop.example.test/#same" }
        XCTAssertEqual(same.map(\.policy), [.allow])

        let target = "https://127.0.0.1:47913/landing"
        _ = try await evaluate(webView, "window.__click('\(target)'); true")
        try await waitUntil { controller.navigationTrace.filter { $0.url == target }.count >= 2 }
        let clicked = controller.navigationTrace.filter { $0.url == target }
        XCTAssertEqual(clicked.first?.type, .linkActivated)
        XCTAssertEqual(clicked.first?.policy, .reissue, "用户点击的跨域导航先取消")
        XCTAssertEqual(clicked.dropFirst().first?.type, .other, "再由程序 load(URLRequest) 发起")
        XCTAssertEqual(clicked.dropFirst().first?.policy, .allow)
        XCTAssertFalse(clicked.contains { $0.type == .linkActivated && $0.policy == .allow })
        try await waitUntil(timeout: 15) { !webView.isLoading }

        // 新窗口（target=_blank）：同样取消后由程序在当前容器里发起。
        let popup = "https://127.0.0.1:47913/window"
        _ = try await evaluate(webView, "window.__click('\(popup)', '_blank'); true")
        try await waitUntil { controller.navigationTrace.filter { $0.url == popup }.count >= 2 }
        let opened = controller.navigationTrace.filter { $0.url == popup }
        XCTAssertEqual(opened.first?.frame, .newWindow)
        XCTAssertEqual(opened.first?.policy, .reissue)
        XCTAssertEqual(opened.dropFirst().first?.type, .other)
        XCTAssertEqual(opened.dropFirst().first?.frame, .main)
        XCTAssertEqual(opened.dropFirst().first?.policy, .allow)
        try await waitUntil(timeout: 15) { !webView.isLoading }
    }

    /// R1-02（三端共性第 27 条）：先用有效规则打开普通第三方页，之后配置变成 rules=[] → 平台主框架、子框架导航都取消，
    /// 容器显示降级页，不把「没有匹配」当放行；规则表损坏同样。
    func testRulesBecomingEmptyAfterOpenCancelsAndDegrades() async throws {
        let recorder = ExternalRecorder()
        let controller = ExternalWebController(url: nil, appVersion: AppWeb.appVersion, deps: recorder.deps()) {}
        host(controller.webView)
        try await load(controller.webView, html: "external-page", base: "https://shop.example.test/")
        XCTAssertFalse(controller.unavailable)

        recorder.patterns = #"{"version":"t","rules":[]}"#
        _ = try await evaluate(
            controller.webView,
            "window.__addFrame('plat', 'https://m.taobao.example.test/a', false); true"
        )
        try await waitUntil { controller.unavailable }
        let href = try await evaluate(controller.webView, "window.__frameHref('plat')") as? String
        XCTAssertEqual(href, "about:blank", "规则表变空后平台子框架同样不加载")
        _ = try await evaluate(controller.webView, "window.__go('https://shop.taobao.example.test/'); true")
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertEqual(controller.webView.url?.host, "shop.example.test", "平台主框架导航被取消")
        let mainDecisions = controller.navigationTrace.filter { $0.url == "https://shop.taobao.example.test/" }
        XCTAssertEqual(mainDecisions.map(\.policy), [.cancel])

        // 损坏的表（解析不了，回落到空的包内快照）：同样取消。
        let broken = ExternalRecorder()
        let other = ExternalWebController(url: nil, appVersion: AppWeb.appVersion, deps: broken.deps()) {}
        host(other.webView)
        try await load(other.webView, html: "external-page", base: "https://shop.example.test/")
        broken.patterns = #"{"version":"t","rules":[{"platform":"taobao"}]}"#
        _ = try await evaluate(other.webView, "window.__go('https://shop.taobao.example.test/'); true")
        try await waitUntil { other.unavailable }
        XCTAssertEqual(other.webView.url?.host, "shop.example.test")
    }

    /// R1-07（三端共性第 32 条）：脚本跳转（navigationType = other）与 iframe.src 自动加载同样进入 external_page_nav_host 抽样；
    /// 改由程序重新发起的那一次不重复上报。
    func testNavHostSamplingCoversScriptAndSubframeNavigations() async throws {
        let recorder = ExternalRecorder()
        recorder.sampleBp = 10000
        let controller = ExternalWebController(url: nil, appVersion: AppWeb.appVersion, deps: recorder.deps()) {}
        host(controller.webView)
        try await load(controller.webView, html: "external-page", base: "https://shop.example.test/")
        recorder.tracked.removeAll()

        _ = try await evaluate(
            controller.webView,
            "window.__addFrame('auto', 'https://127.0.0.1:47913/frame', false); true"
        )
        try await waitUntil { recorder.navHosts.contains { $0.fields["frame"] == .string("subframe") } }

        _ = try await evaluate(controller.webView, "window.__go('https://127.0.0.1:47913/script'); true")
        try await waitUntil { recorder.navHosts.contains { $0.fields["frame"] == .string("main") } }
        try await waitUntil(timeout: 15) { !controller.webView.isLoading }
        let scripted = controller.navigationTrace.filter { $0.url == "https://127.0.0.1:47913/script" }
        XCTAssertEqual(scripted.first?.type, .other, "脚本跳转不是用户点击")
        XCTAssertEqual(recorder.navHosts.filter { $0.fields["frame"] == .string("main") }.count, 1, "重新发起的那次不重复上报")
        XCTAssertEqual(recorder.navHosts.first?.fields["hit"], .boolean(false))
    }

    /// 三端共性第 37 条：主框架 POST 表单提交到平台域名被拦时，原页面原样保留（取消导航，不用替代响应冒充）。
    func testBlockedMainFramePostKeepsOriginalPage() async throws {
        let recorder = ExternalRecorder()
        let controller = ExternalWebController(url: nil, appVersion: AppWeb.appVersion, deps: recorder.deps()) {}
        host(controller.webView)
        try await load(controller.webView, html: "external-page", base: "https://shop.example.test/")
        _ = try await evaluate(
            controller.webView,
            "window.__marker = 'kept'; window.__post('https://shop.taobao.example.test/submit'); true"
        )
        try await waitUntil { controller.notice == .blocked }
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(controller.webView.url?.absoluteString, "https://shop.example.test/")
        let marker = try await evaluate(controller.webView, "window.__marker") as? String
        XCTAssertEqual(marker, "kept", "原页面文档没有被替换")
    }

    /// 规则表为空（包内快照为空、又没有服务端配置）：第三方页容器不加载任何页面（保守降级，capability-ios.md）。
    func testExternalWebViewRefusesToOpenWithoutRules() throws {
        let recorder = ExternalRecorder()
        recorder.patterns = nil
        let url = try XCTUnwrap(URL(string: "https://shop.example.test/"))
        let controller = ExternalWebController(url: url, appVersion: AppWeb.appVersion, deps: recorder.deps()) {}
        controller.start()
        XCTAssertTrue(controller.unavailable)
        XCTAssertNil(controller.webView.url)
    }

    /// 三端共性第 25 条：页面元素（视频）全屏时隐藏原生标题栏，退出后恢复（WKWebView.fullscreenState 的 KVO）。
    func testFullscreenStateHidesAndRestoresTitleBar() {
        let controller = ExternalWebController(
            url: nil,
            appVersion: AppWeb.appVersion,
            deps: ExternalRecorder().deps()
        ) {}
        XCTAssertFalse(controller.isFullscreen, "KVO 初值：不在全屏")
        controller.fullscreenChanged(.enteringFullscreen)
        XCTAssertTrue(controller.isFullscreen)
        controller.fullscreenChanged(.inFullscreen)
        XCTAssertTrue(controller.isFullscreen)
        controller.fullscreenChanged(.exitingFullscreen)
        XCTAssertFalse(controller.isFullscreen)
        controller.fullscreenChanged(.notInFullscreen)
        XCTAssertFalse(controller.isFullscreen)
    }

    /// 三端共性第 24 条：ExternalPage 的 title 作副标题、nav_style 决定标题栏配色（缺省 light），都传进容器页面。
    func testRouteTitleAndNavStyleReachTheScreen() {
        let dark = ExternalWebContainer.chrome(RouteDestination(
            route: "ExternalPage",
            params: [
                "url": .string("https://shop.example.test/"),
                "title": .string("sub"),
                "nav_style": .string("dark"),
            ]
        ))
        XCTAssertEqual(dark.subtitle, "sub")
        XCTAssertEqual(dark.navStyle, .dark)
        let plain = ExternalWebContainer.chrome(RouteDestination(
            route: "ExternalPage", params: ["url": .string("https://shop.example.test/")]
        ))
        XCTAssertNil(plain.subtitle)
        XCTAssertEqual(plain.navStyle, .light)

        let controller = ExternalWebController(
            url: nil,
            appVersion: AppWeb.appVersion,
            deps: ExternalRecorder().deps()
        ) {}
        let screen = ExternalWebScreen(controller: controller, subtitle: dark.subtitle, navStyle: dark.navStyle)
        XCTAssertEqual(screen.subtitle, "sub")
        XCTAssertEqual(screen.navStyle, .dark)
        XCTAssertNotEqual(ExternalNavStyle.dark.background, ExternalNavStyle.light.background)
        XCTAssertNotEqual(ExternalNavStyle.dark.foreground, ExternalNavStyle.light.foreground)
    }

    // MARK: - 夹具

    /// 第三方页容器的依赖替身：规则表只用保留测试域。
    @MainActor
    final class ExternalRecorder {
        var tracked: [TrackEvent] = []
        var products: [(String, String)] = []
        var searches = 0
        var sampleBp = 0

        var navHosts: [TrackEvent] {
            tracked.filter { $0.name == "external_page_nav_host" }
        }

        var patterns: String? = #"{"version":"t","rules":["#
            + #"{"platform":"taobao","category":"union_host","hosts":["taobao.example.test"],"path_patterns":[]},"#
            + #"{"platform":"taobao","category":"product","hosts":["item.taobao.example.test"],"#
            + #""path_patterns":["^/item$"]}]}"#

        /// 给了就从它取当前规则表（例如真实 ConfigStore 的 linkPatternsJson），否则用 `patterns`。
        var source: (@MainActor () -> String?)?

        func deps() -> ExternalWebDependencies {
            ExternalWebDependencies(
                policy: ExternalNavPolicy(bundledLinkPatterns: [:]),
                linkPatterns: { [unowned self] in
                    if let source {
                        return source()
                    }
                    return patterns
                },
                consented: { true },
                productIntercept: { true },
                navHostSampleBp: { [unowned self] in sampleBp },
                track: { [unowned self] in tracked.append($0) },
                onProductIntent: { [unowned self] url, platform in
                    products.append((url, platform))
                    return true
                },
                onSearch: { [unowned self] in searches += 1 },
                searchLabel: "search",
                roll: { 0 }
            )
        }
    }
}
