@testable import Couli
import CouliNetwork
import Foundation
import Me
import MeCore
import XCTest

/// APP-13a-2-ios T9 待确认【放弃上一次提交】的各分支（brief §1「放弃」，共性第 24、44、47 条）：二次确认 → abandoned → 第 1 步；completed 0 → Done；
/// completed 30411 → 第 2 步；40901 → abandon_busy；强更 10405 → 强更且记录保留。每条同时断言存储记录与请求。
@MainActor
final class App13a2AbandonTests: App13a2TestCase {
    private static func completed(_ code: Int, _ data: String) -> WalletStubProtocol.Reply {
        let original = "{\"code\":\(code),\"msg\":\"\",\"data\":\(data)}"
        return .envelope(code: 0, data: "{\"outcome\":\"completed\",\"original\":\(original)}", headers: [:])
    }

    /// 【放弃上一次提交】→ 二次确认弹窗（绑定原键）→【确定放弃】，等作废请求到达并落定。
    private func abandon(_ controller: PhoneChangeController, key: String) async throws {
        act(controller).askAbandon()
        let dialog = try XCTUnwrap(controller.state.dialog, "没有二次确认")
        guard case let .abandon(dialogKey, _) = dialog else { return XCTFail("应为放弃确认，实际 \(dialog)") }
        XCTAssertEqual(dialogKey, key, "确认框绑定原键")
        XCTAssertTrue(sent(Self.abandonWrite).isEmpty, "二次确认之前不发")
        let before = sent(Self.abandonWrite).count
        act(controller).confirmAbandon(dialog)
        await waitUntil("作废没有发出") { self.sent(Self.abandonWrite).count > before }
        await waitUntil("作废没有落定") { !controller.state.pendingBusy }
        await settle()
    }

    /// 作废请求体：{action: phone_change, idempotency_key: 原键}；不带 Idempotency-Key 头（openapi）。
    private func assertAbandonRequest(_ key: String, file: StaticString = #filePath, line: UInt = #line) {
        let request = sent(Self.abandonWrite).last
        XCTAssertEqual(request?.json["action"] as? String, "phone_change", file: file, line: line)
        XCTAssertEqual(request?.json["idempotency_key"] as? String, key, file: file, line: line)
        XCTAssertNil(request?.header("Idempotency-Key"), "作废不带幂等头", file: file, line: line)
    }

    /// T9：二次确认【再想想】不发；abandoned → 第 1 步（重新验证）、表单与 token 清空；记录删除。
    func testAbandonedBackToStep1() async throws {
        let fixture = fixture()
        let (_, controller) = try await enterPending(fixture)
        let key = try XCTUnwrap(records().first?.key)
        act(controller).askAbandon()
        let first = try XCTUnwrap(controller.state.dialog)
        act(controller).dismissDialog(first)
        XCTAssertNil(controller.state.dialog)
        act(controller).confirmAbandon(first)
        await quietWindow(0.5)
        XCTAssertTrue(sent(Self.abandonWrite).isEmpty, "用过 / 取消的确认框作废")
        script.ok(Self.abandonWrite, "{\"outcome\":\"abandoned\",\"original\":null}")
        try await abandon(controller, key: key)
        assertAbandonRequest(key)
        await waitUntil("abandoned 没有回第 1 步") { controller.state.step == .step1 }
        XCTAssertNil(controller.state.pending)
        XCTAssertEqual(controller.state.newPhone, "")
        XCTAssertFalse(controller.hasStepToken, "重新验证")
        XCTAssertTrue(records().isEmpty)
    }

    /// T9：放弃得到 completed 原结果 0 → Done（摘要取记录）；记录删除；按成功做共享结算（getMe 重取）。
    func testAbandonCompletedSuccessGoesDone() async throws {
        let fixture = fixture()
        let (_, controller) = try await enterPending(fixture)
        let key = try XCTUnwrap(records().first?.key)
        let reads = sent(Self.meRead).count
        script.on(Self.abandonWrite, Self.completed(0, "{}"))
        try await abandon(controller, key: key)
        assertAbandonRequest(key)
        await waitUntil("completed 0 没有进 Done") { controller.state.step == .done }
        XCTAssertEqual(controller.state.doneMaskedPhone, Self.newMasked)
        XCTAssertTrue(records().isEmpty)
        await waitUntil("getMe 没有重取") { self.sent(Self.meRead).count > reads }
    }

    /// T9（共性第 44 条）：completed 原结果 30411 → 第 2 步 + error.30411.phone_change；记录删除；不并号。
    func testAbandonCompleted30411BackToStep2() async throws {
        let fixture = fixture()
        let (_, controller) = try await enterPending(fixture)
        let key = try XCTUnwrap(records().first?.key)
        script.on(Self.abandonWrite, Self.completed(30411, "null"))
        try await abandon(controller, key: key)
        assertAbandonRequest(key)
        await waitUntil("completed 30411 没有回第 2 步") { controller.state.step == .step2 }
        XCTAssertTrue(keys(controller.state).contains("error.30411.phone_change"))
        XCTAssertNil(controller.state.dialog)
        XCTAssertTrue(records().isEmpty)
    }

    /// T9：放弃得到 40901 → abandon_busy，保持待确认，记录保持 unknown。
    func testAbandonBusyKeepsPending() async throws {
        let fixture = fixture()
        let (_, controller) = try await enterPending(fixture)
        let key = try XCTUnwrap(records().first?.key)
        script.on(Self.abandonWrite, Self.code(40901))
        try await abandon(controller, key: key)
        assertAbandonRequest(key)
        XCTAssertEqual(controller.state.pendingNotice?.key, "pending_confirm.abandon_busy")
        XCTAssertEqual(controller.state.step, .pending)
        XCTAssertEqual(records().first?.key, key)
        XCTAssertEqual(records().first?.stateRaw, PendingKeyStore.unknown)
    }

    /// T9（共性第 12 条）：放弃得到强更 10405 → 只消费网络层 Effect 进强更；记录保留（回来仍待确认）。
    func testAbandonForced10405KeepsRecord() async throws {
        let fixture = fixture()
        let (_, controller) = try await enterPending(fixture)
        let key = try XCTUnwrap(records().first?.key)
        script.on(Self.abandonWrite, Self.code(10405, "{\"min_supported_version\":\"99.0.0\"}"))
        act(controller).askAbandon()
        act(controller).confirmAbandon(try XCTUnwrap(controller.state.dialog))
        await waitUntil("作废没有发出") { !self.sent(Self.abandonWrite).isEmpty }
        await waitUntil("没进强更") { fixture.routing.mustShowForceUpdate }
        assertAbandonRequest(key)
        XCTAssertEqual(records().first?.key, key, "记录保留")
        XCTAssertEqual(records().first?.stateRaw, PendingKeyStore.unknown)
        XCTAssertNotEqual(controller.state.step, .step1, "不当作已放弃")
    }
}
