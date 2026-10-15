@testable import Couli
import CouliNetwork
import Foundation
import Me
import MeCore
import Router
import SwiftUI
import XCTest

/// 封禁 / 冻结说明与账户申诉（AC-S1-60、G08–G16）与 10006 统一落点（G09）。
@MainActor
final class MeRiskAppealTests: MeTestCase {
    private func risk(_ fixture: MeAppFixture) async throws -> RiskNoticeController {
        let entry = try XCTUnwrap(fixture.open("RiskNotice"))
        entry.appeared()
        let controller = try XCTUnwrap(entry.controller() as? RiskNoticeController)
        await waitUntil("说明没加载") { controller.state.phase != .loading }
        return controller
    }

    private func appeal(_ fixture: MeAppFixture) async throws -> AppealController {
        let entry = try XCTUnwrap(fixture.open("Appeal"))
        entry.appeared()
        let controller = try XCTUnwrap(entry.controller() as? AppealController)
        await waitUntil("申诉页没加载") { controller.state.phase != .loading }
        return controller
    }

    /// AC-S1-60 a：frozen（frozen_until=2026-10-15T00:00+08:00）显示原因类别与「预计恢复：10-15 00:00」，有返回，有【提交申诉】，没有处理时限。
    func testFrozenNotice() async throws {
        script.ok(
            "GET /v1/me",
            MeSamples.me(risk: "frozen", reason: "abnormal_trade", until: "2026-10-15T00:00:00+08:00")
        )
        let fixture = make()
        fixture.me.clock = { 1_760_068_800_000 }
        let controller = try await risk(fixture)
        let model = try XCTUnwrap(controller.model())
        XCTAssertEqual(model.layoutRaw, RiskLayout.frozen)
        XCTAssertEqual(fixture.me.deps.texts.text(try XCTUnwrap(model.reasonKey)), "异常交易")
        XCTAssertEqual(model.frozenUntilText, "10-15 00:00")
        XCTAssertTrue(model.showBack)
        XCTAssertEqual(model.primaryRaw, RiskNoticeView.submit)
        XCTAssertEqual(requests("GET", "/v1/withdrawals").count, 1, "进行中的提现取第一页（G16）")
    }

    /// AC-S1-60 c：banned 显示原因类别、「长期，直到解除」、无返回、底部联系客服 | 退出登录；表外原因不显示原因行（G08）。
    func testBannedNoticeAndUnknownReason() async throws {
        script.ok("GET /v1/me", MeSamples.me(risk: "banned", reason: "new_category"))
        script.ok("GET /v1/withdrawals", "{\"items\":[\(WalletSamples.withdrawal("W1")),"
            + "\(WalletSamples.withdrawal("W2", status: "PAID_API"))],\"next_cursor\":null}")
        let fixture = make()
        let controller = try await risk(fixture)
        let model = try XCTUnwrap(controller.model())
        XCTAssertEqual(model.layoutRaw, RiskLayout.banned)
        XCTAssertNil(model.reasonKey, "表外原因不显示原因行，不回落")
        XCTAssertFalse(model.showBack)
        XCTAssertEqual(model.footer, [RiskNoticeView.contactCs, RiskNoticeView.logout])
        await waitUntil("提现没到") { !controller.state.withdrawals.isEmpty }
        XCTAssertEqual(controller.state.withdrawals.map(\.id), ["W1"], "只取进行中的")
        XCTAssertEqual(fixture.me.deps.texts.text(controller.state.withdrawals[0].titleKey), "审核中")
        RiskNoticeActions.make(controller, controller.state).primary()
        XCTAssertEqual(fixture.router.path.last?.route, "Appeal")
    }

    /// AC-S1-60 c：提交申诉 → 本页进度态；处理中再次提交返回原单，页面仍是进度页；每次点击新键；维持后「维持原处理结果」与【再次申诉】。
    func testAppealSubmitProgressAndUpheld() async throws {
        script.ok("GET /v1/me", MeSamples.me(risk: "banned", reason: "malicious_rights"))
        let created = MeSamples.json(MeSamples.appeal("processing"))
        script.ok("POST /v1/me/appeals", created)
        let fixture = make()
        let controller = try await appeal(fixture)
        XCTAssertEqual(controller.layout, AppealView.submit)
        AppealActions.make(controller, controller.state).input("   ")
        XCTAssertFalse(controller.submitEnabled, "全空白不可提交")
        AppealActions.make(controller, controller.state).input(" 测试申诉，请核查。 ")
        AppealActions.make(controller, controller.state).submit()
        await waitUntil("没切进度态") { controller.layout == AppealView.progress }
        let first = try XCTUnwrap(requests("POST", "/v1/me/appeals").first)
        XCTAssertEqual(Set(first.json.keys), ["target_type", "content"], "不带 target_id（G11）")
        XCTAssertEqual(first.json["target_type"] as? String, "account")
        XCTAssertNotNil(first.header("Idempotency-Key"))
        XCTAssertEqual(fixture.router.path.last?.route, "Appeal", "不新开页")

        // 再次进入提交页（维持后的再次申诉路径），服务端对处理中的返回原单
        script.ok("GET /v1/me/appeals", MeSamples.appeals([MeSamples.appeal("upheld", closed: true)]))
        controller.load()
        await waitUntil("维持结果没到") { controller.layout == AppealView.resultUpheld }
        AppealActions.make(controller, controller.state).again()
        XCTAssertEqual(controller.layout, AppealView.submit)
        AppealActions.make(controller, controller.state).input("再说明一次")
        AppealActions.make(controller, controller.state).submit()
        await waitUntil("没切进度态") { controller.layout == AppealView.progress }
        let posts = requests("POST", "/v1/me/appeals")
        XCTAssertEqual(posts.count, 2)
        XCTAssertNotEqual(posts[0].header("Idempotency-Key"), posts[1].header("Idempotency-Key"), "每次点击新键")
        XCTAssertEqual(controller.latest?["appeal_id"] as? String, "test-AP1", "返回原单")
    }

    /// 维持后 RiskNotice 显示「最近一次申诉：维持原处理结果」与【提交申诉】；申诉摘要读取失败只影响这一行（统一错误 + trace6 + 本区重试）。
    func testUpheldLineAndAppealsFailure() async throws {
        script.ok("GET /v1/me", MeSamples.me(risk: "banned", reason: "account_security"))
        script.ok("GET /v1/me/appeals", MeSamples.appeals([MeSamples.appeal("upheld", closed: true)]))
        let fixture = make()
        let controller = try await risk(fixture)
        await waitUntil("摘要没到") { controller.model()?.upheldLine == true }
        XCTAssertEqual(controller.model()?.layoutRaw, RiskLayout.bannedUpheld)
        XCTAssertEqual(controller.model()?.primaryRaw, RiskNoticeView.submit)
        script.fail("GET /v1/me/appeals", 50001)
        controller.load()
        await waitUntil("摘要失败没显示") { controller.state.appealsError != nil }
        XCTAssertFalse(controller.model()?.upheldLine ?? true, "失败时不显示这一行")
    }

    /// 申诉提交在途时离开页面：响应回来不改已出栈的页面（写请求不取消）。
    func testSubmitInFlightThenLeave() async throws {
        script.ok("GET /v1/me", MeSamples.me(risk: "frozen", reason: "abnormal_trade"))
        script.on("POST /v1/me/appeals", .hold)
        let fixture = make()
        let controller = try await appeal(fixture)
        AppealActions.make(controller, controller.state).input("说明")
        AppealActions.make(controller, controller.state).submit()
        await waitUntil("没发出") { !WalletStubProtocol.heldIds.isEmpty }
        fixture.router.path.removeLast()
        XCTAssertTrue(controller.hasLeft)
        XCTAssertEqual(controller.state.input, "", "申诉草稿清空")
        WalletStubProtocol.release(try XCTUnwrap(WalletStubProtocol.heldIds.first),
                                   with: .envelope(code: 0, data: MeSamples.json(MeSamples.appeal("processing")),
                                                   headers: [:]))
        await settle()
        XCTAssertEqual(controller.state.phase, .loading, "已出栈的页面不被改动")
        XCTAssertNil(fixture.router.path.last { $0.route == "Appeal" })
    }

    /// 会话失效 → 登录 B → 返回：只能登录访问的 RiskNotice / Appeal 已移出导航栈，不见 A 的内容。
    func testSessionSwitchRemovesLoginOnlyPages() async throws {
        script.ok("GET /v1/me", MeSamples.me(risk: "frozen", reason: "abnormal_trade"))
        let fixture = make()
        let notice = try await risk(fixture)
        let appealPage = try await appeal(fixture)
        AppealActions.make(appealPage, appealPage.state).input("A 的申诉内容")
        try fixture.switchAccount(to: "user-b")
        await waitUntil("没换代") { fixture.me.currentIdentity.account == "user-b" }
        XCTAssertFalse(fixture.router.path.contains { $0.route == "RiskNotice" || $0.route == "Appeal" })
        XCTAssertTrue(notice.hasLeft && appealPage.hasLeft)
        XCTAssertEqual(appealPage.state.input, "")
        XCTAssertNil(notice.state.risk)
    }

    /// 42901：申诉提交按 Retry-After 禁用（执行层 + 页面）。
    func testAppealRetryAfter() async throws {
        script.ok("GET /v1/me", MeSamples.me(risk: "frozen", reason: "abnormal_trade"))
        script.fail("POST /v1/me/appeals", 42901, headers: ["Retry-After": "40"])
        let fixture = make()
        let controller = try await appeal(fixture)
        AppealActions.make(controller, controller.state).input("说明")
        AppealActions.make(controller, controller.state).submit()
        await waitUntil("42901 没提示") { controller.state.error?.key == "error.42901" }
        XCTAssertTrue(fixture.me.gates.appeal.active)
        XCTAssertEqual(controller.state.input, "说明", "保留输入")
        AppealActions.make(controller, controller.state).submit()
        await settle()
        XCTAssertEqual(requests("POST", "/v1/me/appeals").count, 1, "禁用期内不发")
    }

    // MARK: - 10006（G09）

    /// 任一请求 10006 → 统一落到 RiskNotice（栈里只留它），只开一个；记「本次运行因 10006 进入」（appealing 选封禁版式，G10）。
    func testAny10006LandsOnRiskNoticeOnce() async throws {
        script.fail("GET /v1/wallet/summary", 10006)
        script.ok("GET /v1/me", MeSamples.me(risk: "appealing", reason: "fraud_invite"))
        let fixture = make()
        fixture.router.open(RouteRequest(route: "OrderList", from: .inApp))
        let result = await fixture.client.send(ApiCall(operationId: "getWalletSummary"))
        guard case .failure(10006, _, _, _, _, _) = result else { return XCTFail("应为 10006") }
        await waitUntil("没有落到 RiskNotice") { fixture.router.path.map(\.route) == ["RiskNotice"] }
        XCTAssertTrue(fixture.me.enteredBy10006(fixture.me.computeIdentity()))
        let entry = try XCTUnwrap(fixture.me.entry(for: try XCTUnwrap(fixture.router.path.last)))
        entry.appeared()
        let controller = try XCTUnwrap(entry.controller() as? RiskNoticeController)
        await waitUntil("说明没加载") { controller.state.phase != .loading }
        XCTAssertEqual(controller.model()?.layoutRaw, RiskLayout.bannedAppealing)
        // 栈顶已是 RiskNotice：再来 10006 不重复打开
        _ = await fixture.client.send(ApiCall(operationId: "getWalletSummary"))
        await settle()
        XCTAssertEqual(fixture.router.path.map(\.route), ["RiskNotice"])
    }

    /// 发起之后用户又导航过、进过后台（scenePhase inactive 同样作废），迟到的 10006 不覆盖用户后续导航；强更显示中不打开。
    func testStale10006AndForceUpdateDoNotNavigate() async throws {
        script.on("GET /v1/wallet/summary", .hold)
        let fixture = make()
        let task = Task { await fixture.client.send(ApiCall(operationId: "getWalletSummary")) }
        await waitUntil("没发出") { !WalletStubProtocol.heldIds.isEmpty }
        fixture.me.scenePhaseChanged(.inactive)
        fixture.me.scenePhaseChanged(.active)
        WalletStubProtocol.release(try XCTUnwrap(WalletStubProtocol.heldIds.first),
                                   with: .envelope(code: 10006, data: "null", headers: [:]))
        _ = await task.value
        await settle()
        XCTAssertTrue(fixture.router.path.isEmpty, "inactive 之后作废导航许可")

        // 强更显示中
        fixture.update.on10405(minSupported: "99.0.0")
        await waitUntil("没进强更") { fixture.router.isOnForceUpdate }
        script.fail("GET /v1/wallet/summary", 10006)
        _ = await fixture.client.send(ApiCall(operationId: "getWalletSummary"))
        await settle()
        XCTAssertFalse(fixture.router.path.contains { $0.route == "RiskNotice" }, "强更优先")
    }

    /// RiskNotice 已有内容时刷新失败：保留内容并标示「没有刷新」（A34 同口径），不静默。
    func testRefreshFailureKeepsContentWithMarker() async throws {
        script.ok("GET /v1/me", MeSamples.me(risk: "frozen", reason: "abnormal_trade"))
        let fixture = make()
        let controller = try await risk(fixture)
        script.fail("GET /v1/me", 50001)
        controller.load()
        await waitUntil("刷新失败没标示") { controller.state.refreshError != nil }
        XCTAssertNotNil(controller.model(), "保留上次内容")
        XCTAssertTrue(controller.state.refreshError?.showTrace6 ?? false)
    }
}
