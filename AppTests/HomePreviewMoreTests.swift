#if DEBUG
import ClientCore
import Config
@testable import Couli
import CouliNetwork
import Foundation
import Generated
import HomeCore
import Router
import XCTest

/// HomePreview 第 2 版补充（评审 T-07、T-08、T-09、T-17）：错误分流的真实错误码、预览装配（api 公告、商品池、当前环境）、
/// 预览实例的可见性 / 后台 / 换代、两个实例内容与出口各自独立。都经真实深链、Router、ApiClient 与 AppHome.preview。
final class HomePreviewMoreTests: HomeAppTestCase {
    private func draft(_ version: Int, _ sections: [[String: Any]]) -> String {
        MeSamples.json(["page_key": "home", "version": version, "sections": sections])
    }

    private func open(_ fixture: HomeAppFixture, token: String) throws -> HomePreviewModel {
        let url = try XCTUnwrap(URL(string: "couli-debug://r/HomePreview?page_key=home&token=\(token)"))
        fixture.routing.handle(url: url)
        let top = try XCTUnwrap(fixture.router.path.last)
        XCTAssertEqual(top.route, "HomePreview")
        return fixture.home.preview(for: top)
    }

    private func forcedUpdate(_ fixture: HomeAppFixture) -> Bool {
        fixture.update.ui.status == .belowMin || fixture.router.path.last?.route == RoutePolicy.forceUpdate
            || fixture.router.lastDecision?.kind == .forceUpdate
    }

    // MARK: - T-07 错误分流

    /// 42901：真实错误码、不带编号的统一文案、写入共享闸门；禁用期内【重试】不可用且不发出；到期恢复后重试取到草稿。
    func testPreview42901UsesSharedGateAndRecoversAfterExpiry() async throws {
        script.on(
            "GET /v1/pages/home/preview", .envelope(code: 42901, data: "null", headers: ["Retry-After": "1"]),
            .envelope(code: 0, data: draft(7, [HomeAppSamples.activity("d", action: ["route": "Help"])]), headers: [:])
        )
        script.install()
        let fixture = make()
        let model = try open(fixture, token: "g1")
        await model.whenIdle()
        guard case let .failed(failure) = model.phase else { return XCTFail("应为错误态：\(model.phase)") }
        XCTAssertEqual(failure?.code, 42901)
        XCTAssertEqual(failure?.message, DefaultTexts.text("error.42901"))
        XCTAssertEqual(failure?.retryEnabled, false)
        XCTAssertTrue(fixture.home.gate.active)
        model.retry()
        await model.whenIdle()
        XCTAssertEqual(requests("GET", "/v1/pages/home/preview").count, 1, "禁用期内重试发出了")
        guard case let .failed(still) = model.phase else { return XCTFail("禁用期内重试改变了状态：\(model.phase)") }
        XCTAssertEqual(still?.code, 42901, "禁用期内重试把错误态换掉了")
        XCTAssertEqual(still?.retryEnabled, false, "禁用期内【重试】又变成可用")
        fixture.clock.advance(1000)
        await waitUntil("禁用期到了【重试】没有恢复", timeout: 8) {
            if case let .failed(failure) = model.phase {
                return failure?.retryEnabled == true
            }
            return false
        }
        model.retry()
        await model.whenIdle()
        XCTAssertEqual(model.phase, .draft)
    }

    /// 10405：照已有分流进强更，不当成草稿也不当成可重试的普通错误。
    func testPreview10405EntersForceUpdate() async throws {
        script.fail("GET /v1/pages/home/preview", 10405)
        script.install()
        let fixture = make()
        let model = try open(fixture, token: "f1")
        await model.whenIdle()
        XCTAssertNotEqual(model.phase, .draft)
        await waitUntil("10405 没有进强更") { forcedUpdate(fixture) }
    }

    /// 另一种 5xxxx（50002）保留真实错误码、文案带 trace6；传输失败给通用文案、不带编号、可重试。
    func testPreviewOtherServerErrorKeepsCodeAndTransportFailureIsRetryable() async throws {
        script.on("GET /v1/pages/home/preview", .envelope(code: 50002, data: "null", headers: [:]), .disconnect)
        script.install()
        let fixture = make()
        let model = try open(fixture, token: "e1")
        await model.whenIdle()
        guard case let .failed(server) = model.phase else { return XCTFail("应为错误态：\(model.phase)") }
        XCTAssertEqual(server?.code, 50002)
        XCTAssertTrue(server?.message.contains("6789ab") == true, "5xxxx 要带 trace6：\(server?.message ?? "")")
        model.retry()
        await model.whenIdle()
        guard case let .failed(transport) = model.phase else { return XCTFail("应为错误态：\(model.phase)") }
        XCTAssertNil(transport?.code)
        XCTAssertEqual(transport?.retryEnabled, true)
        XCTAssertFalse(transport?.message.contains("6789ab") ?? true)
    }

    // MARK: - T-08 预览装配

    /// 草稿含 api 公告与商品池：经预览装配走当前环境的 ApiClient 取公告、经首页端口取商品，结果都被采用。
    func testPreviewDraftUsesApiNoticesAndProductPool() async throws {
        script.ok("GET /v1/pages/home/preview", draft(8, [HomeAppSamples.noticeApi, HomeAppSamples.pool]))
        script.install()
        let port = TestHomePort()
        port.set(items: { _, _ in HomeAppSamples.products(["test:p1", "test:p2"]) })
        let fixture = make(port: port)
        let model = try open(fixture, token: "a1")
        await model.whenIdle()
        let controller = try XCTUnwrap(model.controller)
        XCTAssertEqual(controller.state.section("nb_api")?.items.compactMap(\.title), ["确认收货后，返利随联盟月度结算入账"])
        XCTAssertEqual(
            controller.state.section("scroll")?.items.compactMap(\.product?.productKey),
            ["test:p1", "test:p2"]
        )
        XCTAssertEqual(requests("GET", "/v1/articles").last?.query, "category=notice")
    }

    /// 预览商品池收到 10405：同样进强更（共性第 26 条，预览数据源出口）。
    func testPreviewPoolTenFourZeroFiveEntersForceUpdate() async throws {
        script.ok("GET /v1/pages/home/preview", draft(9, [HomeAppSamples.pool]))
        script.install()
        let port = TestHomePort()
        port.set(items: { _, _ in HomeAppSamples.failure(10405) })
        let fixture = make(port: port)
        let model = try open(fixture, token: "a2")
        await model.whenIdle()
        await waitUntil("预览数据源 10405 没有进强更") { forcedUpdate(fixture) }
    }

    /// 预览按「当前选中的环境」发出：切到 prod 之后再打开，请求发往 prod 的地址；首页假服务在 prod 不答假数据。
    func testPreviewFollowsCurrentEnvironment() async throws {
        script.ok("GET /v1/pages/home/preview", draft(10, [HomeAppSamples.activity("d", action: ["route": "Help"])]))
        script.install()
        let fixture = make()
        let first = try open(fixture, token: "t1")
        await first.whenIdle()
        XCTAssertEqual(
            requests("GET", "/v1/pages/home/preview").last?.host,
            AppEnvironment.test.endpoints.apiBaseURL.host
        )
        fixture.router.path = []
        try fixture.environment.switchTo(.prod)
        let second = try open(fixture, token: "t2")
        await second.whenIdle()
        XCTAssertEqual(
            requests("GET", "/v1/pages/home/preview").last?.host,
            AppEnvironment.prod.endpoints.apiBaseURL.host
        )
        let fake = try XCTUnwrap(DebugFakeHome
            .port(arguments: [DebugFakeLoginServer.launchArgument]) { fixture.environment.current })
        let call = HomeCall(anonymous: false, owner: nil, sendAllowed: { true })
        if case .success = await fake.getPage(pageKey: "home", call: call) {
            XCTFail("prod 环境下首页假服务答了假数据")
        }
    }

    // MARK: - T-09 预览实例的可见性、后台与换代

    /// 预览弹窗图片挂起时，预览被别的页面盖住 / App 进后台：图片到了也不弹；回到可见后才弹。
    func testPreviewPopupWaitsWhileCoveredOrInBackground() async throws {
        let image = "https://img.example.com/popup.png"
        for covered in [true, false] {
            WalletStubProtocol.reset()
            script.ok("GET /v1/pages/home/preview", draft(11, [HomeAppSamples.popup()]))
            script.install()
            let fixture = make()
            fixture.images.hold(image)
            let model = try open(fixture, token: covered ? "c1" : "b1")
            await waitUntil("预览弹窗图片没挂到替身上") { fixture.images.waiting(image) }
            if covered {
                fixture.open("Search")
            } else {
                AppScenePhases.apply(.background, AppScenePhases.Targets(routing: fixture.routing, home: fixture.home))
            }
            fixture.images.release(image)
            await model.whenIdle()
            XCTAssertNil(model.controller?.state.popup, covered ? "被盖住时弹了" : "后台时弹了")
            if covered {
                fixture.router.path.removeLast()
            } else {
                AppScenePhases.apply(.active, AppScenePhases.Targets(routing: fixture.routing, home: fixture.home))
            }
            await waitUntil("回到可见后没有弹") { model.controller?.state.popup != nil }
        }
    }

    /// 会话换代作废预览实例后，等它的全部工作结算：没有按新身份重取、没有迟到的副作用。
    func testInvalidatedPreviewSettlesWithoutRefetch() async throws {
        script.ok("GET /v1/pages/home/preview", draft(12, [HomeAppSamples.notice("nb", item: "n1")]))
        script.install()
        let fixture = make()
        let model = try open(fixture, token: "s1")
        await model.whenIdle()
        try fixture.switchAccount(to: "user-b")
        await waitUntil("换代后预览没有作废") { model.phase == .invalidated }
        await model.whenIdle()
        await fixture.controller.whenIdle()
        XCTAssertEqual(model.phase, .invalidated)
        XCTAssertEqual(requests("GET", "/v1/pages/home/preview").count, 1, "作废后按新身份重取了")
        XCTAssertTrue(fixture.storage.prefs.closedKeys().isEmpty)
        XCTAssertTrue(fixture.events.events.isEmpty)
    }

    // MARK: - T-17 两个实例各自独立

    /// 两个预览返回不同草稿且逆序到达：各显示自己的内容；在第一个里关公告只影响它自己；退出第二个后，第一个的内容与点击仍可用。
    func testTwoPreviewsKeepTheirOwnDraftsAndExits() async throws {
        script.on("GET /v1/pages/home/preview", .hold)
        script.install()
        let fixture = make()
        let first = try open(fixture, token: "ta")
        let second = try open(fixture, token: "tb")
        await waitUntil("两个预览请求没都挂起") { WalletStubProtocol.heldIds.count == 2 }
        let held = WalletStubProtocol.requests.filter { $0.path == "/v1/pages/home/preview" }
        let idA = try XCTUnwrap(held.first { $0.query == "token=ta" }?.id)
        let idB = try XCTUnwrap(held.first { $0.query == "token=tb" }?.id)
        let notice = HomeAppSamples.notice("nb", item: "n1")
        WalletStubProtocol.release(idB, with: .envelope(code: 0, data: draft(21, [
            notice, HomeAppSamples.activity("draft_b", action: ["route": "FindOrder"]),
        ]), headers: [:]))
        WalletStubProtocol.release(idA, with: .envelope(code: 0, data: draft(20, [
            notice, HomeAppSamples.activity("draft_a", action: ["route": "Help"]),
        ]), headers: [:]))
        await first.whenIdle()
        await second.whenIdle()
        XCTAssertEqual(first.banner?.draftVersion, 20)
        XCTAssertEqual(second.banner?.draftVersion, 21)
        let firstController = try XCTUnwrap(first.controller)
        let secondController = try XCTUnwrap(second.controller)
        XCTAssertFalse(firstController === secondController)
        XCTAssertEqual(firstController.state.sectionIds, ["nb", "draft_a"])
        XCTAssertEqual(secondController.state.sectionIds, ["nb", "draft_b"])
        firstController.closeNotice(try XCTUnwrap(firstController.state.section("nb")?.items.first?.close))
        XCTAssertEqual(firstController.state.sectionIds, ["draft_a"])
        XCTAssertEqual(secondController.state.sectionIds, ["nb", "draft_b"], "关公告影响了另一个预览")
        second.exit()
        XCTAssertEqual(fixture.router.path.map(\.route), ["HomePreview"])
        XCTAssertEqual(first.phase, .draft)
        XCTAssertEqual(first.controller?.state.sectionIds, ["draft_a"])
        first.controller?.open(try XCTUnwrap(first.controller?.state.section("draft_a")?.items.first?.tap))
        XCTAssertEqual(fixture.router.path.last?.route, "Help")
    }
}
#endif
