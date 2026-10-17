@testable import Couli
import CouliNetwork
import Foundation
import Router
import Wallet
@testable import WalletCore
import XCTest

/// FU-IOS-0713 终版补测：完成信号承重（M43a、M44a/b/c/d/e）与 installBackends 计数（M22b）。`whenIdle()` 之后直接做正向断言，不再轮询。
extension FollowupIos0713FinalTests {
    // MARK: - 完成信号承重（whenIdle 之后直接正向断言）

    /// M44a：发码任务。发码响应放行后 `stepUp.whenIdle()` 返回时，倒计时已经按结果开始。
    /// M43a：WalletRequests 包装（验证请求）。验证响应放行后 `stepUp.whenIdle()` 返回时，token 已交出、面板已收起。
    func test_fuios0713_final_stepUpWhenIdleCoversSendTaskAndVerifyRequest() async throws {
        let fixture = fresh("面板完成信号")
        script.on("POST /v1/withdrawals", .hold)
        script.on("POST /v1/auth/sms-codes", .hold, Self.smsOk)
        script.on("POST /v1/auth/step-up", .hold, Self.stepOk)
        let controller = try await withdraw(fixture)
        await typeAmount(controller, "10")
        actions(controller).submit()
        await waitUntil("提交没有挂住") { WalletStubProtocol.heldIds.count == 1 }
        WalletStubProtocol.release(try XCTUnwrap(WalletStubProtocol.heldIds.first), with: Self.need)
        let stepUp = controller.flow.stepUp
        await waitUntil("发码没有挂住") { stepUp.state != nil && WalletStubProtocol.heldIds.count == 1 }
        WalletStubProtocol.release(try XCTUnwrap(WalletStubProtocol.heldIds.first), with: Self.smsOk)
        await stepUp.whenIdle()
        let sent = try XCTUnwrap(stepUp.state)
        XCTAssertEqual(sent.phase, .ready, "whenIdle 返回时发码结果已结算")
        XCTAssertGreaterThan(sent.resendLeftSec, 0, "whenIdle 返回时倒计时已开始")
        let held = try await verifyAndHold(stepUp, "面板完成信号")
        WalletStubProtocol.release(held, with: Self.stepOk)
        await stepUp.whenIdle()
        XCTAssertNil(stepUp.state, "whenIdle 返回时验证结果已结算（token 交出、面板收起）")
        await waitUntil("原键重放没有挂住") { WalletStubProtocol.heldIds.count == 1 }
        WalletStubProtocol.release(try XCTUnwrap(WalletStubProtocol.heldIds.first), with: Self.landed)
        await controller.flow.whenIdle()
        XCTAssertTrue(onTop(fixture, WalletRoutes.withdrawRecords), "whenIdle 返回时重放结果已采用")
    }

    /// M44b：SensitiveFlow 提交任务。提交成功响应放行后 `flow.whenIdle()` 返回时已进提现记录。
    func test_fuios0713_final_flowWhenIdleCoversSubmitTask() async throws {
        let fixture = fresh("提交完成信号")
        script.on("POST /v1/withdrawals", .hold)
        let controller = try await withdraw(fixture)
        await typeAmount(controller, "10")
        actions(controller).submit()
        await waitUntil("提交没有挂住") { WalletStubProtocol.heldIds.count == 1 }
        WalletStubProtocol.release(try XCTUnwrap(WalletStubProtocol.heldIds.first), with: Self.landed)
        await controller.flow.whenIdle()
        XCTAssertTrue(onTop(fixture, WalletRoutes.withdrawRecords), "whenIdle 返回时提交结果已采用")
    }

    /// M44e：runConfirm 任务。【确认上一笔】成功响应放行后 `flow.whenIdle()` 返回时已进提现记录。
    func test_fuios0713_final_flowWhenIdleCoversRunConfirmTask() async throws {
        let fixture = fresh("确认完成信号")
        let controller = try await withdraw(fixture)
        try await enterPending(controller)
        script.on("POST /v1/withdrawals", .hold)
        flowActions(controller.flow).confirm()
        await waitUntil("确认没有挂住") { WalletStubProtocol.heldIds.count == 1 }
        WalletStubProtocol.release(try XCTUnwrap(WalletStubProtocol.heldIds.first), with: Self.landed)
        await controller.flow.whenIdle()
        XCTAssertTrue(onTop(fixture, WalletRoutes.withdrawRecords), "whenIdle 返回时确认结果已采用")
        XCTAssertEqual(confirmCalls(fixture), 1, "确认入口 1 次")
    }

    /// M44c：abandon 任务。【放弃】的响应放行后 `flow.whenIdle()` 返回时待确认已结束。
    func test_fuios0713_final_flowWhenIdleCoversAbandonTask() async throws {
        let fixture = fresh("放弃完成信号")
        let controller = try await withdraw(fixture)
        try await enterPending(controller)
        script.on("POST /v1/idempotency-keys/abandon", .hold)
        flowActions(controller.flow).askAbandon()
        flowActions(controller.flow).abandon()
        await waitUntil("放弃没有挂住") { WalletStubProtocol.heldIds.count == 1 }
        WalletStubProtocol.release(
            try XCTUnwrap(WalletStubProtocol.heldIds.first),
            with: .envelope(code: 0, data: "{\"outcome\":\"abandoned\",\"original\":null}", headers: [:])
        )
        await controller.flow.whenIdle()
        XCTAssertNil(controller.flow.state.pending, "whenIdle 返回时放弃结果已采用（待确认结束）")
        XCTAssertEqual(fixture.api.calls("abandon:" + WithdrawController.operation), 1, "放弃入口 1 次")
    }

    /// M44d：refreshPending 任务。本机未决记录被结束后读一次记录，`flow.whenIdle()` 返回时待确认已按记录清掉。
    func test_fuios0713_final_flowWhenIdleCoversRefreshPendingTask() async throws {
        let fixture = fresh("记录同步完成信号")
        let controller = try await withdraw(fixture)
        try await enterPending(controller)
        let key = try XCTUnwrap(controller.flow.state.pending?.key)
        try fixture.pendingBackend.delete(account: "user-a", key: key)
        controller.flow.refreshPending()
        await controller.flow.whenIdle()
        XCTAssertNil(controller.flow.state.pending, "whenIdle 返回时记录同步已采用")
    }

    // MARK: - M22b：installBackends 之后计数仍生效

    /// installBackends 重建依赖后，页面仍经生产注入的 WalletApi：打开提现页后 rules 入口有计数，且与实际发送一致。
    func test_fuios0713_final_installBackendsKeepsWalletApiCounting() async throws {
        let fixture = fresh("installBackends 计数")
        fixture.wallet.installBackends(realname: GateRealName(), labor: GateLabor())
        _ = try await withdraw(fixture)
        let calls = fixture.api.calls("getWithdrawRules")
        XCTAssertGreaterThan(calls, 0, "installBackends 之后 rules 读取经计数入口")
        XCTAssertEqual(calls, WalletStubProtocol.requests("GET", "/v1/withdrawals/rules").count, "入口与实际发送一致")
    }
}
