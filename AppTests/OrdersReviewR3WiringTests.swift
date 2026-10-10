import Config
@testable import Couli
import Foundation
import OrderCore
import Orders
import Router
import XCTest

/// APP-08 iOS 第 3 轮评审（NATIVE/APP-08/ios-review-r3.md）的 App 接线复现：
/// - R3-01：恢复记录落在 Application Support 旁的原子文件（不在 UserDefaults）；撤回 / 切环境删除并确认（共性第 40 条）；
/// - R3-02：订单列表卡与详情的【复制】旧回调在撤回同意 / 切换环境 / 换账号之后执行：零写入（共性第 41 条）；
/// - I18：切环境后仍在栈里的商品详情换上新环境的待跟单执行器，再次外跳回来照常出卡（共性第 43 条）。
@MainActor
final class OrdersReviewR3WiringTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        suiteName = "OrdersReviewR3WiringTests.\(UUID().uuidString)"
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

    private static func envelope(_ data: String) -> AppStubProtocol.Reply {
        .json(status: 200, body: "{\"code\":0,\"msg\":\"\",\"data\":\(data),\"trace_id\":\"t\"}")
    }

    private static let listBody = "{\"items\":[{\"order_id\":\"o1\",\"platform\":\"taobao\",\"title\":\"t\","
        + "\"image_url\":null,\"pay_amount_fen\":100,\"quantity\":1,\"order_no\":\"\(fullOrderNo)\","
        + "\"display_status\":\"PAID\",\"reason\":null,\"est_rebate_fen\":1,\"paid_at\":\"2026-10-02T09:31:00+08:00\","
        + "\"is_other_product\":false}],\"next_cursor\":null,\"earliest_visible_date\":null}"

    private static let tracksBody = "{\"items\":[{\"link_id\":\"L1\",\"attempt_id\":\"a1\",\"platform\":\"taobao\","
        + "\"jumped_at\":\"2026-10-09T10:00:00+08:00\",\"show_claim_entry\":true,\"dismissed\":false}]}"

    /// 加载好的列表页，复制出口换成计数（统计到达写入口的次数）。
    private func loadedList(_ fixture: OrdersAppFixture) async throws -> (OrderListPageConfig, Counter) {
        AppStubProtocol.install { _ in Self.envelope(Self.listBody) }
        let list = fixture.orders.listPage(RouteDestination(route: "OrderList"))
        let counter = Counter()
        let original = list.copy
        list.copy = { text in
            counter.writes.append(text)
            return original(text)
        }
        list.controller.start()
        for _ in 0..<400 where list.controller.snapshot.phase != .content {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertEqual(list.controller.snapshot.phase, .content)
        return (list, counter)
    }

    @MainActor
    private final class Counter {
        var writes: [String] = []
    }

    /// 与 OrdersScreen 同一写法：渲染这一刻取票据，回调只捕获它。
    private func renderedCopy(_ page: OrderListPageConfig) throws -> () -> Void {
        let item = try XCTUnwrap(page.controller.snapshot.items.first)
        let ticket = page.copyTicket(item)
        return { page.copyOrderNo(ticket, rendered: Self.fullOrderNo) }
    }

    // MARK: - R3-01

    func testRestoreRecordLivesInFileNotUserDefaults() {
        let fixture = make()
        AppStubProtocol.install { _ in .hold }
        let list = fixture.orders.listPage(RouteDestination(route: "OrderList"))
        list.controller.updateSearchText(Self.fullOrderNo)
        list.controller.submitSearch()
        fixture.orders.persist()
        XCTAssertTrue(fixture.orders.cache.pageState.exists, "恢复记录写进原子文件")
        XCTAssertNil(defaults.object(forKey: OrderPageStateFile.legacyKey), "不再写 UserDefaults")
        XCTAssertEqual(fixture.orders.restorer.stored?.conditions.keyword, Self.fullOrderNo)
    }

    // MARK: - R3-02

    /// 撤回同意 / 切换环境：保留 A 账号自购卡渲染出的【复制】回调，清理之后执行 → 零写入（不写剪贴板、不留自写记录）。
    func testOldListCopyCallbackAfterCleanupWritesNothing() async throws {
        for path in ["withdrawal", "environment"] {
            AppStubProtocol.reset()
            let fixture = make()
            let withdrawal = EnvironmentSwitchCleanerRegistry(cleaners: [])
            let environmentSwitch = EnvironmentSwitchCleanerRegistry(cleaners: [])
            OrderCacheCleaner.register(fixture.cleaner, withdrawal: withdrawal, environmentSwitch: environmentSwitch)
            let (list, counter) = try await loadedList(fixture)
            let old = try renderedCopy(list)
            old()
            XCTAssertEqual(counter.writes, [Self.fullOrderNo], "\(path)：对照：有效时到达写入口一次")
            _ = path == "withdrawal" ? withdrawal.cleanAll() : environmentSwitch.cleanAll()
            old()
            XCTAssertEqual(counter.writes.count, 1, "\(path)：清理后旧回调零写入")
        }
    }

    /// 换账号：旧列表页的旧回调零写入。
    func testOldListCopyCallbackAfterAccountSwitchWritesNothing() async throws {
        let fixture = make()
        let (list, counter) = try await loadedList(fixture)
        let old = try renderedCopy(list)
        fixture.network.client.signOut()
        try fixture.tokens.save(access: "at-b", refresh: "rt-b", scope: "full", account: "user-b")
        old()
        XCTAssertTrue(counter.writes.isEmpty, "会话换代（还没走到 checkSession）：零写入")
        fixture.orders.checkSession()
        old()
        XCTAssertTrue(counter.writes.isEmpty, "换代之后：零写入")
    }

    /// 详情：旧回调在切环境之后执行 → 零写入。
    func testOldDetailCopyCallbackAfterCleanupWritesNothing() async throws {
        let fixture = make()
        let withdrawal = EnvironmentSwitchCleanerRegistry(cleaners: [])
        let environmentSwitch = EnvironmentSwitchCleanerRegistry(cleaners: [])
        OrderCacheCleaner.register(fixture.cleaner, withdrawal: withdrawal, environmentSwitch: environmentSwitch)
        let body = "{\"order_id\":\"o1\",\"platform\":\"taobao\",\"title\":\"t\",\"image_url\":null,"
            + "\"pay_amount_fen\":100,\"quantity\":1,\"order_no\":\"\(Self.fullOrderNo)\","
            + "\"display_status\":\"PAID\",\"reason\":null,\"est_rebate_fen\":1,\"paid_at\":null,"
            + "\"is_other_product\":false,\"product_key\":\"tb:9007\","
            + "\"reason_action\":[],\"timeline\":[],\"expected_credit_period\":null,\"credit_overdue\":false,"
            + "\"actual_fen\":null,\"clawback_fen\":null,\"appeal_pending\":false,\"is_price_compare\":null}"
        AppStubProtocol.install { _ in Self.envelope(body) }
        let router = fixture.routing.router
        router.open(RouteRequest(route: "OrderDetail", values: ["order_id": .string("o1")], from: .inApp))
        let page = fixture.orders.detailPage(try XCTUnwrap(router.path.last))
        let counter = Counter()
        page.controller.copy = { counter.writes.append($0)
            return true
        }
        page.controller.start()
        for _ in 0..<400 where page.controller.snapshot.phase != .content {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        let ticket = page.controller.copyTicket()
        XCTAssertNotNil(ticket)
        _ = environmentSwitch.cleanAll()
        page.controller.copyOrderNo(ticket, rendered: Self.fullOrderNo)
        XCTAssertTrue(counter.writes.isEmpty, "切环境后旧回调零写入")
    }

    // MARK: - I18

    /// 切环境（撤回同意同口径）后仍在栈里的商品详情：新执行器在再次外跳回来后照常拉卡、出卡。
    func testProductPageRebuildsPendingServiceAfterCleanup() async throws {
        for path in ["environment", "withdrawal"] {
            AppStubProtocol.reset()
            let fixture = make()
            let withdrawal = EnvironmentSwitchCleanerRegistry(cleaners: [])
            let environmentSwitch = EnvironmentSwitchCleanerRegistry(cleaners: [])
            OrderCacheCleaner.register(fixture.cleaner, withdrawal: withdrawal, environmentSwitch: environmentSwitch)
            AppStubProtocol.install { request in
                request.path == "/v1/orders/pending-tracks" ? Self.envelope(Self.tracksBody) : .hold
            }
            let router = fixture.routing.router
            router.open(RouteRequest(
                route: "ProductDetail", values: ["platform": .string("taobao"), "product_key": .string("tb:milk")],
                from: .inApp
            ))
            let product = try XCTUnwrap(router.path.last)
            _ = fixture.orders.pendingSlot(for: product, purchase: nil, trade: nil)
            let first = try XCTUnwrap(fixture.orders.pendingService(product.id))
            fixture.orders.jumped(
                product.id, platform: "taobao", origin: fixture.orders.jumpOrigin(product.id), visible: true
            )
            for _ in 0..<400 where first.state.cards.isEmpty {
                try await Task.sleep(nanoseconds: 5_000_000)
            }
            XCTAssertEqual(first.state.cards.map(\.linkId), ["L1"], "\(path)：前提")

            _ = path == "withdrawal" ? withdrawal.cleanAll() : environmentSwitch.cleanAll()

            let fresh = try XCTUnwrap(fixture.orders.pendingService(product.id), "\(path)：换上新执行器")
            XCTAssertFalse(fresh === first)
            XCTAssertTrue(fresh.state.cards.isEmpty, "\(path)：不带旧环境的卡")
            // 再次外跳，回到前台
            fixture.orders.jumped(
                product.id, platform: "taobao", origin: fixture.orders.jumpOrigin(product.id), visible: false
            )
            fixture.orders.pageForeground(product.id)
            for _ in 0..<400 where fresh.state.cards.isEmpty {
                try await Task.sleep(nanoseconds: 5_000_000)
            }
            XCTAssertEqual(fresh.state.cards.map(\.linkId), ["L1"], "\(path)：再次外跳回来照常出卡")
            XCTAssertTrue(first.state.cards.isEmpty, "\(path)：旧执行器仍作废")
        }
    }
}
