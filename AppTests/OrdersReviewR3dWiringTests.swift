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

/// APP-08 iOS 第三次定向复核（NATIVE/APP-08/ios-recheck-r3fix-c.md）第四次窄修的 App 接线复现：
/// - NEW-01：撤回清理未完成（凭据不可读）期间，身份快照只读内存里的会话世代与作废世代，不调用令牌存储——清理失败、执行器随清理回调重建、
///   再次构造身份时令牌读取次数都为零；
/// - RC-06：真实购买控制器停在 JumpTip，换账号后确认旧弹窗 → 零 markTipRead；确认后、首发前换账号 → 零发送。
@MainActor
final class OrdersReviewR3dWiringTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        suiteName = "OrdersReviewR3dWiringTests.\(UUID().uuidString)"
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

    private static func envelope(_ data: String) -> AppStubProtocol.Reply {
        .json(status: 200, body: "{\"code\":0,\"msg\":\"\",\"data\":\(data),\"trace_id\":\"t\"}")
    }

    private func openProduct(_ fixture: OrdersAppFixture) throws -> RouteDestination {
        let router = fixture.routing.router
        router.open(RouteRequest(
            route: "ProductDetail", values: ["platform": .string("taobao"), "product_key": .string("tb:milk")],
            from: .inApp
        ))
        return try XCTUnwrap(router.path.last)
    }

    // MARK: - NEW-01

    /// 评审场景：撤回同意的清理里令牌删除失败（标记保留、凭据不可读）；订单清理回调随 hub 换代重建商品页的待跟单执行器（调用
    /// currentOwner）。整个不可读期间令牌存储读取次数为零；身份只带内存里的世代（账号为空）。
    func testWithdrawalCleanupFailureAndExecutorRebuildReadNoTokens() throws {
        let fixture = make()
        OrderCacheCleaner.register(
            fixture.cleaner, withdrawal: fixture.withdrawal,
            environmentSwitch: EnvironmentSwitchCleanerRegistry(cleaners: [])
        )
        let product = try openProduct(fixture)
        _ = fixture.orders.pendingSlot(for: product, purchase: nil, trade: nil)
        let before = fixture.orders.pendingService(product.id)
        XCTAssertEqual(fixture.orders.currentOwner().account, "user-a", "前提：可读时读得到账号")

        fixture.tokens.failClears = true
        let reads = fixture.store.reads
        let failures = fixture.runner.run()
        XCTAssertFalse(failures.isEmpty, "前提：令牌删除失败")
        XCTAssertFalse(fixture.runner.credentialsReadable, "前提：撤回清理未完成，凭据不可读")
        XCTAssertNotNil(fixture.orders.pendingService(product.id))
        XCTAssertFalse(fixture.orders.pendingService(product.id) === before, "前提：清理回调重建了执行器")

        // 不可读期间再次构造身份、比较、重建执行器
        let owner = fixture.orders.currentOwner()
        XCTAssertNil(owner.account)
        XCTAssertEqual(owner.request?.generation, fixture.network.client.sessionGeneration)
        XCTAssertNil(owner.request?.account)
        XCTAssertFalse(fixture.orders.isCurrent(owner))
        XCTAssertNil(fixture.orders.jumpOrigin(product.id))
        _ = fixture.orders.jumpSource(product.id)
        _ = fixture.orders.pendingSlot(for: product, purchase: nil, trade: nil)
        fixture.orders.checkSession()

        XCTAssertEqual(fixture.store.reads, reads, "撤回清理未完成期间令牌读取次数为零")
    }

    // MARK: - RC-06

    private static let card: TradeObject = [
        "product_key": "tb:milk", "item_ref": "r1", "platform": "taobao", "title": "牛奶",
        "price_basis": "final_price", "final_price_fen": 4678, "rebate_basis": "estimated",
        "rebate_min_fen": 123, "rebate_max_fen": 234, "rebate_cap_reason": NSNull(),
        "link_id": "L1", "cta": ["text_key": "btn.buy.coupon"], "availability": "ok",
        "disclaimer_keys": ["price_basis", "rebate_estimate"],
    ]

    private static let openBody = "{\"attempt_id\":\"A1\",\"jump\":{\"primary\":{\"type\":\"scheme\","
        + "\"value\":\"couli-test-none://x\"},\"fallbacks\":[],\"expire_at\":\"2099-01-01T00:00:00+08:00\"},"
        + "\"price_changed\":false,\"old_final_price_fen\":4678,\"new_final_price_fen\":4678,\"new_link_id\":null,"
        + "\"requote_failed\":false,\"new_rebate_min_fen\":123,\"new_rebate_max_fen\":234,\"availability\":\"ok\","
        + "\"quoted_at\":\"2026-10-09T10:00:00+08:00\"}"

    private func readPosts() -> [AppStubProtocol.Recorded] {
        AppStubProtocol.requests.filter { $0.path == "/v1/me/tips/jump_tip/read" }
    }

    /// 真实接线：A 的购买停在 JumpTip（未读）。swapBeforeConfirm：确认前换成 B（会话通知已处理）；否则确认后、markTipRead 首发前换成 B。
    func testRealJumpTipConfirmAcrossAccountSwitchSendsNoMarkRead() async throws {
        for swapBeforeConfirm in [true, false] {
            AppStubProtocol.reset()
            let fixture = make()
            let trade = AppTrade(
                network: fixture.network, config: fixture.config, privacy: fixture.privacy, routing: fixture.routing,
                login: fixture.login, track: { _, _ in }
            )
            AppStubProtocol.install { request in
                if request.path.hasSuffix("/open") {
                    return Self.envelope(Self.openBody)
                }
                if request.path == "/v1/me/tips" {
                    return Self.envelope("{\"jump_tip\":{}}")
                }
                return .hold
            }
            let product = try openProduct(fixture)
            let purchase = trade.makePurchase(for: product, updateCard: { _, _ in }, refetchCard: { _, _, _ in })
            _ = fixture.orders.pendingSlot(for: product, purchase: purchase, trade: trade)
            purchase.buy(Self.card, spm: nil)
            for _ in 0..<400 where purchase.state.dialog == nil {
                try await Task.sleep(nanoseconds: 5_000_000)
            }
            XCTAssertEqual(purchase.state.dialog, .jumpTip(platform: "taobao"), "前提：停在 JumpTip")
            if swapBeforeConfirm {
                fixture.network.client.signOut()
                try fixture.tokens.save(access: "at-b", refresh: "rt-b", scope: "full", account: "user-b")
                fixture.orders.checkSession()
                purchase.confirm(purchase.state.dialogTicket)
                XCTAssertEqual(purchase.state.toast?.key, PurchaseTextKeys.jumpExpired, "旧方案作废，提示重新点购买")
            } else {
                purchase.confirm(purchase.state.dialogTicket)
                fixture.network.client.signOut()
                try fixture.tokens.save(access: "at-b", refresh: "rt-b", scope: "full", account: "user-b")
            }
            try await Task.sleep(nanoseconds: 300_000_000)
            XCTAssertTrue(readPosts().isEmpty, "swapBeforeConfirm=\(swapBeforeConfirm)：零 markTipRead 发送")
            withExtendedLifetime(trade) {}
        }
    }
}
