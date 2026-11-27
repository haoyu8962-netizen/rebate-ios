@testable import Couli
import CouliNetwork
import Foundation
import Session
import Wallet
import WalletCore
import XCTest

/// FU-IOS-WALLETSETTLEMENT-SCOPE 写测（零变化）：提现、改收款与它们打开的二次验证面板，在与 (a1) / (b1) 同样的作用域变化与时序下，
/// 行为与改前逐字一致（任务书 §2「只改注销这条流；提现 / 改收款零行为变化，不改 WalletOwner、不改 IdentityCheck 判据」、
/// 「提现 / 改收款的 ticket 不带核对」「不 reset 共享的 sms / verify gate」）。
///
/// 现状绿、改后仍须绿：这一组钉住「作用域核对只加在注销 flow 上」，防止把核对误加到提现 / 收款的 WriteTicket、发送前闸门或面板结算上
/// （变异「把核对误加到提现 ticket」应让本组变红）。作用域变化同 (b) 组：存储里只换 scope，再走会话同步出口。
@MainActor
final class FuIosWalletScopeZeroChangeTests: FuIosWalletSettlementScopeTestCase {
    private func payoutActions(_ controller: PayoutAccountController) -> PayoutActions {
        PayoutActions.make(controller, controller.state, risk: controller.flow.state.riskDialog?.id)
    }

    /// (零变化 / b1 变体) 提现提交在途，同世代作用域 full → deletion_only，之后提交拿到 42901 → 照写 gates.withdraw（按 WalletOwner，
    /// 不看作用域）。
    func testWithdraw42901AfterScopeChangeStillWritesWithdrawGate() async throws {
        let fixture = make()
        script.on("POST /v1/withdrawals", .hold)
        let controller = try await withdraw(fixture)
        await typeAmount(controller, "10")
        actions(controller).submit()
        await waitUntil("提交没有到达假服务") { self.heldId("POST /v1/withdrawals") != nil }

        try switchScope(fixture, to: SessionScope.deletionOnly)
        let held = try XCTUnwrap(heldId("POST /v1/withdrawals"))
        WalletStubProtocol.release(held, with: Self.retryAfter(30))
        await waitUntil("(零变化) 提现 42901 没有写入 gates.withdraw") { fixture.gates.withdraw.active }
        XCTAssertFalse(fixture.gates.deletion.active, "注销的截止时间单独一份")
    }

    /// (零变化 / b1 变体) 改收款保存在途，同世代作用域变化后拿到 42901 → 照写 gates.payout。
    func testPayout42901AfterScopeChangeStillWritesPayoutGate() async throws {
        script.ok("GET /v1/me/payout-account", "{}")
        let fixture = make()
        script.on("PUT /v1/me/payout-account", .hold)
        let controller = try await payout(fixture)
        XCTAssertTrue(controller.state.editing, "前提：未绑定直接显示表单")
        payoutActions(controller).logon("zhangsan@example.com")
        payoutActions(controller).payee("测试三")
        payoutActions(controller).save()
        await waitUntil("保存没有到达假服务") { self.heldId("PUT /v1/me/payout-account") != nil }

        try switchScope(fixture, to: SessionScope.deletionOnly)
        let held = try XCTUnwrap(heldId("PUT /v1/me/payout-account"))
        WalletStubProtocol.release(held, with: Self.retryAfter(30))
        await waitUntil("(零变化) 改收款 42901 没有写入 gates.payout") { fixture.gates.payout.active }
    }

    // D10-3641：原 testWithdrawPanelSms42901AfterScopeChangeStillWritesSmsGate 前置由提现挪到改收款
    /// (零变化 / b3 变体) 改收款打开的二次验证面板发码在途，同世代作用域变化后拿到 42901 → 照写 gates.sms（改收款面板同样不带作用域核对）。
    func testPayoutPanelSms42901AfterScopeChangeStillWritesSmsGate() async throws {
        script.ok("GET /v1/me/payout-account", "{}")
        let fixture = make()
        script.on("PUT /v1/me/payout-account", .envelope(code: 10003, data: "null", headers: [:]))
        script.on(Self.smsSend, .hold)
        let controller = try await payout(fixture)
        payoutActions(controller).logon("zhangsan@example.com")
        payoutActions(controller).payee("测试三")
        payoutActions(controller).save()
        await waitUntil("发码没有到达假服务") { self.heldId(Self.smsSend) != nil }
        XCTAssertEqual(
            controller.flow.stepUp.state?.action, PayoutAccountController.action, "前提：改收款的二次验证面板"
        )

        try switchScope(fixture, to: SessionScope.deletionOnly)
        let held = try XCTUnwrap(heldId(Self.smsSend))
        WalletStubProtocol.release(held, with: Self.retryAfter(120))
        await waitUntil("(零变化) 改收款面板发码 42901 没有写入 gates.sms") { fixture.gates.sms.active }
    }

    /// (零变化 / a1 变体) 提现待确认卡【确认上一笔】：确认先拿 10002 → 网络层刷新（full → full）→ 原键原体重放 1 次 → 成功。
    /// 提现的发送前闸门只看 42901，与改前一致。
    func testWithdrawConfirmReplaysAfterRefreshAsBefore() async throws {
        let fixture = make()
        let controller = try await withdraw(fixture)
        try await enterPending(controller)
        script.on(
            "POST /v1/withdrawals", .envelope(code: 10002, data: "null", headers: [:]),
            .envelope(code: 0, data: WalletSamples.withdrawal("W-confirm"), headers: [:])
        )
        script.on(Self.refresh, Self.tokens("after", scope: SessionScope.full))

        flowActions(controller.flow).confirm()
        await waitUntil("确认没有成功") { fixture.router.path.last?.route == WalletRoutes.withdrawRecords }

        XCTAssertEqual(sent(Self.refresh).count, 1, "前提：10002 触发 1 次刷新")
        XCTAssertEqual(posts.count, 3, "(零变化) 首次 1 次 + 确认 1 次 + 刷新后重放 1 次")
        let keys = Set(posts.compactMap { $0.header("Idempotency-Key") })
        XCTAssertEqual(keys.count, 1, "(零变化) 确认与重放都用原键")
        XCTAssertEqual(Set(posts.map(\.body)).count, 1, "(零变化) 确认与重放都用原体")
    }
}
