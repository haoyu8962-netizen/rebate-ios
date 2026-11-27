@testable import Couli
import CouliNetwork
import Foundation
import Router
import SwiftUI
import UIKit
import Wallet
import WalletCore
import XCTest

/// APP-09 iOS 第 1 轮评审 R1-04、R1-05、R1-06：写请求与发码的共享结算不依赖页面执行器、面板存活（会话级 WalletSettlement）。
final class WalletReviewR1SettleTests: WalletFlowTestCase {
    // MARK: - R1-04 / R1-05 / R1-06 共享结算不依赖页面执行器

    // D10-3641：原 testReleasedWithdrawPageLateSuccessStillRefreshesWalletAndDropsToken 拆两条：钱包刷新这半留在提现（不经面板的迟到成功）
    /// R1-04：提交在途时离开提现页、执行器释放之后成功 → 钱包仍被通知刷新。令牌核销那半见 testReleasedPayoutPageLateSuccessStillDropsToken。
    func testReleasedWithdrawPageLateSuccessStillRefreshesWallet() async throws {
        let fixture = make()
        let wallet = try XCTUnwrap(fixture.open(WalletRoutes.wallet)?.controller as? WalletController)
        wallet.load()
        await waitUntil { wallet.state.summary != nil }
        weak var released: WithdrawController?
        var visibleBefore = 0
        do {
            script.on("POST /v1/withdrawals", .hold)
            let controller = try await withdraw(fixture)
            await typeAmount(controller, "10")
            actions(controller).submit()
            await waitUntil("提交没有发出") { WalletStubProtocol.heldIds.count == 1 }
            released = controller
            visibleBefore = WalletStubProtocol.requests("GET", "/v1/wallet/summary").count
            fixture.router.path.removeLast()
        }
        // 回到钱包页本身会按可见性重取一次：等它发出后再记数，只看成功结算带来的刷新
        await waitUntil("钱包回到可见没有重取") {
            WalletStubProtocol.requests("GET", "/v1/wallet/summary").count > visibleBefore
        }
        await settle()
        XCTAssertNil(released, "前提：提现页执行器已释放")
        let summaries = WalletStubProtocol.requests("GET", "/v1/wallet/summary").count
        let held = try XCTUnwrap(WalletStubProtocol.heldIds.first)
        WalletStubProtocol.release(
            held,
            with: .envelope(code: 0, data: WalletSamples.withdrawal("W-late"), headers: [:])
        )
        await waitUntil("执行器释放后成功没有通知钱包刷新") {
            WalletStubProtocol.requests("GET", "/v1/wallet/summary").count > summaries
        }
    }

    // D10-3641：原 testReleasedWithdrawPageLateSuccessStillRefreshesWalletAndDropsToken 拆两条：令牌核销这半由提现挪到改收款
    /// R1-04：带 token 的保存重放在途时离开收款账号页、执行器释放之后成功 → 已核销的 token 被丢弃（改收款不刷新钱包，marksWalletDirty=false；
    /// 钱包刷新那半见 testReleasedWithdrawPageLateSuccessStillRefreshesWallet）。
    func testReleasedPayoutPageLateSuccessStillDropsToken() async throws {
        script.ok("GET /v1/me/payout-account", "{}")
        let fixture = make()
        weak var released: PayoutAccountController?
        do {
            script.on("PUT /v1/me/payout-account", Self.need, .hold)
            let controller = try await payout(fixture)
            fillAndSavePayout(controller)
            try await passStepUp(controller.flow.stepUp)
            await waitUntil("重放没有发出") { WalletStubProtocol.heldIds.count == 1 }
            XCTAssertNotNil(payoutToken(fixture), "前提：token 在内存")
            released = controller
            fixture.router.path.removeLast()
        }
        await settle()
        XCTAssertNil(released, "前提：收款账号页执行器已释放")
        let held = try XCTUnwrap(WalletStubProtocol.heldIds.first)
        WalletStubProtocol.release(held, with: .envelope(code: 0, data: WalletSamples.alipay, headers: [:]))
        // 改收款成功不通知钱包刷新：等共享结算按 action 丢弃 token（take 只读不删，轮询不改变缓存）
        await waitUntil("执行器释放后成功没有结算 token") { self.payoutToken(fixture) == nil }
        XCTAssertNil(payoutToken(fixture), "执行器释放后成功：已核销的 token 照样丢弃")
    }

    /// R1-04：执行器释放后迟到的 42901 仍按点击时的身份写入提现的共享禁用期。
    func testReleasedWithdrawPageLate42901StillStartsSharedGate() async throws {
        let fixture = make()
        weak var released: WithdrawController?
        do {
            script.on("POST /v1/withdrawals", .hold)
            let controller = try await withdraw(fixture)
            await typeAmount(controller, "10")
            actions(controller).submit()
            await waitUntil("提交没有发出") { WalletStubProtocol.heldIds.count == 1 }
            released = controller
            fixture.router.path.removeLast()
        }
        await settle()
        XCTAssertNil(released, "前提：提现页执行器已释放")
        XCTAssertFalse(fixture.gates.withdraw.active)
        let held = try XCTUnwrap(WalletStubProtocol.heldIds.first)
        WalletStubProtocol.release(held, with: .envelope(code: 42901, data: "null", headers: ["Retry-After": "30"]))
        await waitUntil("执行器释放后的 42901 没有写入共享禁用期") { fixture.gates.withdraw.active }
    }

    // D10-3641：原 testAbandonCompletedWithOriginalSuccessDropsToken 前置由提现挪到改收款
    /// R1-05（G17）：带 token 保存成功但响应丢失 → 放弃得到 completed 且原结果成功 → 对应 action 的 token 被清除；单纯 abandoned 不清。
    func testAbandonCompletedWithOriginalSuccessDropsTokenOnPayout() async throws {
        script.ok("GET /v1/me/payout-account", "{}")
        let fixture = make()
        let controller = try await payout(fixture)
        script.on("PUT /v1/me/payout-account", Self.need, .disconnect)
        fillAndSavePayout(controller)
        try await passStepUp(controller.flow.stepUp)
        await waitUntil("没有进入待确认") { controller.flow.state.pending != nil }
        XCTAssertNotNil(payoutToken(fixture), "前提：带过的 token 仍在内存")
        let original = "{\"code\":0,\"msg\":\"\",\"data\":\(WalletSamples.alipay)}"
        script.ok("POST /v1/idempotency-keys/abandon", "{\"outcome\":\"completed\",\"original\":\(original)}")
        flowActions(controller.flow).askAbandon()
        flowActions(controller.flow).abandon()
        await waitUntil("放弃没有结算") { controller.flow.state.pending == nil }
        XCTAssertNil(payoutToken(fixture), "completed 且原结果成功：token 已被核销，按 action 丢弃")

        // 单纯 abandoned（原请求没有受理）：不算业务成功，token 不因此清除
        let second = try await payout(fixture)
        script.on("PUT /v1/me/payout-account", Self.need, .disconnect)
        fillAndSavePayout(second)
        try await passStepUp(second.flow.stepUp)
        await waitUntil("没有进入待确认") { second.flow.state.pending != nil }
        script.ok("POST /v1/idempotency-keys/abandon", "{\"outcome\":\"abandoned\",\"original\":null}")
        flowActions(second.flow).askAbandon()
        flowActions(second.flow).abandon()
        await waitUntil("放弃没有结算") { second.flow.state.pending == nil }
        XCTAssertNotNil(payoutToken(fixture), "abandoned 不当作业务成功核销")
    }

    // D10-3641：原 testLateSms42901AfterPanelReleasedStillStartsSharedGate 前置由提现挪到改收款
    /// R1-06：发码在途时关闭面板并退出收款账号页，旧面板与执行器释放后，迟到的 42901（Retry-After 120）仍写入发码的共享禁用期；重进后
    /// 新面板不再发码。
    func testLateSms42901AfterPanelReleasedStillStartsSharedGateOnPayout() async throws {
        script.ok("GET /v1/me/payout-account", "{}")
        let fixture = make()
        weak var releasedPanel: StepUpController?
        weak var releasedPage: PayoutAccountController?
        do {
            script.on("PUT /v1/me/payout-account", Self.need)
            script.on("POST /v1/auth/sms-codes", .hold)
            let controller = try await payout(fixture)
            fillAndSavePayout(controller)
            await waitUntil("发码没有发出") { WalletStubProtocol.heldIds.count == 1 }
            let stepUp = controller.flow.stepUp
            let panel = try XCTUnwrap(stepUp.state)
            StepUpActions.make(stepUp, panel).close()
            releasedPanel = stepUp
            releasedPage = controller
            fixture.router.path.removeLast()
        }
        await settle()
        XCTAssertNil(releasedPage, "前提：收款账号页执行器已释放")
        XCTAssertNil(releasedPanel, "前提：旧面板已释放")
        let held = try XCTUnwrap(WalletStubProtocol.heldIds.first)
        WalletStubProtocol.release(held, with: .envelope(code: 42901, data: "null", headers: ["Retry-After": "120"]))
        await waitUntil("旧面板释放后的 42901 没有写入发码禁用期") { fixture.gates.sms.active }
        XCTAssertGreaterThan(fixture.gates.sms.remainingMillis, 100_000, "按 Retry-After 120 秒")

        script.on("POST /v1/auth/sms-codes", .envelope(code: 0, data: "{\"resend_after_sec\":60}", headers: [:]))
        let again = try await payout(fixture)
        fillAndSavePayout(again)
        await waitUntil("新面板没有打开") { again.flow.stepUp.state != nil }
        await settle()
        XCTAssertEqual(WalletStubProtocol.requests("POST", "/v1/auth/sms-codes").count, 1, "禁用期内新面板不再发码")
        XCTAssertEqual(again.flow.stepUp.state?.error?.key, "error.42901")
    }

    // MARK: - 改收款辅助（D10-3641）

    private static let need = WalletStubProtocol.Reply.envelope(code: 10003, data: "null", headers: [:])
    /// 下面填的表单推出的改收款摘要：改收款令牌按摘要缓存，取用时不带摘要恒为 nil（见 LockIos6c97062PayoutStepUpReplayTests）。
    private static let alipaySummary = ["payout_method": "alipay", "alipay_logon_id": "zhangsan@example.com"]

    private func payoutActions(_ controller: PayoutAccountController) -> PayoutActions {
        PayoutActions.make(controller, controller.state, risk: controller.flow.state.riskDialog?.id)
    }

    /// 收款账号页（未绑定直接是表单）填支付宝并点【保存】。
    private func fillAndSavePayout(_ controller: PayoutAccountController) {
        payoutActions(controller).logon("zhangsan@example.com")
        payoutActions(controller).payee("测试三")
        payoutActions(controller).save()
    }

    private func payoutToken(_ fixture: WalletAppFixture) -> String? {
        fixture.wallet.deps.tokens.take(
            action: PayoutAccountController.action, account: "user-a", nowMs: 0,
            summary: StepUpSummary.key(Self.alipaySummary)
        )
    }
}
