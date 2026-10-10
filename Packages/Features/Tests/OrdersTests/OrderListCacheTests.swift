import CouliNetwork
import OrderCore
import XCTest

/// 订单列表的断网缓存（TECH-20、G10）与详情返回只替换那一行（G17）。
@MainActor
final class OrderListCacheTests: XCTestCase {
    private var env = FakeOrderEnv()

    override func setUp() async throws {
        env = FakeOrderEnv()
    }

    private func make(cache: OrderCacheStore? = nil) -> OrderListController {
        OrderListController(api: makeOrdersClient(), gate: OrderRateGate(), env: env, cache: cache)
    }

    // MARK: - TECH-20

    func testStaleCacheOnlyForDefaultViewTransportFailure() async {
        let cache = OrderCacheStore(root: temporaryDirectory())
        OrdersStub.install { _ in OrderFixtures.ok(OrderFixtures.page([OrderFixtures.row("o1")])) }
        let online = make(cache: cache)
        online.start()
        await eventually { online.snapshot.phase == .content }

        OrdersStub.install { _ in .offline }
        let offline = make(cache: cache)
        offline.start()
        await eventually { offline.snapshot.phase == .stale }
        XCTAssertEqual(offline.snapshot.items.map(\.orderId), ["o1"])
        XCTAssertEqual(offline.snapshot.staleAt, env.nowMs)
        XCTAssertFalse(offline.loadMore(), "stale 状态下不能翻页")

        offline.setGroup("credited")
        await eventually { offline.snapshot.phase == .error }
        XCTAssertEqual(offline.snapshot.error?.actionRaw, OrderErrorKind.networkError, "带筛选查询失败不用缓存")

        OrdersStub.install { _ in OrderFixtures.fail(50001) }
        let server = make(cache: cache)
        server.start()
        await eventually { server.snapshot.phase == .error }
        XCTAssertEqual(server.snapshot.error?.actionRaw, OrderErrorKind.errorTrace6, "5xxxx 不用缓存")
        XCTAssertTrue(errorText(server.snapshot.error).contains("123456"))

        // 换账号：新账号断网看到的是网络错误态，不是旧账号的数据
        env.account = "user-b"
        cache.reconcileOwner(account: "user-b")
        OrdersStub.install { _ in .offline }
        let other = make(cache: cache)
        other.start()
        await eventually { other.snapshot.phase == .error }
        XCTAssertEqual(other.snapshot.error?.actionRaw, OrderErrorKind.networkError)
    }

    func testRefreshSuccessClearsStale() async {
        let cache = OrderCacheStore(root: temporaryDirectory())
        OrdersStub.install { _ in OrderFixtures.ok(OrderFixtures.page([OrderFixtures.row("o1")])) }
        let online = make(cache: cache)
        online.start()
        await eventually { online.snapshot.phase == .content }
        OrdersStub.install { _ in .offline }
        let list = make(cache: cache)
        list.start()
        await eventually { list.snapshot.phase == .stale }
        OrdersStub.install { _ in OrderFixtures.ok(OrderFixtures.page([OrderFixtures.row("o2")])) }
        list.refresh()
        await eventually { list.snapshot.phase == .content }
        XCTAssertNil(list.snapshot.staleAt, "刷新成功后提示条消失")
        XCTAssertEqual(cache.readList(account: "user-a", scope: "self")?.data.items.map(\.orderId), ["o2"], "缓存更新")
    }

    // MARK: - G17

    func testReplaceRowOnlyReplacesThatRow() async throws {
        OrdersStub.install { _ in
            OrderFixtures.ok(OrderFixtures.page([OrderFixtures.row("o1"), OrderFixtures.row("o2")]))
        }
        let list = make()
        list.start()
        await eventually { list.snapshot.phase == .content }
        let object = try? JSONSerialization.jsonObject(
            with: Data(OrderFixtures.detail("o2", status: "WAITING", actual: "999").utf8)
        ) as? [String: Any]
        let detail = try? XCTUnwrap(object.flatMap(OrderJSON.detail))
        list.replaceRow(with: try XCTUnwrap(detail))
        XCTAssertEqual(list.snapshot.items.map(\.displayStatusRaw), ["PAID", "WAITING"])
        XCTAssertNil(list.snapshot.items[1].actualFen, "不把详情才有的 actual_fen 带进列表")
        XCTAssertEqual(OrdersStub.requests("/v1/orders").count, 1, "不额外请求列表")
    }
}
