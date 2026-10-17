@testable import Couli
import CouliNetwork
import Foundation
@testable import OrderCore
import Orders
import Router
import Wallet
@testable import WalletCore
import XCTest

/// FU-IOS-0712 重理后补修（RW-01）：未知身份不算当前；身份暂时未知期间用户的接管在换上身份后保留，旧恢复记录不覆盖。全部经生产入口。
extension FollowupIos0712FixR1ColdStartTests {
    /// 持续未知期间构造的列表页：两份未确认身份相同也不算当前（不发请求）；用户切子 Tab、输入搜索照样受理；身份恢复后换上的新页面保留
    /// 这些操作，不恢复磁盘旧条件与锚点。
    func testReworkFixUserTakeoverWhileUnknownSurvivesIdentityRecovery() async throws {
        let fixture = OrdersAppFixture.make(suiteName: suiteName, defaults: defaults)
        _ = try await seedOwnedCacheAndRecord(fixture)
        let requests = AppStubProtocol.requests.count
        fixture.store.failReads(fromNth: 1)
        let cold = coldOrders(fixture) { true }
        let page = cold.listPage(RouteDestination(route: "OrderList"))
        XCTAssertFalse(page.controller.owner.identityKnown, "前提：持续未知期间构造")
        XCTAssertEqual(page.controller.ownerCheck, .unknown, "两份未确认身份相同也不算当前")
        page.controller.start()
        XCTAssertTrue(page.controller.setScope(OrderQuery.shareScope), "未知期间切子 Tab 受理")
        page.controller.updateSearchText("abc")
        let sent = AppStubProtocol.requests.count
        XCTAssertEqual(sent, requests, "未知期间不发请求")
        fixture.store.stopFailing()
        cold.checkSession()
        let fresh = cold.listPage(RouteDestination(route: "OrderList"))
        XCTAssertFalse(fresh === page, "换上已确认身份的新页面")
        let query = fresh.controller.snapshot.query
        XCTAssertEqual(query.scope, OrderQuery.shareScope, "保留用户切的子 Tab")
        XCTAssertEqual(fresh.controller.snapshot.searchText, "abc", "保留用户输入的搜索词")
        XCTAssertFalse(fresh.anchor.restoring, "旧恢复任务取消")
    }

    /// 只在搜索框里输入（没有提交）：同样算接管，换上身份后保留输入、不恢复旧锚点。
    func testReworkFixSearchTypingWhileUnknownSurvivesIdentityRecovery() async throws {
        let fixture = OrdersAppFixture.make(suiteName: suiteName, defaults: defaults)
        _ = try await seedOwnedCacheAndRecord(fixture)
        fixture.store.failReads(fromNth: 1)
        let cold = coldOrders(fixture) { true }
        let page = cold.listPage(RouteDestination(route: "OrderList"))
        page.controller.updateSearchText("37123")
        fixture.store.stopFailing()
        cold.checkSession()
        let fresh = cold.listPage(RouteDestination(route: "OrderList"))
        let text = fresh.controller.snapshot.searchText
        XCTAssertEqual(text, "37123", "保留输入")
        XCTAssertFalse(fresh.anchor.restoring, "旧恢复任务取消")
    }
}

extension FollowupIos0712FixR1ColdStartTests {
    /// 接管记下之后、新页面建出之前发生已知换代（换账号）：接管属于旧会话，丢弃，新会话的页面按默认条件。
    func testReworkFixTakeoverDroppedOnSessionChange() async throws {
        let fixture = OrdersAppFixture.make(suiteName: suiteName, defaults: defaults)
        _ = try await seedOwnedCacheAndRecord(fixture)
        fixture.store.failReads(fromNth: 1)
        let cold = coldOrders(fixture) { true }
        let page = cold.listPage(RouteDestination(route: "OrderList"))
        XCTAssertTrue(page.controller.setScope(OrderQuery.shareScope), "前提：未知期间受理")
        fixture.store.stopFailing()
        cold.checkSession()
        XCTAssertNotNil(cold.takeover, "前提：接管已记下")
        fixture.network.client.signOut()
        try fixture.tokens.save(access: "at-b", refresh: "rt-b", scope: "full", account: "user-b")
        cold.checkSession()
        let fresh = cold.listPage(RouteDestination(route: "OrderList"))
        let scope = fresh.controller.snapshot.query.scope
        XCTAssertNil(cold.takeover, "换代丢弃接管")
        XCTAssertNotEqual(scope, OrderQuery.shareScope, "新会话按默认条件")
    }
}

/// FU-IOS-0712 重理后补修（RW-02、RW-03）：共享结算三态；写请求已结束、等身份确认时页面有出口。
final class FollowupIos0712FixReworkWalletTests: WalletFlowTestCase {
    /// 可控的本机时钟（钱包 `clock`）。
    private final class Clock {
        var now: Int64 = 1_000_000
    }

    /// RW-02：只有共享结算那一次身份读取失败、42901（Retry-After 10 秒）：确认后禁用期按原截止生效（扣掉等待的 3 秒），
    /// 不能在 Retry-After 内再发。
    func testReworkFixRetryAfterHeldWhileUnknownStartsAtOriginalDeadline() async throws {
        let fixture = make()
        let clock = Clock()
        fixture.wallet.clock = { clock.now }
        let controller = try await withdraw(fixture)
        await typeAmount(controller, "10")
        script.on("POST /v1/withdrawals", .hold)
        actions(controller).submit()
        await waitUntil("提交没有挂住") { WalletStubProtocol.heldIds.count == 1 }
        let held = try XCTUnwrap(WalletStubProtocol.heldIds.first)
        // 响应回来后：网络层处理 42901 时自己读一次会话（第 1 次），共享结算的身份核对是第 2 次——只让它失败；页面的核对照常成功
        fixture.store.failRead(nth: 2)
        WalletStubProtocol.release(held, with: .envelope(code: 42901, data: "null", headers: ["Retry-After": "10"]))
        await waitUntil("结果没有到达") { fixture.wallet.deps.settlement.hasHeld }
        await waitUntil("页面没有采用结果") { controller.flow.state.phase != .submitting }
        let gated = fixture.gates.withdraw.active
        XCTAssertFalse(gated, "前提：结算读失败，禁用期还没启动")
        clock.now += 3000
        fixture.wallet.checkSession()
        let remaining = fixture.gates.withdraw.remainingMillis
        XCTAssertTrue(fixture.gates.withdraw.active, "确认后补结算")
        XCTAssertLessThanOrEqual(remaining, 7000, "按原截止（扣掉等待的时长）")
        XCTAssertFalse(fixture.wallet.deps.settlement.hasHeld, "只结算一次")
        actions(controller).submit()
        await settle()
        XCTAssertEqual(posts.count, 1, "Retry-After 内不能再发")
    }

    /// RW-02：成功结果的共享结算读失败：确认后补做 token 消费与钱包刷新。
    func testReworkFixSuccessSettlementHeldWhileUnknownConsumesTokenAndRefreshes() async throws {
        let fixture = make()
        let wallet = try XCTUnwrap(fixture.open(WalletRoutes.wallet)?.controller as? WalletController)
        wallet.load()
        await waitUntil { wallet.state.summary != nil }
        let controller = try await withdraw(fixture)
        await typeAmount(controller, "10")
        let tokens = fixture.wallet.deps.tokens
        tokens.put(action: WithdrawController.action, account: "user-a", token: "t", expireAtMs: Int64.max)
        script.on("POST /v1/withdrawals", .hold)
        actions(controller).submit()
        await waitUntil("提交没有挂住") { WalletStubProtocol.heldIds.count == 1 }
        let held = try XCTUnwrap(WalletStubProtocol.heldIds.first)
        fixture.store.failRead(nth: 1)
        WalletStubProtocol.release(
            held,
            with: .envelope(code: 0, data: WalletSamples.withdrawal("W-new"), headers: [:])
        )
        await waitUntil("结果没有到达") { fixture.wallet.deps.settlement.hasHeld }
        let kept = tokens.take(action: WithdrawController.action, account: "user-a", nowMs: 0)
        XCTAssertEqual(kept, "t", "前提：结算还没做")
        let summaries = WalletStubProtocol.requests("GET", "/v1/wallet/summary").count
        fixture.wallet.checkSession()
        let token = tokens.take(action: WithdrawController.action, account: "user-a", nowMs: 0)
        XCTAssertNil(token, "确认后消费 token")
        await waitUntil("钱包没有被通知刷新") {
            WalletStubProtocol.requests("GET", "/v1/wallet/summary").count > summaries
        }
    }

    /// RW-03：提交结果（30306 业务错误）到达时身份暂时未知 → 不再显示「提交中」，页面给【重试】；Keychain 恢复后用户留在本页点【重试】即出结果
    /// （不调外部 checkSession），不重发。
    func testReworkFixSubmitAwaitingIdentityHasInPageExit() async throws {
        let fixture = make()
        let controller = try await withdraw(fixture)
        await typeAmount(controller, "10")
        script.on("POST /v1/withdrawals", .hold)
        actions(controller).submit()
        await waitUntil("提交没有挂住") { WalletStubProtocol.heldIds.count == 1 }
        let held = try XCTUnwrap(WalletStubProtocol.heldIds.first)
        fixture.store.failReads(fromNth: 1)
        WalletStubProtocol.release(held, with: .envelope(code: 30306, data: "null", headers: [:]))
        await waitUntil("结果没有到达") { controller.flow.state.awaitingIdentity }
        let waiting = controller.flow.state
        XCTAssertFalse(waiting.canSubmit, "不换键重提")
        XCTAssertEqual(fixture.router.path.last?.route, WalletRoutes.withdraw, "身份未知：不采用")
        fixture.store.stopFailing()
        flowActions(controller.flow).recheck()
        await waitUntil("本页核对后没有出结果") { controller.flow.state.error != nil }
        let applied = controller.flow.state
        XCTAssertFalse(applied.awaitingIdentity, "采用后结束等待")
        XCTAssertEqual(applied.error?.key, "error.30306", "采用原结果")
        XCTAssertEqual(applied.phase, .editing)
        XCTAssertEqual(posts.count, 1, "不重发")
    }

    /// RW-03：【确认上一笔】的结果到达时身份暂时未知 → 页面给【重试】；恢复后本页点【重试】即采用，不重发。
    func testReworkFixConfirmAwaitingIdentityHasInPageExit() async throws {
        let fixture = make()
        let controller = try await withdraw(fixture)
        try await enterPending(controller)
        script.on("POST /v1/withdrawals", .hold)
        flowActions(controller.flow).confirm()
        await waitUntil("确认没有挂住") { WalletStubProtocol.heldIds.count == 1 }
        let held = try XCTUnwrap(WalletStubProtocol.heldIds.first)
        fixture.store.failReads(fromNth: 1)
        WalletStubProtocol.release(
            held, with: .envelope(code: 0, data: WalletSamples.withdrawal("W-confirm"), headers: [:])
        )
        await waitUntil("确认结果没有到达") { controller.flow.state.awaitingIdentity }
        fixture.store.stopFailing()
        let posted = posts.count
        flowActions(controller.flow).recheck()
        await waitUntil("本页核对后没有出结果") { fixture.router.path.last?.route == WalletRoutes.withdrawRecords }
        XCTAssertEqual(posts.count, posted, "不重发")
    }

    /// RW-02：保留着等身份确认的结算属于点击时的会话；之后确认的是别的会话（换账号）→ 丢弃，不结算到新会话。
    func testReworkFixHeldSettlementDroppedOnSessionChange() async throws {
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
        // 换账号：会话版本变化的通知里同步核对、按已知换代重建（不等后续核对）
        try fixture.switchAccount(to: "user-b")
        let kept = fixture.wallet.deps.settlement.hasHeld
        XCTAssertFalse(kept, "换代即丢弃")
        fixture.wallet.checkSession()
        XCTAssertFalse(fixture.gates.withdraw.active, "不结算到新会话")
    }
}
