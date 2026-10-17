import ClientCore
import Config
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

/// FU-IOS-0712 末轮窄修三（订单侧 RC-04 同口径核对）：启动时身份读取失败，订单判据带 `known = false`，与之后「确认没有会话」的判据不同，
/// 身份确认后走启动态变化并补做对账。本例是回归保护（订单原本就不受 RC-04 影响）。
extension FollowupIos0712FixR1ColdStartTests {
    /// RC-04（订单）：没有 pending_clear、令牌已不存在、只有初始化那一次读取失败；恢复后确认没有会话 → 旧列表缓存与 owner 文件被删。
    func testInitOnlyReadFailureThenConfirmedNoSessionDeletesOldOrderCache() async throws {
        let fixture = OrdersAppFixture.make(suiteName: suiteName, defaults: defaults)
        let owner = try await seedOwnedCacheAndRecord(fixture)
        XCTAssertFalse(fixture.orders.cache.isPendingClear, "前提：没有待清理")
        try fixture.tokens.clear()
        fixture.store.failRead(nth: 1)
        let cold = coldOrders(fixture) { true }
        XCTAssertFalse(cold.sessionKey.known, "前提：初始化那次读取失败")
        XCTAssertNotNil(listCache(fixture, owner), "前提：身份未知时不删")
        cold.checkSession()
        let key = cold.sessionKey
        XCTAssertTrue(key.known, "恢复后确认")
        XCTAssertNil(key.account, "确认没有会话")
        XCTAssertNil(listCache(fixture, owner), "旧列表缓存已删")
        XCTAssertFalse(FileManager.default.fileExists(atPath: ownerFile(fixture).path), "缓存 owner 已删")
    }
}

/// FU-IOS-0712 末轮窄修三（钱包侧 RC-02 / G53、RC-04）。
final class FollowupIos0712FixR3cWalletTests: WalletFlowTestCase {
    /// RC-02 / G53：未知期间建的钱包页，恢复时识别成功、换上身份，但紧接着加载的身份核对读取失败：页面结算为可重试的失败态（不留无出口
    /// 的加载态）并记下待补取；读取再次恢复后，判据相同的核对也给同一页补取，加载出摘要。
    func testWalletLoadAbortedByReadFailureAfterRecoveryResumesOnNextConfirmation() async throws {
        let fixture = make()
        let key = fixture.wallet.sessionKey
        fixture.router.open(RouteRequest(route: WalletRoutes.wallet, from: .inApp))
        let top = try XCTUnwrap(fixture.router.path.last)
        XCTAssertEqual(top.route, WalletRoutes.wallet, "前提：路由已通过守卫")
        fixture.tokens.failReads = .readFailed
        let entry = try XCTUnwrap(fixture.wallet.entry(for: top))
        fixture.tokens.failReads = nil
        let controller = try XCTUnwrap(entry.controller as? WalletController)
        XCTAssertNil(controller.state.owner.account, "前提：建页时身份未知")
        // 恢复：识别那次读取成功（换上身份），之后本次核对里的读取（加载的身份核对）全部暂时失败
        fixture.store.failReads(fromNth: 2)
        _ = fixture.wallet.entry(for: top)
        fixture.store.stopFailing()
        XCTAssertEqual(controller.state.owner.account, "user-a", "前提：已换上身份")
        XCTAssertTrue(controller.loadPending, "加载核对失败：记下待补取")
        let settled = controller.state.phase
        XCTAssertEqual(settled, .error, "不留无出口的加载态：可重试的失败态")
        // 再次恢复：判据相同，同一页补取
        let again = try XCTUnwrap(fixture.wallet.entry(for: top))
        XCTAssertTrue(again === entry, "同一页面")
        XCTAssertEqual(fixture.wallet.sessionKey, key, "判据不变")
        await waitUntil("补取后摘要没有加载") { controller.state.summary != nil || controller.state.phase == .error }
        let summary = controller.state.summary
        let pending = controller.loadPending
        XCTAssertNotNil(summary, "同页能加载")
        XCTAssertFalse(pending, "待补取已完成")
    }

    /// RC-02 / G53：中止后的失败态里点【重试】（与下拉同一入口）也能加载，禁用期照旧拦。
    func testWalletLoadAbortedByReadFailureRetriesFromSettledState() async throws {
        let fixture = make()
        // 建页时可能已发出的摘要请求挂住不回（只看本例触发的那次加载）
        script.on("GET /v1/wallet/summary", .hold)
        let entry = try XCTUnwrap(fixture.open(WalletRoutes.wallet))
        let controller = try XCTUnwrap(entry.controller as? WalletController)
        XCTAssertEqual(controller.state.owner.account, "user-a", "前提：建页时身份已确认")
        // 加载的身份核对暂时读失败
        fixture.store.failReads(fromNth: 1)
        controller.load()
        fixture.store.stopFailing()
        script.ok("GET /v1/wallet/summary", WalletSamples.summary)
        XCTAssertEqual(controller.state.phase, .error, "前提：加载核对失败后结算为失败态")
        XCTAssertTrue(controller.loadPending)
        fixture.wallet.gates.read.start(30000)
        XCTAssertFalse(controller.refresh(), "禁用期内不发")
        let gated = controller.state.error?.key
        XCTAssertEqual(gated, "error.42901", "按限流结算")
        fixture.wallet.gates.reset()
        XCTAssertTrue(controller.refresh(), "【重试】")
        await waitUntil("重试后摘要没有加载") { controller.state.summary != nil || controller.state.error != nil }
        let summary = controller.state.summary
        XCTAssertNotNil(summary, "重试能加载")
    }

    /// RC-04（钱包）：磁盘残留 A/E1 摘要与金额草稿、没有 pending_clear、令牌已不存在；只有初始化那一次读取失败，恢复后确认没有会话
    /// → 旧摘要与草稿文件实际删除。
    func testWalletInitOnlyReadFailureThenConfirmedNoSessionDeletesOldFiles() async throws {
        let fixture = make()
        let controller = try XCTUnwrap(fixture.open(WalletRoutes.wallet)?.controller as? WalletController)
        controller.load()
        await waitUntil("摘要没有到位") { controller.state.summary != nil }
        let owner = controller.state.owner
        let store = fixture.cleaner.store
        store.writeDraft(account: owner.account, loginEpoch: owner.loginEpoch, amount: "8.5", ticket: store.generation)
        XCTAssertNotNil(store.read(account: owner.account, loginEpoch: owner.loginEpoch), "前提：E1 摘要")
        XCTAssertEqual(store.readDraft(account: owner.account, loginEpoch: owner.loginEpoch), "8.5", "前提：E1 草稿")
        XCTAssertFalse(store.isPendingClear, "前提：没有待清理")
        try fixture.tokens.clear()
        fixture.store.failRead(nth: 1)
        let cold = coldWallet(fixture)
        XCTAssertEqual(cold.sessionKey, "", "初始化身份未知：不记判据")
        XCTAssertNotNil(store.read(account: owner.account, loginEpoch: owner.loginEpoch), "前提：身份未知时不删")
        cold.checkSession()
        let summary = store.read(account: owner.account, loginEpoch: owner.loginEpoch)
        let draft = store.readDraft(account: owner.account, loginEpoch: owner.loginEpoch)
        XCTAssertNil(summary, "旧摘要已删")
        XCTAssertNil(draft, "旧草稿已删")
        let left = ((try? FileManager.default.contentsOfDirectory(atPath: store.root.path)) ?? [])
            .filter { $0 != "pending_clear" }
        XCTAssertEqual(left, [], "缓存目录里没有残留分区与归属记录")
    }

    /// 同一组合上走生产初始化的冷启动钱包（同一缓存目录、同一网络层）。
    private func coldWallet(_ fixture: WalletAppFixture) -> AppWallet {
        let config = AppConfig(
            client: fixture.network.client, file: ClientFile(name: suiteName + "-cold.json"),
            environmentRegistry: EnvironmentSwitchCleanerRegistry(cleaners: [])
        )
        let runner = fixture.runner
        return AppWallet(
            network: fixture.network, config: config, routing: fixture.routing, login: fixture.login,
            mask: AmountMaskStore(defaults: defaults), cleaner: fixture.cleaner,
            credentialsReadable: { runner.credentialsReadable }
        )
    }
}
