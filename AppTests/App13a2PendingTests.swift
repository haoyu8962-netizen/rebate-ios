@testable import Couli
import CouliNetwork
import Foundation
import Me
import MeCore
import Wallet
import WalletCore
import XCTest

/// APP-13a-2-ios T9 结果未知 → 待确认，【确认上一次提交】的各分支（brief §1「待确认」，共性第 7、44、47 条，G25，M9）。
/// 每条同时断言存储记录（MemoryPendingKeyBackend 原始视图）与请求头（Idempotency-Key / X-Step-Up-Token）。
@MainActor
final class App13a2PendingTests: App13a2TestCase {
    /// 进入待确认后的那条记录（结果未知、原键、原体）。
    private func pendingRecord() throws -> PendingKeyRecord {
        let record = try XCTUnwrap(records().first, "没有未决记录")
        XCTAssertEqual(record.stateRaw, PendingKeyStore.unknown)
        XCTAssertTrue(record.everUnknown)
        return record
    }

    /// 点【确认上一次提交】并等这次确认到达假服务、落定。
    private func confirm(_ controller: PhoneChangeController) async {
        let before = binds.count
        act(controller).confirmPending()
        await waitUntil("确认没有发出") { self.binds.count > before }
        await waitUntil("确认没有落定") { !controller.state.pendingBusy }
        await settle()
    }

    /// T9：结果未知 → 待确认卡；0 次新键请求（不自动重发）；卡片摘要是本机脱敏的新号；表单置灰；读屏 alert（assertive）。
    func testUnknownResultEntersPendingWithoutNewKey() async throws {
        let fixture = fixture()
        let (_, controller) = try await enterPending(fixture)
        let record = try pendingRecord()
        XCTAssertEqual(record.key, binds.first?.header("Idempotency-Key"), "记录键 = 发出的键")
        XCTAssertEqual(controller.state.pending?.key, record.key)
        XCTAssertEqual(controller.state.pending?.maskedPhone, Self.newMasked)
        XCTAssertFalse(controller.submitEnabled, "表单置灰")
        XCTAssertTrue(controller.pendingActionsEnabled)
        XCTAssertEqual(controller.state.announce?.assertive, true, "待确认卡出现：alert（T14）")
        await quietWindow(0.8)
        XCTAssertEqual(binds.count, 1, "不换键、不自动重发")
    }

    /// T9：确认成功 → Done（摘要取记录）；记录删除；确认用原键原体。
    func testConfirmSuccess() async throws {
        let fixture = fixture()
        let (_, controller) = try await enterPending(fixture)
        let record = try pendingRecord()
        script.on(Self.bindWrite, Self.code(0, "{}"))
        await confirm(controller)
        let request = try XCTUnwrap(binds.last)
        XCTAssertEqual(request.header("Idempotency-Key"), record.key, "原键")
        XCTAssertEqual(request.body, record.body, "原体")
        await waitUntil("确认成功没有进 Done") { controller.state.step == .done }
        XCTAssertEqual(controller.state.doneMaskedPhone, Self.newMasked)
        XCTAssertTrue(records().isEmpty, "键结束")
    }

    /// T9（三端任务书 §2.5，M9）：确认得到 10003 → 面板（phone_change），验证后沿用原键原体再确认，带新 token（与首次绑定 G53 不同）；记录在成功前保留。
    func testConfirm10003OpensPanelAndKeepsKey() async throws {
        let fixture = fixture()
        let (_, controller) = try await enterPending(fixture)
        let record = try pendingRecord()
        script.on(Self.bindWrite, Self.code(10003), Self.code(0, "{}"))
        act(controller).confirmPending()
        let stepUp = try XCTUnwrap(controller.stepUp)
        await waitUntil("确认 10003 没有弹面板（M9）") { stepUp.state?.phase == .ready }
        XCTAssertEqual(stepUp.state?.action, "phone_change")
        XCTAssertEqual(records().first?.key, record.key, "面板期间记录保留")
        XCTAssertEqual(records().first?.stateRaw, PendingKeyStore.unknown)
        StepUpActions.make(stepUp, try XCTUnwrap(stepUp.state)).code("112233")
        StepUpActions.make(stepUp, try XCTUnwrap(stepUp.state)).verify()
        await waitUntil("验证后没有再确认") { self.binds.count == 3 }
        let replay = binds[2]
        XCTAssertEqual(replay.header("Idempotency-Key"), record.key, "沿用原键")
        XCTAssertEqual(replay.body, record.body, "原体")
        XCTAssertEqual(replay.header("X-Step-Up-Token"), Self.panelToken)
        await waitUntil("没有进 Done") { controller.state.step == .done }
        XCTAssertTrue(records().isEmpty)
    }

    /// T9（共性第 44 条）：确认得到 20003 等 2xxxx → cannot_confirm，不标红字段；记录保持 unknown。
    func testConfirm20003CannotConfirmWithoutFieldError() async throws {
        let fixture = fixture()
        let (_, controller) = try await enterPending(fixture)
        let record = try pendingRecord()
        script.on(Self.bindWrite, Self.code(20003))
        await confirm(controller)
        XCTAssertEqual(binds.last?.header("Idempotency-Key"), record.key)
        XCTAssertEqual(controller.state.pendingNotice?.key, "pending_confirm.cannot_confirm")
        XCTAssertNil(controller.state.phoneError, "不标红字段")
        XCTAssertNil(controller.state.codeError)
        XCTAssertEqual(controller.state.step, .pending)
        XCTAssertEqual(records().first?.stateRaw, PendingKeyStore.unknown, "记录保留")
    }

    /// T9（共性第 44、47 条）：确认得到 3xxxx（30411）→ 回第 2 步并显示 error.30411.phone_change；记录删除；不并号。
    func testConfirm30411BackToStep2() async throws {
        let fixture = fixture()
        let (_, controller) = try await enterPending(fixture)
        let record = try pendingRecord()
        script.on(Self.bindWrite, Self.code(30411, "{\"reason\":\"mergeable\",\"merge_ticket\":\"mt-test-0002\"}"))
        await confirm(controller)
        XCTAssertEqual(binds.last?.header("Idempotency-Key"), record.key)
        await waitUntil("没有回第 2 步") { controller.state.step == .step2 }
        XCTAssertTrue(keys(controller.state).contains("error.30411.phone_change"))
        XCTAssertNil(controller.state.dialog, "不进并号")
        XCTAssertTrue(records().isEmpty, "3xxxx 键结束")
    }

    /// T9：确认得到 40901 / 5xxxx / 42901 → retry_later，保持待确认，记录保持 unknown、每次都用原键；42901 之后 phoneGate 让两个按钮置灰。
    func testConfirmRetryLaterBranches() async throws {
        let fixture = fixture()
        let (_, controller) = try await enterPending(fixture)
        let record = try pendingRecord()
        for reply in [Self.code(40901), Self.code(50001), Self.retryAfter(30)] {
            script.on(Self.bindWrite, reply)
            await confirm(controller)
            XCTAssertEqual(binds.last?.header("Idempotency-Key"), record.key, "原键")
            XCTAssertEqual(binds.last?.body, record.body, "原体")
            XCTAssertEqual(controller.state.pendingNotice?.key, "pending_confirm.retry_later")
            XCTAssertEqual(controller.state.step, .pending)
            XCTAssertEqual(records().first?.key, record.key)
            XCTAssertEqual(records().first?.stateRaw, PendingKeyStore.unknown)
        }
        XCTAssertTrue(fixture.bind.writeGated(fixture.bind.identity()), "42901 写进共用 phoneGate")
        XCTAssertFalse(controller.pendingActionsEnabled, "确认 / 放弃都置灰")
        let count = binds.count
        act(controller).confirmPending()
        await quietWindow(0.6)
        XCTAssertEqual(binds.count, count, "禁用期内 0 次发送")
    }

    /// T9（brief §1「在途时两个按钮都置灰」）：确认在途 → pendingBusy、两个按钮置灰；结果回来恢复。
    func testConfirmInFlightDisablesBothButtons() async throws {
        let fixture = fixture()
        let (_, controller) = try await enterPending(fixture)
        script.on(Self.bindWrite, .hold)
        act(controller).confirmPending()
        await waitUntil("确认没有挂起") { self.heldId(Self.bindWrite) != nil }
        XCTAssertTrue(controller.state.pendingBusy)
        XCTAssertFalse(controller.pendingActionsEnabled)
        WalletStubProtocol.release(try XCTUnwrap(heldId(Self.bindWrite)), with: Self.code(40901))
        await waitUntil("没有恢复") { !controller.state.pendingBusy }
        XCTAssertTrue(controller.pendingActionsEnabled)
    }
}
