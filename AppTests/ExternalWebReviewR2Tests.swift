import BridgeHost
import ClientCore
@testable import Couli
import Foundation
import Generated
@testable import Web
import WebKit
import XCTest

/// APP-04 iOS 第 2、3 轮评审：第三方页容器在真实 WKWebView 里的补充用例（R2-01 运行中换成坏规则表、R2-03 元素全屏；
/// 第 3 轮的 SPA 地址同步与抽样 hit 字段）。
@MainActor
final class ExternalWebReviewR2Tests: WebViewTestCase {
    /// 第 2 轮评审 R2-01（三端共性第 40 条）：运行中配置把规则换成坏表（类别拼错 union_hots、主机写成带 https:// 的地址），
    /// 真实 ConfigStore 整表回落到上一次成功的表，已打开的第三方页容器照样拦下平台主框架、子框架与新窗口。
    func testRuntimeReplacementWithInvalidRulesFallsBackToLastGoodTable() async throws {
        var pending: [(ConfigReply) -> Void] = []
        let store = ConfigStore(
            readFile: { nil }, writeFile: { _ in }, fetcher: { _, done in pending.append(done) },
            clock: { 1 }, bundled: DefaultConfig.json
        )
        func rules(category: String, host: String) -> String {
            #"{"link_patterns":{"version":"v","rules":[{"platform":"taobao","category":""# + category
                + #"","hosts":[""# + host + #""],"path_patterns":[]}]}}"#
        }
        store.onColdStart()
        pending.removeFirst()(ConfigReply(
            kindRaw: ConfigReply.ok, bodyJson: rules(category: "union_host", host: "taobao.example.test"), etag: nil
        ))
        let recorder = ExternalWebContainerTests.ExternalRecorder()
        recorder.source = { store.linkPatternsJson }
        let controller = ExternalWebController(url: nil, appVersion: AppWeb.appVersion, deps: recorder.deps()) {}
        host(controller.webView)
        try await load(controller.webView, html: "external-page", base: "https://shop.example.test/")

        for (category, host) in [("union_hots", "taobao.example.test"), ("union_host", "https://taobao.example.test")] {
            store.onForeground()
            pending.removeFirst()(ConfigReply(
                kindRaw: ConfigReply.ok, bodyJson: rules(category: category, host: host), etag: nil
            ))
            XCTAssertEqual(store.sourceRaw, ConfigStore.sourceCurrent, "新配置已生效，只有坏的规则表整表回落")
            let label = "\(category) \(host)"
            let before = controller.navigationTrace.count
            _ = try await evaluate(controller.webView, "window.__go('https://shop.taobao.example.test/'); true")
            try await waitUntil { controller.navigationTrace.count > before }
            try await Task.sleep(nanoseconds: 300_000_000)
            XCTAssertEqual(controller.webView.url?.host, "shop.example.test", label)
            let main = controller.navigationTrace.dropFirst(before)
                .filter { $0.url == "https://shop.taobao.example.test/" }
            XCTAssertEqual(main.map(\.policy), [.cancel], label)
            XCTAssertEqual(controller.notice, .blocked, "按上一次成功的表拦下（不是降级页）：\(label)")
            XCTAssertFalse(controller.unavailable, label)
            controller.goSearch()

            _ = try await evaluate(
                controller.webView, "window.__addFrame('f\(before)', 'https://m.taobao.example.test/a', false); true"
            )
            try await waitUntil { controller.notice == .blocked }
            let href = try await evaluate(controller.webView, "window.__frameHref('f\(before)')") as? String
            XCTAssertEqual(href, "about:blank", "平台子框架不加载：\(label)")
            controller.goSearch()

            _ = try await evaluate(
                controller.webView, "window.__click('https://shop.taobao.example.test/n', '_blank'); true"
            )
            try await waitUntil { controller.notice == .blocked }
            XCTAssertEqual(controller.webView.url?.host, "shop.example.test", "新窗口请求同样拦下：\(label)")
            controller.goSearch()
        }
    }

    /// 第 2 轮评审 R2-03（三端共性第 42 条）：第三方页在用户手势里对 canvas、div 请求元素全屏 → 不进入全屏，标题栏
    /// （主机名、返回、关闭）不隐藏。evaluateJavaScript 在 WKWebView 里按用户手势执行（与页面里的点击同等）。
    func testElementFullscreenRequestDoesNotHideTitleBar() async throws {
        let recorder = ExternalWebContainerTests.ExternalRecorder()
        let controller = ExternalWebController(url: nil, appVersion: AppWeb.appVersion, deps: recorder.deps()) {}
        host(controller.webView)
        try await load(controller.webView, html: "external-page", base: "https://shop.example.test/")
        let enabled = try await evaluate(
            controller.webView, "Boolean(document.fullscreenEnabled || document.webkitFullscreenEnabled)"
        ) as? Bool
        XCTAssertEqual(enabled, false, "任意元素的 Fullscreen API 已关闭")
        for tag in ["canvas", "div"] {
            _ = try await evaluate(controller.webView, """
            (function () {
              var el = document.createElement('\(tag)');
              el.style.width = '200px'; el.style.height = '200px';
              document.body.appendChild(el);
              var request = el.requestFullscreen || el.webkitRequestFullscreen;
              if (request) {
                try { var p = request.call(el); if (p && p.catch) { p.catch(function () {}); } } catch (e) {}
              }
              return true;
            })()
            """)
            try await Task.sleep(nanoseconds: 1_000_000_000)
            XCTAssertEqual(controller.webView.fullscreenState, .notInFullscreen, tag)
            XCTAssertFalse(controller.isFullscreen, "\(tag) 请求全屏后标题栏不隐藏")
            let element = try await evaluate(
                controller.webView, "String(document.fullscreenElement || document.webkitFullscreenElement || null)"
            ) as? String
            XCTAssertEqual(element, "null", tag)
        }
    }

    /// 第 3 轮（三端共性第 48 条）：SPA 页内跳转（pushState、replaceState、片段导航）不触发 didCommit；标题栏的主机名与返回
    /// 按钮改由 KVO 跟随 WKWebView 的 url 与 canGoBack，页内跳转后容器状态与 WebView 当前状态一致。
    /// 说明：loadHTMLString 加载的测试页不产生历史项（实测 backList 始终为 0），canGoBack 的变化无法在单测里制造，
    /// 这里核对的是「跟随」而不是具体取值；iOS 没有系统浏览器出口，不涉及出口地址。
    func testTitleBarFollowsSinglePageNavigation() async throws {
        let recorder = ExternalWebContainerTests.ExternalRecorder()
        let controller = ExternalWebController(url: nil, appVersion: AppWeb.appVersion, deps: recorder.deps()) {}
        host(controller.webView)
        try await load(controller.webView, html: "external-page", base: "https://shop.example.test/")
        for script in [
            "history.pushState({}, '', '/spa/2')", "history.replaceState({}, '', '/spa/3')", "location.hash = 'x'",
        ] {
            _ = try await evaluate(controller.webView, script + "; true")
            try await Task.sleep(nanoseconds: 300_000_000)
            XCTAssertEqual(controller.host, controller.webView.url?.host, script)
            XCTAssertEqual(controller.host, "shop.example.test", script)
            XCTAssertEqual(controller.canGoBack, controller.webView.canGoBack, script)
        }
        XCTAssertEqual(controller.webView.url?.path, "/spa/3")
    }

    /// 第 3 轮（三端共性第 49 条）：external_page_nav_host 的 hit 表示「是否命中规则表」，与导航动作分开：promo 被放行时
    /// hit 仍为 true；不命中任何规则时为 false。
    func testNavHostHitIsSeparateFromAction() async throws {
        let recorder = ExternalWebContainerTests.ExternalRecorder()
        recorder.sampleBp = 10000
        recorder.patterns = #"{"version":"t","rules":["#
            + #"{"platform":"taobao","category":"union_host","hosts":["taobao.example.test"],"path_patterns":[]},"#
            + #"{"platform":"taobao","category":"promo","hosts":["promo.example.test"],"path_patterns":[]}]}"#
        let controller = ExternalWebController(url: nil, appVersion: AppWeb.appVersion, deps: recorder.deps()) {}
        host(controller.webView)
        try await load(controller.webView, html: "external-page", base: "https://shop.example.test/")
        recorder.tracked.removeAll()
        _ = try await evaluate(controller.webView, "window.__go('https://promo.example.test/p'); true")
        try await waitUntil { !recorder.navHosts.isEmpty }
        let promo = controller.navigationTrace.filter { $0.url == "https://promo.example.test/p" }
        XCTAssertNotEqual(promo.first?.policy, .cancel, "promo 不用于导航阻断（放行）")
        XCTAssertEqual(recorder.navHosts.first?.fields["hit"], .boolean(true), "命中 promo 规则：hit 为真")

        recorder.tracked.removeAll()
        _ = try await evaluate(
            controller.webView, "window.__addFrame('plain', 'https://plain.example.test/x', false); true"
        )
        try await waitUntil { !recorder.navHosts.isEmpty }
        XCTAssertEqual(recorder.navHosts.first?.fields["hit"], .boolean(false), "不命中任何规则：hit 为假")
    }
}
