@testable import Couli
import CouliNetwork
import Foundation
import Generated
import Me
import MeCore
import WalletCore
import XCTest

/// APP-13a-2-ios T2 第 1 步（验证当前手机号）：发码体、phone_bound=false 不发、发码与验证分开限流（共性第 26 条）、验证共用 gates.verify 的
/// 同一实例（共性第 31 条、M12）、20002 / 20003 清空并 assertive、成功进第 2 步且 token 不外泄、30414 提前返回（补 (b) 的发码 / 验证两处）、
/// 「原手机号不能用了」走客服出口。
@MainActor
final class App13a2Step1Tests: App13a2TestCase {
    /// T2（brief §1 第 1 步、§3、锁 d47f660e5）：发码体逐字节 {"action":"phone_change","purpose":"step_up"}，没有 phone；验证体只有
    /// action + code，不带 summary（契约：phone_change 带 summary → 20001）。
    func testSendAndVerifyBodies() async throws {
        let fixture = fixture()
        let (_, controller) = try await enter(fixture)
        await passStep1(controller, code: "123456")
        let sms = try XCTUnwrap(stepSms.first)
        XCTAssertEqual(sms.body, Self.oldBody, "发码体逐字节")
        XCTAssertNil(sms.json["phone"], "step_up 发码不带 phone")
        XCTAssertNotNil(sms.header("Authorization"), "requiresSession：带本人令牌")
        let verify = try XCTUnwrap(sent(Self.stepUpVerify).first)
        XCTAssertEqual(verify.json["action"] as? String, "phone_change")
        XCTAssertEqual(verify.json["code"] as? String, "123456")
        XCTAssertNil(verify.json["summary"], "phone_change 不绑摘要")
        XCTAssertEqual(Set(verify.json.keys), ["action", "code"])
    }

    /// T2（D10-1682 ②）：本会话已知 phone_bound=false → 【获取验证码】0 次请求，【下一步】不可点。
    func testPhoneUnboundSendsNothing() async throws {
        let fixture = fixture()
        let (_, controller) = try await enter(fixture)
        fixture.login.phone.record(false, generation: fixture.client.sessionGeneration)
        act(controller).requestOldCode()
        act(controller).oldCode("123456")
        act(controller).next()
        await quietWindow(0.8)
        XCTAssertTrue(stepSms.isEmpty, "已知未绑手机：不发码")
        XCTAssertTrue(sent(Self.stepUpVerify).isEmpty)
        XCTAssertEqual(controller.state.step, .step1)
    }

    /// T2 + 共性第 31 条（M12）：第 1 步验证遇 42901 → 写进钱包的 gates.verify（同一实例），StepUpSheet 一侧（订阅同一闸门）随之置灰。
    func testVerify42901WritesSharedVerifyGate() async throws {
        script.on(Self.stepUpVerify, Self.retryAfter(30))
        let fixture = fixture()
        let (_, controller) = try await enter(fixture)
        act(controller).requestOldCode()
        await waitUntil("没有发码") { !self.stepSms.isEmpty && !controller.state.oldSending }
        act(controller).oldCode("123456")
        act(controller).next()
        await waitUntil("42901 没有写进 gates.verify") { fixture.wallet.deps.gates.verify.active }
        XCTAssertTrue(fixture.wallet.deps.gates.verify.blocked, "StepUpSheet 订阅的同一闸门置灰")
        XCTAssertFalse(controller.nextEnabled, "【下一步】随之置灰")
        XCTAssertEqual(controller.state.step, .step1)
        XCTAssertFalse(fixture.wallet.deps.gates.sms.active, "发码限流与验证限流分开（共性第 26 条）")
    }

    /// 共性第 31 条反向（M12）：别处（如提现面板）让 gates.verify 进禁用期 → 【下一步】置灰，点了 0 次验证请求；【获取验证码】不受影响。
    func testSharedVerifyGateBlocksNext() async throws {
        let fixture = fixture()
        let (_, controller) = try await enter(fixture)
        act(controller).requestOldCode()
        await waitUntil("没有发码") { !self.stepSms.isEmpty && !controller.state.oldSending }
        act(controller).oldCode("123456")
        fixture.wallet.deps.gates.verify.start(30000)
        XCTAssertFalse(controller.nextEnabled)
        act(controller).next()
        await quietWindow(0.8)
        XCTAssertTrue(sent(Self.stepUpVerify).isEmpty, "验证闸门禁用期内 0 次验证请求")
        XCTAssertEqual(controller.state.step, .step1)
    }

    /// 共性第 26 条：【获取验证码】只看发码限制，【下一步】只看验证限制。
    func testSendAndVerifyLimitsAreSeparate() async throws {
        let fixture = fixture()
        let (_, controller) = try await enter(fixture)
        fixture.wallet.deps.gates.verify.start(30000)
        XCTAssertTrue(controller.oldCodeSendEnabled, "验证限流不挡发码")
        fixture.wallet.deps.gates.verify.reset()
        fixture.wallet.deps.gates.sms.start(30000)
        XCTAssertFalse(controller.oldCodeSendEnabled, "发码限流挡发码（全局 gates.sms，FU-IOS-STEPUP-SMS-GATE-GLOBAL）")
        act(controller).oldCode("123456")
        XCTAssertTrue(controller.nextEnabled, "发码限流不挡【下一步】")
    }

    /// T2（brief §1）：验证遇 20002 / 20003 → 清空输入、提示 assertive 播报，停在第 1 步。
    func testWrongOrExpiredCodeClearsAndAnnouncesAssertive() async throws {
        for code in [20002, 20003] {
            WalletStubProtocol.reset()
            script.install()
            script.on(Self.stepUpVerify, Self.code(code))
            let fixture = fixture()
            let (_, controller) = try await enter(fixture)
            act(controller).requestOldCode()
            await waitUntil("没有发码") { !self.stepSms.isEmpty && !controller.state.oldSending }
            act(controller).oldCode("123456")
            act(controller).next()
            await waitUntil("\(code) 没有落到第 1 步") { controller.state.oldError?.key == "error.\(code)" }
            XCTAssertEqual(controller.state.oldCode, "", "\(code)：清空输入")
            XCTAssertEqual(controller.state.oldError?.assertive, true, "\(code)：assertive")
            XCTAssertEqual(controller.state.step, .step1)
            XCTAssertFalse(controller.hasStepToken)
            fixture.router.path = []
            XCTAssertFalse(controller.alive, "\(code)：设置页出栈，子页同步作废")
        }
    }

    /// T2：验证成功 → 第 2 步；流程拿到 token（只读观察口），token 不出现在页面状态与未决记录里（「不进日志」）。
    func testVerifySuccessGoesToStep2WithoutLeakingToken() async throws {
        let fixture = fixture()
        let (_, controller) = try await enter(fixture)
        await passStep1(controller)
        XCTAssertTrue(controller.hasStepToken)
        XCTAssertFalse(String(describing: controller.state).contains(Self.stepToken), "页面状态不含 token")
        XCTAssertTrue(records().allSatisfy {
            !$0.body.contains(Self.stepToken) && !$0.summary.contains(Self.stepToken)
        })
        XCTAssertEqual(controller.state.newPhone, "", "第 1 步不显示 / 不预填任何号码（D10-2203 ③）")
    }

    /// 补 (b)（D10-2203）：第 1 步发码遇 30414 → error.30414 +【联系客服】；【知道了】后回设置页，不停在半路。
    func testSend30414ShowsUnavailableAndReturnsToSettings() async throws {
        script.on(Self.smsSend, Self.code(30414))
        let fixture = fixture()
        let (settings, controller) = try await enter(fixture)
        act(controller).requestOldCode()
        await waitUntil("发码 30414 没有落到弹窗") { controller.state.dialog != nil }
        let dialog = try XCTUnwrap(controller.state.dialog)
        guard case .unavailable = dialog else { return XCTFail("应为 30414 弹窗，实际 \(dialog)") }
        XCTAssertEqual(DefaultTexts.text("error.30414"), "暂不支持自助更换手机号，请联系客服", "契约原句")
        act(controller).dismissDialog(dialog)
        XCTAssertEqual(settings.state.sub, .none, "回到设置页")
        XCTAssertNil(settings.phoneChange)
        XCTAssertFalse(controller.alive)
    }

    /// 补 (b)：第 1 步验证遇 30414 → 同一句 + 【联系客服】走统一客服出口；回设置页。
    func testVerify30414ShowsUnavailableWithContactService() async throws {
        script.on(Self.stepUpVerify, Self.code(30414))
        let fixture = fixture()
        let (settings, controller) = try await enter(fixture)
        act(controller).requestOldCode()
        await waitUntil("没有发码") { !self.stepSms.isEmpty && !controller.state.oldSending }
        act(controller).oldCode("123456")
        act(controller).next()
        await waitUntil("验证 30414 没有落到弹窗") { controller.state.dialog != nil }
        let dialog = try XCTUnwrap(controller.state.dialog)
        guard case .unavailable = dialog else { return XCTFail("应为 30414 弹窗，实际 \(dialog)") }
        XCTAssertNotEqual(controller.state.step, .step2, "不进第 2 步")
        act(controller).contactService(dialog)
        XCTAssertNotNil(fixture.me.cs.sheet, "【联系客服】走统一客服出口")
        act(controller).dismissDialog(dialog)
        XCTAssertEqual(settings.state.sub, .none)
    }

    /// brief §1：「原手机号不能用了？联系客服」走统一客服出口，不提交、不发码；返回回到设置页。
    func testOldUnavailableOpensCustomerServiceAndBackReturns() async throws {
        let fixture = fixture()
        let (settings, controller) = try await enter(fixture)
        act(controller).oldUnavailable()
        XCTAssertNotNil(fixture.me.cs.sheet)
        XCTAssertTrue(stepSms.isEmpty)
        XCTAssertTrue(binds.isEmpty)
        act(controller).back()
        XCTAssertEqual(settings.state.sub, .none, "第 1 步返回 → 设置页")
    }

    /// T14（读屏，state 层）：第 1 步发码成功 → 「已发送」礼貌播报（step_up.sent，assertive=false）。
    func testCodeSentAnnouncedPolitely() async throws {
        let fixture = fixture()
        let (_, controller) = try await enter(fixture)
        act(controller).requestOldCode()
        await waitUntil("没有播报已发送") { controller.state.announce?.key == "step_up.sent" }
        XCTAssertEqual(controller.state.announce?.assertive, false, "polite")
        XCTAssertGreaterThan(controller.state.oldResendLeftSec, 0, "起倒计时")
        XCTAssertFalse(controller.oldCodeSendEnabled, "倒计时内不可再发")
    }
}
