@testable import Couli
import CouliNetwork
import Foundation
@testable import OrderCore
import Orders
import Router
import Session
import Wallet
@testable import WalletCore
import XCTest

/// FU-IOS-0712 末轮窄修（R3-01～R3-03）：冷启动身份快照、待清理独立于身份、同会话世代的登录世代换代。
extension FollowupIos0712FixR1ColdStartTests {
    func coldOrders(_ fixture: OrdersAppFixture, readable: @escaping @MainActor () -> Bool) -> AppOrders {
        AppOrders(
            network: fixture.network, config: fixture.config, routing: fixture.routing, login: fixture.login,
            cleaner: OrderCacheCleaner(store: OrderCacheStore(
                root: fixture.orders.cache.root, legacyPageStateDefaults: defaults
            )), defaults: defaults, credentialsReadable: readable
        )
    }

    /// R3-01：只有列表执行器构造时那一次身份读取失败、下一次就成功：恢复决策只用执行器那份快照（未知 → 延后，不删记录）；判据已记下 A，
    /// 再次打开订单 Tab 时不保留这个身份未知的页面，新页面恢复到锚点。
    func testConstructionOnlyReadFailureKeepsRecordAndNextPageRestoresAnchor() async throws {
        let fixture = OrdersAppFixture.make(suiteName: suiteName, defaults: defaults)
        let owner = try await seedOwnedCacheAndRecord(fixture)
        let cold = coldOrders(fixture) { true }
        // listPage：判据核对（第 1 次读取，成功、记下 A）→ 列表执行器构造（第 2 次读取，暂时失败）
        fixture.store.failRead(nth: 2)
        let first = cold.listPage(RouteDestination(route: "OrderList"))
        XCTAssertFalse(first.controller.owner.identityKnown, "前提：只有构造时那一次读取失败")
        assertNothingDeleted(fixture, owner, cold, "构造时一次读取失败")
        let second = cold.listPage(RouteDestination(route: "OrderList"))
        XCTAssertFalse(second === first, "判据已记 A 也不保留身份未知的页面")
        XCTAssertEqual(second.controller.owner.account, "user-a")
        XCTAssertEqual(second.anchor.target, "o1", "新页面恢复到锚点")
        assertNothingDeleted(fixture, owner, cold, "恢复后")
    }

    /// R3-02（订单）：上次删除失败留下的持久待清理标记，在身份暂时未知的生产初始化里照样先完成——缓存、恢复记录实际被删。
    func testPendingClearCompletesAtInitEvenWhenIdentityIsUnknown() async throws {
        let fixture = OrdersAppFixture.make(suiteName: suiteName, defaults: defaults)
        let owner = try await seedOwnedCacheAndRecord(fixture)
        XCTAssertTrue(fixture.orders.cache.markPendingClear(), "前提：持久待清理标记已写入")
        let cold = coldOrders(fixture) { false }
        XCTAssertFalse(cold.cache.isPendingClear, "待清理已完成")
        XCTAssertFalse(FileManager.default.fileExists(atPath: ownerFile(fixture).path), "缓存 owner 已删")
        XCTAssertNil(listCache(fixture, owner), "列表缓存已删")
        XCTAssertFalse(cold.cache.pageState.exists, "恢复记录文件已删")
    }

    /// R3-02（钱包）：身份暂时未知的生产初始化里，已登记的待清理照样先完成，摘要缓存实际被删。
    func testWalletPendingClearCompletesAtInitEvenWhenIdentityIsUnknown() async throws {
        WalletStubProtocol.reset()
        let script = WalletScript()
        script.install()
        defer { WalletStubProtocol.reset() }
        let suite = suiteName + "-wp"
        let first = WalletAppFixture.make(suiteName: suite, defaults: defaults)
        let controller = try XCTUnwrap(first.open(WalletRoutes.wallet)?.controller as? WalletController)
        controller.load()
        await waitUntil("摘要没有到位") { controller.state.summary != nil }
        let owner = controller.state.owner
        let root = first.cleaner.store.root
        XCTAssertTrue(OrderSiblingPendingFlag(root: root).set(), "前提：持久待清理标记")
        let cold = WalletAppFixture.make(suiteName: suite, defaults: defaults, unknownIdentityAtInit: true)
        XCTAssertFalse(cold.cleaner.store.isPendingClear, "待清理已完成")
        let partitions = ((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? [])
            .filter { $0 != "pending_clear" }
        XCTAssertEqual(partitions, [], "摘要缓存实际被删")
        XCTAssertNil(cold.cleaner.store.read(account: owner.account, loginEpoch: owner.loginEpoch))
    }

    /// R3-03（订单）：会话世代不变、同账号登录世代 E1 → E2：已知换代——旧分区删除、页面重建，E2 读不到。
    func testSameGenerationLoginEpochChangeClearsOldPartitionAndRebuildsPage() async throws {
        let fixture = OrdersAppFixture.make(suiteName: suiteName, defaults: defaults)
        let owner = try await seedOwnedCacheAndRecord(fixture)
        let page = fixture.orders.listPage(RouteDestination(route: "OrderList"))
        let generation = fixture.network.client.sessionGeneration
        try fixture.tokens.save(access: "at-e2", refresh: "rt-e2", scope: "full", account: "user-a")
        XCTAssertEqual(fixture.network.client.sessionGeneration, generation, "前提：会话世代不变")
        let fresh = try XCTUnwrap(fixture.tokens.loginEpoch)
        XCTAssertNotEqual(fresh, owner.loginEpoch)
        fixture.orders.checkSession()
        XCTAssertNil(listCache(fixture, owner), "旧分区已删")
        XCTAssertNil(fixture.orders.restorer.stored, "旧恢复记录已删")
        XCTAssertNil(fixture.orders.listConfig, "旧页面作废")
        let rebuilt = fixture.orders.listPage(RouteDestination(route: "OrderList"))
        XCTAssertFalse(rebuilt === page, "页面重建")
        XCTAssertEqual(rebuilt.controller.owner.loginEpoch, fresh)
        let store = OrderCacheStore(root: fixture.orders.cache.root)
        store.partitionedByLoginEpoch = true
        XCTAssertNil(store.readList(account: "user-a", loginEpoch: fresh, scope: OrderQuery.selfScope), "E2 读不到")
    }

    /// R3-03（钱包）：同上——摘要旧分区删除、页面换上 E2 的身份，E2 读不到。
    func testWalletSameGenerationLoginEpochChangeClearsOldPartitionAndRebuildsPage() async throws {
        WalletStubProtocol.reset()
        let script = WalletScript()
        script.install()
        defer { WalletStubProtocol.reset() }
        let fixture = WalletAppFixture.make(suiteName: suiteName + "-we", defaults: defaults)
        let controller = try XCTUnwrap(fixture.open(WalletRoutes.wallet)?.controller as? WalletController)
        controller.load()
        await waitUntil("摘要没有到位") { controller.state.summary != nil }
        let owner = controller.state.owner
        let generation = fixture.network.client.sessionGeneration
        try fixture.tokens.save(access: "at-e2", refresh: "rt-e2", scope: "full", account: "user-a")
        XCTAssertEqual(fixture.network.client.sessionGeneration, generation, "前提：会话世代不变")
        let fresh = try XCTUnwrap(fixture.tokens.loginEpoch)
        fixture.wallet.checkSession()
        XCTAssertNil(fixture.cleaner.store.read(account: owner.account, loginEpoch: owner.loginEpoch), "旧分区已删")
        XCTAssertEqual(controller.state.owner.loginEpoch, fresh, "页面换上 E2 的身份")
        XCTAssertNil(controller.state.summary, "旧摘要不再显示")
        XCTAssertNil(fixture.cleaner.store.read(account: "user-a", loginEpoch: fresh), "E2 读不到")
    }
}
