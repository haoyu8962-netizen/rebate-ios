import Config
@testable import Couli
import CouliNetwork
import Foundation
import Generated
import OrderCore
import Orders
import Router
import Trade
import XCTest

/// APP-08 iOS 第 3 轮后第二次定向复核（NATIVE/APP-08/ios-recheck-r3fix-b.md）第三次窄修的 App 接线复现：
/// - RC-01：执行器固定的网络归属随订单请求交给 ApiClient；排队后、首发前底层会话换代（App 的换代通知还没处理）或切环境 → 旧请求零发送；
/// - RC-06：真实购买控制器（AppTrade.makePurchase + AppOrders.pendingSlot 接线）在确认前换账号 / 切环境 → 旧方案作废，不外跳、
///   不交付完成事件，提示重新点购买取新方案。
@MainActor
final class OrdersReviewR3cWiringTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        suiteName = "OrdersReviewR3cWiringTests.\(UUID().uuidString)"
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

    /// 底层会话换成 B（不调 checkSession：App 的换代通知还没处理）。
    private func switchToB(_ fixture: OrdersAppFixture) throws {
        fixture.network.client.signOut()
        try fixture.tokens.save(access: "at-b", refresh: "rt-b", scope: "full", account: "user-b")
    }

    private func orderRequests() -> [AppStubProtocol.Recorded] {
        AppStubProtocol.requests.filter { $0.path.hasPrefix("/v1/orders") }
    }

    // MARK: - RC-01

    /// 评审场景：A 的搜索（完整订单号）通过入口检查、排进 Task → 执行前会话变成 B、换代通知还没处理 → 零发送（不随 B 的凭据发出）。
    /// 切环境（作废世代 +1、App 侧清理还没跑）同样零发送。
    func testQueuedOrderRequestsAfterSessionOrEnvironmentChangeSendNothing() async throws {
        for path in ["account", "environment"] {
            AppStubProtocol.reset()
            let fixture = make()
            AppStubProtocol.install { _ in .hold }
            let list = fixture.orders.listPage(RouteDestination(route: "OrderList"))
            list.controller.updateSearchText(Self.fullOrderNo)
            XCTAssertTrue(list.controller.submitSearch(), "\(path)：前提：入口检查通过")
            let router = fixture.routing.router
            router.open(RouteRequest(route: "OrderDetail", values: ["order_id": .string("o1")], from: .inApp))
            let detail = fixture.orders.detailPage(try XCTUnwrap(router.path.last))
            detail.controller.start()
            if path == "account" {
                try switchToB(fixture)
            } else {
                fixture.network.client.invalidateSessions()
            }
            try await Task.sleep(nanoseconds: 150_000_000)
            XCTAssertTrue(orderRequests().isEmpty, "\(path)：排队的列表 / 搜索 / 详情请求零发送")
        }
    }

    /// 待跟单拉取：外跳回来、拉取排进 Task → 执行前会话变成 B → 零发送。
    func testQueuedPendingFetchAfterSessionSwapSendsNothing() async throws {
        let fixture = make()
        AppStubProtocol.install { _ in .hold }
        let product = RouteDestination(route: "ProductDetail")
        _ = fixture.orders.pendingSlot(for: product, purchase: nil, trade: nil)
        fixture.orders.jumped(
            product.id, platform: "taobao", origin: fixture.orders.jumpOrigin(product.id), visible: true
        )
        try switchToB(fixture)
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertTrue(orderRequests().isEmpty, "待跟单拉取零发送")
    }

    // MARK: - RC-06

    private static let card: TradeObject = [
        "product_key": "tb:milk", "item_ref": "ref-tb:milk", "platform": "taobao", "title": "milk title",
        "price_fen": 5678, "coupon_fen": 1000, "final_price_fen": 4678, "est_net_price_fen": 4555,
        "rebate_min_fen": 123, "rebate_max_fen": 234, "rebate_basis": "normal", "benefit_tags": ["x"],
        "link_id": "L1", "cta": ["text_key": "btn.buy.coupon"], "availability": "ok",
        "disclaimer_keys": ["price_basis", "rebate_estimate"],
    ]

    /// 改价确认（price_changed）的 open 响应：方案只有一个拉起步骤。
    private static let openBody = "{\"attempt_id\":\"A1\",\"jump\":{\"primary\":{\"type\":\"scheme\","
        + "\"value\":\"couli-test-none://x\"},\"fallbacks\":[],\"expire_at\":\"2099-01-01T00:00:00+08:00\"},"
        + "\"price_changed\":true,\"old_final_price_fen\":4678,\"new_final_price_fen\":4990,\"new_link_id\":null,"
        + "\"requote_failed\":false,\"new_rebate_min_fen\":123,\"new_rebate_max_fen\":234,\"availability\":\"ok\","
        + "\"quoted_at\":\"2026-10-09T10:00:00+08:00\"}"

    private final class Events {
        var tracked: [TrackEvent] = []
    }

    private struct Wired {
        let trade: AppTrade
        let purchase: OpenPurchaseController
        let product: RouteDestination
    }

    /// 真实接线的购买控制器：商品页在栈里、待跟单 slot 接上，点购买后停在改价确认。
    private func purchaseAtConfirm(
        _ fixture: OrdersAppFixture, events: Events
    ) async throws -> Wired {
        let trade = AppTrade(
            network: fixture.network, config: fixture.config, privacy: fixture.privacy, routing: fixture.routing,
            login: fixture.login, track: { event, _ in events.tracked.append(event) }
        )
        AppStubProtocol.install { request in
            if request.path.hasSuffix("/open") {
                return Self.envelope(Self.openBody)
            }
            if request.path == "/v1/me/tips" {
                return Self.envelope("{\"jump_tip\":{\"taobao\":\"2026-10-01T00:00:00+08:00\"}}")
            }
            return .hold
        }
        let router = fixture.routing.router
        router.open(RouteRequest(
            route: "ProductDetail", values: ["platform": .string("taobao"), "product_key": .string("tb:milk")],
            from: .inApp
        ))
        let product = try XCTUnwrap(router.path.last)
        let purchase = trade.makePurchase(for: product, updateCard: { _, _ in }, refetchCard: { _, _, _ in })
        _ = fixture.orders.pendingSlot(for: product, purchase: purchase, trade: trade)
        purchase.buy(Self.card, spm: nil)
        for _ in 0..<400 where purchase.state.dialog == nil {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        return Wired(trade: trade, purchase: purchase, product: product)
    }

    /// 评审场景：旧会话 / 旧环境已返回方案、页面停在改价确认 → 换账号（会话通知已处理）或切环境（换执行器，商品页仍在栈里）→ 用户点
    /// 【继续购买】：旧方案作废，不外跳（没有 link_jump 上报）、不交付完成事件（新执行器不拉卡），提示重新点购买、不自动重发旧尝试。
    func testRealPurchaseConfirmAfterIdentityChangeDropsStalePlan() async throws {
        for path in ["account", "environment"] {
            AppStubProtocol.reset()
            let fixture = make()
            let withdrawal = EnvironmentSwitchCleanerRegistry(cleaners: [])
            let environmentSwitch = EnvironmentSwitchCleanerRegistry(cleaners: [])
            OrderCacheCleaner.register(fixture.cleaner, withdrawal: withdrawal, environmentSwitch: environmentSwitch)
            let events = Events()
            let wired = try await purchaseAtConfirm(fixture, events: events)
            let purchase = wired.purchase
            XCTAssertEqual(
                purchase.state.dialog, .confirmPrice(oldFen: 4678, newFen: 4990, rebateGone: false, coupon: false),
                "\(path)：前提：停在改价确认"
            )
            if path == "account" {
                try switchToB(fixture)
                fixture.orders.checkSession()
            } else {
                _ = environmentSwitch.cleanAll()
            }
            XCTAssertTrue(fixture.routing.router.path.contains { $0.id == wired.product.id }, "\(path)：前提：商品页仍在栈里")
            purchase.confirm(purchase.state.dialogTicket)
            try await Task.sleep(nanoseconds: 200_000_000)

            XCTAssertNil(purchase.state.dialog, "\(path)")
            XCTAssertEqual(purchase.state.toast?.key, PurchaseTextKeys.jumpExpired, "\(path)：提示重新点购买取新方案")
            XCTAssertTrue(events.tracked.isEmpty, "\(path)：旧方案没有执行（没有 link_jump 上报）")
            let paths = AppStubProtocol.requests.map(\.path)
            XCTAssertFalse(paths.contains("/v1/orders/pending-tracks"), "\(path)：没有完成事件驱动新执行器拉卡")
            XCTAssertFalse(paths.contains("/v1/me/tips"), "\(path)：确认即止，不继续走外跳前的提示查询")
            XCTAssertEqual(paths.filter { $0.hasSuffix("/open") }.count, 1, "\(path)：不自动重发旧尝试")
            withExtendedLifetime(wired.trade) {}
        }
    }
}
