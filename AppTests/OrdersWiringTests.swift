import ClientCore
import Config
@testable import Couli
import CouliNetwork
import Foundation
import Generated
import OrderCore
import Orders
import Privacy
import Router
import Session
import Update
import UserNotifications
import XCTest

/// APP-08 App 接线：订单路由登记；列表 / 详情页的跳转入口经 Router 落到精确的路由与参数（共性第 12、18 条：从页面配置的按钮回调出发）；
/// H5 入口的容器地址（共性第 22、29 条）；会话换代清空详情并移出导航栈、清空列表条件与恢复记录（共性第 1、19 条）；详情出栈作废；
/// 断网缓存登记进两个清理注册表。
@MainActor
final class OrdersWiringTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        suiteName = "OrdersWiringTests.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        AppStubProtocol.reset()
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        AppStubProtocol.reset()
    }

    private func make() -> OrdersAppFixture {
        OrdersAppFixture.make(suiteName: suiteName, defaults: defaults)
    }

    private func detail(_ json: String) throws -> OrderDetail {
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        return try XCTUnwrap(OrderJSON.detail(object))
    }

    private static func detailJSON(status: String, actions: String = "[]", reason: String = "null") -> String {
        "{\"order_id\":\"o1\",\"platform\":\"taobao\",\"title\":\"t\",\"image_url\":null,\"pay_amount_fen\":100,"
            + "\"quantity\":1,\"order_no\":\"3712\",\"display_status\":\"\(status)\",\"reason\":\(reason),"
            + "\"est_rebate_fen\":1,\"paid_at\":null,\"is_other_product\":false,\"product_key\":\"tb:9007\","
            + "\"reason_action\":\(actions),\"timeline\":[],\"expected_credit_period\":null,\"credit_overdue\":false,"
            + "\"actual_fen\":null,\"clawback_fen\":null,\"appeal_pending\":true,\"is_price_compare\":null}"
    }

    // MARK: - 路由

    func testRoutesRegisteredAndInRoutesJson() {
        for route in AppOrderRoutes.all {
            XCTAssertNotNil(Routes.all[route], "\(route) 不在 routes.json")
        }
        for route in ["OrderList", "OrderDetail", "FindOrder", "Ledger", "Help"] {
            XCTAssertNotNil(RouteViewRegistry.builders[route], "\(route) 没有接页面")
        }
    }

    func testListEntriesLandOnExactRoutes() {
        let fixture = make()
        let router = fixture.routing.router
        let page = fixture.orders.listPage(RouteDestination(route: "OrderList"))
        page.onOpenDetail("o1")
        XCTAssertEqual(router.path.last?.route, "OrderDetail")
        XCTAssertEqual(router.path.last?.params, ["order_id": .string("o1")])
        router.path.removeAll()
        page.onFindOrder()
        XCTAssertEqual(router.path.last?.route, "FindOrder")
        XCTAssertEqual(router.path.last?.params, [:])
        router.path.removeAll()
        page.onHome()
        XCTAssertEqual(router.tabRoot.route, "Home")
    }

    func testRouteScopeShareSwitchesSubTab() {
        let fixture = make()
        let page = fixture.orders.listPage(RouteDestination(route: "OrderList", params: ["scope": .string("share")]))
        XCTAssertEqual(page.controller.snapshot.query.scope, "share")
    }

    func testDetailEntriesLandOnExactRoutes() throws {
        let fixture = make()
        let router = fixture.routing.router
        router.open(RouteRequest(route: "OrderDetail", values: ["order_id": .string("o1")], from: .inApp))
        let page = fixture.orders.detailPage(try XCTUnwrap(router.path.last))

        // 「查看商品」：ProductDetail，参数只有 platform 与 product_key（AC-S1-104）
        let product = try XCTUnwrap(ViewProductEntry.view(detail(Self.detailJSON(status: "PAID"))))
        page.onOpen(product)
        XCTAssertEqual(router.path.last?.route, "ProductDetail")
        XCTAssertEqual(router.path.last?.params, ["platform": .string("taobao"), "product_key": .string("tb:9007")])

        // 详情按钮：CLAWED_BACK + PUNISH →【联系客服】（Help）+【查看流水】（Ledger）
        let clawed = OrderDetailActions.view(try detail(Self.detailJSON(
            status: "CLAWED_BACK", actions: "[\"CONTACT_CS\"]", reason: "\"PUNISH\""
        )))
        XCTAssertEqual(clawed.buttons.map(\.route), ["Help", "Ledger"])
        for button in clawed.buttons {
            page.onOpen(RouteTarget(route: button.route, params: [:]))
            XCTAssertEqual(router.path.last?.route, button.route)
            XCTAssertEqual(router.path.last?.params, [:])
        }
        for (status, action, route) in [
            ("INVALID", "[\"APPEAL\"]", "Appeal"), ("PAID", "[\"REAUTH\"]", "AuthManage"),
            ("PAID", "[\"CLAIM\"]", "FindOrder"),
        ] {
            let view = OrderDetailActions.view(try detail(Self.detailJSON(status: status, actions: action)))
            let button = try XCTUnwrap(view.buttons.first)
            page.onOpen(RouteTarget(route: button.route, params: [:]))
            XCTAssertEqual(router.path.last?.route, route)
        }
        // 「查看说明」：Help 带配置的 article_id
        let help = try XCTUnwrap(PriceCompareEntry.target(
            ["price_compare": ["route": "Help", "params": ["article_id": "price-compare"]]], routes: Routes.all
        ))
        page.onOpen(help)
        XCTAssertEqual(router.path.last?.route, "Help")
        XCTAssertEqual(router.path.last?.params, ["article_id": .string("price-compare")])
        // 【去提现】：Withdraw 是 realname 路由，守卫按实名前置落点（A08 同口径）；请求的是 Withdraw {}
        page.onOpen(RouteTarget(route: "Withdraw", params: [:]))
        XCTAssertEqual(router.lastDecision?.route.map { ["Withdraw", "BindPhone", "RealName"].contains($0) }, true)
    }

    func testH5RouteAddressFromConfigBaseAndPath() {
        let config = "{\"h5_base_url\":\"https://h5.example.invalid/app/\"}"
        XCTAssertEqual(
            H5RouteURL.make(route: "Help", params: ["article_id": .string("price compare")], configJson: config)?
                .absoluteString,
            "https://h5.example.invalid/app/help?article_id=price%20compare"
        )
        XCTAssertEqual(
            H5RouteURL.make(route: "FindOrder", params: [:], configJson: config)?.absoluteString,
            "https://h5.example.invalid/app/find-order"
        )
        XCTAssertEqual(
            H5RouteURL.make(route: "Ledger", params: [:], configJson: config)?.absoluteString,
            "https://h5.example.invalid/app/ledger"
        )
        XCTAssertNil(H5RouteURL.make(route: "Help", params: [:], configJson: "{}"), "基址缺失不加载")
        XCTAssertNil(H5RouteURL.make(
            route: "Help", params: [:], configJson: "{\"h5_base_url\":\"http://h5.example.invalid\"}"
        ), "不是 https 不加载")
        XCTAssertNil(H5RouteURL.make(
            route: "Help", params: [:], configJson: "{\"h5_base_url\":\"https://h5.example.invalid/?a=1\"}"
        ), "带查询串不加载")
        XCTAssertNil(H5RouteURL.make(route: "OrderDetail", params: [:], configJson: config), "原生路由没有 H5 地址")
    }

    // MARK: - 会话换代与出栈

    func testSessionChangeClearsDetailRemovesItAndResetsList() throws {
        let fixture = make()
        AppStubProtocol.install { _ in .hold }
        let router = fixture.routing.router
        let list = fixture.orders.listPage(RouteDestination(route: "OrderList"))
        list.controller.updateSearchText("3712345678901234567")
        list.controller.submitSearch()
        fixture.orders.persist()
        router.open(RouteRequest(route: "OrderDetail", values: ["order_id": .string("o1")], from: .inApp))
        let page = fixture.orders.detailPage(try XCTUnwrap(router.path.last))
        // A 会话失效 → 登录 B
        fixture.network.client.signOut()
        try fixture.tokens.save(access: "at-b", refresh: "rt-b", scope: "full", account: "user-b")
        fixture.orders.checkSession()
        XCTAssertEqual(page.controller.snapshot.phase, .cleared, "旧详情同步清空快照")
        XCTAssertNil(page.controller.snapshot.detail)
        XCTAssertFalse(router.path.contains { $0.route == "OrderDetail" }, "旧会话详情页移出导航栈")
        let fresh = fixture.orders.listPage(RouteDestination(route: "OrderList"))
        XCTAssertFalse(fresh === list, "列表执行器整份换新")
        XCTAssertEqual(fresh.controller.snapshot.searchText, "", "搜索框（可能是上一账号的完整订单号）清空")
        XCTAssertNil(fixture.orders.restorer.stored, "恢复记录删除")
        XCTAssertTrue(list.controller.isLeft)
    }

    func testDetailPopLeavesAndCancels() async throws {
        let fixture = make()
        AppStubProtocol.install { _ in .hold }
        let router = fixture.routing.router
        router.open(RouteRequest(route: "OrderDetail", values: ["order_id": .string("o1")], from: .inApp))
        let page = fixture.orders.detailPage(try XCTUnwrap(router.path.last))
        page.controller.start()
        await AppStubProtocol.waitUntilHeld()
        XCTAssertEqual(page.controller.inFlight, 1)
        router.path.removeAll()
        XCTAssertTrue(page.controller.isLeft, "出栈的同步出口作废")
        XCTAssertEqual(page.controller.inFlight, 0)
    }

    func testCacheCleanerRegisteredInBothRegistries() {
        let withdrawal = EnvironmentSwitchCleanerRegistry(cleaners: [])
        let environmentSwitch = EnvironmentSwitchCleanerRegistry(cleaners: [])
        OrderCacheCleaner.register(withdrawal: withdrawal, environmentSwitch: environmentSwitch)
        OrderCacheCleaner.register(withdrawal: withdrawal, environmentSwitch: environmentSwitch)
        XCTAssertEqual(withdrawal.registeredNames, [OrderCacheCleaner.name])
        XCTAssertEqual(environmentSwitch.registeredNames, [OrderCacheCleaner.name])
        XCTAssertTrue(PrivacyWithdrawalCleanup.registry.registeredNames.contains(OrderCacheCleaner.name), "生产组合已登记")
        XCTAssertTrue(EnvironmentSwitchCleanerRegistry.shared.registeredNames.contains(OrderCacheCleaner.name))
    }

    func testNotificationStatusMapping() {
        XCTAssertEqual(AppOrders.notificationRaw(.notDetermined), PendingTrackRaw.notDetermined)
        XCTAssertEqual(AppOrders.notificationRaw(.denied), PendingTrackRaw.denied)
        XCTAssertEqual(AppOrders.notificationRaw(.authorized), PendingTrackRaw.granted)
        XCTAssertEqual(AppOrders.notificationRaw(.provisional), PendingTrackRaw.granted)
    }
}
