@testable import Couli
import CouliNetwork
import Foundation
import Generated
import Router
import Wallet
import WalletCore
import XCTest

/// 提交（AC-S2-62、G17、G19）：新键与原始请求体、10003 二次验证后沿用原键重放 1 次、10002 刷新后沿用原键自动重发、成功以 WithdrawRecords
/// {withdrawal_id} 替换提现页并通知钱包刷新、44001 弹窗与客服出口、30306 阻断。
final class WithdrawSubmitTests: WalletFlowTestCase {
    /// 成功 → Router 以 WithdrawRecords {withdrawal_id} 替换本页（返回时回到钱包），钱包摘要被通知刷新；请求带新键与原始请求体。
    func testSubmitSuccessReplacesWithRecordsAndRefreshesWallet() async throws {
        let fixture = make()
        let wallet = try XCTUnwrap(fixture.open(WalletRoutes.wallet)?.controller as? WalletController)
        wallet.load()
        await waitUntil { wallet.state.summary != nil }
        let controller = try await withdraw(fixture)
        await typeAmount(controller, "10")
        let summaries = WalletStubProtocol.requests("GET", "/v1/wallet/summary").count
        actions(controller).submit()
        await waitUntil("没有进提现记录") { fixture.router.path.last?.route == WalletRoutes.withdrawRecords }
        XCTAssertEqual(fixture.router.path.map { $0.route ?? "" }, [WalletRoutes.wallet, WalletRoutes.withdrawRecords])
        XCTAssertEqual(fixture.router.path.last?.params, [WalletRoutes.withdrawalId: .string("W-new")])
        let post = try XCTUnwrap(posts.first)
        XCTAssertEqual(post.json["amount_fen"] as? Int, 1000)
        XCTAssertEqual(post.json.count, 1, "请求体只有 amount_fen")
        XCTAssertNotNil(post.header("Idempotency-Key"))
        XCTAssertNotNil(post.header("X-Sign"), "签名走网络层真实管线")
        await waitUntil("钱包没有被通知刷新") {
            WalletStubProtocol.requests("GET", "/v1/wallet/summary").count > summaries
        }
        XCTAssertEqual(controller.state.announce?.key, "withdraw.submitted_spoken")
    }

    /// 10003 → 二次验证面板：打开即发码（phone、purpose=step_up、action=withdraw）；验证成功后沿用原键重放 1 次并带 X-Step-Up-Token；
    /// token 只在内存，重放成功后丢弃。
    func testStepUpReplaysSameKeyWithToken() async throws {
        script.on(
            "POST /v1/withdrawals", .envelope(code: 10003, data: "null", headers: [:]),
            .envelope(code: 0, data: WalletSamples.withdrawal("W-step"), headers: [:])
        )
        let fixture = make()
        let controller = try await withdraw(fixture)
        await typeAmount(controller, "10")
        actions(controller).submit()
        try await passStepUp(controller.flow.stepUp)
        await waitUntil("没有进提现记录") { fixture.router.path.last?.route == WalletRoutes.withdrawRecords }
        let sms = try XCTUnwrap(WalletStubProtocol.requests("POST", "/v1/auth/sms-codes").first?.json)
        XCTAssertEqual(sms["purpose"] as? String, "step_up")
        XCTAssertEqual(sms["action"] as? String, "withdraw")
        XCTAssertEqual(sms["phone"] as? String, "13800005678")
        let verify = try XCTUnwrap(WalletStubProtocol.requests("POST", "/v1/auth/step-up").first?.json)
        XCTAssertEqual(verify["action"] as? String, "withdraw")
        XCTAssertEqual(posts.count, 2)
        XCTAssertEqual(posts[0].header("Idempotency-Key"), posts[1].header("Idempotency-Key"), "沿用原键")
        XCTAssertEqual(posts[0].body, posts[1].body, "沿用原请求体")
        XCTAssertNil(posts[0].header("X-Step-Up-Token"))
        XCTAssertEqual(posts[1].header("X-Step-Up-Token"), "fixture-step-up")
        XCTAssertNil(posts[1].json["step_up_token"], "token 不进请求体")
        XCTAssertNil(fixture.wallet.deps.tokens.take(action: "withdraw", account: "user-a", nowMs: 0), "成功后丢弃")
    }

    /// 重放预算至多一次（共性第 16 条）：二次验证后仍 10003 → 不再弹面板，提示 error.10003，首次提交的键结束（下次新键）。
    func testSecondStepUpRequiredStopsAndNextSubmitUsesNewKey() async throws {
        script.fail("POST /v1/withdrawals", 10003)
        let fixture = make()
        let controller = try await withdraw(fixture)
        await typeAmount(controller, "10")
        actions(controller).submit()
        try await passStepUp(controller.flow.stepUp)
        await waitUntil { posts.count == 2 && controller.flow.state.phase == .editing }
        XCTAssertNil(controller.flow.stepUp.state, "不再弹面板")
        XCTAssertEqual(controller.flow.state.error?.key, "error.10003")
        script.ok("POST /v1/withdrawals", WalletSamples.withdrawal("W-2"))
        actions(controller).submit()
        await waitUntil { posts.count == 3 }
        XCTAssertNotEqual(posts[2].header("Idempotency-Key"), posts[0].header("Idempotency-Key"), "下次用新键")
    }

    /// 用户关闭面板：回到可编辑，本次键不用了（从未结果未知，下次用新键）；面板关闭后焦点回到【提交】由页面负责。
    func testClosingStepUpEndsKey() async throws {
        script.on(
            "POST /v1/withdrawals", .envelope(code: 10003, data: "null", headers: [:]),
            .envelope(code: 0, data: WalletSamples.withdrawal("W-3"), headers: [:])
        )
        let fixture = make()
        let controller = try await withdraw(fixture)
        await typeAmount(controller, "10")
        actions(controller).submit()
        await waitUntil { controller.flow.stepUp.state != nil }
        let panel = try XCTUnwrap(controller.flow.stepUp.state)
        StepUpActions.make(controller.flow.stepUp, panel).close()
        XCTAssertEqual(controller.flow.state.phase, .editing)
        actions(controller).submit()
        await waitUntil { posts.count == 2 }
        XCTAssertNotEqual(posts[0].header("Idempotency-Key"), posts[1].header("Idempotency-Key"))
    }

    /// 10002 → 网络层单飞刷新后沿用原键自动重发（至多 1 次）。
    func testRefresh10002ResendsSameKey() async throws {
        script.on(
            "POST /v1/withdrawals", .envelope(code: 10002, data: "null", headers: [:]),
            .envelope(code: 0, data: WalletSamples.withdrawal("W-4"), headers: [:])
        )
        script.ok(
            "POST /v1/auth/refresh",
            "{\"access_token\":\"at2\",\"refresh_token\":\"rt2\",\"session_scope\":\"full\"}"
        )
        let fixture = make()
        let controller = try await withdraw(fixture)
        await typeAmount(controller, "10")
        actions(controller).submit()
        await waitUntil("没有进提现记录") { fixture.router.path.last?.route == WalletRoutes.withdrawRecords }
        XCTAssertEqual(posts.count, 2)
        XCTAssertEqual(posts[0].header("Idempotency-Key"), posts[1].header("Idempotency-Key"))
        XCTAssertEqual(WalletStubProtocol.requests("POST", "/v1/auth/refresh").count, 1)
    }

    /// 44001 → WithdrawBlocked 弹窗（标题回落 error.44001），金额保留；【联系客服申诉】经 Router 打开 Help。
    func testRiskBlockedDialogAndAppeal() async throws {
        script.fail("POST /v1/withdrawals", 44001, data: "{\"risk_msg_code\":\"fixture_unlisted_reason\"}")
        let fixture = make()
        let controller = try await withdraw(fixture)
        await typeAmount(controller, "10")
        actions(controller).submit()
        await waitUntil { controller.flow.state.riskDialog != nil }
        XCTAssertEqual(controller.flow.state.riskDialog?.titleKey, "error.44001")
        XCTAssertEqual(controller.state.amountText, "10", "金额保留")
        actions(controller).appeal()
        XCTAssertEqual(fixture.router.path.last?.route, WalletRoutes.help)
        XCTAssertNil(controller.flow.state.riskDialog)
    }

    /// 30306：本页记下服务端阻断并禁用提交；只有之后明确允许的 rules 才解除（共性第 10 条）。
    func testFeatureOffBlocksUntilAllowedRules() async throws {
        script.fail("POST /v1/withdrawals", 30306)
        let fixture = make()
        let controller = try await withdraw(fixture)
        await typeAmount(controller, "10")
        script.ok("GET /v1/withdrawals/rules", WalletSamples.rules(can: false, block: 30306))
        actions(controller).submit()
        await waitUntil { controller.state.serverBlocked && controller.state.rules?.canWithdraw == false }
        XCTAssertEqual(controller.flow.state.error?.key, "error.30306")
        actions(controller).submit()
        await settle()
        XCTAssertEqual(posts.count, 1, "阻断期间不再提交")
        script.ok("GET /v1/withdrawals/rules", WalletSamples.rules(net: 1100))
        await typeAmount(controller, "11")
        XCTAssertFalse(controller.state.serverBlocked, "阻断之后发出、明确允许的 rules 才解除")
    }
}
