import BridgeHost
@testable import Couli
import Foundation
import Generated
import SwiftUI
@testable import Web
import WebKit
import XCTest

/// APP-04 验收 §5.2：用 XCTest 宿主（Couli App）把包内测试 HTML 加载进真实的 WKWebView，证明
/// 子框架（同地址、srcdoc、sandbox）调用被拒、非可信 origin 被拒、缺手势被拒、ExternalWebView 不注入桥且拦得住平台域导航。
/// 页面用 loadHTMLString + https baseURL 加载（文档 origin 就是 baseURL 的 origin），不连任何网络。
@MainActor
final class WebContainerTests: WebViewTestCase {
    private static let trusted = "https://h5.example.test"

    // MARK: - 可信容器

    func testMainFrameCallsWorkAndEverySubframeIsRefused() async throws {
        let fixture = try makeTrusted()
        try await load(fixture.controller.webView, html: "bridge-frames", base: Self.trusted + "/page")
        let bridgeInMain = try await evaluate(fixture.controller.webView, "window.__T.bridgeInMain") as? Bool
        XCTAssertEqual(bridgeInMain, true, "主框架应有 __REBATE_BRIDGE__")

        _ = try await evaluate(fixture.controller.webView, "window.__callMain('main_env', 'app.getEnv'); true")
        _ = try await evaluate(fixture.controller.webView, "window.__startFrames(); true")
        for label in ["main_env", "same_url_frame", "srcdoc_frame", "sandbox_frame"] {
            try await waitFor(fixture.controller.webView, "window.__T.results['\(label)'] !== undefined", label)
        }
        let results = try await resultCodes(fixture.controller.webView)
        XCTAssertEqual(results["main_env"], BridgeCode.ok)
        XCTAssertEqual(results["same_url_frame"], BridgeCode.notAllowed, "同地址子框架必须按子框架拒绝")
        XCTAssertEqual(results["srcdoc_frame"], BridgeCode.notAllowed)
        XCTAssertEqual(results["sandbox_frame"], BridgeCode.notAllowed)

        // 同地址子框架的文档地址确实等于主框架地址（按 URL 相等判主框架会被骗过），子框架里也没有 __REBATE_BRIDGE__。
        let info = try await evaluate(fixture.controller.webView, "JSON.stringify(window.__T.info)") as? String ?? "{}"
        let frames = AppWeb.object(info) ?? [:]
        XCTAssertEqual((frames["same_url_frame"] as? [String: Any])?["href"] as? String, Self.trusted + "/page")
        for label in ["same_url_frame", "srcdoc_frame", "sandbox_frame"] {
            XCTAssertEqual((frames[label] as? [String: Any])?["bridge"] as? String, "undefined", label)
        }
        XCTAssertEqual(fixture.services.envCalls, 1, "只有主框架那一次调用执行了")
    }

    func testUntrustedOriginIsRefused() async throws {
        let fixture = try makeTrusted()
        try await load(fixture.controller.webView, html: "bridge-frames", base: Self.trusted + "/page")
        // 白名单变化（不再含本页 origin）：同一页面的调用在原生按 origin 拒收。
        fixture.origins.value = ["https://other.example.test"]
        _ = try await evaluate(fixture.controller.webView, "window.__callMain('after_change', 'app.getEnv'); true")
        try await waitFor(
            fixture.controller.webView,
            "window.__T.results['after_change'] !== undefined",
            "after_change"
        )
        let results = try await resultCodes(fixture.controller.webView)
        XCTAssertEqual(results["after_change"], BridgeCode.notAllowed)
        XCTAssertEqual(fixture.services.envCalls, 0)

        // 主框架导航到白名单外的 https 地址：不在可信容器里加载，交给 ExternalWebView（Router）。
        let untrusted = try makeTrusted()
        try await loadExpectingCancel(
            untrusted.controller.webView,
            html: "bridge-frames",
            base: "https://evil.example.test/"
        )
        XCTAssertEqual(untrusted.opened.map(\.host), ["evil.example.test"])
        XCTAssertNotEqual(untrusted.controller.webView.url?.host, "evil.example.test")
    }

    func testGestureRequiredMethodWithoutTapIsRefused() async throws {
        let fixture = try makeTrusted()
        try await load(fixture.controller.webView, html: "bridge-frames", base: Self.trusted + "/page")
        _ = try await evaluate(
            fixture.controller.webView, "window.__callMain('clip', 'clipboard.write', {text: 'probe'}); true"
        )
        try await waitFor(fixture.controller.webView, "window.__T.results['clip'] !== undefined", "clip")
        let results = try await resultCodes(fixture.controller.webView)
        XCTAssertEqual(results["clip"], BridgeCode.gestureMissing)
        XCTAssertEqual(fixture.services.clipboardWrites, 0)
    }

    func testUserAgentOnlyAppendsAppSuffix() async throws {
        let fixture = try makeTrusted()
        try await load(fixture.controller.webView, html: "bridge-frames", base: Self.trusted + "/page")
        let agent = try await evaluate(fixture.controller.webView, "navigator.userAgent") as? String ?? ""
        XCTAssertTrue(agent.hasSuffix(" Couli/" + AppWeb.appVersion), agent)
        XCTAssertTrue(agent.contains("Mobile/"), "系统默认 UA 原有内容要保留：\(agent)")
    }

    /// 同源子框架（编排者三端裁定，共性第 13 条）：指向可信 origin 的子框架文档不加载；空白文档放行；跨源 https 放行（调用仍 90403）。
    func testTrustedOriginSubframeDocumentsAreNotLoaded() throws {
        let page = try XCTUnwrap(URL(string: Self.trusted + "/other"))
        XCTAssertFalse(TrustedWebController.allowsSubframe(page, isTrustedOrigin: true))
        XCTAssertTrue(TrustedWebController.allowsSubframe(
            try XCTUnwrap(URL(string: "about:srcdoc")),
            isTrustedOrigin: false
        ))
        XCTAssertTrue(TrustedWebController.allowsSubframe(
            try XCTUnwrap(URL(string: "about:blank")),
            isTrustedOrigin: false
        ))
        XCTAssertTrue(TrustedWebController.allowsSubframe(
            try XCTUnwrap(URL(string: "https://cdn.example.test/x")),
            isTrustedOrigin: false
        ))
        XCTAssertFalse(TrustedWebController.allowsSubframe(
            try XCTUnwrap(URL(string: "http://cdn.example.test/x")),
            isTrustedOrigin: false
        ))
    }

    /// 同源子框架（编排者三端裁定，共性第 13 条，S0）在真实 WKWebView 里：指向可信 origin 的子框架文档（含 sandbox 的）
    /// 在 decidePolicyFor navigationAction 里被取消，iframe 仍停在空白文档；跨源 https 子框架不计入（放行加载，调用桥仍 90403）。
    func testTrustedOriginSubframeNavigationIsCancelledInRealWebView() async throws {
        let fixture = try makeTrusted()
        let webView = fixture.controller.webView
        try await load(webView, html: "bridge-frames", base: Self.trusted + "/page")
        _ = try await evaluate(webView, "window.__addFrame('same_origin', '\(Self.trusted)/child', false); true")
        _ = try await evaluate(webView, "window.__addFrame('same_origin_sandbox', '\(Self.trusted)/x', true); true")
        _ = try await evaluate(webView, "window.__addFrame('same_url', '\(Self.trusted)/page', false); true")
        try await waitUntil { fixture.controller.blockedSubframeCount == 3 }
        _ = try await evaluate(webView, "window.__addFrame('cross', 'https://cdn.example.test/x', false); true")
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertEqual(fixture.controller.blockedSubframeCount, 3, "跨源 https 子框架不按同源取消")
        for label in ["same_origin", "same_url"] {
            let href = try await evaluate(webView, "window.__frameHref('\(label)')") as? String
            XCTAssertEqual(href, "about:blank", "\(label) 不得载入独立的可信源文档")
        }
        XCTAssertEqual(fixture.services.envCalls, 0)
    }

    /// 三端共性第 23 条：ui.setNavBar 的全部参数在真实容器里生效；做不到的（status_bar_style=light）整次 90001、什么都不改。
    func testSetNavBarAppliesEveryParameter() async throws {
        let fixture = try makeTrusted()
        let controller = fixture.controller
        let webView = controller.webView
        try await load(webView, html: "bridge-frames", base: Self.trusted + "/page")
        let params = #"{title:'T',visible:true,bg_color:'#112233',text_color:'#FFFFFF80',immersive:true,"#
            + #"hide_close:true,hide_bottom_safe_area:true,bounce:false,status_bar_style:'dark'}"#
        _ = try await evaluate(webView, "window.__callMain('nav1', 'ui.setNavBar', \(params)); true")
        try await waitFor(webView, "window.__T.results['nav1'] !== undefined", "nav1")
        let nav1Codes = try await resultCodes(webView)
        XCTAssertEqual(nav1Codes["nav1"], BridgeCode.ok)
        XCTAssertEqual(controller.navTitle, "T")
        XCTAssertTrue(controller.hideClose)
        XCTAssertFalse(webView.scrollView.bounces, "bounce=false 生效")
        XCTAssertEqual(
            controller.navStyle.background,
            BridgeColor(red: 17 / 255, green: 34 / 255, blue: 51 / 255, alpha: 1)
        )
        XCTAssertEqual(controller.navStyle.text?.alpha ?? 0, 128 / 255, accuracy: 0.001)
        XCTAssertTrue(controller.navStyle.immersive)
        XCTAssertTrue(controller.navStyle.hideBottomSafeArea)

        let more = #"{bg_gradient:['#000000','#FFFFFF'],bg_image:'https://img.example.test/a.png',visible:false}"#
        _ = try await evaluate(webView, "window.__callMain('nav2', 'ui.setNavBar', \(more)); true")
        try await waitFor(webView, "window.__T.results['nav2'] !== undefined", "nav2")
        let nav2Codes = try await resultCodes(webView)
        XCTAssertEqual(nav2Codes["nav2"], BridgeCode.ok)
        XCTAssertEqual(controller.navStyle.gradient?.count, 2)
        XCTAssertEqual(controller.navStyle.image?.host, "img.example.test")
        XCTAssertFalse(controller.navBarVisible)

        _ = try await evaluate(
            webView, "window.__callMain('nav3', 'ui.setNavBar', {status_bar_style:'light', title:'X'}); true"
        )
        try await waitFor(webView, "window.__T.results['nav3'] !== undefined", "nav3")
        let nav3Codes = try await resultCodes(webView)
        XCTAssertEqual(nav3Codes["nav3"], BridgeCode.notSupported, "做不到的参数不能返回成功")
        XCTAssertEqual(controller.navTitle, "T", "失败时什么都不改")
    }

    /// 可信容器的授权页隔离（共性第 16 条）：主框架导航到授权页不加载，也不转交第三方页容器。
    func testTrustedContainerRefusesAuthPages() async throws {
        let fixture = try makeTrusted()
        try await load(fixture.controller.webView, html: "bridge-frames", base: Self.trusted + "/page")
        _ = try await evaluate(
            fixture.controller.webView,
            "location.href = 'https://appleid.apple.com/auth/authorize'; true"
        )
        try await Task.sleep(nanoseconds: 800_000_000)
        XCTAssertEqual(fixture.controller.webView.url?.host, "h5.example.test")
        XCTAssertTrue(fixture.opened.isEmpty)
    }

    // MARK: - 第 1 轮评审

    /// R1-04（三端共性第 29 条）：旧页面的 auth.getUser 在途（等待、退避中）→ 主框架开始加载另一个可信页面，新页面
    /// 迟迟不提交、最后失败 → 旧调用必须在导航开始时就失效（不能等 didCommit），失败后也不能恢复。
    /// 目标用回环地址的空闲端口：可信白名单里有它，连接被拒，导航只开始、不提交。
    func testMainFrameNavigationStartRevokesOldCallsBeforeCommit() async throws {
        let slow = "https://127.0.0.1:47913"
        let fixture = try makeTrusted(accountKey: "account-a#1")
        fixture.origins.value = [Self.trusted, slow]
        fixture.services.holdUser = true
        let webView = fixture.controller.webView
        try await load(webView, html: "bridge-frames", base: Self.trusted + "/page")
        _ = try await evaluate(webView, "window.__callMain('user', 'auth.getUser'); true")
        try await waitUntil { !fixture.services.userValidities.isEmpty }
        let validity = try XCTUnwrap(fixture.services.userValidities.first)
        XCTAssertTrue(validity.isValid)

        _ = try await evaluate(webView, "location.href = '\(slow)/next'; true")
        try await waitUntil { !validity.isValid }
        try await waitUntil(timeout: 15) { !webView.isLoading }
        XCTAssertEqual(webView.url?.host, "h5.example.test", "新页面没有提交")
        XCTAssertFalse(validity.isValid, "导航失败后旧调用仍是失效的")
        fixture.services.releaseUsers()
    }

    /// 三端共性第 36 条：ui.setNavBar 切换 immersive 不重建承载 WKWebView 的视图（WebView 留在同一组合位置），页面不重载。
    func testImmersiveToggleKeepsWebViewInPlace() async throws {
        let fixture = try makeTrusted(hosted: false)
        let controller = fixture.controller
        let webView = controller.webView
        let hosting = UIHostingController(rootView: TrustedWebScreen(controller: controller))
        hostController(hosting)
        try await load(webView, html: "bridge-frames", base: Self.trusted + "/page")
        _ = try await evaluate(webView, "window.__marker = 'kept'; true")
        let container = try XCTUnwrap(webView.superview)

        for (label, value) in [("imm_on", "true"), ("imm_off", "false")] {
            _ = try await evaluate(
                webView,
                "window.__callMain('\(label)', 'ui.setNavBar', {immersive: \(value)}); true"
            )
            try await waitFor(webView, "window.__T.results['\(label)'] !== undefined", label)
            hosting.view.setNeedsLayout()
            hosting.view.layoutIfNeeded()
            try await Task.sleep(nanoseconds: 300_000_000)
            XCTAssertEqual(controller.navStyle.immersive, value == "true")
            XCTAssertTrue(webView.superview === container, "\(label)：承载 WebView 的视图没有重建")
            XCTAssertNotNil(webView.window)
        }
        let marker = try await evaluate(webView, "window.__marker") as? String
        XCTAssertEqual(marker, "kept", "页面没有重载")
    }

    // MARK: - 夹具

    private final class Box<Value> {
        var value: Value

        init(_ value: Value) {
            self.value = value
        }
    }

    private struct TrustedFixture {
        let controller: TrustedWebController
        let services: FakeBridgeServices
        let origins: Box<[String]>
        let openedBox: Box<[URL]>

        var opened: [URL] {
            openedBox.value
        }
    }

    private func makeTrusted(accountKey: String? = nil, hosted: Bool = true) throws -> TrustedFixture {
        let services = FakeBridgeServices()
        let origins = Box([Self.trusted])
        let opened = Box<[URL]>([])
        let controller = TrustedWebController(
            url: nil,
            appVersion: AppWeb.appVersion,
            hostFactory: { ui in
                BridgeHost(
                    protocol: {
                        BridgeProtocol(trustedOrigins: origins.value, linkPatterns: [:], shareDomains: [])
                    },
                    caller: {
                        BridgeCallerState(
                            privacy: BridgePrivacy.consented, accountKey: accountKey,
                            update: BridgeUpdateState.supported
                        )
                    },
                    services: services,
                    ui: ui,
                    awaitUpdate: { BridgeUpdateState.supported }
                )
            },
            onOpenExternal: { opened.value.append($0) },
            onClose: {}
        )
        if hosted {
            host(controller.webView)
        }
        return TrustedFixture(controller: controller, services: services, origins: origins, openedBox: opened)
    }

    /// window.__T.results 里每条标准响应的 code。
    private func resultCodes(_ webView: WKWebView) async throws -> [String: Int] {
        let text = try await evaluate(webView, "JSON.stringify(window.__T.results)") as? String ?? "{}"
        var codes: [String: Int] = [:]
        for (label, value) in AppWeb.object(text) ?? [:] {
            if let reply = value as? String, let body = AppWeb.object(reply), let code = body["code"] as? Int {
                codes[label] = code
            } else if let body = value as? [String: Any], let code = body["code"] as? Int {
                codes[label] = code
            }
        }
        return codes
    }
}

/// 只计数的业务能力替身（测试里不连真实 ApiClient、Router）。
@MainActor
final class FakeBridgeServices: BridgeServices {
    var envCalls = 0
    var clipboardWrites = 0
    /// 为真时 auth.getUser 一直等着（模拟请求在途、退避中），直到 `releaseUsers()`。
    var holdUser = false
    /// 每次 auth.getUser 拿到的调用有效性（ApiClient 发请求前要查它）。
    var userValidities: [BridgeCallValidity] = []
    private var userWaiters: [CheckedContinuation<Void, Never>] = []

    func releaseUsers() {
        let waiters = userWaiters
        userWaiters = []
        waiters.forEach { $0.resume() }
    }

    func env() -> [String: Any] {
        envCalls += 1
        return ["platform": "ios"]
    }

    func config(keys _: [String]) -> BridgeOutcome {
        .ok(["values": [:]])
    }

    func user(validity: BridgeCallValidity) async -> BridgeOutcome {
        userValidities.append(validity)
        if holdUser {
            await withCheckedContinuation { userWaiters.append($0) }
        }
        return .fail(BridgeCode.notSupported)
    }

    func h5Token(readOnly _: Bool, validity _: BridgeCallValidity) async -> BridgeOutcome {
        .fail(BridgeCode.notSupported)
    }

    func login() async -> BridgeOutcome {
        .ok(["logged_in": false])
    }

    func signedRequest(
        method _: String,
        path _: String,
        bodyJson _: String?,
        validity _: BridgeCallValidity
    ) async -> BridgeOutcome {
        .fail(BridgeCode.notSupported)
    }

    /// 给了就由它处理 nav.open（如接真实 Router：`AppBridgeServices.navOpen(router:…)`）。
    var navOpenHandler: (@MainActor (String, String, Bool) -> BridgeOutcome)?

    func navOpen(route: String, paramsJson: String, readOnlyPagesOnly: Bool) async -> BridgeOutcome {
        navOpenHandler?(route, paramsJson, readOnlyPagesOnly) ?? .ok(["opened": false])
    }

    func clipboardWrite(text _: String) -> BridgeOutcome {
        clipboardWrites += 1
        return .ok()
    }

    func clipboardRead() async -> BridgeOutcome {
        .ok(["text": ""])
    }

    func setClipboardAutoDetect(enabled _: Bool) -> BridgeOutcome {
        .ok()
    }

    func pushStatus() async -> BridgeOutcome {
        .ok(["enabled": false])
    }

    func requestPermission(type _: String, isStillValid _: @escaping @MainActor () -> Bool) async -> BridgeOutcome {
        .ok(["granted": false])
    }

    func track(name _: String) -> BridgeOutcome {
        .ok()
    }

    func reportRejected(method _: String, code _: Int) {}
}
