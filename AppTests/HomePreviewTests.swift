#if DEBUG
import ClientCore
import Config
@testable import Couli
import CouliNetwork
import Foundation
import Generated
import HomeCore
import Privacy
import Router
import XCTest

/// HomePreview（TECH-11，03 §3.6，G24；AC-S1-86 ③④ = AC-HOME-07 客户端部分；brief §2 第 14 条；cross-platform-lessons 第
/// 5、10–13、16、20 条）。
/// 只在 Debug / Staging：经真实深链解析与 Router（debug_only 路由由 App 的 DebugOnlyRoutes 合并）、真实 ApiClient 调 previewPage（本地假服务回答）。
final class HomePreviewTests: HomeAppTestCase {
    private let draft: [String: Any] = [
        "page_key": "home", "version": 7,
        "sections": [
            HomeAppSamples.notice("nb", item: "n1"),
            HomeAppSamples.activity("draft_act", action: ["route": "Help"]),
            ["id": "bad", "type": "banner", "version": 2, "props": ["height_ratio": 0.4, "autoplay_ms": 0],
             "data_source": ["kind": "static", "items": [] as [Any]]],
            HomeAppSamples.popup(),
        ],
    ]

    private func deepLink(_ token: String, extra: String = "") throws -> URL {
        try XCTUnwrap(URL(string: "couli-debug://r/HomePreview?page_key=home&token=\(token)\(extra)"))
    }

    private func openPreview(_ fixture: HomeAppFixture, token: String) throws -> HomePreviewModel {
        fixture.routing.handle(url: try deepLink(token))
        let top = try XCTUnwrap(fixture.router.path.last, "深链没有打开预览")
        XCTAssertEqual(top.route, "HomePreview")
        let model = fixture.home.preview(for: top)
        XCTAssertTrue(model === fixture.home.preview(for: top), "同一个导航实例只有一个预览模型")
        return model
    }

    /// 深链 …/r/HomePreview?page_key=home&token=t1 → 用当前环境调 previewPage → 草稿经同一渲染器显示；预览条显示页面键、环境名、草稿版本、
    /// 「HH:mm 前有效」（收到 token 起 10 分钟）；token 不进显示文字与埋点；不切换环境；预览期间首页 LKG、弹窗计数、关闭记录都不变，没有埋点。
    func testDeepLinkPreviewShowsDraftReadOnly() async throws {
        script.ok("GET /v1/pages/home/preview", MeSamples.json(draft))
        script.install()
        let fixture = make()
        await fixture.launch()
        let identity = fixture.controller.identity
        let lkgBefore = fixture.lkgVersion(identity)
        let model = try openPreview(fixture, token: "t1-secret")
        await model.whenIdle()
        XCTAssertEqual(model.phase, .draft)
        let requests = requests("GET", "/v1/pages/home/preview")
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.query, "token=t1-secret")
        let banner = try XCTUnwrap(model.banner)
        XCTAssertEqual(banner.pageKey, "home")
        XCTAssertEqual(banner.environmentName, fixture.environment.current.id)
        XCTAssertEqual(banner.draftVersion, 7)
        XCTAssertEqual(banner.validUntil, "12:10")
        XCTAssertFalse(String(describing: banner).contains("t1-secret"), "token 进了显示文字")
        let controller = try XCTUnwrap(model.controller)
        XCTAssertEqual(controller.state.sectionIds, ["nb", "draft_act"], "草稿用同一渲染器")
        XCTAssertEqual(controller.state.dropped.map(\.id), ["bad"], "页底列出被丢弃的卡与原因")
        // 草稿里的 popup 立即弹一次，不计数；关闭公告不写记录
        let popup = try XCTUnwrap(controller.state.popup)
        controller.popupShown(popup.ticket)
        controller.closePopup(popup.ticket)
        controller.closeNotice(try XCTUnwrap(controller.state.section("nb")?.items.first?.close))
        XCTAssertEqual(fixture.storage.prefs.shownToday(sectionId: "popup", nowMs: fixture.clock.now), 0)
        XCTAssertTrue(fixture.storage.prefs.closedKeys().isEmpty)
        XCTAssertEqual(fixture.lkgVersion(identity), lkgBefore)
        XCTAssertTrue(fixture.events.events.isEmpty)
        XCTAssertEqual(fixture.environment.current, .test, "不因扫码切换环境")
        // 卡片可点，跳转照常经 Router
        controller.open(try XCTUnwrap(controller.state.section("draft_act")?.items.first?.tap))
        XCTAssertEqual(fixture.router.path.last?.route, "Help")
    }

    /// 30701 → 过期 / 环境不符页；【退出预览】只关闭本实例（不改原 Tab、不清别的页）；【切换环境】打开已有的调试环境切换入口，自己不切。
    func testExpiredShowsExitAndSwitchEnvironment() async throws {
        script.fail("GET /v1/pages/home/preview", 30701)
        script.install()
        let fixture = make()
        await fixture.launch()
        _ = fixture.routing.selectTab(.orders)
        let tabRoot = fixture.router.tabRoot
        fixture.open("Search")
        let model = try openPreview(fixture, token: "t2")
        await model.whenIdle()
        XCTAssertEqual(model.phase, .expired)
        var opened = 0
        fixture.home.onOpenEnvironmentSwitch = { opened += 1 }
        model.switchEnvironment()
        XCTAssertEqual(opened, 1)
        XCTAssertEqual(fixture.environment.current, .test)
        model.exit()
        XCTAssertEqual(fixture.router.path.map(\.route), ["Search"], "只关闭本实例")
        XCTAssertEqual(fixture.router.tabRoot, tabRoot, "不改原来所在的 Tab")
    }

    /// 其他错误：统一错误分流（保留真实错误码，5xxxx 带 trace6）+【重试】；重试成功后显示草稿。42901 写入共享闸门，【重试】随之置灰。
    func testOtherErrorsUseUnifiedTextAndRetry() async throws {
        script.on(
            "GET /v1/pages/home/preview", .envelope(code: 50001, data: "null", headers: [:]),
            .envelope(code: 0, data: MeSamples.json(draft), headers: [:])
        )
        script.install()
        let fixture = make()
        let model = try openPreview(fixture, token: "t3")
        await model.whenIdle()
        guard case let .failed(failure) = model.phase else {
            return XCTFail("应为错误态：\(model.phase)")
        }
        XCTAssertEqual(failure?.code, 50001)
        // 假服务的 trace_id 是 stub-trace-0123456789ab
        XCTAssertTrue(failure?.message.contains("6789ab") == true, "5xxxx 要带 trace6：\(failure?.message ?? "")")
        XCTAssertEqual(failure?.retryEnabled, true)
        model.retry()
        await model.whenIdle()
        XCTAssertEqual(model.phase, .draft)
    }

    /// 出栈（返回）时同步作废 previewPage：迟到的响应不再显示草稿。
    func testLeavingCancelsInFlightPreview() async throws {
        script.on("GET /v1/pages/home/preview", .hold)
        script.install()
        let fixture = make()
        let model = try openPreview(fixture, token: "t4")
        await waitUntil("预览请求没发出") { !WalletStubProtocol.heldIds.isEmpty }
        // 返回（出栈）是同步出口：AppHome 按 Router 栈变化作废本实例的请求，不靠视图的 onDisappear
        fixture.router.path.removeLast()
        for id in WalletStubProtocol.heldIds {
            WalletStubProtocol.release(id, with: .envelope(code: 0, data: MeSamples.json(draft), headers: [:]))
        }
        await model.whenIdle()
        XCTAssertNotEqual(model.phase, .draft)
        XCTAssertNil(model.controller)
    }

    /// 每个预览导航实例各有自己的模型；退出第二个不影响第一个（共性第 11、12 条）。
    func testTwoPreviewInstancesAreIndependent() async throws {
        script.ok("GET /v1/pages/home/preview", MeSamples.json(draft))
        script.install()
        let fixture = make()
        let first = try openPreview(fixture, token: "ta")
        let second = try openPreview(fixture, token: "tb")
        XCTAssertFalse(first === second)
        await first.whenIdle()
        await second.whenIdle()
        second.exit()
        XCTAssertEqual(fixture.router.path.map(\.route), ["HomePreview"])
        XCTAssertEqual(first.phase, .draft)
    }

    /// 预览打开期间会话换代：作废本实例（不按新身份自动重取），只留【退出预览】（H19）。
    func testSessionChangeInvalidatesPreviewInstance() async throws {
        script.ok("GET /v1/pages/home/preview", MeSamples.json(draft))
        script.install()
        let fixture = make()
        let model = try openPreview(fixture, token: "t5")
        await model.whenIdle()
        XCTAssertEqual(model.phase, .draft)
        try fixture.switchAccount(to: "user-b")
        await waitUntil("会话换代后预览没有作废") { model.phase == .invalidated }
        XCTAssertNil(model.controller?.state.popup)
        XCTAssertEqual(requests("GET", "/v1/pages/home/preview").count, 1, "不得按新身份自动重取")
    }

    /// 深链只取 page_key、token：多余参数（host）不进请求（G24 ②；整条拒绝还是丢弃多余参数由已有解析器决定，两种都不得带出去）。
    func testExtraDeepLinkParamsNeverReachPreviewRequest() async throws {
        script.ok("GET /v1/pages/home/preview", MeSamples.json(draft))
        script.install()
        let fixture = make()
        fixture.routing.handle(url: try deepLink("t6", extra: "&host=https%3A%2F%2Fother.example.com"))
        if let top = fixture.router.path.last, top.route == "HomePreview" {
            let model = fixture.home.preview(for: top)
            await model.whenIdle()
        }
        for request in requests("GET", "/v1/pages/home/preview") {
            XCTAssertEqual(request.query, "token=t6")
        }
        XCTAssertTrue(WalletStubProtocol.requests.allSatisfy { !$0.path.contains("other.example.com") })
    }

    /// 不申请、不声明相机权限，任何构建都不加扫码代码（BR-ID-13 细则；红线 2）。
    func testNoCameraPermissionOrScanningCode() throws {
        XCTAssertNil(Bundle.main.object(forInfoDictionaryKey: "NSCameraUsageDescription"))
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while !FileManager.default.fileExists(atPath: directory.appendingPathComponent("contract.lock").path) {
            directory = directory.deletingLastPathComponent()
        }
        for folder in ["App", "Packages/Core/Sources", "Packages/Features/Sources"] {
            let root = directory.appendingPathComponent(folder)
            for case let path as String in FileManager.default.enumerator(atPath: root.path) ?? NSEnumerator() {
                guard path.hasSuffix(".swift") || path.hasSuffix(".plist") else { continue }
                let text = try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
                for word in [
                    "AVCaptureDevice",
                    "AVCaptureSession",
                    "AVMetadataObject",
                    "NSCameraUsageDescription",
                    "DataScanner",
                ] {
                    XCTAssertFalse(text.contains(word), "\(folder)/\(path) 含 \(word)")
                }
            }
        }
    }

    /// 测试包连 prod 时，首页的 Debug 假服务不答假数据（只在环境允许 MOCK_DATA 时接管；共性第 16 条，F-X-02）。
    func testDebugFakeHomeAnswersOnlyWhenEnvironmentAllowsMockData() async throws {
        var current = AppEnvironment.test
        let port = try XCTUnwrap(
            DebugFakeHome.port(arguments: [DebugFakeLoginServer.launchArgument], environment: { current }),
            "带假服务启动参数时要有首页假服务"
        )
        let call = HomeCall(anonymous: false, owner: nil, sendAllowed: { true })
        guard case .success = await port.getPage(pageKey: "home", call: call) else {
            return XCTFail("test 环境假服务应答页面")
        }
        current = .prod
        if case .success = await port.getPage(pageKey: "home", call: call) {
            XCTFail("prod 环境假服务答了假数据")
        }
        if case .success = await port.listSectionItems(pageKey: "home", sectionId: "feed", cursor: nil, call: call) {
            XCTFail("prod 环境假服务答了假商品")
        }
        XCTAssertNil(DebugFakeHome.port(arguments: [], environment: { .test }), "没带启动参数不接管")
    }
}
#endif
