@testable import Couli
import CouliNetwork
import Foundation
import Generated
import Router
import Wallet
import WalletCore
import XCTest

/// 换号、撤回同意、切换环境（APP-09 共性第 13、39、52、59、60、63、64、65 条，APP-08 第 1、19 条）：表单与执行器在构造时固定身份，之后只
/// 比较；保留的旧页面回调（渲染时取出）在令牌已换、清空通知还没执行的窗口里零写入、零发送；会话失效 → 登录 B → 返回旧页面不见 A 的数据。
final class WalletSessionTests: WalletFlowTestCase {
    /// 令牌已换、清空通知还没执行：旧页面保留的输入、【全部提现】、档位、【提交】回调一律不受理（零写入、零 POST）；收款账号表单同样。
    func testOldRenderedCallbacksAfterSilentTokenSwapSendNothing() async throws {
        let fixture = make()
        let controller = try await withdraw(fixture)
        await typeAmount(controller, "10")
        let old = actions(controller)
        let rules = WalletStubProtocol.requests("GET", "/v1/withdrawals/rules").count
        try fixture.swapTokensSilently(to: "user-b")
        old.amount("50")
        old.fillAll()
        old.quick(500)
        old.submit()
        await settle()
        XCTAssertEqual(controller.state.amountText, "10", "旧回调不写入金额")
        XCTAssertTrue(posts.isEmpty, "旧表单不以新会话的身份提交")
        XCTAssertEqual(WalletStubProtocol.requests("GET", "/v1/withdrawals/rules").count, rules, "估算不为旧金额重新绑定当前会话")
        // 新渲染的回调同样不受理：表单身份仍是 A，只比较、不重绑
        actions(controller).submit()
        await settle()
        XCTAssertTrue(posts.isEmpty)
    }

    /// 收款账号与实名表单：令牌已换后旧回调写不进（卡号、姓名、身份证号不进换代后的表单），【保存】零 PUT。
    func testIdentityFormsIgnoreOldCallbacksAfterTokenSwap() async throws {
        script.ok("GET /v1/me/payout-account", "{}")
        let fixture = make()
        fixture.wallet.installBackends(realname: FixtureRealName(), labor: nil)
        let controller = try await payout(fixture)
        let old = PayoutActions.make(controller, controller.state, risk: nil)
        old.payee("测试三")
        try fixture.swapTokensSilently(to: "user-b")
        old.logon("zhangsan@example.com")
        old.save()
        await settle()
        XCTAssertEqual(controller.state.form.alipayLogonId, "", "旧回调不写入")
        XCTAssertTrue(saves.isEmpty)
        fixture.router.path.removeAll()
        try fixture.switchAccount(to: "user-a")
        let real = try XCTUnwrap(fixture.open(WalletRoutes.realName)?.controller as? RealNameController)
        let oldReal = RealNameActions.make(real, real.state)
        try fixture.swapTokensSilently(to: "user-c")
        oldReal.name("测试三")
        oldReal.idNo("000000000000000000")
        XCTAssertEqual(real.state.name, "")
        XCTAssertEqual(real.state.idNo, "")
    }

    /// 会话失效 → 登录 B → 返回旧 Withdraw / PayoutAccount：不见 A 的金额、已填内容与待确认；页面换上同一次读取的新身份。
    func testSessionInvalidThenLoginBReturnsToClearedPages() async throws {
        let fixture = make()
        let controller = try await withdraw(fixture)
        try await enterPending(controller)
        let payoutPage = try await payout(fixture)
        payoutPage.change(version: payoutPage.state.version, shown: try XCTUnwrap(payoutPage.state.account),
                          owner: payoutPage.owner)
        PayoutActions.make(payoutPage, payoutPage.state, risk: nil).payee("测试三")
        fixture.network.client.signOut()
        fixture.routing.sessionStateChanged(resumePending: false)
        try fixture.switchAccount(to: "user-b")
        XCTAssertEqual(payoutPage.state.form, PayoutForm(), "已填内容同步清空")
        XCTAssertEqual(controller.state.amountText, "")
        XCTAssertNil(controller.flow.state.pending, "A 的待确认不展示")
        XCTAssertEqual(controller.owner.account, "user-b")
        XCTAssertEqual(payoutPage.owner.account, "user-b")
        await waitUntil { controller.state.phase == .content }
        let lookup = await fixture.network.client.pendingStatus(operationId: "createWithdrawal")
        XCTAssertEqual(lookup, .none, "B 读不到 A 的未决记录")
    }

    /// 撤回同意：表单、请求、确认弹窗零发送（屏障先于标记，凭据不可读）；切换环境同样（作废世代变化，固定身份不再是当前）。
    func testWithdrawalAndEnvironmentSwitchZeroSend() async throws {
        let fixture = make()
        let controller = try await withdraw(fixture)
        try await enterPending(controller)
        flowActions(controller.flow).askAbandon()
        let dialog = flowActions(controller.flow)
        let page = actions(controller)
        let before = WalletStubProtocol.requests.count
        _ = fixture.runner.run()
        dialog.abandon()
        dialog.confirm()
        page.submit()
        page.amount("20")
        await settle()
        XCTAssertEqual(WalletStubProtocol.requests.count, before, "撤回后零发送")
        XCTAssertGreaterThanOrEqual(fixture.wallet.clearedCount, 1, "钱包清理项随撤回执行")
        let fresh = make()
        let second = try await withdraw(fresh)
        await typeAmount(second, "10")
        let kept = actions(second)
        let count = WalletStubProtocol.requests.count
        fresh.network.client.invalidateSessions()
        try fresh.cleaner.cleanForEnvironmentSwitch()
        kept.submit()
        kept.fillAll()
        await settle()
        XCTAssertEqual(WalletStubProtocol.requests.count, count, "切换环境后旧页面零发送")
    }

    /// 提交在途时出栈：响应回来不改页面（已出栈），结论只落到未决记录（结果未知 → unknown）。
    func testInFlightSubmitAfterLeaveSettlesRecordOnly() async throws {
        script.on("POST /v1/withdrawals", .hold)
        let fixture = make()
        let controller = try await withdraw(fixture)
        await typeAmount(controller, "10")
        actions(controller).submit()
        await waitUntil { WalletStubProtocol.heldIds.count == 1 }
        fixture.router.path.removeAll()
        XCTAssertFalse(controller.alive)
        let held = try XCTUnwrap(WalletStubProtocol.heldIds.first)
        WalletStubProtocol.release(held, with: .disconnect)
        var state = ""
        for _ in 0..<300 where state != PendingKeyStore.unknown {
            if case let .record(record) = await fixture.network.client.pendingStatus(operationId: "createWithdrawal") {
                state = record.stateRaw
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(state, PendingKeyStore.unknown, "结论落到未决记录")
        XCTAssertNil(controller.flow.state.pending, "已出栈的页面不改")
    }
}
