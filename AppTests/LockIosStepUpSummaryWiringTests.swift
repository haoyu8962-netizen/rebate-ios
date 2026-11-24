@testable import Couli
import CouliNetwork
import Foundation
import Router
import Wallet
@testable import WalletCore
import XCTest

/// LOCK-ios 段 3（App 接线）：改收款二次验证的业务摘要（BR-ID-08 细则「绑定业务摘要」，D10-1665 / D10-1667）经生产入口与真实 ApiClient。
/// - 首次保存：stepUp 请求体带 summary，取自保存的请求体——支付宝 {payout_method, alipay_logon_id}、借记卡 {payout_method, card_no}，
///   不带收款人姓名、开户行；10003 后沿用原幂等键只重放一次，带上令牌；
/// - 确认上一笔（同进程 / 冷启动）：摘要由本机未决记录的原请求体推出；
/// - 提现 stepUp 不带 summary；
/// - 令牌缓存：改收款摘要相同才复用（不同、不带摘要的旧令牌都不带）；提现不带令牌（升锁 6c97062、D10-2903 ① 甲：带头仍按 stepUp，
///   提现 stepUp 为 nil，缓存里残留旧提现令牌也不带）。
final class LockIosStepUpSummaryWiringTests: WalletFlowTestCase {
    static let need = WalletStubProtocol.Reply.envelope(code: 10003, data: "null", headers: [:])
    static let saved = WalletStubProtocol.Reply.envelope(code: 0, data: WalletSamples.alipay, headers: [:])
    static let alipaySummary = ["payout_method": "alipay", "alipay_logon_id": "zhangsan@example.com"]
    static let bankSummary = ["payout_method": "bank_card", "card_no": "6222 0000 0000 0009"]

    var verifies: [WalletStubProtocol.Recorded] {
        WalletStubProtocol.requests("POST", "/v1/auth/step-up")
    }

    func payoutActions(_ controller: PayoutAccountController) -> PayoutActions {
        PayoutActions.make(controller, controller.state, risk: controller.flow.state.riskDialog?.id)
    }

    /// 打开收款账号页（未绑定 → 表单），按方式填好（借记卡含开户行、收款人姓名）。
    func openForm(_ fixture: WalletAppFixture, bank: Bool) async throws -> PayoutAccountController {
        script.ok("GET /v1/me/payout-account", "{}")
        let controller = try await payout(fixture)
        XCTAssertTrue(controller.state.editing, "前提：未绑定直接显示表单")
        if bank {
            payoutActions(controller).method(WalletJSON.bankCard)
            payoutActions(controller).card("6222 0000 0000 0009")
            payoutActions(controller).bank("测试银行")
        } else {
            payoutActions(controller).logon(" zhangsan@example.com ")
        }
        payoutActions(controller).payee("测试三")
        return controller
    }

    func idle(_ flow: SensitiveFlow) async {
        for _ in 0..<3 {
            await flow.stepUp.whenIdle()
            await flow.whenIdle()
        }
    }

    /// stepUp 请求体里的 summary（字典）；没有 summary 键为 nil。
    func summary(_ request: WalletStubProtocol.Recorded?) -> [String: String]? {
        request?.json["summary"] as? [String: String]
    }

    func assertSameKey(_ requests: [WalletStubProtocol.Recorded], _ tag: String,
                       file: StaticString = #filePath, line: UInt = #line) {
        let keys = Set(requests.compactMap { $0.header("Idempotency-Key") })
        XCTAssertEqual(keys.count, 1, "\(tag)：全程沿用同一个幂等键", file: file, line: line)
        XCTAssertEqual(requests.compactMap { $0.header("Idempotency-Key") }.count, requests.count, tag,
                       file: file, line: line)
    }

    // MARK: - 首次保存

    /// 首次保存 10003 → 面板 → 验证体带摘要（不含姓名、开户行）→ 原键只重放一次、带令牌。
    func assertFirstSave(bank: Bool) async throws {
        let tag = bank ? "借记卡" : "支付宝"
        let fixture = make()
        script.on("PUT /v1/me/payout-account", Self.need, Self.saved)
        let controller = try await openForm(fixture, bank: bank)
        payoutActions(controller).save()
        try await passStepUp(controller.flow.stepUp)
        await waitUntil("\(tag)：没有重放") { self.saves.count == 2 }
        await idle(controller.flow)
        XCTAssertEqual(verifies.count, 1, tag)
        let verify = try XCTUnwrap(verifies.first?.json)
        XCTAssertEqual(verify["action"] as? String, "payout_account_change", tag)
        let expected = bank ? Self.bankSummary : Self.alipaySummary
        XCTAssertEqual(summary(verifies.first), expected, "\(tag)：摘要取自保存的请求体")
        let raw = verifies.first?.body ?? ""
        for absent in ["payee_name", "bank_name", "测试三", "测试银行"] {
            XCTAssertFalse(raw.contains(absent), "\(tag)：验证体不含 \(absent)")
        }
        XCTAssertEqual(saves.count, 2, "\(tag)：10003 后只重放一次")
        assertSameKey(saves, tag)
        XCTAssertNil(saves[0].header("X-Step-Up-Token"), tag)
        XCTAssertEqual(saves[1].header("X-Step-Up-Token"), "fixture-step-up", "\(tag)：重放带令牌")
        XCTAssertEqual(saves[0].body, saves[1].body, "\(tag)：沿用原请求体")
    }

    func testFirstSaveAlipayVerifyCarriesSummary() async throws {
        try await assertFirstSave(bank: false)
    }

    func testFirstSaveBankCardVerifyCarriesSummary() async throws {
        try await assertFirstSave(bank: true)
    }

    // MARK: - 确认上一笔

    /// 同进程：保存断连 → 待确认 → 【确认】得到 10003 → 面板 → 验证体的摘要由未决记录原体推出 → 原键只重放一次。
    func testConfirmPendingVerifyUsesOriginalBodySummary() async throws {
        let fixture = make()
        script.on("PUT /v1/me/payout-account", .disconnect, Self.need, Self.saved)
        let controller = try await openForm(fixture, bank: true)
        payoutActions(controller).save()
        await waitUntil("没有进入待确认") { controller.flow.state.pending != nil }
        await idle(controller.flow)
        flowActions(controller.flow).confirm()
        try await passStepUp(controller.flow.stepUp)
        await waitUntil("确认没有重放") { self.saves.count == 3 }
        await idle(controller.flow)
        XCTAssertEqual(summary(verifies.last), Self.bankSummary, "确认上一笔：摘要取自未决记录原体")
        XCTAssertEqual(saves.count, 3, "断连 1 + 确认 1 + 10003 后重放 1")
        assertSameKey(saves, "确认上一笔")
        XCTAssertEqual(saves[2].header("X-Step-Up-Token"), "fixture-step-up")
        XCTAssertEqual(Set(saves.map(\.body)).count, 1, "确认与重放都用原请求体")
    }

    /// 冷启动：上一进程保存断连留下未决记录；新进程（同一份本机记录）打开页面恢复待确认 →【确认】得到 10003 → 验证体摘要由记录原体推出。
    func testColdStartConfirmVerifyUsesRecordBodySummary() async throws {
        let backend = MemoryPendingKeyBackend()
        let first = make(pending: backend)
        script.on("PUT /v1/me/payout-account", .disconnect)
        let before = try await openForm(first, bank: false)
        payoutActions(before).save()
        await waitUntil("没有进入待确认") { before.flow.state.pending != nil }
        await idle(before.flow)

        script.on("PUT /v1/me/payout-account", Self.need, Self.saved)
        let second = make(pending: backend)
        script.ok("GET /v1/me/payout-account", "{}")
        let controller = try await payout(second)
        await waitUntil("冷启动没有恢复待确认") { controller.flow.state.pending != nil }
        await idle(controller.flow)
        flowActions(controller.flow).confirm()
        try await passStepUp(controller.flow.stepUp)
        await waitUntil("确认没有重放") { self.saves.count == 3 }
        XCTAssertEqual(summary(verifies.last), Self.alipaySummary, "冷启动确认：摘要取自本机记录原体")
        assertSameKey(saves, "冷启动确认")
    }

    // MARK: - 提现

    /// 提现 stepUp 请求体只有 action 与 code，不带 summary。
    func testWithdrawVerifyHasNoSummary() async throws {
        let fixture = make()
        script.on("POST /v1/withdrawals", Self.need, .envelope(
            code: 0, data: WalletSamples.withdrawal("W-sum"), headers: [:]
        ))
        let controller = try await withdraw(fixture)
        await typeAmount(controller, "10")
        actions(controller).submit()
        try await passStepUp(controller.flow.stepUp)
        await waitUntil("没有进提现记录") { fixture.router.path.last?.route == WalletRoutes.withdrawRecords }
        let verify = try XCTUnwrap(verifies.first?.json)
        XCTAssertEqual(Set(verify.keys), ["action", "code"], "提现不带 summary")
        XCTAssertEqual(verify["action"] as? String, "withdraw")
    }

    // MARK: - 令牌缓存

    /// 缓存里有同摘要的改收款令牌：保存直接带上，不弹面板。
    func testCachedTokenWithSameSummaryIsReused() async throws {
        let fixture = make()
        script.on("PUT /v1/me/payout-account", Self.saved)
        let controller = try await openForm(fixture, bank: false)
        fixture.wallet.deps.tokens.put(
            action: "payout_account_change", account: "user-a", token: "t-same", expireAtMs: .max,
            summary: StepUpSummary.key(Self.alipaySummary)
        )
        payoutActions(controller).save()
        await waitUntil("没有保存") { self.saves.count == 1 }
        await idle(controller.flow)
        XCTAssertEqual(saves.first?.header("X-Step-Up-Token"), "t-same", "摘要相同复用")
        XCTAssertTrue(verifies.isEmpty)
    }

    /// 缓存里的改收款令牌摘要与本次请求体不同（`key`）：保存不带它（服务端回 10003 → 面板）。
    func assertNotReused(token: String, key: String?) async throws {
        let fixture = make()
        script.on("PUT /v1/me/payout-account", Self.need)
        let controller = try await openForm(fixture, bank: false)
        fixture.wallet.deps.tokens.put(
            action: "payout_account_change", account: "user-a", token: token, expireAtMs: .max, summary: key
        )
        payoutActions(controller).save()
        await waitUntil("\(token)：面板没有打开") { controller.flow.stepUp.state != nil }
        XCTAssertEqual(saves.count, 1, token)
        XCTAssertNil(saves.first?.header("X-Step-Up-Token"), "\(token)：不复用")
        controller.flow.stepUp.state.map { StepUpActions.make(controller.flow.stepUp, $0).close() }
        await idle(controller.flow)
    }

    /// 别的收款账号摘要的令牌不复用。
    func testCachedTokenWithDifferentSummaryIsNotReused() async throws {
        let other = StepUpSummary.key(["payout_method": "alipay", "alipay_logon_id": "lisi@example.com"])
        try await assertNotReused(token: "t-other", key: other)
    }

    /// 不带摘要的旧令牌（段 3 之前缓存的）不用于带摘要的改收款请求。
    func testCachedLegacyTokenWithoutSummaryIsNotReused() async throws {
        try await assertNotReused(token: "t-legacy", key: nil)
    }

    /// 提现（升锁 6c97062，D10-2903 ① 甲）：缓存里残留同 action 的旧提现令牌（不带摘要）也不带——带 X-Step-Up-Token 仍按 stepUp，
    /// 提现 stepUp 为 nil；只发一次，不验证、不弹面板。随 FU-IOS-WITHDRAW-STEPUP-PANEL-CLEANUP（提现不再取缓存令牌）改成「提现不取令牌」。
    func testWithdrawCachedTokenIsNotSent() async throws {
        let fixture = make()
        script.on("POST /v1/withdrawals", .envelope(code: 0, data: WalletSamples.withdrawal("W-tok"), headers: [:]))
        let controller = try await withdraw(fixture)
        fixture.wallet.deps.tokens.put(action: "withdraw", account: "user-a", token: "t-w", expireAtMs: .max)
        await typeAmount(controller, "10")
        actions(controller).submit()
        await waitUntil("没有进提现记录") { fixture.router.path.last?.route == WalletRoutes.withdrawRecords }
        await idle(controller.flow)
        XCTAssertEqual(posts.count, 1, "只发一次")
        XCTAssertNil(posts.first?.header("X-Step-Up-Token"), "缓存里有旧提现令牌也不带（带头仍按 stepUp）")
        XCTAssertTrue(verifies.isEmpty)
        XCTAssertNil(controller.flow.stepUp.state, "不弹面板")
    }
}
