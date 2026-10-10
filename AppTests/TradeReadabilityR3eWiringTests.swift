@testable import Couli
import CouliNetwork
import Foundation
import Router
import Trade
import XCTest

/// APP-08 iOS 第五次修复（既有旁路，隐私类不降级）：基本模式或撤回清理未完成（凭据不可读）时，发起页回前台问「是否已登录」
/// （AppTrade.loggedIn）与商品卡映射的上下文（AppSearch.productContext）都不读令牌——令牌存储读取次数为零。
@MainActor
final class TradeReadabilityR3eWiringTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        suiteName = "TradeReadabilityR3eWiringTests.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        AppStubProtocol.reset()
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default
            .removeItem(at: FileManager.default.temporaryDirectory.appendingPathComponent(suiteName))
        AppStubProtocol.reset()
    }

    private func openProduct(_ fixture: OrdersAppFixture) throws -> RouteDestination {
        let router = fixture.routing.router
        router.open(RouteRequest(
            route: "ProductDetail", values: ["platform": .string("taobao"), "product_key": .string("tb:milk")],
            from: .inApp
        ))
        return try XCTUnwrap(router.path.last)
    }

    /// 撤回清理里令牌删除失败（凭据不可读、隐私结论仍是已同意）：回前台、问登录状态、商品卡映射都零读取。
    func testUnreadableForegroundAndProductMappingReadNoTokens() throws {
        let fixture = OrdersAppFixture.make(suiteName: suiteName, defaults: defaults)
        let runner = fixture.runner
        let trade = AppTrade(
            network: fixture.network, config: fixture.config, privacy: fixture.privacy, routing: fixture.routing,
            login: fixture.login, credentialsReadable: { runner.credentialsReadable }, track: { _, _ in }
        )
        let product = try openProduct(fixture)
        let purchase = trade.makePurchase(for: product, updateCard: { _, _ in }, refetchCard: { _, _, _ in })
        XCTAssertTrue(trade.loggedIn, "前提：可读时已登录")

        fixture.tokens.failClears = true
        XCTAssertFalse(fixture.runner.run().isEmpty, "前提：令牌删除失败")
        XCTAssertFalse(runner.credentialsReadable, "前提：凭据不可读")
        let reads = fixture.store.reads

        purchase.onBackground()
        purchase.onForeground()
        XCTAssertFalse(trade.loggedIn)
        let context = AppSearch.productContext(
            client: fixture.network.client, privacy: fixture.privacy, readable: { runner.credentialsReadable }
        )
        XCTAssertEqual(context["loggedIn"] as? Bool, false)
        XCTAssertEqual(fixture.store.reads, reads, "不可读期间令牌读取次数为零")
        withExtendedLifetime(trade) {}
    }

    /// 基本模式（撤回同意后）：回前台、问登录状态、商品卡映射都零读取。
    func testBasicModeForegroundAndProductMappingReadNoTokens() throws {
        let fixture = OrdersAppFixture.make(suiteName: suiteName, defaults: defaults)
        let trade = AppTrade(
            network: fixture.network, config: fixture.config, privacy: fixture.privacy, routing: fixture.routing,
            login: fixture.login, credentialsReadable: { true }, track: { _, _ in }
        )
        let product = try openProduct(fixture)
        let purchase = trade.makePurchase(for: product, updateCard: { _, _ in }, refetchCard: { _, _, _ in })
        fixture.privacy.withdraw()
        XCTAssertTrue(trade.basicMode, "前提：基本模式")
        let reads = fixture.store.reads

        purchase.onBackground()
        purchase.onForeground()
        XCTAssertFalse(trade.loggedIn)
        let context = AppSearch.productContext(
            client: fixture.network.client, privacy: fixture.privacy, readable: { true }
        )
        XCTAssertEqual(context["loggedIn"] as? Bool, false)
        XCTAssertEqual(context["privacy"] as? String, "basic")
        XCTAssertEqual(fixture.store.reads, reads, "基本模式下令牌读取次数为零")
        withExtendedLifetime(trade) {}
    }
}
