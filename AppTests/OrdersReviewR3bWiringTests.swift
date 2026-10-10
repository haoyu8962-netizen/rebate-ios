import Config
@testable import Couli
import Foundation
import OrderCore
import Orders
import Router
import XCTest

/// APP-08 iOS 第 3 轮后定向复核（NATIVE/APP-08/ios-recheck-r3fix.md）第二次窄修的 App 接线复现：
/// - RC-02：后台保存抢在会话通知之前：只认页面固定身份，不把 A 的搜索词保存成 B 的记录；随后以 B 重启不恢复；
/// - RC-06：外跳完成事件携带发起时固定的会话、环境与 slot 世代；换执行器 / 换账号后迟到的旧完成事件不驱动新执行器。
@MainActor
final class OrdersReviewR3bWiringTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        suiteName = "OrdersReviewR3bWiringTests.\(UUID().uuidString)"
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

    private static let tracksBody = "{\"items\":[{\"link_id\":\"L1\",\"attempt_id\":\"a1\",\"platform\":\"taobao\","
        + "\"jumped_at\":\"2026-10-09T10:00:00+08:00\",\"show_claim_entry\":true,\"dismissed\":false}]}"

    private func switchToB(_ fixture: OrdersAppFixture) throws {
        fixture.network.client.signOut()
        try fixture.tokens.save(access: "at-b", refresh: "rt-b", scope: "full", account: "user-b")
    }

    // MARK: - RC-02

    /// 评审场景：A 的列表保留完整订单号搜索词（只有搜索查询、没有默认列表缓存 owner 文件）→ 会话变成 B、会话通知还没处理 → 后台保存
    /// 抢先执行 → 进程结束 → 以 B 重启：记录没有被改成 B 的，B 不恢复 A 的搜索词。
    func testBackgroundSaveBeforeSessionNoticeThenRestartDoesNotRebindToB() throws {
        let fixture = make()
        AppStubProtocol.install { _ in .hold }
        let list = fixture.orders.listPage(RouteDestination(route: "OrderList"))
        list.controller.updateSearchText(Self.fullOrderNo)
        list.controller.submitSearch()
        fixture.orders.persist()
        XCTAssertEqual(fixture.orders.restorer.stored?.owner, OrderCacheStore.hash("user-a"), "前提：A 的记录")
        let ownerFile = fixture.orders.cache.root.appendingPathComponent("owner")
        XCTAssertFalse(FileManager.default.fileExists(atPath: ownerFile.path), "前提：没有缓存 owner 文件")

        try switchToB(fixture)
        // 后台保存抢在会话通知之前（保存入口本身）
        fixture.orders.persist()
        XCTAssertEqual(
            fixture.orders.restorer.stored?.owner, OrderCacheStore.hash("user-a"), "不以当前会话 B 重写 A 的搜索词"
        )
        // 进程在这里结束 → 以 B 重启：同一份文件上的新恢复器
        let file = OrderPageStateFile(url: fixture.orders.cache.pageState.url)
        let restarted = OrderPageRestorer(file: file, unit: OrderCacheStore(root: fixture.orders.cache.root))
        XCTAssertNil(restarted.decide(account: "user-b"), "B 不恢复 A 的搜索词")
    }

    /// 进后台的保存入口：先核对会话（换代即清空、删除旧记录），旧页面不再保存。
    func testSceneBackgroundAfterSessionSwapErasesInsteadOfSaving() throws {
        let fixture = make()
        AppStubProtocol.install { _ in .hold }
        let list = fixture.orders.listPage(RouteDestination(route: "OrderList"))
        list.controller.updateSearchText(Self.fullOrderNo)
        list.controller.submitSearch()
        fixture.orders.persist()
        try switchToB(fixture)
        fixture.orders.sceneEnteredBackground()
        XCTAssertNil(fixture.orders.restorer.stored, "会话换代：旧记录删除，不保存旧页面")
        XCTAssertTrue(list.invalidated)
    }

    // MARK: - RC-06

    /// 评审场景：商品详情的外跳还在等系统完成回调 → 切环境（换执行器，同一 destination.id）或换账号 → 旧完成回调迟到交付：
    /// 不改新 slot、不驱动新执行器（不拉卡、不出卡）；新的外跳尝试取新来源，照常出卡。
    func testStaleJumpCompletionDoesNotDriveNewService() async throws {
        for path in ["environment", "account"] {
            AppStubProtocol.reset()
            let fixture = make()
            let withdrawal = EnvironmentSwitchCleanerRegistry(cleaners: [])
            let environmentSwitch = EnvironmentSwitchCleanerRegistry(cleaners: [])
            OrderCacheCleaner.register(fixture.cleaner, withdrawal: withdrawal, environmentSwitch: environmentSwitch)
            AppStubProtocol.install { request in
                request.path == "/v1/orders/pending-tracks" ? Self.envelope(Self.tracksBody) : .hold
            }
            let product = RouteDestination(route: "ProductDetail")
            _ = fixture.orders.pendingSlot(for: product, purchase: nil, trade: nil)
            // 外跳发起：固定来源
            let staleOrigin = try XCTUnwrap(fixture.orders.jumpOrigin(product.id))
            if path == "environment" {
                _ = environmentSwitch.cleanAll()
            } else {
                try switchToB(fixture)
                fixture.orders.checkSession()
            }
            let current = try XCTUnwrap(fixture.orders.pendingService(product.id))
            // 旧完成事件迟到交付（在前台）+ 之后回到前台
            fixture.orders.jumped(product.id, platform: "taobao", origin: staleOrigin, visible: true)
            fixture.orders.pageForeground(product.id)
            try await Task.sleep(nanoseconds: 150_000_000)
            XCTAssertTrue(
                AppStubProtocol.requests.filter { $0.path == "/v1/orders/pending-tracks" }.isEmpty,
                "\(path)：旧事件不驱动新执行器拉卡"
            )
            XCTAssertTrue(current.state.cards.isEmpty, "\(path)：不出卡")
            // 新的外跳尝试：新来源，照常
            fixture.orders.jumped(
                product.id, platform: "taobao", origin: fixture.orders.jumpOrigin(product.id), visible: true
            )
            for _ in 0..<400 where current.state.cards.isEmpty {
                try await Task.sleep(nanoseconds: 5_000_000)
            }
            XCTAssertEqual(current.state.cards.map(\.linkId), ["L1"], "\(path)：新尝试照常出卡")
        }
    }

    /// 等待回前台期间来源变了（换账号）：回前台不拉。
    func testAwaitingJumpDroppedWhenOriginChangesBeforeForeground() async throws {
        let fixture = make()
        AppStubProtocol.install { request in
            request.path == "/v1/orders/pending-tracks" ? Self.envelope(Self.tracksBody) : .hold
        }
        let product = RouteDestination(route: "ProductDetail")
        _ = fixture.orders.pendingSlot(for: product, purchase: nil, trade: nil)
        fixture.orders.jumped(
            product.id, platform: "taobao", origin: fixture.orders.jumpOrigin(product.id), visible: false
        )
        try switchToB(fixture)
        fixture.orders.checkSession()
        fixture.orders.pageForeground(product.id)
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertTrue(AppStubProtocol.requests.filter { $0.path == "/v1/orders/pending-tracks" }.isEmpty)
    }
}
