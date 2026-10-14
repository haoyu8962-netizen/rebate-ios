@testable import Couli
import CouliNetwork
import Foundation
import Router
import Wallet
import WalletCore
import XCTest

/// 结果未知与待确认（BR-ID-10 细则「敏感操作的幂等键」，AC-S2-62 ⑨–⑳ ㉒）：不换键、不自动重发；【确认上一笔】原键原体重发、【放弃上一笔】二次确认
/// 后作废；各结局是否结束键；跨午夜与 24 小时不解除、换账号不发不展示、原账号再登录恢复、10405 不结束键。
final class WithdrawPendingTests: WalletFlowTestCase {
    /// 结果未知 → 待确认：新的提交入口置灰（不换键、不自动重发）；【确认上一笔】用原键、原请求体重发，成功同提交成功。
    func testUnknownEntersPendingAndConfirmReusesKeyAndBody() async throws {
        let fixture = make()
        let controller = try await withdraw(fixture)
        try await enterPending(controller)
        XCTAssertEqual(posts.count, 1, "结果未知不自动重发")
        XCTAssertFalse(controller.flow.state.canSubmit)
        actions(controller).submit()
        await settle()
        XCTAssertEqual(posts.count, 1, "待确认时【提交】不发")
        script.ok("POST /v1/withdrawals", WalletSamples.withdrawal("W-confirm"))
        flowActions(controller.flow).confirm()
        await waitUntil("没有进提现记录") { fixture.router.path.last?.route == WalletRoutes.withdrawRecords }
        XCTAssertEqual(posts.count, 2)
        XCTAssertEqual(posts[0].header("Idempotency-Key"), posts[1].header("Idempotency-Key"))
        XCTAssertEqual(posts[0].body, posts[1].body)
    }

    /// 确认的结局：3xxxx → 键结束，显示该错误并恢复【提交】（⑯）；20903 → 键结束；其他 2xxxx → cannot_confirm 保持待确认；42901 →
    /// retry_later，保持待确认并写入提现的共享禁用期。
    func testConfirmOutcomes() async throws {
        // swiftlint:disable:next large_tuple
        let cases: [(Int, Bool, String)] = [
            (30303, true, "error.30303"), (20903, true, "error.20903"),
            (20002, false, "pending_confirm.cannot_confirm"), (42901, false, "pending_confirm.retry_later"),
        ]
        for (code, ends, key) in cases {
            WalletStubProtocol.reset()
            script.install()
            let fixture = make()
            let controller = try await withdraw(fixture)
            try await enterPending(controller)
            script.fail("POST /v1/withdrawals", code, data: code == 30303 ? "{\"reason\":\"daily_count\"}" : "null")
            flowActions(controller.flow).confirm()
            await waitUntil("确认没有结算 \(code)") {
                ends ? controller.flow.state.pending == nil : controller.flow.state.pendingNotice?.key == key
            }
            if ends {
                // 30303 按 reason 取子键（G06：占位符取不到值时用 fallbacks）
                XCTAssertEqual(controller.flow.state.error?.key, code == 30303 ? "error.30303.daily_count" : key)
                XCTAssertTrue(controller.flow.state.canSubmit, "恢复【提交】")
            } else {
                XCTAssertEqual(controller.flow.state.phase, .pending)
            }
            if code == 42901 {
                XCTAssertTrue(fixture.gates.withdraw.active, "提交、确认、放弃共用一个截止时间")
                XCTAssertFalse(fixture.gates.payout.active, "收款账号的截止时间单独一份")
            }
            fixture.router.path.removeAll()
        }
    }

    /// 放弃：先弹二次确认，点【确定放弃】才调 abandon（不带 Idempotency-Key）。abandoned → 键结束、表单可用；completed（原结果成功）→ 以
    /// 提现记录替换本页；completed（原结果 3xxxx）→ 显示该错误；40901 → abandon_busy 保持待确认。
    func testAbandonOutcomes() async throws {
        let replies: [(String, String?)] = [
            ("{\"outcome\":\"abandoned\",\"original\":null}", nil),
            (
                "{\"outcome\":\"completed\",\"original\":{\"code\":0,\"msg\":\"\",\"data\":"
                    + "\(WalletSamples.withdrawal("W-done"))}}",
                WalletRoutes.withdrawRecords
            ),
            ("{\"outcome\":\"completed\",\"original\":{\"code\":30301,\"msg\":\"\",\"data\":null}}", "error.30301"),
        ]
        for (data, expectation) in replies {
            WalletStubProtocol.reset()
            script.install()
            let fixture = make()
            let controller = try await withdraw(fixture)
            try await enterPending(controller)
            script.ok("POST /v1/idempotency-keys/abandon", data)
            flowActions(controller.flow).askAbandon()
            XCTAssertNotNil(controller.flow.state.abandonConfirmKey, "先弹二次确认")
            XCTAssertTrue(WalletStubProtocol.requests("POST", "/v1/idempotency-keys/abandon").isEmpty)
            flowActions(controller.flow).abandon()
            await waitUntil("放弃没有结算") { controller.flow.state.pending == nil }
            let abandon = try XCTUnwrap(WalletStubProtocol.requests("POST", "/v1/idempotency-keys/abandon").first)
            XCTAssertNil(abandon.header("Idempotency-Key"))
            XCTAssertEqual(abandon.json["action"] as? String, "withdraw")
            XCTAssertEqual(abandon.json["idempotency_key"] as? String, posts[0].header("Idempotency-Key"))
            switch expectation {
            case WalletRoutes.withdrawRecords:
                await waitUntil { fixture.router.path.last?.route == WalletRoutes.withdrawRecords }
            case let .some(key):
                XCTAssertEqual(controller.flow.state.error?.key, key)
            case .none:
                XCTAssertEqual(controller.flow.state.toast?.key, "pending_confirm.abandoned")
                XCTAssertTrue(controller.flow.state.canSubmit)
            }
            fixture.router.path.removeAll()
        }
    }

    /// 40901 → abandon_busy，保持待确认；确认 / 放弃在途时两个按钮都置灰（WithdrawPendingBusy）。
    func testAbandonBusyKeepsPendingAndInFlightDisablesButtons() async throws {
        let fixture = make()
        let controller = try await withdraw(fixture)
        try await enterPending(controller)
        script.on("POST /v1/idempotency-keys/abandon", .hold)
        flowActions(controller.flow).askAbandon()
        flowActions(controller.flow).abandon()
        await waitUntil { WalletStubProtocol.heldIds.count == 1 }
        XCTAssertEqual(controller.flow.state.pending?.inFlight, true, "在途时两个按钮都置灰")
        flowActions(controller.flow).confirm()
        await settle()
        XCTAssertEqual(posts.count, 1, "在途时确认不受理")
        let held = try XCTUnwrap(WalletStubProtocol.heldIds.first)
        WalletStubProtocol.release(held, with: .envelope(code: 40901, data: "null", headers: [:]))
        await waitUntil { controller.flow.state.pendingNotice?.key == "pending_confirm.abandon_busy" }
        XCTAssertNotNil(controller.flow.state.pending)
        XCTAssertEqual(controller.flow.state.pending?.inFlight, false)
    }

    /// 不按时间解除（跨午夜、24 小时）；换账号不发、不展示；原账号再登录恢复；10405 不结束键。
    func testPendingSurvivesTimeAccountSwitchAndForceUpdate() async throws {
        let fixture = make()
        let controller = try await withdraw(fixture)
        try await enterPending(controller)
        let key = posts[0].header("Idempotency-Key")
        fixture.wallet.clock = { Int64(Date().timeIntervalSince1970 * 1000) + 25 * 3_600_000 }
        try fixture.switchAccount(to: "user-b")
        await settle()
        XCTAssertNil(controller.flow.state.pending, "别的账号不展示上一个账号的待确认")
        flowActions(controller.flow).confirm()
        await settle()
        XCTAssertEqual(posts.count, 1, "别的账号不发")
        try fixture.switchAccount(to: "user-a")
        await waitUntil("原账号再登录恢复待确认") { controller.flow.state.pending != nil }
        XCTAssertEqual(controller.flow.state.pending?.key, key, "24 小时后、跨午夜仍是同一个键")
        script.fail("POST /v1/withdrawals", 10405, data: "{\"min_supported_version\":\"9.9.9\"}")
        flowActions(controller.flow).confirm()
        await waitUntil { posts.count == 2 }
        await settle()
        // 10405 进已有的强更分流（强更页盖住提现页）；未决记录不结束，升级后发起页仍是待确认
        let lookup = await fixture.network.client.pendingStatus(operationId: "createWithdrawal")
        guard case let .record(record) = lookup else {
            return XCTFail("10405 不结束未决键")
        }
        XCTAssertEqual(record.key, key)
        XCTAssertEqual(posts[1].header("Idempotency-Key"), key)
    }

    /// 42901 共享截止时间（共性第 15 条）：首次提交得到 42901 后，确认 / 放弃在执行层也被同一个截止时间拦下；发码的截止时间单独一份。
    func testRetryAfterSharedDeadlineBlocksConfirmAtExecutionLayer() async throws {
        let fixture = make()
        let controller = try await withdraw(fixture)
        try await enterPending(controller)
        fixture.gates.withdraw.start(30000)
        flowActions(controller.flow).confirm()
        XCTAssertEqual(controller.flow.state.pendingNotice?.key, "pending_confirm.retry_later")
        let target = PendingTarget(
            account: "user-a", key: controller.flow.state.pending?.key ?? "", expected: controller.owner.request,
            sendAllowed: fixture.gates.withdraw.sendAllowed
        )
        let result = await fixture.network.client.confirmPending(
            operationId: "createWithdrawal", stepUpToken: nil, target: target
        )
        XCTAssertEqual(result, .localReject(reason: LocalRejectReason.sendBlocked), "执行层拦截，零写出")
        XCTAssertEqual(posts.count, 1)
        XCTAssertFalse(fixture.gates.sms.active)
    }
}
