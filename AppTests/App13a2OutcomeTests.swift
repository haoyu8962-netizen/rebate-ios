@testable import Couli
import CouliNetwork
import Foundation
import Generated
import Me
import MeCore
import XCTest

/// APP-13a-2-ios 第 2 步提交的结局（brief §1「结局」）：T6 20001 / 20002 / 20003、补 (d) 新号等于当前号、T7 30411 / 30414 / 44001 / 20903、
/// T8 前置码、T13 D10-2165 ① 现状（非终结码之后下次用新键）。
@MainActor
final class App13a2OutcomeTests: App13a2TestCase {
    /// 提交一次，等结局落定（不在提交中）。
    private func submitAndSettle(_ controller: PhoneChangeController) async {
        await submit(controller)
        await waitUntil("提交结局没有落定") { !controller.state.submitting }
        await settle()
    }

    // MARK: - T6 / 补 (d)

    /// T6（brief §1、G23）：20001 phone_invalid → 新号框提示 error.20001.phone_invalid；新号保留；token 保留；再点用新键，不重新验证。
    func testPhoneInvalidKeepsInputAndToken() async throws {
        script.on(Self.bindWrite, Self.code(20001, "{\"fields\":[\"phone\"],\"reason\":\"phone_invalid\"}"),
                  Self.code(0, "{}"))
        let fixture = fixture()
        let (_, controller) = try await readyToSubmit(fixture)
        await submitAndSettle(controller)
        XCTAssertEqual(controller.state.phoneError?.key, "error.20001.phone_invalid")
        XCTAssertEqual(controller.state.newPhone, Self.newPhone, "保留新号")
        XCTAssertTrue(controller.hasStepToken, "token 不丢（G23）")
        XCTAssertTrue(records().isEmpty, "从未结果未知的键结束（D10-2165 ① 现状）")
        let verifies = sent(Self.stepUpVerify).count
        await submit(controller)
        XCTAssertNotEqual(binds[1].header("Idempotency-Key"), binds[0].header("Idempotency-Key"), "再点用新键")
        XCTAssertEqual(binds[1].header("X-Step-Up-Token"), Self.stepToken, "沿用第 1 步 token")
        XCTAssertEqual(sent(Self.stepUpVerify).count, verifies, "不重新验证")
    }

    /// 补 (d)（D10-2259 ④，B1-20b）：新号等于当前号 → 20001 data.fields=[phone]（不带 reason）→ 新号框标红，用同一句 error.20001.phone_invalid。
    func testSameAsCurrentNumberMarksPhoneField() async throws {
        script.on(Self.bindWrite, Self.code(20001, "{\"fields\":[\"phone\"]}"))
        let fixture = fixture()
        let (_, controller) = try await readyToSubmit(fixture)
        await submitAndSettle(controller)
        XCTAssertEqual(controller.state.phoneError?.key, "error.20001.phone_invalid", "同一句提示")
        XCTAssertEqual(DefaultTexts.text("error.20001.phone_invalid"), "请输入 11 位中国大陆手机号")
        XCTAssertNil(controller.state.codeError)
        XCTAssertEqual(controller.state.step, .step2)
        XCTAssertEqual(controller.state.newPhone, Self.newPhone)
        XCTAssertTrue(controller.hasStepToken)
    }

    /// T6：20002 → 验证码旁 error.20002（不清码）；20003 → error.20003 并清空验证码。两者保留新号与 token。
    func testCodeErrorsOnCodeField() async throws {
        for (code, cleared) in [(20002, false), (20003, true)] {
            WalletStubProtocol.reset()
            script.install()
            script.on(Self.stepUpVerify, Self.token(Self.stepToken))
            script.on(Self.bindWrite, Self.code(code))
            let fixture = fixture()
            let (_, controller) = try await readyToSubmit(fixture)
            await submitAndSettle(controller)
            XCTAssertEqual(controller.state.codeError?.key, "error.\(code)")
            XCTAssertEqual(controller.state.newCode.isEmpty, cleared, "\(code)：清码 = \(cleared)")
            XCTAssertEqual(controller.state.newPhone, Self.newPhone)
            XCTAssertTrue(controller.hasStepToken, "\(code)：token 不丢")
            fixture.router.path = []
        }
    }

    // MARK: - T7

    /// T7（G08，M4）：30411（含 mergeable + merge_ticket）→ error.30411.phone_change；没有并号弹窗、没有 /v1/auth/merge 请求；新号保留。
    func test30411NeverMerges() async throws {
        script.on(Self.bindWrite, Self.code(30411, "{\"reason\":\"mergeable\",\"merge_ticket\":\"mt-test-0001\"}"))
        let fixture = fixture()
        let (_, controller) = try await readyToSubmit(fixture)
        await submitAndSettle(controller)
        XCTAssertTrue(keys(controller.state).contains("error.30411.phone_change"), "换号专句（brief §11 第 8 项）")
        XCTAssertFalse(keys(controller.state).contains("error.30411.mergeable"))
        XCTAssertNil(controller.state.dialog, "没有并号弹窗")
        await quietWindow(0.6)
        XCTAssertTrue(sent("POST /v1/auth/merge").isEmpty, "不调并号接口")
        XCTAssertEqual(controller.state.step, .step2)
        XCTAssertEqual(controller.state.newPhone, Self.newPhone)
        XCTAssertTrue(records().isEmpty, "3xxxx 键结束")
    }

    /// 补 (b)（D10-2203）+ T7：提交遇 30414 → 同一句 error.30414 +【联系客服】；【知道了】后回设置页。
    func testSubmit30414ShowsUnavailableAndReturnsToSettings() async throws {
        script.on(Self.bindWrite, Self.code(30414))
        let fixture = fixture()
        let (settings, controller) = try await readyToSubmit(fixture)
        await submitAndSettle(controller)
        let dialog = try XCTUnwrap(controller.state.dialog)
        guard case .unavailable = dialog else { return XCTFail("应为 30414 弹窗，实际 \(dialog)") }
        act(controller).contactService(dialog)
        XCTAssertNotNil(fixture.me.cs.sheet, "【联系客服】走统一客服出口")
        act(controller).dismissDialog(dialog)
        XCTAssertEqual(settings.state.sub, .none, "不停在半路")
        XCTAssertNil(settings.phoneChange)
    }

    /// T7（G09，M11）：44001 → PhoneChangeNewBlocked 弹窗：标题回落 error.44001（快照没有 risk_msg.*）；新号保留、验证码清空、token 不丢；
    /// 【联系客服申诉】走客服出口；【知道了】留在第 2 步。
    func test44001RiskDialog() async throws {
        script.on(Self.bindWrite, Self.code(44001, "{\"risk_msg_code\":\"phone_blacklisted\"}"))
        let fixture = fixture()
        let (settings, controller) = try await readyToSubmit(fixture)
        await submitAndSettle(controller)
        let dialog = try XCTUnwrap(controller.state.dialog)
        guard case let .risk(titleKey, _) = dialog else { return XCTFail("应为风控弹窗，实际 \(dialog)") }
        XCTAssertEqual(fixture.me.deps.texts.text(titleKey), DefaultTexts.text("error.44001"), "标题回落 error.44001")
        XCTAssertEqual(controller.state.newPhone, Self.newPhone, "新号保留")
        XCTAssertEqual(controller.state.newCode, "", "验证码清空（M11）")
        XCTAssertTrue(controller.hasStepToken, "第 1 步 token 不丢（G09）")
        act(controller).contactService(dialog)
        XCTAssertNotNil(fixture.me.cs.sheet, "【联系客服申诉】")
        act(controller).dismissDialog(dialog)
        XCTAssertNil(controller.state.dialog)
        XCTAssertEqual(controller.state.step, .step2)
        XCTAssertEqual(settings.state.sub, .phoneChange)
    }

    /// T7（共性第 24 条，M10）：20903 → 回第 1 步，表单与 token 都清空。
    func test20903BackToStep1AndClears() async throws {
        script.on(Self.bindWrite, Self.code(20903))
        let fixture = fixture()
        let (_, controller) = try await readyToSubmit(fixture)
        await submitAndSettle(controller)
        await waitUntil("没有回第 1 步") { controller.state.step == .step1 }
        XCTAssertEqual(controller.state.newPhone, "")
        XCTAssertEqual(controller.state.newCode, "")
        XCTAssertEqual(controller.state.oldCode, "")
        XCTAssertFalse(controller.hasStepToken, "token 清空（M10）")
        XCTAssertNil(fixture.wallet.deps.tokens.take(action: "phone_change", account: Self.account, nowMs: 0))
    }

    // MARK: - T8

    /// T8（BR-ID-10「不适用的动作」）：前置码 10001 / 10004 / 10005 → 只引导，用户再点之前 0 次 POST /v1/me/phone；保留新号、清空验证码。
    func testPrerequisiteCodesNeverAutoResubmit() async throws {
        for code in [10004, 10005] {
            WalletStubProtocol.reset()
            script.install()
            script.on(Self.stepUpVerify, Self.token(Self.stepToken))
            script.on(Self.bindWrite, Self.code(code, "{\"consent_type\":\"agreement\"}"))
            let fixture = fixture()
            let (_, controller) = try await readyToSubmit(fixture)
            await submit(controller)
            await quietWindow(1.0)
            XCTAssertEqual(binds.count, 1, "\(code)：回来不自动提交")
            XCTAssertEqual(controller.state.newPhone, Self.newPhone, "\(code)：保留新号")
            XCTAssertEqual(controller.state.newCode, "", "\(code)：清空验证码")
            fixture.router.path = []
        }
    }

    // MARK: - T13 D10-2165 ① 现状

    /// T13（`D10-2165 ① 现状`，brief §5）：从未结果未知的提交遇 50401 → trace6 提示，记录被删，下次点击用新键。裁定改成 HELD 时本条有意翻转。
    func testNeverUnknown50401DropsRecordAndNextUsesNewKey() async throws {
        script.on(Self.bindWrite, Self.code(50401), Self.code(0, "{}"))
        let fixture = fixture()
        let (_, controller) = try await readyToSubmit(fixture)
        await submitAndSettle(controller)
        XCTAssertEqual(controller.state.notice?.showTrace6, true, "5xxxx 附 trace6")
        XCTAssertTrue(records().isEmpty, "D10-2165 ① 现状：记录被删")
        act(controller).newCode("654321")
        await submit(controller)
        XCTAssertNotEqual(binds[1].header("Idempotency-Key"), binds[0].header("Idempotency-Key"), "D10-2165 ① 现状：新键")
        XCTAssertEqual(binds[1].header("X-Step-Up-Token"), Self.stepToken)
    }

    /// T13（`D10-2165 ① 现状`）：从未结果未知的提交遇非强更 10405（刷新暂时失败 → 不是强更 Effect）→ 按 5xxxx，记录被删，下次用新键。
    func testNeverUnknownNonForced10405DropsRecordAndNextUsesNewKey() async throws {
        script.on(Self.bindWrite, Self.code(10405, "{\"min_supported_version\":\"0.0.1\"}"), Self.code(0, "{}"))
        script.on("POST /v1/auth/refresh", .disconnect)
        let fixture = fixture()
        let (_, controller) = try await readyToSubmit(fixture)
        await submitAndSettle(controller)
        XCTAssertFalse(fixture.routing.mustShowForceUpdate, "非强更不进强更（共性第 12 条）")
        XCTAssertTrue(records().isEmpty, "D10-2165 ① 现状：记录被删")
        act(controller).newCode("654321")
        await submit(controller)
        let firstKey = try XCTUnwrap(binds.first?.header("Idempotency-Key"))
        XCTAssertNotEqual(binds.last?.header("Idempotency-Key"), firstKey, "D10-2165 ① 现状：新键")
    }
}
