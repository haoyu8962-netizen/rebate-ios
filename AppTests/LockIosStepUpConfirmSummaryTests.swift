@testable import Couli
import CouliNetwork
import Foundation
import Router
import Wallet
@testable import WalletCore
import XCTest

/// LOCK-ios 段 3（App 接线，D10-1720 / D10-1722）：【确认上一笔】与改收款业务摘要。全部经生产入口（收款【保存】断连 → 待确认卡 →【确认】）
/// 与真实 ApiClient，只把传输层换成本地假服务。
/// - D10-1722 (c)：确认上一笔按未决记录原体推出的摘要取缓存令牌（`SensitiveFlow+Pending.swift` confirm 里 `tokens.take(… summary:)`）——
///   同摘要复用并带上、不弹面板；不同摘要 / 不带摘要的旧令牌不复用（确认不带令牌 → 10003 → 面板）；
/// - D10-1720 ⑥：改收款推不出摘要（未决记录原体缺了账号字段）时确认得到 10003 → 不开面板、不发 stepUp、不发码，待确认卡 pendingNotice 为稍后再试，
///   待确认卡保留；提现确认得到 10003 不开面板、不发码，保持待确认并提示 error.10003（D10-3639 C、D10-3641）。
final class LockIosStepUpConfirmSummaryTests: WalletFlowTestCase {
    static let need = WalletStubProtocol.Reply.envelope(code: 10003, data: "null", headers: [:])
    static let saved = WalletStubProtocol.Reply.envelope(code: 0, data: WalletSamples.alipay, headers: [:])
    static let alipaySummary = ["payout_method": "alipay", "alipay_logon_id": "zhangsan@example.com"]
    static let payoutAction = "payout_account_change"

    var verifies: [WalletStubProtocol.Recorded] {
        WalletStubProtocol.requests("POST", "/v1/auth/step-up")
    }

    var smsSent: [WalletStubProtocol.Recorded] {
        WalletStubProtocol.requests("POST", "/v1/auth/sms-codes")
    }

    func payoutActions(_ controller: PayoutAccountController) -> PayoutActions {
        PayoutActions.make(controller, controller.state, risk: controller.flow.state.riskDialog?.id)
    }

    func idle(_ flow: SensitiveFlow) async {
        for _ in 0..<3 {
            await flow.stepUp.whenIdle()
            await flow.whenIdle()
        }
    }

    /// 打开收款账号页（未绑定 → 表单），填支付宝并【保存】；第一次 PUT 断连进待确认（缓存里此时没有令牌，首次保存不带）。
    /// `then` 是之后（确认）的 PUT 回答（nil = 不改脚本）。
    func enterPayoutPending(_ fixture: WalletAppFixture,
                            then reply: WalletStubProtocol.Reply? = nil) async throws -> PayoutAccountController {
        script.ok("GET /v1/me/payout-account", "{}")
        script.on("PUT /v1/me/payout-account", .disconnect)
        let controller = try await payout(fixture)
        payoutActions(controller).logon(" zhangsan@example.com ")
        payoutActions(controller).payee("测试三")
        payoutActions(controller).save()
        await waitUntil("没有进入待确认") { controller.flow.state.pending != nil }
        await idle(controller.flow)
        XCTAssertEqual(saves.count, 1, "前提：首次保存发出 1 次")
        XCTAssertNil(saves.first?.header("X-Step-Up-Token"), "前提：首次保存没带令牌")
        if let reply {
            script.on("PUT /v1/me/payout-account", reply)
        }
        return controller
    }

    func putPayoutToken(_ fixture: WalletAppFixture, _ token: String, summary: [String: String]?) {
        fixture.wallet.deps.tokens.put(
            action: Self.payoutAction, account: "user-a", token: token, expireAtMs: .max,
            summary: StepUpSummary.key(summary)
        )
    }

    // MARK: - (c) 确认上一笔按摘要复用缓存令牌

    /// 缓存里有同 action、同账号、摘要与未决记录原体相同的令牌：确认直接带上它，不弹面板、不发码、不验证；原键确认成功落地。
    /// 删掉 confirm 里 `tokens.take` 的 `summary:` 入参（缺省 nil）时，带摘要的缓存条目对 nil 不相等、取不到 → 确认不带令牌，这条变红。
    func testConfirmReusesCachedTokenWithSameSummary() async throws {
        let fixture = make()
        let controller = try await enterPayoutPending(fixture, then: Self.saved)
        putPayoutToken(fixture, "t-same", summary: Self.alipaySummary)
        flowActions(controller.flow).confirm()
        await waitUntil("确认没有发出") { self.saves.count == 2 }
        await idle(controller.flow)
        XCTAssertEqual(saves[1].header("X-Step-Up-Token"), "t-same", "摘要相同：确认带上缓存令牌")
        XCTAssertEqual(saves[0].header("Idempotency-Key"), saves[1].header("Idempotency-Key"), "确认沿用原键")
        XCTAssertEqual(saves[0].body, saves[1].body, "确认沿用原请求体")
        XCTAssertNil(controller.flow.stepUp.state, "不弹二次验证面板")
        XCTAssertTrue(smsSent.isEmpty, "不发码")
        XCTAssertTrue(verifies.isEmpty, "不验证")
        await waitUntil("确认成功后待确认卡没有收起") { controller.flow.state.pending == nil }
    }

    /// 缓存令牌的摘要是 `cached`（与未决记录原体推出的不同）：确认不带它 → 10003 → 面板（发码 1 次）。
    func assertConfirmDoesNotReuse(_ token: String, cached: [String: String]?,
                                   file: StaticString = #filePath, line: UInt = #line) async throws {
        let fixture = make()
        let controller = try await enterPayoutPending(fixture, then: Self.need)
        putPayoutToken(fixture, token, summary: cached)
        flowActions(controller.flow).confirm()
        await waitUntil("\(token)：面板没有打开", file: file, line: line) { controller.flow.stepUp.state != nil }
        await idle(controller.flow)
        XCTAssertEqual(saves.count, 2, "\(token)：断连 1 + 确认 1", file: file, line: line)
        XCTAssertNil(saves[1].header("X-Step-Up-Token"), "\(token)：摘要不同，确认不复用", file: file, line: line)
        XCTAssertEqual(smsSent.count, 1, "\(token)：走二次验证面板（发码 1 次）", file: file, line: line)
        controller.flow.stepUp.state.map { StepUpActions.make(controller.flow.stepUp, $0).close() }
        await idle(controller.flow)
    }

    /// 别的收款账号摘要的令牌：确认不复用。
    func testConfirmDoesNotReuseTokenWithDifferentSummary() async throws {
        try await assertConfirmDoesNotReuse(
            "t-other", cached: ["payout_method": "alipay", "alipay_logon_id": "lisi@example.com"]
        )
    }

    /// 不带摘要的旧令牌：确认不复用。删掉 confirm 里 `tokens.take` 的 `summary:` 入参时它被取出带上，这条变红。
    func testConfirmDoesNotReuseLegacyTokenWithoutSummary() async throws {
        try await assertConfirmDoesNotReuse("t-legacy", cached: nil)
    }

    // MARK: - ⑥ 改收款推不出摘要

    /// 冷启动：上一进程保存断连留下未决记录，记录原体缺了账号字段（推不出摘要）；新进程【确认】得到 10003 → 不开面板、不发 stepUp、
    /// 不发码，待确认卡 pendingNotice 为稍后再试，待确认卡保留（同一个键）。
    func testPayoutConfirmWithoutDerivableSummaryDoesNotOpenPanel() async throws {
        let backend = MemoryPendingKeyBackend()
        let first = make(pending: backend)
        _ = try await enterPayoutPending(first)
        var record = try XCTUnwrap(backend.list(account: "user-a").first, "前提：留下未决记录")
        record.body = WalletJSON.text(["payout_method": "alipay", "payee_name": "测试三"])
        try backend.write(record)
        XCTAssertNil(StepUpSummary.payoutChange(body: record.body), "前提：记录原体推不出摘要")

        script.on("PUT /v1/me/payout-account", Self.need)
        let second = make(pending: backend)
        let controller = try await payout(second)
        await waitUntil("冷启动没有恢复待确认") { controller.flow.state.pending != nil }
        await idle(controller.flow)
        XCTAssertEqual(controller.flow.state.pending?.key, record.key)
        flowActions(controller.flow).confirm()
        await waitUntil("确认没有发出") { self.saves.count == 2 }
        await idle(controller.flow)
        await quietWindow(0.3)
        XCTAssertEqual(second.api.calls("confirm:" + PayoutAccountController.operation), 1, "确认发出 1 次（得到 10003）")
        XCTAssertNil(controller.flow.stepUp.state, "推不出摘要：不打开二次验证面板")
        XCTAssertEqual(second.api.calls(StepUpController.sendOperation), 0, "不调用发码入口")
        XCTAssertEqual(second.api.calls(StepUpController.verifyOperation), 0, "不调用验证入口")
        XCTAssertTrue(smsSent.isEmpty, "不发 sendSmsCode")
        XCTAssertTrue(verifies.isEmpty, "不发 stepUp")
        XCTAssertEqual(controller.flow.state.pendingNotice?.key, SensitiveOutcome.retryLaterKey, "待确认卡提示稍后再试")
        XCTAssertEqual(controller.flow.state.pending?.key, record.key, "待确认卡保留原键")
        XCTAssertFalse(controller.flow.state.pendingUnreadable, "重新查记录后仍读得到")
        XCTAssertTrue(controller.flow.state.pendingActionsEnabled, "待确认卡【确认】/【放弃】恢复可用")
        XCTAssertEqual(controller.flow.state.phase, .pending, "保持待确认")
    }

    // D10-3641：原 testWithdrawConfirmStillOpensPanel 改断新行为（确认计数原样保留）
    /// 提现确认上一笔得到 10003（D10-3639 C）：确认只发 1 次（断连 1 + 确认 1）；不开面板、不发码；保持待确认、原键在卡上，待确认卡提示
    /// error.10003（不是稍后再试）。
    func testWithdrawConfirm10003NoPanelKeepsPending() async throws {
        let fixture = make()
        let controller = try await withdraw(fixture)
        try await enterPending(controller)
        await idle(controller.flow)
        let key = try XCTUnwrap(controller.flow.state.pending?.key, "前提：待确认卡带原键")
        script.on("POST /v1/withdrawals", Self.need)
        flowActions(controller.flow).confirm()
        await waitUntil("提现确认没有发出") { self.posts.count == 2 }
        await idle(controller.flow)
        await quietWindow(0.3)
        XCTAssertEqual(posts.count, 2, "断连 1 + 确认 1")
        XCTAssertNil(controller.flow.stepUp.state, "提现确认不开面板")
        XCTAssertTrue(smsSent.isEmpty, "提现确认不发码")
        XCTAssertEqual(fixture.api.calls(StepUpController.sendOperation), 0, "不调用发码入口")
        XCTAssertEqual(controller.flow.state.pendingNotice?.key, "error.10003", "待确认卡提示 error.10003")
        XCTAssertNotEqual(controller.flow.state.pendingNotice?.key, SensitiveOutcome.retryLaterKey, "提现不提示稍后再试")
        XCTAssertEqual(controller.flow.state.phase, .pending, "保持待确认")
        XCTAssertEqual(controller.flow.state.pending?.key, key, "原键在卡上")
        XCTAssertEqual(posts[1].header("Idempotency-Key"), posts[0].header("Idempotency-Key"), "确认沿用原键")
    }
}
