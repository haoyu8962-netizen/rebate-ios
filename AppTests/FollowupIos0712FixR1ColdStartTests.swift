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

/// 编排追加 F-X-19：冷启动期间的启动态变化（凭据从不可读变可读、账号从无到有，会话世代不变）不是会话换代：不删订单恢复记录与断网缓存；
/// 账号可读之前建出的列表页换掉，新页面按真实身份决策并恢复。真正换代（退出）照旧删除。
@MainActor
final class FollowupIos0712FixR1ColdStartTests: XCTestCase {
    var suiteName = ""
    var defaults: UserDefaults!
    private static let keyword = "3712345678901234567"

    override func setUpWithError() throws {
        suiteName = "FollowupIos0712FixR1ColdStartTests.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        AppStubProtocol.reset()
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default
            .removeItem(at: FileManager.default.temporaryDirectory.appendingPathComponent(suiteName))
        AppStubProtocol.reset()
    }

    func testStartupReadableTransitionKeepsRestoreRecordAndColdStartRestores() {
        let fixture = OrdersAppFixture.make(suiteName: suiteName, defaults: defaults)
        AppStubProtocol.install { _ in .hold }
        // 进程 1：订单 Tab 记下搜索词与条件（进后台保存）
        let list = fixture.orders.listPage(RouteDestination(route: "OrderList"))
        list.controller.updateSearchText(Self.keyword)
        list.controller.submitSearch()
        fixture.orders.persist()
        XCTAssertEqual(fixture.orders.restorer.stored?.conditions.keyword, Self.keyword, "前提：记录已保存")

        // 进程 2（冷启动）：同一份会话与目录；启动时凭据还不可读
        var readable = false
        let cache = OrderCacheStore(root: fixture.orders.cache.root, legacyPageStateDefaults: defaults)
        let cold = AppOrders(
            network: fixture.network, config: fixture.config, routing: fixture.routing, login: fixture.login,
            cleaner: OrderCacheCleaner(store: cache), defaults: defaults, credentialsReadable: { readable }
        )
        let early = cold.listPage(RouteDestination(route: "OrderList"))
        XCTAssertNil(early.controller.owner.account, "账号可读之前建出的页没有账号")
        XCTAssertNotNil(cold.restorer.stored, "账号未知：不决策、不删记录")
        // 启动态变化：凭据变可读（会话世代不变）
        readable = true
        cold.checkSession()
        XCTAssertNotNil(cold.restorer.stored, "启动态变化不是换代：恢复记录不删")
        let page = cold.listPage(RouteDestination(route: "OrderList"))
        XCTAssertFalse(page === early, "账号可读之前的页换掉")
        XCTAssertEqual(page.controller.owner.account, "user-a")
        XCTAssertEqual(page.controller.snapshot.query.conditions.keyword, Self.keyword, "冷启动恢复搜索词与条件")

        // 对照：真正换代（退出，会话世代推进）照旧删除
        fixture.network.client.signOut()
        cold.checkSession()
        XCTAssertNil(cold.restorer.stored, "会话换代：删恢复记录")
    }

    // MARK: - 第 2 轮修复 R2-01：身份暂时未知时不删缓存 owner、列表缓存与恢复记录

    private static func envelope(_ data: String) -> AppStubProtocol.Reply {
        .json(status: 200, body: "{\"code\":0,\"msg\":\"\",\"data\":\(data),\"trace_id\":\"t\"}")
    }

    private static let listBody = "{\"items\":[{\"order_id\":\"o1\",\"platform\":\"taobao\",\"title\":\"t\","
        + "\"image_url\":null,\"pay_amount_fen\":100,\"quantity\":1,\"order_no\":\"3712345678901234567\","
        + "\"display_status\":\"PAID\",\"reason\":null,\"est_rebate_fen\":1,\"paid_at\":\"2026-10-02T09:31:00+08:00\","
        + "\"is_other_product\":false}],\"next_cursor\":null,\"earliest_visible_date\":null}"

    /// 进程 1：默认列表加载成功（写下缓存 owner 与列表缓存），视口顶部记为 o1，进后台保存恢复记录。返回分区内的固定身份。
    func seedOwnedCacheAndRecord(_ fixture: OrdersAppFixture) async throws -> OrderOwner {
        AppStubProtocol.install { _ in Self.envelope(Self.listBody) }
        let list = fixture.orders.listPage(RouteDestination(route: "OrderList"))
        list.controller.start()
        for _ in 0..<400 where list.controller.snapshot.phase != .content {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertTrue(list.recordTop("o1"), "前提：记下锚点")
        fixture.orders.persist()
        let owner = list.controller.owner
        XCTAssertTrue(FileManager.default.fileExists(atPath: ownerFile(fixture).path), "前提：缓存 owner 文件")
        XCTAssertNotNil(listCache(fixture, owner), "前提：列表缓存")
        XCTAssertEqual(fixture.orders.restorer.stored?.anchor, "o1", "前提：恢复记录带锚点")
        AppStubProtocol.install { _ in .hold }
        return owner
    }

    func ownerFile(_ fixture: OrdersAppFixture) -> URL {
        fixture.orders.cache.root.appendingPathComponent("owner")
    }

    func listCache(_ fixture: OrdersAppFixture, _ owner: OrderOwner) -> CachedOrderList? {
        let store = OrderCacheStore(root: fixture.orders.cache.root)
        store.partitionedByLoginEpoch = true
        return store.readList(account: owner.account, loginEpoch: owner.loginEpoch, scope: OrderQuery.selfScope)
    }

    func assertNothingDeleted(
        _ fixture: OrdersAppFixture,
        _ owner: OrderOwner,
        _ cold: AppOrders,
        _ label: String
    ) {
        XCTAssertTrue(FileManager.default.fileExists(atPath: ownerFile(fixture).path), "\(label)：缓存 owner 不删")
        XCTAssertNotNil(listCache(fixture, owner), "\(label)：列表缓存不删")
        XCTAssertEqual(cold.restorer.stored?.anchor, "o1", "\(label)：恢复记录不删")
    }

    /// 冷启动（走生产 init）时凭据暂不可读：init 的归属对账与列表页决策都延后，缓存 owner、列表缓存、恢复记录都不删；凭据恢复可读后
    /// 恢复到锚点。对照：确认没有会话（退出）照旧删除。
    func testColdStartWithUnreadableCredentialsKeepsOwnedCacheAndRecordThenRestoresAnchor() async throws {
        let fixture = OrdersAppFixture.make(suiteName: suiteName, defaults: defaults)
        let owner = try await seedOwnedCacheAndRecord(fixture)
        var readable = false
        let cold = AppOrders(
            network: fixture.network, config: fixture.config, routing: fixture.routing, login: fixture.login,
            cleaner: OrderCacheCleaner(store: OrderCacheStore(
                root: fixture.orders.cache.root, legacyPageStateDefaults: defaults
            )), defaults: defaults, credentialsReadable: { readable }
        )
        assertNothingDeleted(fixture, owner, cold, "凭据暂不可读的 init")
        _ = cold.listPage(RouteDestination(route: "OrderList"))
        cold.checkSession()
        assertNothingDeleted(fixture, owner, cold, "凭据暂不可读时打开订单 Tab")
        readable = true
        cold.checkSession()
        assertNothingDeleted(fixture, owner, cold, "凭据恢复可读")
        let page = cold.listPage(RouteDestination(route: "OrderList"))
        XCTAssertEqual(page.controller.owner.account, "user-a")
        XCTAssertEqual(page.anchor.target, "o1", "恢复到锚点")
        XCTAssertNotNil(listCache(fixture, owner), "同一登录的缓存仍可读")

        fixture.network.client.signOut()
        cold.checkSession()
        XCTAssertNil(cold.restorer.stored, "确认退出：恢复记录照删")
        XCTAssertFalse(FileManager.default.fileExists(atPath: ownerFile(fixture).path), "确认退出：缓存按无归属删除")
    }

    /// 凭据可读标记为 true，但 Keychain 暂时读失败：同样按身份未知延后，不删；读取恢复后恢复到锚点。
    func testKeychainTransientReadFailureDefersAndRestoresAfterRecovery() async throws {
        let fixture = OrdersAppFixture.make(suiteName: suiteName, defaults: defaults)
        let owner = try await seedOwnedCacheAndRecord(fixture)
        fixture.tokens.failReads = .readFailed
        let cold = AppOrders(
            network: fixture.network, config: fixture.config, routing: fixture.routing, login: fixture.login,
            cleaner: OrderCacheCleaner(store: OrderCacheStore(
                root: fixture.orders.cache.root, legacyPageStateDefaults: defaults
            )), defaults: defaults, credentialsReadable: { true }
        )
        assertNothingDeleted(fixture, owner, cold, "读失败时的 init")
        let early = cold.listPage(RouteDestination(route: "OrderList"))
        XCTAssertNil(early.controller.owner.account)
        cold.checkSession()
        assertNothingDeleted(fixture, owner, cold, "读失败时打开订单 Tab")
        fixture.tokens.failReads = nil
        cold.checkSession()
        assertNothingDeleted(fixture, owner, cold, "读取恢复")
        let page = cold.listPage(RouteDestination(route: "OrderList"))
        XCTAssertFalse(page === early)
        XCTAssertEqual(page.anchor.target, "o1", "读取恢复后恢复到锚点")
    }

    /// 钱包同口径：会话中 Keychain 暂时读失败（身份暂时未知）不删摘要缓存；恢复后同一登录照常读回。
    func testWalletTransientUnknownIdentityKeepsSummaryCache() async throws {
        WalletStubProtocol.reset()
        let script = WalletScript()
        script.install()
        defer { WalletStubProtocol.reset() }
        let fixture = WalletAppFixture.make(suiteName: suiteName + "-w", defaults: defaults)
        let controller = try XCTUnwrap(fixture.open(WalletRoutes.wallet)?.controller as? WalletController)
        controller.load()
        await waitUntil("摘要没有到位") { controller.state.summary != nil }
        let owner = controller.state.owner
        fixture.tokens.failReads = .readFailed
        fixture.wallet.checkSession()
        XCTAssertNotNil(
            fixture.cleaner.store.read(account: owner.account, loginEpoch: owner.loginEpoch), "身份暂时未知：不删"
        )
        fixture.tokens.failReads = nil
        fixture.wallet.checkSession()
        XCTAssertNotNil(
            fixture.cleaner.store.read(account: owner.account, loginEpoch: owner.loginEpoch), "恢复后同一登录照常读回"
        )
    }

    /// 会话中途 Keychain 暂时读失败（身份变未知、会话世代不变）：订单不当作换代——不清显示、不删恢复记录与缓存；读取恢复后仍是同一页。
    func testMidSessionTransientReadFailureIsNotASessionChange() async throws {
        let fixture = OrdersAppFixture.make(suiteName: suiteName, defaults: defaults)
        let owner = try await seedOwnedCacheAndRecord(fixture)
        let page = fixture.orders.listPage(RouteDestination(route: "OrderList"))
        fixture.tokens.failReads = .readFailed
        fixture.orders.checkSession()
        assertNothingDeleted(fixture, owner, fixture.orders, "会话中途读失败")
        XCTAssertTrue(fixture.orders.listConfig === page, "不换页")
        fixture.tokens.failReads = nil
        fixture.orders.checkSession()
        assertNothingDeleted(fixture, owner, fixture.orders, "读取恢复")
        XCTAssertTrue(fixture.orders.listConfig === page, "仍是同一页")
    }
}
