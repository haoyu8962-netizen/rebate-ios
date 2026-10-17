@testable import Couli
import CouliNetwork
import Foundation
import Router
import Wallet
@testable import WalletCore
import XCTest

/// FU-IOS-0712 重理后补修二（RV-01～RV-04）：「结果待身份确认」与「共享结算未落地」都是独立的提交锁；刷新接收端三态；待确认卡区分在途与待确认。
final class FollowupIos0712FixRework2Tests: WalletFlowTestCase {
    /// RV-01 / RV-04：恢复出的待确认页，【确认上一笔】成功响应到达时只有采用那一次身份读取失败；随后待确认记录按网络层结论已不存在。
    /// 页面不因此解除提交锁、不丢原结果：提交与确认都不可用、点了不发；待确认卡停转圈但仍禁用；本页【重试】后按原结果落地，POST 不增加。
    func testConfirmSuccessAwaitingIdentityStaysLockedWhenRecordVanishes() async throws {
        let fixture = make()
        let controller = try await withdraw(fixture)
        try await enterPending(controller)
        script.on("POST /v1/withdrawals", .hold)
        flowActions(controller.flow).confirm()
        await waitUntil("确认没有挂住") { WalletStubProtocol.heldIds.count == 1 }
        XCTAssertTrue(controller.flow.state.pendingCardBusy, "前提：请求在途时转圈")
        let held = try XCTUnwrap(WalletStubProtocol.heldIds.first)
        // 响应回来后：共享结算核对（第 1 次）成功，页面采用核对（第 2 次）失败，之后的待确认记录重读成功（读到已不存在）
        fixture.store.failRead(nth: 2)
        WalletStubProtocol.release(
            held, with: .envelope(code: 0, data: WalletSamples.withdrawal("W-confirm"), headers: [:])
        )
        await waitUntil("确认结果没有到达") { controller.flow.state.awaitingIdentity }
        await settle()
        let posted = posts.count
        let waiting = controller.flow.state
        XCTAssertTrue(waiting.awaitingIdentity, "记录消失不解除待确认锁")
        XCTAssertFalse(waiting.canSubmit, "提交锁住")
        XCTAssertFalse(waiting.pendingCardBusy, "待确认卡停转圈")
        XCTAssertFalse(waiting.pendingActionsEnabled, "确认 / 放弃仍禁用")
        XCTAssertNil(waiting.pendingNotice, "不再显示正在处理")
        actions(controller).submit()
        flowActions(controller.flow).confirm()
        await settle()
        XCTAssertEqual(posts.count, posted, "等待期间再点提交 / 确认都不发")
        flowActions(controller.flow).recheck()
        await waitUntil("本页核对后没有按原结果落地") {
            fixture.router.path.last?.route == WalletRoutes.withdrawRecords
        }
        await settle()
        XCTAssertEqual(posts.count, posted, "写请求不增加")
    }

    /// RV-02：只有共享结算那次读取失败、42901 留在会话级服务里，页面已恢复可编辑。用户留在本页直接再点【提交】（之前没有任何外部
    /// 核对）：仍未知 → 不发；身份恢复后再点 → 先补结算、禁用期生效 → 仍不发。
    func testHeldRetryAfterLocksSubmitBeforeAnyExternalCheck() async throws {
        let fixture = make()
        let controller = try await withdraw(fixture)
        await typeAmount(controller, "10")
        script.on("POST /v1/withdrawals", .hold)
        actions(controller).submit()
        await waitUntil("提交没有挂住") { WalletStubProtocol.heldIds.count == 1 }
        let held = try XCTUnwrap(WalletStubProtocol.heldIds.first)
        fixture.store.failRead(nth: 2)
        WalletStubProtocol.release(held, with: .envelope(code: 42901, data: "null", headers: ["Retry-After": "10"]))
        await waitUntil("结果没有到达") { fixture.wallet.deps.settlement.hasHeld }
        await waitUntil("页面没有采用结果") { controller.flow.state.phase == .editing }
        script.on("POST /v1/withdrawals")
        fixture.store.failReads(fromNth: 1)
        actions(controller).submit()
        await settle()
        XCTAssertEqual(posts.count, 1, "共享结算未落地、身份仍未知：不发")
        fixture.store.stopFailing()
        actions(controller).submit()
        await settle()
        let gated = fixture.gates.withdraw.active
        XCTAssertTrue(gated, "再点时先补结算，禁用期生效")
        XCTAssertEqual(posts.count, 1, "Retry-After 内不发")
    }

    /// RV-03：成功结果的共享结算在未知期保留；发起页已按成功退出（换成提现记录）。恢复时共享结算发出钱包刷新，但钱包页接收端那一次
    /// 身份读取失败：刷新责任保留，同一次确认里补取摘要。
    func testWalletDirtyReceiverUnknownKeepsRefreshDuty() async throws {
        let fixture = make()
        let wallet = try XCTUnwrap(fixture.open(WalletRoutes.wallet)?.controller as? WalletController)
        wallet.load()
        await waitUntil { wallet.state.summary != nil }
        let controller = try await withdraw(fixture)
        await typeAmount(controller, "10")
        script.on("POST /v1/withdrawals", .hold)
        actions(controller).submit()
        await waitUntil("提交没有挂住") { WalletStubProtocol.heldIds.count == 1 }
        let held = try XCTUnwrap(WalletStubProtocol.heldIds.first)
        fixture.store.failRead(nth: 1)
        WalletStubProtocol.release(
            held, with: .envelope(code: 0, data: WalletSamples.withdrawal("W-new"), headers: [:])
        )
        await waitUntil("发起页没有按成功退出") { fixture.router.path.last?.route == WalletRoutes.withdrawRecords }
        XCTAssertTrue(fixture.wallet.deps.settlement.hasHeld, "前提：共享结算保留")
        let summaries = WalletStubProtocol.requests("GET", "/v1/wallet/summary").count
        // 核对：快照（第 1 次）→ 共享结算（第 2 次）→ 钱包页接收刷新（第 3 次，失败）
        fixture.store.failRead(nth: 3)
        fixture.wallet.checkSession()
        await waitUntil("刷新责任丢了") {
            WalletStubProtocol.requests("GET", "/v1/wallet/summary").count > summaries
        }
        XCTAssertFalse(wallet.loadPending, "补取完成")
    }
}
