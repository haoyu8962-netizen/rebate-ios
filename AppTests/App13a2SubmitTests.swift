@testable import Couli
import CouliNetwork
import Foundation
import Login
import Me
import MeCore
import Wallet
import WalletCore
import XCTest

/// APP-13a-2-ios T3 第 2 步发码（规范化号码同一限流槽、与 BindPhone 页共用截止时间）、T4 提交成功（带第 1 步 token、新键、原体、脱敏摘要、Done
/// 固定摘要、共享结算：getMe 重取、全部 token 清空、会话不清）、T5 提交 10003 → 面板 → 原键原体重放 1 次、不循环。
@MainActor
final class App13a2SubmitTests: App13a2TestCase {
    // MARK: - T3

    /// T3（共性第 15、30 条，G85）：「+86 139 0000 1234」与「13900001234」落在同一个 bind 限流槽；这份截止时间与 BindPhone 页
    /// （BindPhoneService）共用。
    func testBindSmsSlotIsNormalizedAndShared() async throws {
        let fixture = fixture()
        let (_, controller) = try await enter(fixture)
        await passStep1(controller)
        act(controller).newPhone("+86 139 0000 1234")
        act(controller).requestNewCode()
        await waitUntil("第 2 步没有发码") { !self.bindSms.isEmpty }
        await waitUntil("第 2 步发码没有回来") { !controller.state.newSending }
        XCTAssertEqual(bindSms.count, 1)
        XCTAssertEqual(bindSms.first?.json["purpose"] as? String, "bind")
        let owner = fixture.bind.identity()
        XCTAssertGreaterThan(
            fixture.bind.smsRemainingSec(owner, phone: Self.newPhone, now: fixture.bind.clock()), 0,
            "截止时间按规范化号码记在 BindPhoneService（与 BindPhone 页同一份）"
        )
        act(controller).newPhone(Self.newPhone)
        XCTAssertGreaterThan(controller.state.newResendLeftSec, 0, "换一种写法仍在同一槽的倒计时内")
        XCTAssertFalse(controller.newCodeSendEnabled)
        act(controller).requestNewCode()
        await quietWindow(0.6)
        XCTAssertEqual(bindSms.count, 1, "同一槽不再发")
    }

    /// T3 反向：BindPhone 页先为这个号码发过码 → 换号第 2 步同一号码直接显示倒计时、不再发。
    func testBindPageDeadlineAppliesToPhoneChange() async throws {
        let fixture = fixture()
        let (_, controller) = try await enter(fixture)
        await passStep1(controller)
        var done = false
        fixture.bind.sendCode(fixture.bind.identity(), phone: Self.newPhone) { _ in done = true }
        await waitUntil("BindPhone 发码没有回来") { done }
        act(controller).newPhone("139 0000 1234")
        XCTAssertGreaterThan(controller.state.newResendLeftSec, 0)
        act(controller).requestNewCode()
        await quietWindow(0.6)
        XCTAssertEqual(bindSms.count, 1, "共用截止时间：换号页不再发")
    }

    // MARK: - T4

    /// T4（brief §1 第 2 步、G24、G33、M1）：提交带第 1 步的 X-Step-Up-Token、新的 Idempotency-Key，体只有 phone（去首尾空白的原文）与 code；
    /// 写出时的未决记录摘要只含本机脱敏号码。
    func testSubmitCarriesStepTokenNewKeyAndMaskedSummary() async throws {
        script.on(Self.bindWrite, .hold)
        let fixture = fixture()
        let (_, controller) = try await readyToSubmit(fixture, phone: "  \(Self.newPhone) ")
        await submit(controller)
        let request = try XCTUnwrap(binds.last)
        XCTAssertEqual(request.header("X-Step-Up-Token"), Self.stepToken, "更换带第 1 步 token（M1）")
        let key = try XCTUnwrap(request.header("Idempotency-Key"))
        XCTAssertFalse(key.isEmpty)
        XCTAssertEqual(request.json["phone"] as? String, Self.newPhone, "只去首尾空白（G33）")
        XCTAssertEqual(request.json["code"] as? String, "654321")
        XCTAssertEqual(Set(request.json.keys), ["phone", "code"])
        let record = try XCTUnwrap(records().first, "写出前落未决记录")
        XCTAssertEqual(record.key, key, "记录键 = 请求头的键")
        XCTAssertEqual(record.body, request.body, "记录原体 = 实际发出的字节")
        XCTAssertTrue(record.summary.contains(Self.newMasked), "摘要是脱敏号码（G24）")
        XCTAssertFalse(record.summary.contains(Self.newPhone), "摘要不含明文号码")
        XCTAssertFalse(controller.submitEnabled, "在途不可再点")
        WalletStubProtocol.release(try XCTUnwrap(heldId(Self.bindWrite)), with: Self.code(0, "{}"))
        await waitUntil("没有进 Done") { controller.state.step == .done }
    }

    /// T4（G33、brief §11 第 11 项）：带国家码与空格的输入原样提交（只去首尾空白），摘要与 Done 用规整后的脱敏号码。
    func testFormattedInputSubmittedVerbatim() async throws {
        let fixture = fixture()
        let (_, controller) = try await readyToSubmit(fixture, phone: " +86 139 0000 1234 ")
        await submit(controller)
        XCTAssertEqual(binds.last?.json["phone"] as? String, "+86 139 0000 1234")
        await waitUntil("没有进 Done") { controller.state.step == .done }
        XCTAssertEqual(controller.state.doneMaskedPhone, Self.newMasked)
    }

    /// T4（共性第 9、13、17 条，D10-2192 / 补 (a)，M5）：成功 → Done 显示实际发送的固定摘要（在途时改表单也不变）；共享结算清**全部** action 的
    /// token、重取 getMe、流程 token 失效；当前设备不退出、不清会话，成功页文案没有「重新登录」。
    func testSuccessSharedSettlementKeepsSession() async throws {
        script.on(Self.bindWrite, .hold)
        let fixture = fixture()
        let (settings, controller) = try await readyToSubmit(fixture)
        let tokens = fixture.wallet.deps.tokens
        for action in ["withdraw", "payout_account_change", "account_deletion"] {
            tokens.put(action: action, account: Self.account, token: "t-\(action)", expireAtMs: Int64.max)
        }
        let reads = sent(Self.meRead).count
        await submit(controller)
        act(controller).newPhone("13700007777")
        WalletStubProtocol.release(try XCTUnwrap(heldId(Self.bindWrite)), with: Self.code(0, "{}"))
        await waitUntil("没有进 Done") { controller.state.step == .done }
        XCTAssertEqual(controller.state.doneMaskedPhone, Self.newMasked, "Done 取实际发送的固定摘要（共性第 17 条）")
        for action in ["withdraw", "payout_account_change", "account_deletion", "phone_change"] {
            XCTAssertNil(tokens.take(action: action, account: Self.account, nowMs: 0), "\(action) 的 token 清掉（M5）")
        }
        XCTAssertFalse(controller.hasStepToken, "流程 token 失效")
        await waitUntil("getMe 没有重取") { self.sent(Self.meRead).count > reads }
        XCTAssertTrue(fixture.login.loggedIn, "当前设备不退出（D10-2192）")
        XCTAssertTrue(sent("POST /v1/auth/logout").isEmpty)
        XCTAssertFalse(fixture.router.path.contains { $0.route == "Login" }, "不引导重新登录")
        let texts = fixture.me.deps.texts
        for key in ["phone_change.done.title", "phone_change.done.desc"] {
            XCTAssertFalse(texts.format(key, ["phone": Self.newMasked]).contains("重新登录"), key)
        }
        XCTAssertNil(controller.state.notice, "成功页没有额外提示")
        // 【完成】回设置页的唯一实例；设置行按重取的 Me 刷新
        act(controller).finish()
        XCTAssertEqual(settings.state.sub, .none)
        XCTAssertEqual(fixture.router.path.filter { $0.route == "Settings" }.count, 1)
    }

    // MARK: - T5

    /// T5（共性第 17 条，M2）：提交 10003 → 面板（action = phone_change，发码 / 验证体同第 1 步口径）→ 只用同一个键、同一份请求体、新 token 重放 1 次；
    /// 重放再遇 10003 不循环（不再弹面板、不再发）。
    func testSubmit10003ReplaysOnceWithSameKeyAndBody() async throws {
        script.on(Self.bindWrite, Self.code(10003), Self.code(10003))
        // 倒计时 5 秒：第 1 步与面板共用同一份「账号 + action」发码截止时间（brief §1、共性第 31 条），面板打开时沿用、不自动发码
        script.on(Self.smsSend, Self.code(0, "{\"resend_after_sec\":5,\"expires_in_sec\":300}"))
        let fixture = fixture()
        let (_, controller) = try await readyToSubmit(fixture)
        await submit(controller)
        let stepUp = try XCTUnwrap(controller.stepUp)
        await waitUntil("面板没有打开") { stepUp.state?.phase == .ready }
        XCTAssertEqual(stepUp.state?.action, "phone_change")
        XCTAssertEqual(stepSms.last?.body, Self.oldBody, "面板发码体同第 1 步")
        XCTAssertGreaterThan(stepUp.state?.resendLeftSec ?? 0, 0, "面板沿用第 1 步的倒计时")
        XCTAssertEqual(stepSms.count, 1, "面板打开不自动发码（共用截止时间）")
        await waitUntil("面板倒计时没有结束", timeout: 8) { stepUp.state?.resendLeftSec == 0 }
        StepUpActions.make(stepUp, try XCTUnwrap(stepUp.state)).resend()
        await waitUntil("面板【重新获取】没有发码") { self.stepSms.count == 2 }
        XCTAssertEqual(stepSms.last?.body, Self.oldBody, "面板发码体同第 1 步")
        await waitUntil("重新获取没有回来") { stepUp.state?.phase == .ready }
        let panel = try XCTUnwrap(stepUp.state)
        StepUpActions.make(stepUp, panel).code("112233")
        StepUpActions.make(stepUp, try XCTUnwrap(stepUp.state)).verify()
        await waitUntil("没有重放") { self.binds.count == 2 }
        XCTAssertNil(sent(Self.stepUpVerify).last?.json["summary"], "面板验证也不带 summary")
        let (first, replay) = (binds[0], binds[1])
        XCTAssertEqual(replay.header("Idempotency-Key"), first.header("Idempotency-Key"), "原键（M2）")
        XCTAssertEqual(replay.body, first.body, "原体（M2）")
        XCTAssertEqual(replay.header("X-Step-Up-Token"), Self.panelToken, "带面板拿到的新 token")
        await quietWindow(1.0)
        XCTAssertEqual(binds.count, 2, "再遇 10003 不循环")
        XCTAssertNil(stepUp.state, "不再弹面板")
        XCTAssertNotEqual(controller.state.step, .done)
    }

    /// T5：面板关闭（不验证）→ 不重放，回到第 2 步可再提交；新号保留。
    func testClosingPanelDoesNotReplay() async throws {
        script.on(Self.bindWrite, Self.code(10003))
        let fixture = fixture()
        let (_, controller) = try await readyToSubmit(fixture)
        await submit(controller)
        let stepUp = try XCTUnwrap(controller.stepUp)
        await waitUntil("面板没有打开") { stepUp.state?.phase == .ready }
        StepUpActions.make(stepUp, try XCTUnwrap(stepUp.state)).close()
        await quietWindow(0.6)
        XCTAssertEqual(binds.count, 1)
        XCTAssertEqual(controller.state.step, .step2)
        XCTAssertEqual(controller.state.newPhone, Self.newPhone)
    }
}
