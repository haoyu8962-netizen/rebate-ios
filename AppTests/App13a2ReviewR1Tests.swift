@testable import Couli
import CouliNetwork
import Foundation
import Me
import MeCore
import Wallet
import WalletCore
import XCTest

/// APP-13a-2-ios 写测 r4（首轮评审 review-r1.md）：
/// - S2-3 / M8：身份已变、但会话同步出口还没执行（只换存储里的会话，不调 sessionStateChanged / checkSession，照 FuIosWalletScope 系列与
///   WalletAppFixture.swapTokensSilently 的造法）时执行旧回调 → 0 次请求、0 次写入；
/// - S2-1 / 补 (b)：10003 面板里的发码、验证遇 30414 → 与另外三处一致（`.unavailable` + 【联系客服】，确认后回设置页）；
/// - S2-2：面板拿到的 token 重放后回 20002，改码再提交仍带同一 token、不再弹面板、不再验证（brief §1「token 不丢」、T6）；
/// - S3-6：Debug 假服务对「更换」不带 token 回 10003（真实服务端对已绑号的口径），首次绑定照旧。
@MainActor
final class App13a2ReviewR1Tests: App13a2TestCase {
    private var writeCounts: [Int] {
        [stepSms.count, bindSms.count, sent(Self.stepUpVerify).count, binds.count, sent(Self.abandonWrite).count]
    }

    /// 只换存储里的会话（登出后另一个账号写进存储），不走任何会话同步出口（清空通知还没执行的窗口）。
    private func swapSilently(_ fixture: App13a2Fixture, to account: String) throws {
        fixture.client.signOut()
        try fixture.tokens.save(access: "at-\(account)", refresh: "rt-\(account)", scope: "full", account: account,
                                loginEpoch: "fixture-login-\(account)")
        fixture.login.phone.record(true, generation: fixture.client.sessionGeneration)
    }

    // MARK: - S2-3 / M8

    /// M8：第 2 步填好后身份已变、同步出口未执行（子页仍挂在设置页上）→ 旧回调（发码、下一步、输入、提交）0 次请求、0 次写入。
    func testStaleCallbacksBeforeSyncExitDoNothing() async throws {
        let fixture = fixture()
        let (settings, controller) = try await readyToSubmit(fixture)
        let stale = act(controller)
        try swapSilently(fixture, to: "user-b")
        XCTAssertTrue(settings.phoneChange === controller, "前提：同步出口没执行，子页还在")
        XCTAssertFalse(controller.alive, "固定身份已不是当前（只比较）")
        let before = writeCounts
        stale.requestOldCode()
        stale.oldCode("123456")
        stale.next()
        stale.newPhone("13700002222")
        stale.requestNewCode()
        stale.newCode("222222")
        stale.submit()
        await quietWindow(1.0)
        XCTAssertEqual(writeCounts, before, "旧回调 0 次请求（M8）")
        XCTAssertTrue(records("user-b").isEmpty, "新账号 0 次写入")
        XCTAssertTrue(records().isEmpty, "旧账号 0 次写入")
    }

    /// M8：待确认卡的旧回调（确认、放弃）在身份已变、同步出口未执行时 → 0 次请求；旧账号记录原样。
    func testStalePendingCallbacksBeforeSyncExitDoNothing() async throws {
        let fixture = fixture()
        let (settings, controller) = try await enterPending(fixture)
        let record = try XCTUnwrap(records().first)
        let stale = act(controller)
        act(controller).askAbandon()
        let dialog = try XCTUnwrap(controller.state.dialog)
        let afterAsk = act(controller)
        try swapSilently(fixture, to: "user-b")
        XCTAssertTrue(settings.phoneChange === controller, "前提：同步出口没执行")
        let before = writeCounts
        stale.confirmPending()
        afterAsk.confirmAbandon(dialog)
        stale.askAbandon()
        await quietWindow(1.0)
        XCTAssertEqual(writeCounts, before, "旧回调 0 次请求（M8）")
        XCTAssertEqual(records().first, record, "记录原样")
        XCTAssertTrue(records("user-b").isEmpty)
    }

    // MARK: - S2-1 / 补 (b) 面板路径

    private struct PanelPage {
        let settings: SettingsController
        let page: PhoneChangeController
        let panel: StepUpController
    }

    /// 第 1 步 → 第 2 步【提交】→ 10003 → 面板打开（面板与第 1 步共用发码截止时间，打开时沿用倒计时）。
    private func panelAfterSubmit(_ fixture: App13a2Fixture) async throws -> PanelPage {
        let (settings, controller) = try await readyToSubmit(fixture)
        await submit(controller)
        let stepUp = try XCTUnwrap(controller.stepUp)
        await waitUntil("面板没有打开") { stepUp.state?.phase == .ready }
        XCTAssertEqual(stepUp.state?.action, "phone_change")
        return PanelPage(settings: settings, page: controller, panel: stepUp)
    }

    /// 补 (b)：面板内发码（【重新获取】）遇 30414 → `.unavailable`（同一句 + 【联系客服】），面板收起；【知道了】后回设置页。
    func testPanelSms30414ShowsUnavailableAndReturns() async throws {
        script.on(Self.bindWrite, Self.code(10003))
        // 第 1 步倒计时 5 秒：面板打开时一定沿用、不自动发码，第二条回答（30414）只会落到面板上的【重新获取】
        script.on(Self.smsSend, Self.code(0, "{\"resend_after_sec\":5,\"expires_in_sec\":300}"), Self.code(30414))
        let fixture = fixture()
        let opened = try await panelAfterSubmit(fixture)
        let (settings, controller, stepUp) = (opened.settings, opened.page, opened.panel)
        await waitUntil("面板倒计时没有结束", timeout: 8) { stepUp.state?.resendLeftSec == 0 }
        let sentBefore = stepSms.count
        StepUpActions.make(stepUp, try XCTUnwrap(stepUp.state)).resend()
        await waitUntil("面板没有发码") { self.stepSms.count == sentBefore + 1 }
        await waitUntil("面板发码 30414 没有落到弹窗") { controller.state.dialog != nil }
        let dialog = try XCTUnwrap(controller.state.dialog)
        guard case .unavailable = dialog else { return XCTFail("应为 30414 弹窗，实际 \(dialog)") }
        XCTAssertNil(stepUp.state, "面板收起，不停在半路")
        act(controller).dismissDialog(dialog)
        XCTAssertEqual(settings.state.sub, .none, "回到设置页")
        XCTAssertNil(settings.phoneChange)
        XCTAssertEqual(binds.count, 1, "不重放")
    }

    /// 补 (b)：面板内验证遇 30414 → `.unavailable`；【联系客服】走统一客服出口并回设置页。
    func testPanelVerify30414ShowsUnavailableAndReturns() async throws {
        script.on(Self.bindWrite, Self.code(10003))
        script.on(Self.stepUpVerify, Self.token(Self.stepToken), Self.code(30414))
        let fixture = fixture()
        let opened = try await panelAfterSubmit(fixture)
        let (settings, controller, stepUp) = (opened.settings, opened.page, opened.panel)
        StepUpActions.make(stepUp, try XCTUnwrap(stepUp.state)).code("112233")
        StepUpActions.make(stepUp, try XCTUnwrap(stepUp.state)).verify()
        await waitUntil("面板验证 30414 没有落到弹窗") { controller.state.dialog != nil }
        let dialog = try XCTUnwrap(controller.state.dialog)
        guard case .unavailable = dialog else { return XCTFail("应为 30414 弹窗，实际 \(dialog)") }
        XCTAssertNil(stepUp.state, "面板收起")
        act(controller).contactService(dialog)
        XCTAssertNotNil(fixture.me.cs.sheet, "【联系客服】走统一客服出口")
        XCTAssertEqual(settings.state.sub, .none, "回到设置页")
        XCTAssertEqual(binds.count, 1, "不重放")
    }

    // MARK: - S2-2 面板 token

    /// S2-2：提交 10003 → 面板 → 重放回 20002 → 改码再点【提交】：新键（20002 键结束），带面板的同一 token，0 次再验证、不再弹面板 → Done。
    func testPanelTokenSurvivesReplay20002() async throws {
        script.on(Self.bindWrite, Self.code(10003), Self.code(20002), Self.code(0, "{}"))
        let fixture = fixture()
        let opened = try await panelAfterSubmit(fixture)
        let (controller, stepUp) = (opened.page, opened.panel)
        StepUpActions.make(stepUp, try XCTUnwrap(stepUp.state)).code("112233")
        StepUpActions.make(stepUp, try XCTUnwrap(stepUp.state)).verify()
        await waitUntil("没有重放") { self.binds.count == 2 }
        await waitUntil("重放 20002 没有落到验证码") { controller.state.codeError?.key == "error.20002" }
        XCTAssertEqual(binds[1].header("X-Step-Up-Token"), Self.panelToken, "前提：重放带面板 token")
        XCTAssertTrue(controller.hasStepToken, "20002 之后 token 不丢")
        let verifies = sent(Self.stepUpVerify).count
        let sms = stepSms.count
        act(controller).newCode("777777")
        await submit(controller)
        let third = binds[2]
        XCTAssertEqual(third.header("X-Step-Up-Token"), Self.panelToken, "再提交带同一 token")
        XCTAssertNotEqual(third.header("Idempotency-Key"), binds[0].header("Idempotency-Key"), "20002 键结束：新键")
        XCTAssertEqual(third.json["code"] as? String, "777777")
        await waitUntil("没有进 Done") { controller.state.step == .done }
        XCTAssertNil(stepUp.state, "不再弹面板")
        XCTAssertEqual(sent(Self.stepUpVerify).count, verifies, "0 次再验证")
        XCTAssertEqual(stepSms.count, sms, "0 次再发码")
    }

    // MARK: - S3-6 Debug 假服务

    /// S3-6：Debug 假服务在 `change=` 场景下，对已绑号、不带 X-Step-Up-Token 的绑手机请求回 10003（同真实服务端），不落进首次绑定的成功分支。
    func testDebugFakeChangeWithoutTokenAnswers10003() throws {
        let key = DebugFakeOAuth.launchArgument
        let saved = UserDefaults.standard.string(forKey: key)
        addTeardownBlock {
            if let saved {
                UserDefaults.standard.set(saved, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
        UserDefaults.standard.set("change=ok", forKey: key)
        let fake = DebugFakeOAuth()
        XCTAssertTrue(fake.phoneBound, "前提：假账号已绑手机（短信登录）")
        let answer = try XCTUnwrap(fake.answer(
            method: "POST", path: "/v1/me/phone", body: ["phone": Self.newPhone, "code": "123456"], headers: [:]
        ))
        XCTAssertEqual(answer.code, 10003, "更换不带 token → 10003（S3-6）")
    }
}
