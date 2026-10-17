@testable import Couli
import CouliNetwork
import Foundation
import Router
import Wallet
@testable import WalletCore
import XCTest

/// FU-IOS-0713 必测 1（RW-04）续：验证结果分支、面板本页核对出口、确认换代对照。
extension FollowupIos0713StepUpTests {
    /// 填码并点【验证并提交】，等验证请求挂住（假服务已收到）。
    func verifyAndHold(_ stepUp: StepUpController, _ tag: String) async throws -> Int {
        await waitUntil("\(tag)：面板没有可输入") { stepUp.state?.phase == .ready }
        let state = try XCTUnwrap(stepUp.state)
        StepUpActions.make(stepUp, state).code("123456")
        let filled = try XCTUnwrap(stepUp.state)
        StepUpActions.make(stepUp, filled).verify()
        await waitUntil("\(tag)：验证没有挂住") { WalletStubProtocol.heldIds.count == 1 }
        return try XCTUnwrap(WalletStubProtocol.heldIds.first)
    }

    func heldSend(_ tag: String) async throws -> Int {
        await waitUntil("\(tag)：发码没有挂住") { WalletStubProtocol.heldIds.count == 1 }
        return try XCTUnwrap(WalletStubProtocol.heldIds.first)
    }

    /// 原键重放已到服务端、挂着。
    var replayHeld: Bool {
        posts.count == 2 && WalletStubProtocol.heldIds.count == 1
    }

    /// 重放在网络层发送前被本地拒绝（凭据不可读，F-IOS-16 裁定接受）：入口调用了、没有发出、回到编辑态并提示网络错误。
    func localRejected(_ fixture: WalletAppFixture, _ controller: WithdrawController) -> Bool {
        fixture.api.calls(WithdrawController.operation) == 2 && posts.count == 1
            && controller.flow.state.phase == .editing && controller.flow.state.error?.key == WalletErrors.networkKey
    }

    // MARK: - 验证结果（StepUpController.verify / onVerified）

    /// 验证成功（token）响应到达时身份暂时未知（按读取位置遍历，含 token 交给发起方后原键重放的发送前核对）：面板不显示验证中、显示本页
    /// 【重试】；等待期间再填码点【验证并提交】、【重新获取】都不调用入口；确认后按保留的 token 原键重放一次并落地。
    /// 重放请求在假服务挂住：故障窗口在重放到达服务端（或面板 / 流程结算）时结束，之后的回包处理不在本条范围（FU-IOS-0712 已覆盖）。
    /// 唯一接受的另一结局：重放在网络层发送前本地拒绝（F-IOS-16）。
    func testVerifyResultWhileIdentityUnknownDeliversHeldTokenOnce() async throws {
        try await forEachReadPosition("验证结果") { fault, nth in
            let tag = "验证结果/\(fault.rawValue)#\(nth)"
            let fixture = fresh(tag, clock: StepClock())
            script.on("POST /v1/withdrawals", Self.need, .hold, Self.landed)
            script.on("POST /v1/auth/step-up", .hold, Self.stepOk)
            let (controller, stepUp) = try await openPanel(fixture)
            let panel = try XCTUnwrap(stepUp.state?.instance)
            let held = try await verifyAndHold(stepUp, tag)
            let window = FaultWindow(fixture.store)
            window.begin(fault, nth)
            WalletStubProtocol.release(held, with: Self.stepOk)
            await waitUntil("\(tag)：验证结果到达后仍显示验证中") {
                replayHeld || localRejected(fixture, controller) || stepUp.state.map { !$0.showsVerifying } ?? true
            }
            if stepUp.state != nil {
                try assertSettledPanel(stepUp, panel: panel, waiting: true, tag)
                await tapPanelEntries(fixture, controller, tag, verify: true)
            }
            let used = window.end()
            fixture.wallet.checkSession()
            await waitUntil("\(tag)：确认后没有重放") { replayHeld || localRejected(fixture, controller) }
            try await assertReplayOutcome(fixture, controller, tag)
            return used
        }
    }

    func assertReplayOutcome(_ fixture: WalletAppFixture, _ controller: WithdrawController,
                             _ tag: String) async throws {
        if replayHeld {
            let replay = try XCTUnwrap(WalletStubProtocol.heldIds.first)
            WalletStubProtocol.release(replay, with: Self.landed)
            await waitUntil("\(tag)：重放成功后没有落地") {
                fixture.router.path.last?.route == WalletRoutes.withdrawRecords
            }
            XCTAssertEqual(withdrawKeys.count, 1, "\(tag)：重放沿用同一幂等键")
        }
        await idle(controller)
        let final = counts(fixture)
        XCTAssertNil(controller.flow.stepUp.state, "\(tag)：面板收起")
        XCTAssertEqual(final.verifyCalls, 1, "\(tag)：验证入口恰好 1 次")
        XCTAssertEqual(final.smsCalls, 1, "\(tag)：发码入口恰好 1 次")
        XCTAssertEqual(final.withdrawCalls, 2, "\(tag)：提现入口恰好 2 次（10003 + 一次原键重放）")
        XCTAssertLessThanOrEqual(final.withdrawSent, 2, "\(tag)：提现实际发送至多 2 次（重放可能被发送前本地拒绝）")
    }

    // MARK: - 本页核对出口（接口约定：StepUpActions.recheck）

    /// 结果已到、身份暂时未知时面板有本页出口：身份仍不可读时点【重试】并等结算 → 什么都不调用、仍等待；Keychain 恢复后（之前没有任何
    /// 外部 checkSession）点【重试】→ 同一面板按原结果恢复（发码：倒计时；验证：原键重放一次并落地，入口总数：提现 2、短信 1、验证 1）。
    func testSettledPanelHasInPageRecheckExit() async throws {
        for branch in ["发码", "验证"] {
            let tag = "本页出口/\(branch)"
            let clock = StepClock()
            let fixture = fresh(tag, clock: clock)
            script.on("POST /v1/withdrawals", Self.need, Self.landed)
            script.on("POST /v1/auth/sms-codes", branch == "发码" ? .hold : Self.smsOk, Self.smsOk)
            script.on("POST /v1/auth/step-up", .hold, Self.stepOk)
            let (controller, stepUp) = try await openPanel(fixture)
            let panel = try XCTUnwrap(stepUp.state?.instance)
            let held = if branch == "发码" {
                try await heldSend(tag)
            } else {
                try await verifyAndHold(stepUp, tag)
            }
            fixture.store.failReads(fromNth: 1)
            WalletStubProtocol.release(held, with: branch == "发码" ? Self.smsOk : Self.stepOk)
            await waitUntil("\(tag)：结果到达后仍忙碌") {
                stepUp.state.map { !$0.showsSending && !$0.showsVerifying } ?? true
            }
            try assertSettledPanel(stepUp, panel: panel, waiting: true, tag)
            let before = counts(fixture)
            StepUpActions.make(stepUp, try XCTUnwrap(stepUp.state)).recheck()
            await idle(controller)
            let stillWaiting = try XCTUnwrap(stepUp.state, "\(tag)：身份仍不可读时【重试】不收起面板")
            XCTAssertTrue(stillWaiting.showsRecheck, "\(tag)：身份仍不可读：仍等待")
            XCTAssertEqual(counts(fixture), before, "\(tag)：身份仍不可读时【重试】不调用任何入口")
            clock.now += 20000
            fixture.store.disarm()
            StepUpActions.make(stepUp, try XCTUnwrap(stepUp.state)).recheck()
            if branch == "发码" {
                try await assertRestoredCountdown(fixture, controller, panel: panel, tag)
            } else {
                await waitUntil("\(tag)：本页【重试】后没有落地") {
                    fixture.router.path.last?.route == WalletRoutes.withdrawRecords
                }
                await idle(controller)
                let final = counts(fixture)
                XCTAssertEqual(final.withdrawCalls, 2, "\(tag)：提现入口恰好 2 次（10003 + 一次原键重放）")
                XCTAssertEqual(final.withdrawSent, 2, "\(tag)：提现实际发送 2 次")
                XCTAssertEqual(final.smsCalls, 1, "\(tag)：发码入口 1 次")
                XCTAssertEqual(final.verifyCalls, 1, "\(tag)：验证入口 1 次")
                XCTAssertEqual(withdrawKeys.count, 1, "\(tag)：同一幂等键")
            }
        }
    }

    // MARK: - 对照：确认换代

    /// 对照（未知只延后、确认换代才丢弃）：验证结果在身份持续未知时到达后，确认换成另一个账号 → 面板收起、保留的 token 不交给新会话、
    /// 不重放（面板与流程空闲后，提现入口仍只有最初那一笔）。
    func testHeldVerifyResultDroppedOnConfirmedSessionChange() async throws {
        let tag = "换代对照"
        let fixture = fresh(tag, clock: StepClock())
        script.on("POST /v1/withdrawals", Self.need, Self.landed)
        script.on("POST /v1/auth/step-up", .hold, Self.stepOk)
        let (controller, stepUp) = try await openPanel(fixture)
        let held = try await verifyAndHold(stepUp, tag)
        fixture.store.failReads(fromNth: 1)
        WalletStubProtocol.release(held, with: Self.stepOk)
        // 验证请求的回包处理结束（生产完成信号），再确认换代
        await idle(controller)
        fixture.store.disarm()
        try fixture.switchAccount(to: "user-b")
        fixture.wallet.checkSession()
        await waitUntil("\(tag)：换代后面板没有收起") { stepUp.state == nil }
        await idle(controller)
        let final = counts(fixture)
        XCTAssertEqual(final.withdrawCalls, 1, "\(tag)：不重放（入口）")
        XCTAssertEqual(final.withdrawSent, 1, "\(tag)：不重放（发送）")
        XCTAssertNotEqual(fixture.router.path.last?.route, WalletRoutes.withdrawRecords, "\(tag)：不落地")
    }
}
