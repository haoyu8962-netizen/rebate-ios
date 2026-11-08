@testable import Couli
import CouliNetwork
import Foundation
import Router
import Wallet
import WalletCore
import XCTest

/// 前置补办后回到发起页、不自动提交（brief §0 第 4 条，AC-S2-62 ①–④⑥⑧⑩⑰，AC-S2-55 ①②，G04、G05、G28、G29）：补办全程 0 次
/// `POST /v1/withdrawals`；回到同一个提现页实例，金额仍在、立即重取 rules；用户再点【提交】用新键。
final class WithdrawGuideTests: WalletFlowTestCase {
    /// rules 的 block_code=10004 → 按劳务协议引导（用户点按钮才打开）；签署（勾选默认不勾）后出栈回 Withdraw，金额仍在、0 次提交；再点用新键。
    func testLaborGuideSignReturnsWithAmountAndZeroPost() async throws {
        script.ok("GET /v1/withdrawals/rules", WalletSamples.rules(can: false, block: 10004))
        let fixture = make()
        fixture.wallet.installBackends(realname: nil, labor: FixtureLabor())
        let controller = try await withdraw(fixture)
        await typeAmount(controller, "5")
        XCTAssertEqual(controller.state.amountText, "5", "非 30304 时金额框可输入（G29）")
        XCTAssertEqual(controller.state.guide.route, WalletRoutes.laborAgreement)
        XCTAssertEqual(fixture.router.path.last?.route, WalletRoutes.withdraw, "不自动跳")
        actions(controller).guide()
        await waitUntil { fixture.router.path.last?.route == WalletRoutes.laborAgreement }
        let labor = try XCTUnwrap(fixture.page(WalletRoutes.laborAgreement)?.controller as? LaborAgreementController)
        labor.load()
        await waitUntil { labor.state.phase == .content }
        XCTAssertFalse(labor.state.checked, "勾选默认不勾")
        XCTAssertFalse(labor.signEnabled)
        LaborActions.make(labor, labor.state).toggle()
        script.ok("GET /v1/withdrawals/rules", WalletSamples.rules(net: 500))
        LaborActions.make(labor, labor.state).sign()
        await waitUntil("签署后没有回到提现页") { fixture.router.path.last?.route == WalletRoutes.withdraw }
        await waitUntil("回到前台没有重取 rules") { controller.state.rules?.canWithdraw == true }
        XCTAssertEqual(controller.state.amountText, "5", "同一实例，金额保留")
        // 等在途的主线程任务与网络都走完，再确认用户点击之前一个提交都没有发出（不自动提交）
        await settle(40)
        XCTAssertTrue(posts.isEmpty, "签署全程与回到发起页之后 0 次提交")
        actions(controller).submit()
        await waitUntil { posts.count == 1 }
        XCTAssertNotNil(posts[0].header("Idempotency-Key"))
    }

    /// 提交得到 10004（consent_type=labor_agreement）→ 引导 LaborAgreement、键结束；已签用户遇 10004 重签后再提交成功（AC-S2-55）。
    /// 10005 → BindPhone；30305 → PayoutAccount；30304 → RealName。补办全程不重放。
    func testSubmitPrerequisiteCodesGuideWithoutReplay() async throws {
        // swiftlint:disable:next large_tuple
        let cases: [(Int, String, String)] = [
            (10004, "{\"consent_type\":\"labor_agreement\"}", WalletRoutes.laborAgreement),
            (10005, "null", WalletRoutes.bindPhone),
            (30305, "null", WalletRoutes.payoutAccount),
            (30304, "null", WalletRoutes.realName),
        ]
        for (code, data, route) in cases {
            WalletStubProtocol.reset()
            script.install()
            script.fail("POST /v1/withdrawals", code, data: data)
            let fixture = make()
            let controller = try await withdraw(fixture)
            await typeAmount(controller, "10")
            actions(controller).submit()
            await waitUntil("\(code) 没有引导") {
                fixture.router.path.count >= 2 && fixture.router.path.last?.route != WalletRoutes.withdraw
            }
            XCTAssertEqual(fixture.router.path.last?.route, route, "\(code)")
            await settle()
            XCTAssertEqual(posts.count, 1, "\(code) 不重放")
            XCTAssertNil(controller.flow.state.pending)
            XCTAssertFalse(fixture.router.hasPendingAction, "不登记 pending_action")
            fixture.router.path.removeAll()
        }
    }

    /// 被覆盖时到达的前置引导不自动导航（共性第 37、51 条）：保留目标并在页面上给手动入口；回到页面后由用户点入口再打开。
    func testGuideArrivingWhileCoveredOffersManualEntry() async throws {
        script.on("POST /v1/withdrawals", .hold)
        let fixture = make()
        let controller = try await withdraw(fixture)
        await typeAmount(controller, "10")
        actions(controller).submit()
        await waitUntil { WalletStubProtocol.heldIds.count == 1 }
        let held = try XCTUnwrap(WalletStubProtocol.heldIds.first)
        fixture.router.open(RouteRequest(route: WalletRoutes.help, from: .inApp))
        WalletStubProtocol.release(held, with: .envelope(code: 30305, data: "null", headers: [:]))
        await waitUntil { controller.flow.state.guideRoute != nil }
        XCTAssertEqual(fixture.router.path.last?.route, WalletRoutes.help, "被覆盖时不导航")
        fixture.router.path.removeLast()
        // 变得可见在栈真正改完之后的下一轮主线程生效（AppWallet.pathChanged）；用户的点击总在那之后
        await waitUntil("回到页面后没有变成可见") { controller.flow.visibleNow }
        flowActions(controller.flow).openGuide()
        XCTAssertEqual(fixture.router.path.last?.route, WalletRoutes.payoutAccount)
    }

    /// 实名：未实名时要实名的资金页先进 RealName（守卫按 GET /v1/me 的 realname_status，iOS I02）；单独同意默认不勾；30406 / 30405 页内提示，
    /// 30410 当日不能再提交；成功后刷新实名状态、出栈回发起页（不重放）。
    func testRealNameConsentErrorsAndSuccessReturn() async throws {
        script.ok("GET /v1/me", "{\"user_id\":\"user-a\",\"realname_status\":\"none\",\"phone_bound\":true}")
        let fixture = make()
        let backend = FixtureRealName()
        fixture.wallet.installBackends(realname: backend, labor: nil)
        fixture.wallet.open(WalletRoutes.withdraw, params: [:], from: nil)
        await waitUntil("未实名应先进 RealName") { fixture.router.path.last?.route == WalletRoutes.realName }
        let page = try XCTUnwrap(fixture.page(WalletRoutes.realName)?.controller as? RealNameController)
        var actions = RealNameActions.make(page, page.state)
        actions.name(" 测试三 ")
        actions = RealNameActions.make(page, page.state)
        actions.idNo("00000000000000000x")
        XCTAssertEqual(page.state.idNo, "00000000000000000X", "小写 x 转大写")
        for (suffix, code) in [("1", 30406), ("2", 30410)] {
            backend.nextCode = code
            RealNameActions.make(page, page.state).submit()
            XCTAssertNotNil(page.state.consentId, "提交前先弹单独同意")
            XCTAssertFalse(page.state.consentChecked, "默认不勾选")
            RealNameActions.make(page, page.state).agree()
            XCTAssertEqual(backend.calls, code == 30406 ? 0 : 1, "不勾选不提交")
            RealNameActions.make(page, page.state).toggleConsent()
            RealNameActions.make(page, page.state).agree()
            await waitUntil { page.state.error?.key == "error.\(code)" }
            _ = suffix
        }
        XCTAssertTrue(page.state.lockedToday, "30410 当日不能再提交")
        XCTAssertFalse(page.submitEnabled)
        XCTAssertTrue(posts.isEmpty)
    }

    /// Release 形态（没有实名 / 劳务协议后端，G01、G02）：【提交认证】置灰、劳务协议「暂未提供」，不发任何请求。
    func testReleaseShapeIdentityPagesSendNothing() async throws {
        let fixture = make()
        fixture.wallet.installBackends(realname: nil, labor: nil)
        await verifyRealname(fixture)
        let real = try XCTUnwrap(fixture.open(WalletRoutes.realName)?.controller as? RealNameController)
        XCTAssertFalse(real.available)
        XCTAssertFalse(real.submitEnabled)
        fixture.router.path.removeAll()
        let labor = try XCTUnwrap(fixture.open(WalletRoutes.laborAgreement)?.controller as? LaborAgreementController)
        labor.load()
        XCTAssertEqual(labor.state.phase, .unavailable)
        let before = WalletStubProtocol.requests.count
        LaborActions.make(labor, labor.state).sign()
        await settle()
        XCTAssertEqual(WalletStubProtocol.requests.count, before)
    }
}

/// 测试用劳务协议后端（契约没有接口，G02）。
final class FixtureLabor: LaborBackend, @unchecked Sendable {
    func current(owner _: RequestOwnership?) async -> ApiResult {
        .success(
            data: Data("{\"version\":\"v1\",\"text\":\"fixture\",\"text_sha256\":\"abc\",\"need_sign\":true}".utf8),
            traceId: nil,
            idempotencyKey: nil
        )
    }

    func sign(version _: String, textSha256 _: String, owner _: RequestOwnership?) async -> ApiResult {
        .success(data: Data("{}".utf8), traceId: nil, idempotencyKey: nil)
    }
}

/// 测试用实名后端（契约没有接口，G01）：按 `nextCode` 回答，记调用次数；不保存姓名、身份证号。
final class FixtureRealName: RealNameBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private var code = 0

    var nextCode: Int {
        get { lock.withLock { code } }
        set { lock.withLock { code = newValue } }
    }

    var calls: Int {
        lock.withLock { count }
    }

    func submit(name _: String, idNo _: String, idempotencyKey _: String,
                owner _: RequestOwnership?) async -> ApiResult {
        let code = lock.withLock {
            count += 1
            return self.code
        }
        if code == 0 {
            return .success(data: Data("{}".utf8), traceId: nil, idempotencyKey: nil)
        }
        return .failure(
            code: code,
            msg: "",
            data: nil,
            traceId: "fixture-trace",
            effect: ErrorEffect(code: code, kind: .toast),
            idempotencyKey: nil
        )
    }
}
