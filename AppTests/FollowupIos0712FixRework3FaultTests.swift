@testable import Couli
import CouliNetwork
import Foundation
import Router
import Wallet
@testable import WalletCore
import XCTest

/// FU-IOS-0712 补修三：资金写入口的故障顺序（假钱包服务 + 可单次读失败的令牌存储注入，不依赖真机网络）。对【提交】【确认上一笔】
/// 【放弃】分别覆盖：① 写请求超时（传输断开）而服务端实为成功；② 成功后本机记录先被结束、记录同步先读到 none，结果回调随后才到且
/// 身份暂时未知；③ 同一结果被投递两次（两条恢复路径同时补做 + 结算通知重复）。统一断言：同一笔只用一个幂等键（新键写请求为 0）、
/// 不显示可重试错误、恢复前后都不能用新键再提交。
final class FollowupIos0712FixRework3FaultTests: WalletFlowTestCase {
    private static let abandonDone = "{\"outcome\":\"completed\",\"original\":{\"code\":0,\"msg\":\"\",\"data\":"
        + "\(WalletSamples.withdrawal("W-done"))}}"

    private var keys: Set<String> {
        Set(posts.compactMap { $0.header("Idempotency-Key") })
    }

    private var abandons: Int {
        WalletStubProtocol.requests("POST", "/v1/idempotency-keys/abandon").count
    }

    /// 页面处于锁定态：不显示可重试错误、新提交不可用，点了也不发新键。
    private func assertLocked(_: WalletAppFixture, _ controller: WithdrawController, _ label: String) async {
        let state = controller.flow.state
        XCTAssertNil(state.error, "\(label)：不显示可重试错误")
        XCTAssertFalse(state.canSubmit, "\(label)：新提交不可用")
        let before = keys
        actions(controller).submit()
        await settle()
        XCTAssertEqual(keys, before, "\(label)：点提交不产生新键")
    }

    /// ③ 同一结果投递两次：两条恢复路径（回前台、本页【重试】）都补做 + 结算通知重复。
    private func deliverTwice(_ fixture: WalletAppFixture, _ controller: WithdrawController) {
        fixture.wallet.sceneChanged(active: false)
        fixture.wallet.sceneChanged(active: true)
        flowActions(controller.flow).recheck()
        fixture.wallet.deps.pending.send(PendingSettled(account: "user-a", operationId: WithdrawController.operation))
        fixture.wallet.deps.pending.send(PendingSettled(account: "user-a", operationId: WithdrawController.operation))
    }

    // MARK: - 【提交】

    /// ① 提交超时（传输断开）、服务端实为成功：进待确认（不是可重试错误、提交锁住）；【确认上一笔】用原键查到成功后落地。同一笔只一个键。
    func testSubmitTimeoutButServerSucceededLandsWithOneKey() async throws {
        let fixture = make()
        let controller = try await withdraw(fixture)
        try await enterPending(controller)
        await assertLocked(fixture, controller, "超时后")
        script.on("POST /v1/withdrawals", .envelope(code: 0, data: WalletSamples.withdrawal("W-late"), headers: [:]))
        flowActions(controller.flow).confirm()
        await waitUntil("原键确认后没有落地") { fixture.router.path.last?.route == WalletRoutes.withdrawRecords }
        XCTAssertEqual(keys.count, 1, "同一笔只一个幂等键")
    }

    /// ② + ③ 提交在途时本机记录先被结束、同步读到 none；成功回调随后到、页面采用那次读取失败；随后两条恢复路径同时补做。
    func testSubmitRecordVanishesFirstThenDuplicateDeliveryLandsOnce() async throws {
        let fixture = make()
        let controller = try await withdraw(fixture)
        await typeAmount(controller, "10")
        script.on("POST /v1/withdrawals", .hold)
        actions(controller).submit()
        await waitUntil("提交没有挂住") { WalletStubProtocol.heldIds.count == 1 }
        let key = try XCTUnwrap(controller.flow.reuseKey)
        try? fixture.pendingBackend.delete(account: "user-a", key: key)
        controller.flow.refreshPending()
        await settle()
        await assertLocked(fixture, controller, "在途记录消失")
        let held = try XCTUnwrap(WalletStubProtocol.heldIds.first)
        fixture.store.failRead(nth: 2)
        WalletStubProtocol.release(
            held, with: .envelope(code: 0, data: WalletSamples.withdrawal("W-new"), headers: [:])
        )
        await waitUntil("结果没有到达") { controller.flow.state.awaitingIdentity }
        await assertLocked(fixture, controller, "结果待确认")
        deliverTwice(fixture, controller)
        await waitUntil("没有落地") { fixture.router.path.last?.route == WalletRoutes.withdrawRecords }
        await settle()
        XCTAssertEqual(posts.count, 1, "写请求恰好 1")
        XCTAssertEqual(fixture.router.path.filter { $0.route == WalletRoutes.withdrawRecords }.count, 1, "只落地一次")
    }

    // MARK: - 【确认上一笔】

    /// ① 确认超时、服务端实为成功：保持待确认（不显示可重试错误、提交锁住）；再次确认用原键查到成功后落地。
    func testConfirmTimeoutButServerSucceededLandsWithOneKey() async throws {
        let fixture = make()
        let controller = try await withdraw(fixture)
        try await enterPending(controller)
        script.on("POST /v1/withdrawals", .disconnect)
        flowActions(controller.flow).confirm()
        await waitUntil("确认没有结算") {
            controller.flow.state.pending?.inFlight == false && !WalletStubProtocol.requests.isEmpty
        }
        await settle()
        XCTAssertNotNil(controller.flow.state.pending, "仍待确认")
        await assertLocked(fixture, controller, "确认超时后")
        script.on("POST /v1/withdrawals", .envelope(code: 0, data: WalletSamples.withdrawal("W-late"), headers: [:]))
        flowActions(controller.flow).confirm()
        await waitUntil("原键确认后没有落地") { fixture.router.path.last?.route == WalletRoutes.withdrawRecords }
        XCTAssertEqual(keys.count, 1, "同一笔只一个幂等键")
    }

    /// ② + ③ 确认在途时记录先没了、成功回调随后到且页面采用读失败；两条恢复路径同时补做：落地一次，不新增写请求。
    func testConfirmRecordVanishesFirstThenDuplicateDeliveryLandsOnce() async throws {
        let fixture = make()
        let controller = try await withdraw(fixture)
        try await enterPending(controller)
        let key = try XCTUnwrap(controller.flow.state.pending?.key)
        script.on("POST /v1/withdrawals", .hold)
        flowActions(controller.flow).confirm()
        await waitUntil("确认没有挂住") { WalletStubProtocol.heldIds.count == 1 }
        try? fixture.pendingBackend.delete(account: "user-a", key: key)
        controller.flow.refreshPending()
        await settle()
        XCTAssertNotNil(controller.flow.state.pending, "操作锁期间记录消失不清待确认")
        await assertLocked(fixture, controller, "确认在途记录消失")
        let posted = posts.count
        let held = try XCTUnwrap(WalletStubProtocol.heldIds.first)
        fixture.store.failRead(nth: 2)
        WalletStubProtocol.release(
            held, with: .envelope(code: 0, data: WalletSamples.withdrawal("W-confirm"), headers: [:])
        )
        await waitUntil("结果没有到达") { controller.flow.state.awaitingIdentity }
        await assertLocked(fixture, controller, "确认结果待确认")
        deliverTwice(fixture, controller)
        await waitUntil("没有落地") { fixture.router.path.last?.route == WalletRoutes.withdrawRecords }
        await settle()
        XCTAssertEqual(posts.count, posted, "不新增写请求")
        XCTAssertEqual(keys.count, 1, "同一笔只一个幂等键")
    }

    // MARK: - 【放弃】

    /// ① 放弃超时、服务端实为已完成（原结果成功）：保持待确认（不显示可重试错误、提交锁住）；再次放弃查到已完成后按成功落地。
    func testAbandonTimeoutButServerCompletedLandsWithoutNewWrite() async throws {
        let fixture = make()
        let controller = try await withdraw(fixture)
        try await enterPending(controller)
        script.on("POST /v1/idempotency-keys/abandon", .disconnect)
        flowActions(controller.flow).askAbandon()
        flowActions(controller.flow).abandon()
        await waitUntil("放弃没有结算") { controller.flow.state.pending?.inFlight == false && abandons == 1 }
        await settle()
        XCTAssertNotNil(controller.flow.state.pending, "仍待确认")
        await assertLocked(fixture, controller, "放弃超时后")
        script.ok("POST /v1/idempotency-keys/abandon", Self.abandonDone)
        flowActions(controller.flow).askAbandon()
        flowActions(controller.flow).abandon()
        await waitUntil("已完成后没有按成功落地") { fixture.router.path.last?.route == WalletRoutes.withdrawRecords }
        XCTAssertEqual(posts.count, 1, "提现写请求恰好 1（只有最初那笔）")
    }

    /// ② + ③ 放弃在途时记录先没了、已完成（原结果成功）回调随后到且页面采用读失败；两条恢复路径同时补做：按成功落地一次。
    func testAbandonRecordVanishesFirstThenDuplicateDeliveryLandsOnce() async throws {
        let fixture = make()
        let controller = try await withdraw(fixture)
        try await enterPending(controller)
        let key = try XCTUnwrap(controller.flow.state.pending?.key)
        script.on("POST /v1/idempotency-keys/abandon", .hold)
        flowActions(controller.flow).askAbandon()
        flowActions(controller.flow).abandon()
        await waitUntil("放弃没有挂住") { WalletStubProtocol.heldIds.count == 1 }
        try? fixture.pendingBackend.delete(account: "user-a", key: key)
        controller.flow.refreshPending()
        await settle()
        XCTAssertNotNil(controller.flow.state.pending, "操作锁期间记录消失不清待确认")
        await assertLocked(fixture, controller, "放弃在途记录消失")
        let held = try XCTUnwrap(WalletStubProtocol.heldIds.first)
        fixture.store.failRead(nth: 2)
        WalletStubProtocol.release(held, with: .envelope(code: 0, data: Self.abandonDone, headers: [:]))
        await waitUntil("结果没有到达") { controller.flow.state.awaitingIdentity }
        await assertLocked(fixture, controller, "放弃结果待确认")
        deliverTwice(fixture, controller)
        await waitUntil("没有落地") { fixture.router.path.last?.route == WalletRoutes.withdrawRecords }
        await settle()
        XCTAssertEqual(posts.count, 1, "提现写请求恰好 1（只有最初那笔）")
        XCTAssertEqual(abandons, 1, "放弃只发一次")
    }
}
