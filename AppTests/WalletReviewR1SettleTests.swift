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

    /// R1-04：带 token 的提交在途时离开提现页、执行器释放之后成功 → 钱包仍被通知刷新，已核销的 token 被丢弃。
    func testReleasedWithdrawPageLateSuccessStillRefreshesWalletAndDropsToken() async throws {
        let fixture = make()
        let wallet = try XCTUnwrap(fixture.open(WalletRoutes.wallet)?.controller as? WalletController)
        wallet.load()
        await waitUntil { wallet.state.summary != nil }
        weak var released: WithdrawController?
        var visibleBefore = 0
        do {
            script.on("POST /v1/withdrawals", .envelope(code: 10003, data: "null", headers: [:]), .hold)
            let controller = try await withdraw(fixture)
            await typeAmount(controller, "10")
            actions(controller).submit()
            try await passStepUp(controller.flow.stepUp)
            await waitUntil("重放没有发出") { WalletStubProtocol.heldIds.count == 1 }
            XCTAssertNotNil(token(fixture), "前提：token 在内存")
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
        XCTAssertNil(token(fixture), "执行器释放后成功：已核销的 token 照样丢弃")
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

    /// R1-05（G17）：带 token 提交成功但响应丢失 → 放弃得到 completed 且原结果成功 → 对应 action 的 token 被清除；单纯 abandoned 不清。
    func testAbandonCompletedWithOriginalSuccessDropsToken() async throws {
        let fixture = make()
        let controller = try await withdraw(fixture)
        script.on("POST /v1/withdrawals", .envelope(code: 10003, data: "null", headers: [:]), .disconnect)
        await typeAmount(controller, "10")
        actions(controller).submit()
        try await passStepUp(controller.flow.stepUp)
        await waitUntil("没有进入待确认") { controller.flow.state.pending != nil }
        XCTAssertNotNil(token(fixture), "前提：带过的 token 仍在内存")
        let original = "{\"code\":0,\"msg\":\"\",\"data\":\(WalletSamples.withdrawal("W-done"))}"
        script.ok("POST /v1/idempotency-keys/abandon", "{\"outcome\":\"completed\",\"original\":\(original)}")
        flowActions(controller.flow).askAbandon()
        flowActions(controller.flow).abandon()
        await waitUntil("放弃没有结算") { controller.flow.state.pending == nil }
        XCTAssertNil(token(fixture), "completed 且原结果成功：token 已被核销，按 action 丢弃")

        // 单纯 abandoned（原请求没有受理）：不算业务成功，token 不因此清除
        let second = try await withdraw(fixture)
        script.on("POST /v1/withdrawals", .envelope(code: 10003, data: "null", headers: [:]), .disconnect)
        await typeAmount(second, "10")
        actions(second).submit()
        try await passStepUp(second.flow.stepUp)
        await waitUntil("没有进入待确认") { second.flow.state.pending != nil }
        script.ok("POST /v1/idempotency-keys/abandon", "{\"outcome\":\"abandoned\",\"original\":null}")
        flowActions(second.flow).askAbandon()
        flowActions(second.flow).abandon()
        await waitUntil("放弃没有结算") { second.flow.state.pending == nil }
        XCTAssertNotNil(token(fixture), "abandoned 不当作业务成功核销")
    }

    /// R1-06：发码在途时关闭面板并退出提现页，旧面板与执行器释放后，迟到的 42901（Retry-After 120）仍写入发码的共享禁用期；重进后
    /// 新面板不再发码。
    func testLateSms42901AfterPanelReleasedStillStartsSharedGate() async throws {
        let fixture = make()
        weak var releasedPanel: StepUpController?
        weak var releasedPage: WithdrawController?
        do {
            script.on("POST /v1/withdrawals", .envelope(code: 10003, data: "null", headers: [:]))
            script.on("POST /v1/auth/sms-codes", .hold)
            let controller = try await withdraw(fixture)
            await typeAmount(controller, "10")
            actions(controller).submit()
            await waitUntil("发码没有发出") { WalletStubProtocol.heldIds.count == 1 }
            let stepUp = controller.flow.stepUp
            let panel = try XCTUnwrap(stepUp.state)
            StepUpActions.make(stepUp, panel).close()
            releasedPanel = stepUp
            releasedPage = controller
            fixture.router.path.removeLast()
        }
        await settle()
        XCTAssertNil(releasedPage, "前提：提现页执行器已释放")
        XCTAssertNil(releasedPanel, "前提：旧面板已释放")
        let held = try XCTUnwrap(WalletStubProtocol.heldIds.first)
        WalletStubProtocol.release(held, with: .envelope(code: 42901, data: "null", headers: ["Retry-After": "120"]))
        await waitUntil("旧面板释放后的 42901 没有写入发码禁用期") { fixture.gates.sms.active }
        XCTAssertGreaterThan(fixture.gates.sms.remainingMillis, 100_000, "按 Retry-After 120 秒")

        script.on("POST /v1/auth/sms-codes", .envelope(code: 0, data: "{\"resend_after_sec\":60}", headers: [:]))
        let again = try await withdraw(fixture)
        await typeAmount(again, "10")
        actions(again).submit()
        await waitUntil("新面板没有打开") { again.flow.stepUp.state != nil }
        await settle()
        XCTAssertEqual(WalletStubProtocol.requests("POST", "/v1/auth/sms-codes").count, 1, "禁用期内新面板不再发码")
        XCTAssertEqual(again.flow.stepUp.state?.error?.key, "error.42901")
    }

    private func token(_ fixture: WalletAppFixture) -> String? {
        fixture.wallet.deps.tokens.take(action: "withdraw", account: "user-a", nowMs: 0)
    }
}
