@testable import Couli
import CouliNetwork
import Foundation
import Router
import Wallet
@testable import WalletCore
import XCTest

/// 资金红线（brief §3、§9 第 2、3 条；FU-AND-0721 不变式 1）。面板真实挂着（`.sheet` 在窗口里），输入后观察窗内的视图层自动验证也抓得到。
/// 本文件不要求新测量，底版应全绿，实现后必须仍绿。
@MainActor
final class StepUpVisualMoneyTests: StepUpVisualTestCase {
    // MARK: - 不接输满自动验证

    /// 提现：逐位输满 / 一次粘贴 6 位 → 零请求；状态可验证但不动；点【验证并提交】才恰一次。
    func testFullCodeNeverAutoVerifiesOnWithdraw() async throws {
        let host = try await panelOnWithdraw()
        for length in 1...6 {
            try enterCode(String("123456".prefix(length)))
            await settle()
        }
        await quietWindow(1.2)
        XCTAssertEqual(verifies.count, 0, "逐位输满零请求")
        XCTAssertEqual(stepUp?.state?.canVerify, true)
        XCTAssertEqual(stepUp?.state?.phase, .ready, "不进验证中")
        try enterCode("")
        try enterCode("654321")
        await quietWindow(1.2)
        XCTAssertEqual(verifies.count, 0, "一次填入 6 位（短信自动填充）零请求")
        XCTAssertEqual(submits.count, 1, "只有最初那次提交")
        try panelActions().verify()
        await waitUntil("验证没发出") { self.verifies.count == 1 }
        XCTAssertEqual(verifies.first?.json["code"] as? String, "654321")
        XCTAssertEqual(verifies.first?.json["action"] as? String, "withdraw")
        await waitUntil("没有落地") { host.fixture.router.path.last?.route == WalletRoutes.withdrawRecords }
        XCTAssertEqual(verifies.count, 1, "恰一次")
    }

    /// 收款账号：同上，保存写请求不被输满触发。
    func testFullCodeNeverAutoVerifiesOnPayout() async throws {
        try await panelOnPayout()
        try enterCode("123456")
        await quietWindow(1.2)
        XCTAssertEqual(verifies.count, 0, "输满零请求")
        XCTAssertEqual(saves.count, 1, "只有最初那次保存")
    }

    // MARK: - 重放

    /// 提现：显式验证恰一次 → 原键、原体重放恰一次，带 token；发码恰一次；只导航一次。
    func testVerifyReplaysOriginalKeyOnceOnWithdraw() async throws {
        let host = try await panelOnWithdraw()
        host.server.script.on("POST /v1/auth/step-up", Self.stepOk())
        try enterCode("123456")
        try panelActions().verify()
        await waitUntil("没有落地") { host.fixture.router.path.last?.route == WalletRoutes.withdrawRecords }
        await settle()
        XCTAssertEqual(writes, ["POST /v1/withdrawals", "POST /v1/auth/sms-codes", "POST /v1/auth/step-up",
                                "POST /v1/withdrawals"], "写序列")
        XCTAssertEqual(submits[0].header("Idempotency-Key"), submits[1].header("Idempotency-Key"), "原键")
        XCTAssertNotNil(submits[0].header("Idempotency-Key"))
        XCTAssertEqual(submits[0].json as NSDictionary, submits[1].json as NSDictionary, "原体")
        XCTAssertNil(submits[0].header("X-Step-Up-Token"))
        XCTAssertEqual(submits[1].header("X-Step-Up-Token"), "fixture-verified-token")
        XCTAssertNil(host.flow?.stepUp.state, "面板收起")
    }

    /// 收款账号：同上。
    func testVerifyReplaysOriginalKeyOnceOnPayout() async throws {
        let host = try await panelOnPayout()
        host.server.script.on("POST /v1/auth/step-up", Self.stepOk("payout-token"))
        try enterCode("123456")
        try panelActions().verify()
        await waitUntil("没有重放") { self.saves.count == 2 }
        await settle()
        XCTAssertEqual(verifies.count, 1)
        XCTAssertEqual(verifies.first?.json["action"] as? String, "payout_account_change")
        XCTAssertEqual(smsSends.count, 1)
        XCTAssertEqual(smsSends.first?.json["action"] as? String, "payout_account_change")
        XCTAssertEqual(saves[0].header("Idempotency-Key"), saves[1].header("Idempotency-Key"), "原键")
        XCTAssertEqual(saves[0].json as NSDictionary, saves[1].json as NSDictionary, "原体")
        XCTAssertEqual(saves[1].header("X-Step-Up-Token"), "payout-token")
    }

    /// 验证中连点：只发一次；验证中输入被锁。
    func testDoubleVerifySendsOnceAndLocksInput() async throws {
        let host = try await panelOnWithdraw()
        host.server.script.on("POST /v1/auth/step-up", .hold)
        try enterCode("123456")
        let actions = try panelActions()
        actions.verify()
        actions.verify()
        try panelActions().verify()
        await waitUntil { WalletStubProtocol.heldIds.count == 1 }
        XCTAssertEqual(stepUp?.state?.phase, .verifying)
        try enterCode("000000")
        XCTAssertEqual(stepUp?.state?.code, "123456", "验证中不改码")
        await quietWindow(0.3)
        XCTAssertEqual(verifies.count, 1, "连点恰一次")
        XCTAssertEqual(submits.count, 1, "验证答复回来之前不重放")
        withExtendedLifetime(host) {}
    }

    /// 20002 / 20003：清空、留在面板、不重放；改码后重新点才再验证。
    func testWrongCodeClearsStaysAndDoesNotReplay() async throws {
        for code in [20002, 20003] {
            let host = try await panelOnWithdraw()
            let wrong = WalletStubProtocol.Reply.envelope(code: code, data: "null", headers: [:])
            host.server.script.on("POST /v1/auth/step-up", wrong, Self.stepOk())
            try enterCode("000000")
            try panelActions().verify()
            await waitUntil("\(code)：错误没出现") { self.stepUp?.state?.error != nil }
            XCTAssertEqual(stepUp?.state?.code, "", "\(code)：清空")
            XCTAssertEqual(stepUp?.state?.canVerify, false, "\(code)：按钮回到不可用")
            XCTAssertEqual(submits.count, 1, "\(code)：不重放")
            try enterCode("123456")
            await quietWindow(0.6)
            XCTAssertEqual(verifies.count, 1, "\(code)：重新输满也不自动再验证")
            try panelActions().verify()
            await waitUntil("\(code)：没有落地") { host.fixture.router.path.last?.route == WalletRoutes.withdrawRecords }
            XCTAssertEqual(verifies.count, 2, "\(code)：第二次显式点")
            XCTAssertEqual(submits.count, 2, "\(code)：重放一次")
        }
    }

    // MARK: - 关闭与发码节流

    /// 关闭：零验证零重放；10003 那一笔没被受理，键作废、再提交用新键（SensitiveFlow+Apply 现状）；倒计时内重开不再发码、倒计时接着走（共性第 6 条）。
    func testCloseThenReopenDropsKeyAndDoesNotResend() async throws {
        let host = try await panelOnWithdraw()
        try enterCode("123456")
        try panelActions().close()
        await settle()
        XCTAssertNil(stepUp?.state, "面板收起")
        await quietWindow(0.5)
        XCTAssertEqual(verifies.count, 0, "关闭零验证")
        XCTAssertEqual(submits.count, 1, "关闭零重放")
        host.server.script.on("POST /v1/withdrawals", Self.need)
        host.actions?.submit()
        await waitUntil("再次提交没开面板") { self.stepUp?.state?.phase == .ready }
        await waitUntil("倒计时没恢复") { self.stepUp?.state?.resendLeftSec == 48 }
        XCTAssertEqual(smsSends.count, 1, "倒计时内重开不再发码")
        XCTAssertEqual(stepUp?.state?.code, "", "新面板不带旧码")
        XCTAssertEqual(submits.count, 2)
        XCTAssertNotEqual(submits[0].header("Idempotency-Key"), submits[1].header("Idempotency-Key"), "关闭后键作废")
    }

    /// 倒计时中 resend 回调零发码；到点后恰一次（连点不重复），下一轮倒计时开始。
    func testResendThrottle() async throws {
        let host = try await panelOnWithdraw()
        try panelActions().resend()
        await settle()
        XCTAssertEqual(smsSends.count, 1, "倒计时中不发")
        host.wallet.clock = { Self.frozenMillis + 49000 }
        await waitUntil("倒计时没结束", timeout: 4) { self.stepUp?.state?.resendLeftSec == 0 }
        let actions = try panelActions()
        actions.resend()
        actions.resend()
        await waitUntil("没有重发") { self.smsSends.count == 2 }
        await waitUntil("新一轮倒计时") { (self.stepUp?.state?.resendLeftSec ?? 0) > 0 }
        await quietWindow(0.3)
        XCTAssertEqual(smsSends.count, 2, "连点恰一次")
        XCTAssertEqual(verifies.count, 0, "重发不验证")
        XCTAssertEqual(submits.count, 1, "重发不提交")
    }

    /// 发码失败不进倒计时：回退【重新获取】可用（行为层）。
    func testSendFailureFallsBackToResend() async throws {
        try await panelOnWithdraw(sms: Self.serverDown)
        XCTAssertEqual(stepUp?.state?.resendLeftSec, 0)
        XCTAssertNotNil(stepUp?.state?.error)
        try panelActions().resend()
        await waitUntil { self.smsSends.count == 2 }
    }

    // MARK: - owner 票据

    /// 面板身份 = 打开它的表单身份（两宿主）。
    func testPanelOwnerIsFlowOwner() async throws {
        let withdraw = try await panelOnWithdraw()
        XCTAssertEqual(withdraw.flow?.stepUp.state?.owner, withdraw.flow?.owner)
        XCTAssertEqual(withdraw.flow?.stepUp.state?.owner.account, "user-a")
        let payout = try await panelOnPayout()
        XCTAssertEqual(payout.flow?.stepUp.state?.owner, payout.flow?.owner)
    }

    /// 旧面板的回调（渲染时实例）在重开后零动作：输入不进新面板、验证 / 重发 / 关闭都不生效。
    func testStaleInstanceCallbacksDoNothing() async throws {
        let host = try await panelOnWithdraw()
        try enterCode("123456")
        let stale = try panelActions()
        stale.close()
        host.server.script.on("POST /v1/withdrawals", Self.need)
        host.actions?.submit()
        await waitUntil { self.stepUp?.state?.phase == .ready }
        stale.code("999999")
        stale.verify()
        stale.resend()
        stale.close()
        await quietWindow(0.4)
        XCTAssertEqual(stepUp?.state?.code, "", "旧回调不写新面板")
        XCTAssertNotNil(stepUp?.state, "旧【关闭】不关新面板")
        XCTAssertEqual(verifies.count, 0)
        XCTAssertEqual(smsSends.count, 1)
    }

    /// 换号：旧面板回调零写入，不用新账号发码 / 验证，不向新账号落 token（两宿主）。
    func testStaleCallbacksAfterAccountSwitchWriteNothing() async throws {
        for payout in [false, true] {
            let host: WithdrawVisualHost = if payout {
                try await panelOnPayout()
            } else {
                try await panelOnWithdraw()
            }
            try enterCode("123456")
            let stale = try panelActions()
            let before = writes
            try host.fixture.switchAccount(to: "user-b")
            await settle()
            stale.verify()
            stale.resend()
            stale.code("111111")
            await quietWindow(0.5)
            XCTAssertEqual(writes, before, "payout=\(payout)：换号后零写入")
            let action = payout ? "payout_account_change" : "withdraw"
            XCTAssertNil(host.wallet.deps.tokens.take(action: action, account: "user-b", nowMs: Self.frozenMillis),
                         "payout=\(payout)：token 不落到新账号")
        }
    }
}
