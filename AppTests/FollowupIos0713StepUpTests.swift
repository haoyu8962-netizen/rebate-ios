@testable import Couli
import CouliNetwork
import Foundation
import Router
import Wallet
@testable import WalletCore
import XCTest

/// 可控的钱包本机时钟（发码倒计时按它算）。
@MainActor
final class StepClock {
    var now: Int64 = 1_760_000_000_000
}

/// FU-IOS-0713 必测 1（RW-04）：二次验证面板的发码结果、验证结果、等待其他发码完成三条分支遇身份暂时未知。
/// 全部经生产入口（提现【提交】→ 10003 → 面板；面板回调取渲染时的 StepUpActions；身份确认走 AppWallet.checkSession）。
/// 故障按读取位置遍历（「仅第 n 次」「第 n 次起持续」）。统一要求：面板展示不在「发送中 / 验证中」、显示本页【重试】（展示接口
/// `showsSending / showsVerifying / showsRecheck`，页面接线由 tools/ci/check-identity-wiring.py 守住）；面板不被收起、仍是同一实例；
/// 等待期间面板入口不调用发码 / 验证入口；确认后同一面板按原结果恢复（倒计时按原截止、token 交原键重放）。
/// 计数分两层：`WalletApi` 调用入口（`fixture.api`，生产注入的透明计数）与假服务实际收到的请求；负向断言都在 `whenIdle()`
/// （面板、敏感流程已发起含已排队的异步任务全部结束）之后取值。
final class FollowupIos0713StepUpTests: WalletFlowTestCase {
    private let suites = FreshSuites()

    override func tearDown() {
        suites.removeAll()
        super.tearDown()
    }

    static let smsOk = WalletStubProtocol.Reply.envelope(
        code: 0, data: "{\"resend_after_sec\":60,\"expires_in_sec\":300}", headers: [:]
    )
    static let stepOk = WalletStubProtocol.Reply.envelope(
        code: 0, data: "{\"step_up_token\":\"fixture-step-up\",\"expire_at\":\"2099-01-01T00:05:00+08:00\"}",
        headers: [:]
    )
    static let need = WalletStubProtocol.Reply.envelope(code: 10003, data: "null", headers: [:])
    static let landed = WalletStubProtocol.Reply.envelope(
        code: 0, data: WalletSamples.withdrawal("W-step"), headers: [:]
    )

    /// 入口与实际发送的计数（同一时刻取值）。
    struct Counts: Equatable {
        var smsCalls = 0
        var verifyCalls = 0
        var withdrawCalls = 0
        var smsSent = 0
        var verifySent = 0
        var withdrawSent = 0
    }

    func counts(_ fixture: WalletAppFixture) -> Counts {
        Counts(
            smsCalls: fixture.api.calls(StepUpController.sendOperation),
            verifyCalls: fixture.api.calls(StepUpController.verifyOperation),
            withdrawCalls: fixture.api.calls(WithdrawController.operation),
            smsSent: WalletStubProtocol.requests("POST", "/v1/auth/sms-codes").count,
            verifySent: WalletStubProtocol.requests("POST", "/v1/auth/step-up").count,
            withdrawSent: posts.count
        )
    }

    var withdrawKeys: Set<String> {
        Set(posts.compactMap { $0.header("Idempotency-Key") })
    }

    /// 每轮一个全新的组合（独立 UserDefaults、缓存目录、假服务记录）。
    func fresh(_ tag: String, clock: StepClock) -> WalletAppFixture {
        WalletStubProtocol.reset()
        script.install()
        let (name, defaults) = suites.make(suiteName, tag)
        let fixture = WalletAppFixture.make(suiteName: name, defaults: defaults)
        fixture.wallet.clock = { clock.now }
        return fixture
    }

    /// 面板与敏感流程已发起（含已排队）的异步任务全部结束（生产完成信号；两者互相触发，交替等到都空）。
    func idle(_ controller: WithdrawController) async {
        for _ in 0..<3 {
            await controller.flow.stepUp.whenIdle()
            await controller.flow.whenIdle()
        }
    }

    /// 面板不在忙碌展示、仍是同一面板、不显示通用错误（F-X-22）。`waiting`：结果待身份确认，必须显示本页【重试】。
    func assertSettledPanel(_ stepUp: StepUpController, panel: Int, waiting: Bool, _ tag: String,
                            file: StaticString = #filePath, line: UInt = #line) throws {
        let state = try XCTUnwrap(stepUp.state, "\(tag)：身份未知不得收起面板", file: file, line: line)
        XCTAssertEqual(state.instance, panel, "\(tag)：仍是同一面板", file: file, line: line)
        XCTAssertFalse(state.showsSending, "\(tag)：不显示发送中", file: file, line: line)
        XCTAssertFalse(state.showsVerifying, "\(tag)：【验证并提交】不转圈", file: file, line: line)
        if waiting {
            XCTAssertTrue(state.showsRecheck, "\(tag)：显示本页【重试】", file: file, line: line)
        }
        if let error = state.error {
            XCTAssertFalse(error.key.hasPrefix("error."), "\(tag)：不显示通用错误（\(error.key)）", file: file, line: line)
        }
    }

    /// 等待期间点面板上的【重新获取】（`verify`：再填码点【验证并提交】）；等面板与流程空闲后，入口与发送计数都不增加。
    func tapPanelEntries(_ fixture: WalletAppFixture, _ controller: WithdrawController, _ tag: String,
                         verify: Bool = false) async {
        let stepUp = controller.flow.stepUp
        let before = counts(fixture)
        if let state = stepUp.state {
            StepUpActions.make(stepUp, state).resend()
        }
        if verify, let state = stepUp.state {
            StepUpActions.make(stepUp, state).code("123456")
            if let filled = stepUp.state {
                StepUpActions.make(stepUp, filled).verify()
            }
        }
        await idle(controller)
        let after = counts(fixture)
        XCTAssertEqual(after, before, "\(tag)：等待期间面板入口不调用发码 / 验证 / 提现入口")
    }

    /// 打开提现页、输入金额、点【提交】得到 10003，面板打开。
    func openPanel(_ fixture: WalletAppFixture) async throws -> (WithdrawController, StepUpController) {
        let controller = try await withdraw(fixture)
        await typeAmount(controller, "10")
        actions(controller).submit()
        let stepUp = controller.flow.stepUp
        await waitUntil("二次验证面板没有打开") { stepUp.state != nil }
        return (controller, stepUp)
    }

    /// 确认后同一面板按原截止恢复倒计时（到达后时钟已前进 20 秒：剩余 1…40 秒；从确认时重新计时会是 60），倒计时内点【重新获取】不调用入口。
    func assertRestoredCountdown(_ fixture: WalletAppFixture, _ controller: WithdrawController, panel: Int,
                                 _ tag: String) async throws {
        let stepUp = controller.flow.stepUp
        await waitUntil("\(tag)：确认后没有按原截止恢复倒计时") {
            guard let state = stepUp.state else { return false }
            return state.phase == .ready && !state.showsRecheck && (1...40).contains(state.resendLeftSec)
        }
        let restored = try XCTUnwrap(stepUp.state)
        XCTAssertEqual(restored.instance, panel, "\(tag)：恢复的是同一面板")
        StepUpActions.make(stepUp, restored).resend()
        await idle(controller)
        let now = counts(fixture)
        XCTAssertEqual(now.smsCalls, 1, "\(tag)：倒计时内不调用发码入口")
    }

    /// 验证并提交 → 原键重放 → 进提现记录。结束后：发码、验证入口各 1；提现入口 `withdrawals` 次（每次 10003 + 一次原键重放）。
    func finishAndAssertLanded(_ fixture: WalletAppFixture, _ controller: WithdrawController, _ tag: String,
                               withdrawals: Int) async throws {
        try await passStepUp(controller.flow.stepUp)
        await waitUntil("\(tag)：没有落地") { fixture.router.path.last?.route == WalletRoutes.withdrawRecords }
        await idle(controller)
        let final = counts(fixture)
        XCTAssertEqual(final.smsCalls, 1, "\(tag)：发码入口恰好 1 次")
        XCTAssertEqual(final.smsSent, 1, "\(tag)：发码实际发送 1 次")
        XCTAssertEqual(final.verifyCalls, 1, "\(tag)：验证入口恰好 1 次")
        XCTAssertEqual(final.withdrawCalls, withdrawals, "\(tag)：提现入口次数")
        XCTAssertEqual(final.withdrawSent, withdrawals, "\(tag)：提现实际发送次数")
        XCTAssertEqual(posts.last?.header("Idempotency-Key"), posts.dropLast().last?.header("Idempotency-Key"),
                       "\(tag)：重放沿用 10003 那一笔的原键")
    }

    // MARK: - 发码结果（StepUpController+Send launchSend / onSent）

    /// 发码成功响应到达时身份暂时未知（按读取位置遍历）：面板不显示发送中、不被收起；等待期间【重新获取】不调用入口；时钟前进 20 秒后
    /// 身份确认 → 同一面板按原截止恢复倒计时（不重新计时、不延长）；之后验证并提交照常落地。
    func testSendResultWhileIdentityUnknownRestoresSamePanelAtOriginalDeadline() async throws {
        try await forEachReadPosition("发码结果") { fault, nth in
            let tag = "发码结果/\(fault.rawValue)#\(nth)"
            let clock = StepClock()
            let fixture = fresh(tag, clock: clock)
            script.on("POST /v1/withdrawals", Self.need, Self.landed)
            script.on("POST /v1/auth/sms-codes", .hold, Self.smsOk)
            let (controller, stepUp) = try await openPanel(fixture)
            await waitUntil("\(tag)：发码没有挂住") { WalletStubProtocol.heldIds.count == 1 }
            let panel = try XCTUnwrap(stepUp.state?.instance)
            let held = try XCTUnwrap(WalletStubProtocol.heldIds.first)
            let window = FaultWindow(fixture.store)
            window.begin(fault, nth)
            WalletStubProtocol.release(held, with: Self.smsOk)
            await waitUntil("\(tag)：发码结果到达后仍显示发送中") { stepUp.state.map { !$0.showsSending } ?? true }
            try assertSettledPanel(stepUp, panel: panel, waiting: stepUp.state?.resendLeftSec == 0, tag)
            await tapPanelEntries(fixture, controller, tag)
            clock.now += 20000
            let used = window.end()
            fixture.wallet.checkSession()
            try await assertRestoredCountdown(fixture, controller, panel: panel, tag)
            clock.now += 41000
            await waitUntil("\(tag)：原截止之后仍在倒计时（被延长）") { stepUp.state?.resendLeftSec == 0 }
            try await finishAndAssertLanded(fixture, controller, tag, withdrawals: 2)
            return used
        }
    }

    // MARK: - 等待其他发码完成（awaitOther / otherSettled）

    /// 第一个面板的发码在途时关闭面板、再点【提交】得到 10003：新面板等那次发码结束（同一槽位）。那次发码的成功结果到达时身份暂时未知
    /// （按读取位置遍历）：新面板不显示发送中；确认后同一面板按共享截止恢复倒计时，不另调用发码入口。
    func testWaitingForOtherSendWhileIdentityUnknownRestoresSharedDeadline() async throws {
        try await forEachReadPosition("等待其他发码") { fault, nth in
            let tag = "等待其他发码/\(fault.rawValue)#\(nth)"
            let clock = StepClock()
            let fixture = fresh(tag, clock: clock)
            script.on("POST /v1/withdrawals", Self.need, Self.need, Self.landed)
            script.on("POST /v1/auth/sms-codes", .hold, Self.smsOk)
            let (controller, stepUp) = try await openPanel(fixture)
            await waitUntil("\(tag)：发码没有挂住") { WalletStubProtocol.heldIds.count == 1 }
            let first = try XCTUnwrap(stepUp.state)
            StepUpActions.make(stepUp, first).close()
            await waitUntil("\(tag)：关闭面板后没有回到编辑态") { controller.flow.state.phase == .editing }
            actions(controller).submit()
            await waitUntil("\(tag)：第二个面板没有在等待") {
                stepUp.state.map { $0.instance != first.instance && $0.showsSending } ?? false
            }
            let panel = try XCTUnwrap(stepUp.state?.instance)
            XCTAssertEqual(counts(fixture).smsCalls, 1, "\(tag)：前提：第二个面板没有另调用发码入口")
            let held = try XCTUnwrap(WalletStubProtocol.heldIds.first)
            let window = FaultWindow(fixture.store)
            window.begin(fault, nth)
            WalletStubProtocol.release(held, with: Self.smsOk)
            await waitUntil("\(tag)：那次发码结束后仍显示发送中") { stepUp.state.map { !$0.showsSending } ?? true }
            try assertSettledPanel(stepUp, panel: panel, waiting: stepUp.state?.resendLeftSec == 0, tag)
            await tapPanelEntries(fixture, controller, tag)
            clock.now += 20000
            let used = window.end()
            fixture.wallet.checkSession()
            try await assertRestoredCountdown(fixture, controller, panel: panel, tag)
            try await finishAndAssertLanded(fixture, controller, tag, withdrawals: 3)
            return used
        }
    }
}
