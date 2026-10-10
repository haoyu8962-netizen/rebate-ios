import Config
@testable import Couli
import Foundation
import OrderCore
import Orders
import Router
import XCTest

/// APP-08 iOS 第 2 轮评审（NATIVE/APP-08/ios-review-r2.md）的 App 接线复现：
/// - R2-01：撤回同意 / 切换环境经注册表跑订单清理项，恢复记录（可能含完整订单号搜索词）随缓存一起从磁盘删除，内存记录与旧页面的后续写入作废；
///   AppOrders 还没创建（启动对账重试撤回清理）时同样能删；清理单元仍「待清理」时不恢复、不写入（共性第 36 条）；
/// - I15：撤回同意 / 切换环境时商品详情 / 搜索页已显示的待跟单卡清空、执行器作废；栈里的订单详情同步清空并出栈（共性第 38 条）。
@MainActor
final class OrdersReviewR2WiringTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        suiteName = "OrdersReviewR2WiringTests.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        AppStubProtocol.reset()
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default
            .removeItem(at: FileManager.default.temporaryDirectory.appendingPathComponent(suiteName))
        AppStubProtocol.reset()
    }

    private func make() -> OrdersAppFixture {
        OrdersAppFixture.make(suiteName: suiteName, defaults: defaults)
    }

    private static let fullOrderNo = "3712345678901234567"

    /// 自购列表提交完整订单号搜索并保存恢复记录。
    private func searchAndPersist(_ fixture: OrdersAppFixture) -> OrderListPageConfig {
        let list = fixture.orders.listPage(RouteDestination(route: "OrderList"))
        list.controller.updateSearchText(Self.fullOrderNo)
        list.controller.submitSearch()
        fixture.orders.persist()
        XCTAssertEqual(fixture.orders.restorer.stored?.conditions.keyword, Self.fullOrderNo, "前提：恢复记录含完整订单号")
        return list
    }

    // MARK: - R2-01

    /// 撤回同意（撤回注册表）与切换环境（环境注册表）都删掉磁盘上的恢复记录；旧页面之后的保存不再写盘，新页面不恢复。
    func testWithdrawalAndEnvironmentSwitchEraseRestoreRecord() {
        for path in ["withdrawal", "environment"] {
            defaults.removePersistentDomain(forName: suiteName)
            let fixture = make()
            AppStubProtocol.install { _ in .hold }
            let withdrawal = EnvironmentSwitchCleanerRegistry(cleaners: [])
            let environmentSwitch = EnvironmentSwitchCleanerRegistry(cleaners: [])
            OrderCacheCleaner.register(fixture.cleaner, withdrawal: withdrawal, environmentSwitch: environmentSwitch)
            let list = searchAndPersist(fixture)
            let failures = path == "withdrawal" ? withdrawal.cleanAll() : environmentSwitch.cleanAll()
            XCTAssertEqual(failures, [], path)
            XCTAssertFalse(fixture.orders.cache.pageState.exists, "\(path)：磁盘上的恢复记录删除")
            XCTAssertTrue(list.invalidated, "\(path)：旧列表页同步作废")
            XCTAssertTrue(list.controller.isLeft)
            // 旧页面迟到的状态变化 / 进后台保存：不写回
            list.onStateChange()
            fixture.orders.sceneEnteredBackground()
            XCTAssertFalse(fixture.orders.cache.pageState.exists, "\(path)：旧页面的后续写入作废")
            let fresh = fixture.orders.listPage(RouteDestination(route: "OrderList"))
            XCTAssertFalse(fresh === list)
            XCTAssertEqual(fresh.controller.snapshot.searchText, "", "\(path)：新页面不恢复完整订单号")
            XCTAssertFalse(fresh.anchor.restoring)
        }
    }

    /// 启动对账重试上次没清完的撤回清理时 AppOrders 还没创建：清理项自己就能删掉恢复记录（不依赖 AppOrders 的回调）。
    func testCleanerErasesRestoreRecordBeforeAppOrdersExists() throws {
        let record = OrderPageRecord(
            owner: OrderCacheStore.hash("user-a"), conditions: OrderConditions(scope: OrderQuery.selfScope),
            anchor: "o8"
        )
        defaults.set(Data("legacy".utf8), forKey: OrderPageStateFile.legacyKey)
        let cleaner = OrderCacheCleaner(store: OrderCacheStore(
            root: FileManager.default.temporaryDirectory.appendingPathComponent(suiteName).appendingPathComponent("o2"),
            legacyPageStateDefaults: defaults
        ))
        try cleaner.store.pageState.save(JSONEncoder().encode(record))
        XCTAssertNil(cleaner.onCleared, "前提：没有 AppOrders")
        try cleaner.cleanForEnvironmentSwitch()
        XCTAssertFalse(cleaner.store.pageState.exists)
        XCTAssertNil(defaults.object(forKey: OrderPageStateFile.legacyKey), "旧版本的 UserDefaults 记录一并删除")
        XCTAssertFalse(cleaner.store.isPendingClear)
    }

    /// 清理单元仍是「待清理」（上次撤回 / 切环境没删干净，标记在缓存目录之外）：打开订单页不恢复，并删掉记录；之后也不写入。
    func testPendingClearBlocksRestoreAndPersist() throws {
        let fixture = make()
        AppStubProtocol.install { _ in .hold }
        let record = OrderPageRecord(
            owner: OrderCacheStore.hash("user-a"),
            conditions: OrderConditions(scope: OrderQuery.selfScope), anchor: "o8"
        )
        try fixture.orders.cache.pageState.save(JSONEncoder().encode(record))
        XCTAssertTrue(OrderSiblingPendingFlag(root: fixture.orders.cache.root).set())
        defer { _ = OrderSiblingPendingFlag(root: fixture.orders.cache.root).clear() }
        let list = fixture.orders.listPage(RouteDestination(route: "OrderList"))
        XCTAssertFalse(list.anchor.restoring, "待清理期间不恢复")
        XCTAssertFalse(fixture.orders.cache.pageState.exists, "记录删除")
        // iOS RC-04 起：决策前先完成持久清理单元里的清理；清理确认完成后待清理解除。之后又进入待清理且删不掉：不写入
        XCTAssertFalse(fixture.orders.cache.isPendingClear, "决策前已完成清理")
        XCTAssertTrue(OrderSiblingPendingFlag(root: fixture.orders.cache.root).set())
        // 缓存根位置被一个文件占着（不是目录、无法枚举）：清理完成不了
        let root = fixture.orders.cache.root
        try? FileManager.default.removeItem(at: root)
        XCTAssertTrue(FileManager.default.createFile(atPath: root.path, contents: Data("x".utf8)))
        defer { try? FileManager.default.removeItem(at: root) }
        list.controller.updateSearchText(Self.fullOrderNo)
        list.controller.submitSearch()
        fixture.orders.persist()
        XCTAssertFalse(fixture.orders.cache.pageState.exists, "待清理期间不写入")
    }

    // MARK: - I15

    /// 撤回同意 / 切换环境：商品详情 / 搜索页已显示的待跟单卡清空、执行器作废（之后外跳回前台不再拉）；栈里的订单详情清空并出栈。
    func testCleanupClearsPendingSlotsAndDetails() async throws {
        for path in ["withdrawal", "environment"] {
            AppStubProtocol.reset()
            let fixture = make()
            let withdrawal = EnvironmentSwitchCleanerRegistry(cleaners: [])
            let environmentSwitch = EnvironmentSwitchCleanerRegistry(cleaners: [])
            OrderCacheCleaner.register(fixture.cleaner, withdrawal: withdrawal, environmentSwitch: environmentSwitch)
            AppStubProtocol.install { request in
                request.path == "/v1/orders/pending-tracks"
                    ? .json(status: 200, body: "{\"code\":0,\"msg\":\"\",\"data\":{\"items\":[{\"link_id\":\"L1\","
                        + "\"attempt_id\":\"a1\",\"platform\":\"taobao\",\"jumped_at\":\"2026-10-09T10:00:00+08:00\","
                        + "\"show_claim_entry\":true,\"dismissed\":false}]},\"trace_id\":\"t\"}")
                    : .hold
            }
            let router = fixture.routing.router
            // 商品详情真的在栈里（不在栈里的目的地会被路由生存期当作已出栈）
            router.open(RouteRequest(
                route: "ProductDetail", values: ["platform": .string("taobao"), "product_key": .string("tb:milk")],
                from: .inApp
            ))
            let product = try XCTUnwrap(router.path.last)
            XCTAssertEqual(product.route, "ProductDetail")
            _ = fixture.orders.pendingSlot(for: product, purchase: nil, trade: nil)
            let service = try XCTUnwrap(fixture.orders.pendingService(product.id))
            fixture.orders.jumped(
                product.id, platform: "taobao", origin: fixture.orders.jumpOrigin(product.id), visible: true
            )
            for _ in 0..<400 where service.state.cards.isEmpty {
                try await Task.sleep(nanoseconds: 5_000_000)
            }
            XCTAssertEqual(service.state.cards.map(\.linkId), ["L1"], "\(path)：前提：商品详情上显示着待跟单卡")
            router.open(RouteRequest(route: "OrderDetail", values: ["order_id": .string("o1")], from: .inApp))
            let detail = fixture.orders.detailPage(try XCTUnwrap(router.path.last))
            let requestsBefore = AppStubProtocol.requests.count

            _ = path == "withdrawal" ? withdrawal.cleanAll() : environmentSwitch.cleanAll()

            XCTAssertTrue(router.path.contains { $0.id == product.id }, "\(path)：前提：商品详情仍在栈里（切环境不清栈）")
            XCTAssertTrue(service.state.cards.isEmpty, "\(path)：已显示的待跟单卡同步清空")
            // I18（共性第 43 条）：旧执行器作废，仍在栈里的商品详情换上新环境的执行器
            let fresh = try XCTUnwrap(fixture.orders.pendingService(product.id), "\(path)：页面仍在栈里，换上新执行器")
            XCTAssertFalse(fresh === service, "\(path)：不是旧执行器")
            XCTAssertEqual(fixture.orders.pendingSlotCount, 1)
            service.refresh(onlyPlatform: "taobao")
            try await Task.sleep(nanoseconds: 50_000_000)
            XCTAssertEqual(AppStubProtocol.requests.count, requestsBefore, "\(path)：旧执行器作废后不再拉卡")
            XCTAssertTrue(service.state.cards.isEmpty)
            XCTAssertTrue(fresh.state.cards.isEmpty, "\(path)：新执行器不带旧卡")
            XCTAssertEqual(detail.controller.snapshot.phase, .cleared, "\(path)：栈里的订单详情清空快照")
            XCTAssertFalse(router.path.contains { $0.route == "OrderDetail" }, "\(path)：并移出导航栈")
        }
    }
}
