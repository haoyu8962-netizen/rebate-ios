@testable import Couli
import CouliNetwork
import Foundation
import Wallet
@testable import WalletCore
import XCTest

/// FU-IOS-CONTRACT-LOCK-6c97062（D10-2903 ① 甲、D10-2911）：升锁后提现不再要求二次验证，WithdrawSubmitTests 原
/// `testStepUpReplaysSameKeyWithToken` 的资金断言（发码体、验证 action、同键、同体、提交次数、重放带令牌、令牌不进请求体、成功后丢弃令牌）
/// 原样挪到改收款账号（PUT /v1/me/payout-account，action = payout_account_change）。不放进被资金底版钉着的 PayoutAccountTests。
///
/// 提现特有、不能字面原样的两处（照 withdraw-stepup-cases.md R1 对照）：
/// - 原「等进提现记录」→ 改等 `saves.count == 2` 并等执行器空闲（改收款落地看保存成功，不进提现记录）；
/// - 原「`tokens.take(action: "withdraw", …) == nil` 成功后丢弃」→ 取用时**带上改收款的业务摘要**：改收款令牌按摘要缓存，不带摘要去取
///   恒为 nil，断言会空转（SensitiveOutcome.swift StepUpTokenCache.take 的 `entry.summary == summary`）。所以先钉验证体的 summary 就是
///   取用的那份摘要，再断言取不到。
/// 成功后丢弃对改收款同样成立（已核读代码）：SensitiveFlow.send 结算时 `consumesToken: true` → WalletSettlement.applyWrite 成功即
/// `tokens.onSuccess(action: ticket.action)`，ticket.action 是 PayoutAccountController.action（payout_account_change）。
@MainActor
final class LockIos6c97062PayoutStepUpReplayTests: WalletFlowTestCase {
    static let need = WalletStubProtocol.Reply.envelope(code: 10003, data: "null", headers: [:])
    static let saved = WalletStubProtocol.Reply.envelope(code: 0, data: WalletSamples.alipay, headers: [:])
    static let alipaySummary = ["payout_method": "alipay", "alipay_logon_id": "zhangsan@example.com"]

    func payoutActions(_ controller: PayoutAccountController) -> PayoutActions {
        PayoutActions.make(controller, controller.state, risk: controller.flow.state.riskDialog?.id)
    }

    func idle(_ flow: SensitiveFlow) async {
        for _ in 0..<3 {
            await flow.stepUp.whenIdle()
            await flow.whenIdle()
        }
    }

    /// 10003 → 二次验证面板：打开即发码（purpose=step_up、action=payout_account_change、不带 phone）；验证成功后沿用原键、原体重放 1 次
    /// 并带 X-Step-Up-Token；token 不进请求体；只在内存，重放成功后丢弃。
    func testStepUpReplaysSameKeyWithToken() async throws {
        script.ok("GET /v1/me/payout-account", "{}")
        script.on("PUT /v1/me/payout-account", Self.need, Self.saved)
        let fixture = make()
        let controller = try await payout(fixture)
        XCTAssertTrue(controller.state.editing, "前提：未绑定直接显示表单")
        payoutActions(controller).logon("zhangsan@example.com")
        payoutActions(controller).payee("测试三")
        payoutActions(controller).save()
        try await passStepUp(controller.flow.stepUp)
        await waitUntil("没有重放") { self.saves.count == 2 }
        await idle(controller.flow)
        let sms = try XCTUnwrap(WalletStubProtocol.requests("POST", "/v1/auth/sms-codes").first?.json)
        XCTAssertEqual(sms["purpose"] as? String, "step_up")
        XCTAssertEqual(sms["action"] as? String, "payout_account_change")
        XCTAssertNil(sms["phone"]) // modify_existing ruling D10-1682 ③（发码体不带 phone）
        let verify = try XCTUnwrap(WalletStubProtocol.requests("POST", "/v1/auth/step-up").first?.json)
        XCTAssertEqual(verify["action"] as? String, "payout_account_change")
        XCTAssertEqual(
            verify["summary"] as? [String: String], Self.alipaySummary,
            "前提：令牌绑定的摘要就是下面取用的那份（否则「成功后丢弃」空转）"
        )
        XCTAssertEqual(saves.count, 2)
        XCTAssertEqual(saves[0].header("Idempotency-Key"), saves[1].header("Idempotency-Key"), "沿用原键")
        XCTAssertEqual(saves[0].body, saves[1].body, "沿用原请求体")
        XCTAssertNil(saves[0].header("X-Step-Up-Token"))
        XCTAssertEqual(saves[1].header("X-Step-Up-Token"), "fixture-step-up")
        XCTAssertNil(saves[1].json["step_up_token"], "token 不进请求体")
        XCTAssertNil(
            fixture.wallet.deps.tokens.take(
                action: "payout_account_change", account: "user-a", nowMs: 0,
                summary: StepUpSummary.key(Self.alipaySummary)
            ),
            "成功后丢弃"
        )
    }
}
