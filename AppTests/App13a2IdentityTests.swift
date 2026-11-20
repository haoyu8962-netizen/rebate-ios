@testable import Couli
import CouliNetwork
import Foundation
import Me
import MeCore
import Session
import XCTest

/// APP-13a-2-ios T11 身份固定 S0（共性第 6、16、36、45、49 条，M8）与 T12 出栈 / 返回（共性第 21、27、28、35、48 条）。
@MainActor
final class App13a2IdentityTests: App13a2TestCase {
    private var writeCounts: [Int] {
        [stepSms.count, bindSms.count, sent(Self.stepUpVerify).count, binds.count, sent(Self.abandonWrite).count]
    }

    // MARK: - T11

    /// T11（M8）：保留真实页面的旧回调（输入、发码、下一步、提交、确认、放弃），换账号之后执行 → 0 次请求、0 次写入。
    func testStaleCallbacksAfterAccountSwitchDoNothing() async throws {
        let fixture = fixture()
        let (_, controller) = try await readyToSubmit(fixture)
        let stale = act(controller)
        try switchAccount(fixture, to: "user-b")
        await settle()
        let before = writeCounts
        stale.requestOldCode()
        stale.oldCode("123456")
        stale.next()
        stale.newPhone("13700002222")
        stale.requestNewCode()
        stale.newCode("222222")
        stale.submit()
        stale.confirmPending()
        stale.askAbandon()
        await quietWindow(1.0)
        XCTAssertEqual(writeCounts, before, "旧回调 0 次请求")
        XCTAssertTrue(records("user-b").isEmpty, "新账号 0 次写入")
        XCTAssertTrue(records().isEmpty, "旧账号 0 次写入")
    }

    /// T11（M8）：待确认卡的旧回调（确认、放弃）在作用域换代（同账号同登录世代 full → deletion_only）后执行 → 0 次请求；记录原样保留。
    func testStalePendingCallbacksAfterScopeChangeDoNothing() async throws {
        let fixture = fixture()
        let (_, controller) = try await enterPending(fixture)
        let record = try XCTUnwrap(records().first)
        let stale = act(controller)
        act(controller).askAbandon()
        let dialog = try XCTUnwrap(controller.state.dialog)
        try switchScope(fixture, to: SessionScope.deletionOnly)
        await settle()
        let before = writeCounts
        stale.confirmPending()
        stale.confirmAbandon(dialog)
        await quietWindow(1.0)
        XCTAssertEqual(writeCounts, before, "作用域换代后旧回调 0 次请求")
        XCTAssertEqual(records().first, record, "记录原样保留")
    }

    /// T11（共性第 36 条）：A 会话失效 → 登录 B：同步出口作废旧子页并清空 A 的新号、验证码、倒计时、待确认卡；B 的设置页没有旧子页。
    func testAccountSwitchClearsOldSubPage() async throws {
        let fixture = fixture()
        let (_, controller) = try await readyToSubmit(fixture)
        act(controller).requestNewCode()
        await waitUntil("第 2 步没有发码") { !self.bindSms.isEmpty && !controller.state.newSending }
        try switchAccount(fixture, to: "user-b")
        XCTAssertFalse(controller.alive, "同步作废（不等轮询）")
        XCTAssertEqual(controller.state.newPhone, "")
        XCTAssertEqual(controller.state.newCode, "")
        XCTAssertEqual(controller.state.newResendLeftSec, 0)
        XCTAssertNil(controller.state.pending)
        XCTAssertFalse(controller.hasStepToken)
        let top = try XCTUnwrap(fixture.router.path.last { $0.route == "Settings" })
        let settings = try XCTUnwrap(fixture.me.entry(for: top)?.controller() as? SettingsController)
        XCTAssertNil(settings.phoneChange, "B 的设置页没有 A 的子页")
        XCTAssertEqual(settings.state.sub, .none)
    }

    /// T11（共性第 49 条）：提交在途，作用域换代后迟到的 42901 不写新闸门（phoneGate）。
    func testLateSubmit42901AfterScopeChangeSkipsGate() async throws {
        script.on(Self.bindWrite, .hold)
        let fixture = fixture()
        let (_, controller) = try await readyToSubmit(fixture)
        await submit(controller)
        let held = try XCTUnwrap(heldId(Self.bindWrite))
        try switchScope(fixture, to: SessionScope.deletionOnly)
        WalletStubProtocol.release(held, with: Self.retryAfter(30))
        await quietWindow(0.8)
        XCTAssertFalse(fixture.bind.gate.active, "旧作用域的 42901 不写 phoneGate")
    }

    /// T11（共性第 49 条）：第 1 步验证在途，作用域换代后迟到的 42901 不写 gates.verify。
    func testLateVerify42901AfterScopeChangeSkipsVerifyGate() async throws {
        script.on(Self.stepUpVerify, .hold)
        let fixture = fixture()
        let (_, controller) = try await enter(fixture)
        act(controller).requestOldCode()
        await waitUntil("没有发码") { !self.stepSms.isEmpty && !controller.state.oldSending }
        act(controller).oldCode("123456")
        act(controller).next()
        await waitUntil("验证没有挂起") { self.heldId(Self.stepUpVerify) != nil }
        let held = try XCTUnwrap(heldId(Self.stepUpVerify))
        try switchScope(fixture, to: SessionScope.deletionOnly)
        WalletStubProtocol.release(held, with: Self.retryAfter(30))
        await quietWindow(0.8)
        XCTAssertFalse(fixture.wallet.deps.gates.verify.active, "旧作用域的 42901 不写 gates.verify")
    }

    // MARK: - T12

    /// T12（共性第 21、48 条）：提交在途时离开（设置页出栈）→ 写请求不取消；结果未知回来记录变 unknown，不改已离开的页面。
    func testLeavingDoesNotCancelWriteAndKeepsRecord() async throws {
        script.on(Self.bindWrite, .hold)
        let fixture = fixture()
        let (_, controller) = try await readyToSubmit(fixture)
        await submit(controller)
        let held = try XCTUnwrap(heldId(Self.bindWrite))
        fixture.router.path = []
        XCTAssertFalse(controller.alive)
        XCTAssertNil(fixture.wallet.deps.tokens.take(action: "phone_change", account: Self.account, nowMs: 0),
                     "离开子页清 phone_change 的共享 token（G23）")
        WalletStubProtocol.release(held, with: .disconnect)
        await waitUntil("结果未知没有落到记录") { self.records().first?.stateRaw == PendingKeyStore.unknown }
        XCTAssertNotEqual(controller.state.step, .pending, "不改已离开的页面")
        XCTAssertEqual(binds.count, 1)
    }

    /// T12（共性第 25 条）：离开后成功迟到 → 共享结算照做（getMe 重取、全部 token 清），已离开的页面不进 Done。
    func testLateSuccessAfterLeavingStillSettlesShared() async throws {
        script.on(Self.bindWrite, .hold)
        let fixture = fixture()
        let (_, controller) = try await readyToSubmit(fixture)
        fixture.wallet.deps.tokens.put(action: "withdraw", account: Self.account, token: "t-w", expireAtMs: Int64.max)
        await submit(controller)
        let held = try XCTUnwrap(heldId(Self.bindWrite))
        fixture.router.path = []
        let reads = sent(Self.meRead).count
        WalletStubProtocol.release(held, with: Self.code(0, "{}"))
        await waitUntil("共享结算没有重取 getMe") { self.sent(Self.meRead).count > reads }
        XCTAssertNil(fixture.wallet.deps.tokens.take(action: "withdraw", account: Self.account, nowMs: 0))
        XCTAssertNotEqual(controller.state.step, .done)
        XCTAssertTrue(records().isEmpty)
    }

    /// T12（共性第 27、28、35 条）：第 2 步的页面返回与系统返回（设置页 closeSub）都回第 1 步（不提交），并重置第 2 步瞬时状态。
    func testBothBackPathsReturnToStep1() async throws {
        let fixture = fixture()
        let (settings, controller) = try await readyToSubmit(fixture)
        act(controller).back()
        XCTAssertEqual(controller.state.step, .step1, "页面返回 → 第 1 步")
        XCTAssertEqual(controller.state.newCode, "")
        XCTAssertFalse(controller.state.newSending)
        XCTAssertFalse(controller.state.submitting)
        XCTAssertNil(controller.state.phoneError)
        XCTAssertNil(controller.state.codeError)
        XCTAssertEqual(settings.state.sub, .phoneChange, "仍在子页")
        await passStep1(controller)
        fillStep2(controller)
        SettingsActions.make(settings, settings.state).closeSub()
        XCTAssertEqual(controller.state.step, .step1, "系统返回 → 第 1 步（同一处理）")
        XCTAssertEqual(controller.state.newCode, "")
        XCTAssertEqual(settings.state.sub, .phoneChange)
        XCTAssertTrue(binds.isEmpty, "返回不提交")
        SettingsActions.make(settings, settings.state).closeSub()
        XCTAssertEqual(settings.state.sub, .none, "第 1 步再返回 → 设置页")
    }

    /// T12（共性第 28、35 条）：第 2 步发码在途时返回第 1 步，迟到的发码只结算共享倒计时，不更新已换代的表单。
    func testLateBindSmsOnlySettlesCountdown() async throws {
        script.on(Self.smsSend, .envelope(code: 0, data: "{\"resend_after_sec\":60,\"expires_in_sec\":300}",
                                          headers: [:]), .hold)
        let fixture = fixture()
        let (_, controller) = try await readyToSubmit(fixture)
        act(controller).requestNewCode()
        await waitUntil("第 2 步发码没有挂起") { self.heldId(Self.smsSend) != nil }
        let held = try XCTUnwrap(heldId(Self.smsSend))
        act(controller).back()
        WalletStubProtocol.release(held, with: .envelope(code: 0, data: "{\"resend_after_sec\":60}", headers: [:]))
        await quietWindow(0.6)
        XCTAssertEqual(controller.state.step, .step1)
        XCTAssertFalse(controller.state.newCodeSent, "不更新已换代的表单")
        let owner = fixture.bind.identity()
        XCTAssertGreaterThan(fixture.bind.smsRemainingSec(owner, phone: Self.newPhone, now: fixture.bind.clock()), 0,
                             "共享倒计时照常结算")
    }
}
