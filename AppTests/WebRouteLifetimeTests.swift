import BridgeHost
@testable import Couli
import Foundation
import Router
@testable import Web
import XCTest

/// APP-04 iOS 第 1 轮评审 R1-03（三端共性第 28 条）：容器页随路由真正出栈 teardown——用真实 Router 清栈、强更替换栈、
/// 关闭；只是被别的页面盖住不算。另含共性第 33 条：桥来源的 nav.open 先过 Router 的强更只读清单与基本模式守卫。
@MainActor
final class WebRouteLifetimeTests: WebViewTestCase {
    private static let origin = "https://h5.example.test"
    private var guardState = GuardState(
        privacyState: .consented, updateState: .ok, sessionState: .guest, environmentSettled: true,
        appVersion: AppWeb.appVersion, isDebugBuild: true
    )

    private func makeRouter() -> Router {
        Router(
            pendingStore: PendingActionStore(backend: MemoryPendingBackend()),
            state: { [unowned self] in guardState }
        )
    }

    private func makeTrusted(_ services: FakeBridgeServices) -> TrustedWebController {
        TrustedWebController(
            url: nil,
            appVersion: AppWeb.appVersion,
            hostFactory: { ui in
                BridgeHost(
                    protocol: { BridgeProtocol(trustedOrigins: [Self.origin], linkPatterns: [:], shareDomains: []) },
                    caller: {
                        BridgeCallerState(
                            privacy: BridgePrivacy.consented, accountKey: "account-a#1",
                            update: BridgeUpdateState.supported
                        )
                    },
                    services: services,
                    ui: ui,
                    awaitUpdate: { BridgeUpdateState.supported }
                )
            },
            onOpenExternal: { _ in },
            onClose: {}
        )
    }

    /// 页面发起 auth.getUser，请求在途（等待响应或退避）。返回这次调用拿到的有效性与回包记录。
    private func startUserCall(
        _ controller: TrustedWebController,
        _ services: FakeBridgeServices,
        id: String
    ) async throws -> (BridgeCallValidity, ReplyBox) {
        let replies = ReplyBox()
        let host = try XCTUnwrap(controller.host)
        host.handle(
            raw: #"{"v":1,"id":"\#(id)","method":"auth.getUser","params":{}}"#,
            origin: Self.origin, isMainFrame: true, userGesture: false
        ) { replies.values.append($0) }
        for _ in 0..<50 where services.userValidities.count < 1 {
            await Task.yield()
        }
        let validity = try XCTUnwrap(services.userValidities.last, "auth.getUser 应已进入能力实现")
        XCTAssertTrue(validity.isValid)
        return (validity, replies)
    }

    private func webPage() -> RouteDestination {
        RouteDestination(route: "WebPage", params: ["url": .string(Self.origin + "/page")])
    }

    /// 评审原场景：可信页 auth.getUser 在途 → nav.open(Home) 使 Router 清空导航栈 → 容器 teardown，调用立即失效、
    /// 回 90500、之后不再接受新调用。被别的页面盖住时不 teardown。
    func testRouterClearingStackTearsDownTrustedContainer() async throws {
        let router = makeRouter()
        let lifetimes = WebRouteLifetimes(router: router)
        let services = FakeBridgeServices()
        services.holdUser = true
        let controller = makeTrusted(services)
        let page = webPage()
        router.path.append(page)
        lifetimes.register(page) { [weak controller] in controller?.teardown() }
        let (validity, replies) = try await startUserCall(controller, services, id: "u1")

        // 被盖住：目的地仍在栈里，不 teardown。
        router.path.append(RouteDestination(route: "Settings"))
        XCTAssertTrue(validity.isValid, "只是被盖住，不算出栈")
        XCTAssertEqual(lifetimes.registeredCount, 1)

        // 真实 Router 清栈（打开 Tab 根路由 Home）。
        let decision = router.open(RouteRequest(route: "Home", from: .inApp))
        XCTAssertEqual(decision.kind, .open)
        XCTAssertTrue(router.path.isEmpty)
        XCTAssertFalse(validity.isValid, "清栈后在途调用的有效性立即撤销，ApiClient 不再发出、不再重试")
        XCTAssertEqual(ReplyBox.code(replies.values.last.flatMap(\.self)), BridgeCode.nativeError)
        XCTAssertEqual(lifetimes.registeredCount, 0)

        // 之后的新调用一律不执行（宿主已 dispose）。
        services.holdUser = false
        let late = ReplyBox()
        controller.host?.handle(
            raw: #"{"v":1,"id":"u2","method":"auth.getUser","params":{}}"#,
            origin: Self.origin, isMainFrame: true, userGesture: false
        ) { late.values.append($0) }
        await Task.yield()
        XCTAssertEqual(services.userValidities.count, 1, "teardown 后不再执行任何调用")
        services.releaseUsers()
    }

    /// 第 2 轮评审 R2-04（三端共性第 43 条）：真实 WKWebView 里的 WebPage 经 BridgeHost 调 nav.open(Home)，真实 Router
    /// 清栈 → 本容器 teardown。发起导航的这次调用先按成功结算（页面收到 code=0、opened=true），其他在途调用照常 90500。
    func testNavOpenHomeFromWebPageRepliesSuccessBeforeTeardown() async throws {
        let router = makeRouter()
        let lifetimes = WebRouteLifetimes(router: router)
        let services = FakeBridgeServices()
        services.holdUser = true
        services.navOpenHandler = { route, params, readOnly in
            AppBridgeServices.navOpen(router: router, route: route, paramsJson: params, readOnlyPagesOnly: readOnly)
        }
        let controller = makeTrusted(services)
        host(controller.webView)
        try await load(controller.webView, html: "bridge-frames", base: Self.origin + "/page")
        let page = webPage()
        router.path.append(page)
        lifetimes.register(page) { [weak controller] in controller?.teardown() }

        // 另一条在途调用（auth.getUser 等待中）：出栈时照常作废。
        _ = try await evaluate(controller.webView, "window.__callMain('other', 'auth.getUser'); true")
        for _ in 0..<100 where services.userValidities.isEmpty {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let other = try XCTUnwrap(services.userValidities.first)

        _ = try await evaluate(controller.webView, "window.__callMain('nav', 'nav.open', {route: 'Home'}); true")
        try await waitFor(controller.webView, "window.__T.results['nav'] !== undefined", "nav")
        try await waitFor(controller.webView, "window.__T.results['other'] !== undefined", "other")
        let text = try await evaluate(controller.webView, "JSON.stringify(window.__T.results)") as? String ?? "{}"
        let results = AppWeb.object(text) ?? [:]
        let nav = (results["nav"] as? String).flatMap(AppWeb.object) ?? [:]
        XCTAssertEqual(nav["code"] as? Int, BridgeCode.ok, "发起导航的调用按成功回包：\(text)")
        XCTAssertEqual((nav["data"] as? [String: Any])?["opened"] as? Bool, true)
        XCTAssertEqual(ReplyBox.code(results["other"] as? String), BridgeCode.nativeError, "其他在途调用作废")
        XCTAssertFalse(other.isValid)
        XCTAssertTrue(router.path.isEmpty, "Home 清栈")
        XCTAssertEqual(lifetimes.registeredCount, 0, "容器已 teardown")
        XCTAssertEqual(controller.host?.inFlightCount, 0)
        services.releaseUsers()
    }

    /// 强更替换导航栈：栈里的可信容器与第三方页容器都 teardown。
    func testForceUpdateReplacingStackTearsDownContainers() async throws {
        let router = makeRouter()
        let lifetimes = WebRouteLifetimes(router: router)
        let services = FakeBridgeServices()
        services.holdUser = true
        let trusted = makeTrusted(services)
        let external = ExternalWebController(url: nil, appVersion: AppWeb.appVersion, deps: Self.externalDeps()) {}
        let page = webPage()
        let externalPage = RouteDestination(
            route: "ExternalPage",
            params: ["url": .string("https://shop.example.test/")]
        )
        router.path.append(page)
        lifetimes.register(page) { [weak trusted] in trusted?.teardown() }
        router.path.append(externalPage)
        lifetimes.register(externalPage) { [weak external] in external?.teardown() }
        let (validity, _) = try await startUserCall(trusted, services, id: "f1")

        router.enterForceUpdate()
        XCTAssertEqual(router.path.map(\.route), [RoutePolicy.forceUpdate])
        XCTAssertFalse(validity.isValid)
        XCTAssertTrue(external.tornDown)
        services.releaseUsers()
    }

    /// 关闭（从栈里移除自己）同样 teardown；上面还盖着的页面一起出栈。
    func testClosingContainerTearsItDown() async throws {
        let router = makeRouter()
        let lifetimes = WebRouteLifetimes(router: router)
        let services = FakeBridgeServices()
        services.holdUser = true
        let controller = makeTrusted(services)
        let page = webPage()
        router.path.append(page)
        lifetimes.register(page) { [weak controller] in controller?.teardown() }
        let (validity, _) = try await startUserCall(controller, services, id: "c1")
        router.close(page)
        XCTAssertFalse(validity.isValid)
        services.releaseUsers()
    }

    // MARK: - 共性第 33 条

    /// 桥来源的 nav.open（AppBridgeServices 用 RouteSource.bridge）：强更结果未知时只读清单外的路由不打开、导航栈不变；
    /// 基本模式下基本模式清单外的路由不打开。同一路由由 App 内原生操作打开不受只读清单限制（对照）。
    func testBridgeSourcedOpenPassesUpdateAndBasicModeGuardsBeforeSideEffects() {
        let router = makeRouter()
        guardState.update = .unknown
        let bridged = router.open(RouteRequest(route: "Settings", params: [:], source: RouteSource.bridge.rawValue))
        XCTAssertNotEqual(bridged.kind, .open)
        XCTAssertTrue(router.path.isEmpty, "被拦时不产生任何导航副作用")
        let native = router.open(RouteRequest(route: "Settings", from: .inApp))
        XCTAssertEqual(native.kind, .open)
        router.path = []

        guardState.update = .ok
        guardState.privacy = .basicMode
        let basic = router.open(RouteRequest(route: "Wallet", params: [:], source: RouteSource.bridge.rawValue))
        XCTAssertNotEqual(basic.kind, .open)
        XCTAssertNotEqual(basic.kind, .openReadonly)
        XCTAssertTrue(router.path.isEmpty)
    }

    // MARK: - 夹具

    @MainActor
    final class ReplyBox {
        var values: [String?] = []

        static func code(_ reply: String?) -> Int? {
            reply.flatMap(AppWeb.object)?["code"] as? Int
        }
    }

    private static func externalDeps() -> ExternalWebDependencies {
        ExternalWebDependencies(
            policy: ExternalNavPolicy(bundledLinkPatterns: [:]),
            linkPatterns: { nil },
            consented: { true },
            productIntercept: { true },
            navHostSampleBp: { 0 },
            track: { _ in },
            onProductIntent: { _, _ in false },
            onSearch: {},
            searchLabel: "search"
        )
    }
}
