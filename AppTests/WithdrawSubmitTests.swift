@testable import Couli
import CouliNetwork
import Foundation
import Generated
import Router
import Wallet
import WalletCore
import XCTest

/// 提交（AC-S2-62、G17、G19）：新键与原始请求体、不走二次验证只发一次（升锁 6c97062、D10-3639；10003 重放与重放预算的用例
/// 已挪到改收款，D10-3641）、10002 刷新后沿用原键自动重发、成功以 WithdrawRecords {withdrawal_id} 替换提现页并通知钱包刷新、
/// 44001 弹窗与客服出口、30306 阻断。
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

    /// 升锁 6c97062（B1-02zzzc #385，D10-2903 ① 甲）：提现不再要求二次验证（契约 createWithdrawal 没有 x-step-up，x-error-codes 没有
    /// 10003，服务端不再回 10003）。提交只发一次，键与请求体就是首次那份，不带 X-Step-Up-Token，不发码、不验证、不出面板。
    /// 原「10003 → 面板 → 同键带令牌重放、成功后丢弃令牌」的资金断言原样挪到改收款账号：
    /// LockIos6c97062PayoutStepUpReplayTests.testStepUpReplaysSameKeyWithToken。
    func testSubmitSendsOnceWithoutStepUp() async throws {
        let fixture = make()
        let controller = try await withdraw(fixture)
        await typeAmount(controller, "10")
        actions(controller).submit()
        await waitUntil("没有进提现记录") { fixture.router.path.last?.route == WalletRoutes.withdrawRecords }
        await settle()
        XCTAssertTrue(WalletStubProtocol.requests("POST", "/v1/auth/sms-codes").isEmpty, "不发码")
        XCTAssertTrue(WalletStubProtocol.requests("POST", "/v1/auth/step-up").isEmpty, "不验证")
        XCTAssertEqual(posts.count, 1, "只发一次")
        let post = try XCTUnwrap(posts.first)
        XCTAssertNotNil(post.header("Idempotency-Key"), "首次那把键")
        XCTAssertEqual(post.json["amount_fen"] as? Int, 1000)
        XCTAssertEqual(post.json.count, 1, "首次那份请求体：只有 amount_fen")
        XCTAssertNil(post.header("X-Step-Up-Token"))
        XCTAssertNil(post.json["step_up_token"], "token 不进请求体")
        XCTAssertNil(controller.flow.stepUp.state, "不出面板")
    }

    // D10-3641：原 testSecondStepUpRequiredStopsAndNextSubmitUsesNewKey 前置由提现挪到改收款
    /// 重放预算至多一次（共性第 16 条）：二次验证后仍 10003 → 不再弹面板，提示 error.10003，首次保存的键结束（下次新键）。
    /// 提现首个 10003 就结束（不开面板、只发 1 次、下次新键）见 FuIosWithdrawNoStepUpPanelTests.testFirstSubmit10003EndsKeyWithoutPanel。
    func testSecondStepUpRequiredStopsAndNextSubmitUsesNewKeyOnPayout() async throws {
        script.ok("GET /v1/me/payout-account", "{}")
        script.fail("PUT /v1/me/payout-account", 10003)
        let fixture = make()
        let controller = try await payout(fixture)
        fillAndSavePayout(controller)
        try await passStepUp(controller.flow.stepUp)
        await waitUntil { saves.count == 2 && controller.flow.state.phase == .editing }
        XCTAssertNil(controller.flow.stepUp.state, "不再弹面板")
        XCTAssertEqual(controller.flow.state.error?.key, "error.10003")
        script.ok("PUT /v1/me/payout-account", WalletSamples.alipay)
        payoutActions(controller).save()
        await waitUntil { saves.count == 3 }
        XCTAssertNotEqual(saves[2].header("Idempotency-Key"), saves[0].header("Idempotency-Key"), "下次用新键")
    }

    // D10-3641：原 testClosingStepUpEndsKey 前置由提现挪到改收款
    /// 用户关闭面板：回到可编辑，本次键不用了（从未结果未知，下次用新键）；面板关闭后焦点回到【保存】由页面负责。
    func testClosingStepUpEndsKeyOnPayout() async throws {
        script.ok("GET /v1/me/payout-account", "{}")
        script.on(
            "PUT /v1/me/payout-account", .envelope(code: 10003, data: "null", headers: [:]),
            .envelope(code: 0, data: WalletSamples.alipay, headers: [:])
        )
        let fixture = make()
        let controller = try await payout(fixture)
        fillAndSavePayout(controller)
        await waitUntil { controller.flow.stepUp.state != nil }
        let panel = try XCTUnwrap(controller.flow.stepUp.state)
        StepUpActions.make(controller.flow.stepUp, panel).close()
        XCTAssertEqual(controller.flow.state.phase, .editing)
        payoutActions(controller).save()
        await waitUntil { saves.count == 2 }
        XCTAssertNotEqual(saves[0].header("Idempotency-Key"), saves[1].header("Idempotency-Key"))
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

    // MARK: - 改收款辅助（D10-3641）

    private func payoutActions(_ controller: PayoutAccountController) -> PayoutActions {
        PayoutActions.make(controller, controller.state, risk: controller.flow.state.riskDialog?.id)
    }

    /// 收款账号页（未绑定直接是表单）填支付宝并点【保存】。
    private func fillAndSavePayout(_ controller: PayoutAccountController) {
        payoutActions(controller).logon("zhangsan@example.com")
        payoutActions(controller).payee("测试三")
        payoutActions(controller).save()
    }
}
