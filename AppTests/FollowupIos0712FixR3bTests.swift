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

/// FU-IOS-0712 末轮窄修二（订单侧 RC-03）：识别换代的那一次读取就是归属对账用的身份，对账不再另读。
extension FollowupIos0712FixR1ColdStartTests {
    /// RC-03（订单）：会话世代不变、同账号 E1 → E2，换代识别那次读取成功、之后本次核对里的读取全部暂时失败（另读写法里对账那次在其中，
    /// 与之前还有几次读取无关）：旧分区照样删除；读取恢复后再核对也不留下 E1 列表缓存。
    func testEpochChangeWithOnlyReconcileReadFailureDeletesOldPartitionAfterRecovery() async throws {
        let fixture = OrdersAppFixture.make(suiteName: suiteName, defaults: defaults)
        let owner = try await seedOwnedCacheAndRecord(fixture)
        _ = fixture.orders.listPage(RouteDestination(route: "OrderList"))
        let generation = fixture.network.client.sessionGeneration
        try fixture.tokens.save(access: "at-e2", refresh: "rt-e2", scope: "full", account: "user-a")
        XCTAssertEqual(fixture.network.client.sessionGeneration, generation, "前提：会话世代不变")
        let fresh = try XCTUnwrap(fixture.tokens.loginEpoch)
        XCTAssertNotEqual(fresh, owner.loginEpoch)
        let start = fixture.store.reads
        fixture.store.failReads(fromNth: 2)
        fixture.orders.checkSession()
        let reads = fixture.store.reads
        fixture.store.stopFailing()
        XCTAssertEqual(fixture.orders.sessionKey.loginEpoch, fresh, "前提：换代识别成功")
        XCTAssertGreaterThanOrEqual(reads - start, 1, "前提：换代识别那次读取已发生")
        fixture.orders.checkSession()
        XCTAssertEqual(fixture.orders.sessionKey.loginEpoch, fresh, "恢复后判据仍是 E2")
        XCTAssertNil(listCache(fixture, owner), "E1 旧分区已删")
    }
}

/// FU-IOS-0712 末轮窄修二（钱包侧 RC-01～RC-03）。
final class FollowupIos0712FixR3bWalletTests: WalletFlowTestCase {
    /// RC-01：已确认 A/E1、会话世代不变；两次相邻读取之间只有一次暂时失败（另读写法里是判据那次）：不当换代——提现金额、读取禁用期、
    /// 已确认判据与页面固定身份都保留，读取恢复后也不重建。
    func testWalletSingleReadFailureBetweenAdjacentReadsIsNotASessionChange() async throws {
        let fixture = make()
        let controller = try await withdraw(fixture)
        await typeAmount(controller, "10")
        fixture.wallet.gates.read.start(30000)
        let key = fixture.wallet.sessionKey
        let owner = controller.owner
        XCTAssertEqual(controller.state.amountText, "10", "前提：已填金额")
        XCTAssertTrue(fixture.wallet.gates.read.active, "前提：禁用期中")
        XCTAssertEqual(owner.account, "user-a")
        let start = fixture.store.reads
        fixture.store.failRead(nth: 2)
        fixture.wallet.checkSession()
        fixture.wallet.checkSession()
        fixture.wallet.checkSession()
        let reads = fixture.store.reads
        let amount = controller.state.amountText
        let gated = fixture.wallet.gates.read.active
        let kept = fixture.wallet.sessionKey
        let current = controller.owner
        XCTAssertGreaterThanOrEqual(reads - start, 2, "前提：失败的那次读取已发生")
        XCTAssertEqual(amount, "10", "金额不清")
        XCTAssertTrue(gated, "禁用期不重置")
        XCTAssertEqual(kept, key, "已确认判据保留")
        XCTAssertEqual(current, owner, "页面固定身份不变（没有重建）")
    }

    /// RC-02：判据已记 A/E1，钱包路由通过守卫后、建页那一刻 Keychain 暂时读失败（页面固定身份没有账号）；读取恢复后再取页面：
    /// 判据不变也给这个页面换上 A/E1 身份并加载出摘要，不停在加载态。
    func testWalletPageBuiltWhileIdentityUnknownLoadsAfterRecovery() async throws {
        let fixture = make()
        let key = fixture.wallet.sessionKey
        XCTAssertTrue(key.hasPrefix("user-a#"), "前提：判据已记 A")
        fixture.router.open(RouteRequest(route: WalletRoutes.wallet, from: .inApp))
        let top = try XCTUnwrap(fixture.router.path.last)
        XCTAssertEqual(top.route, WalletRoutes.wallet, "前提：路由已通过守卫")
        fixture.tokens.failReads = .readFailed
        let entry = try XCTUnwrap(fixture.wallet.entry(for: top))
        fixture.tokens.failReads = nil
        let controller = try XCTUnwrap(entry.controller as? WalletController)
        XCTAssertNil(controller.state.owner.account, "前提：建页时身份未知")
        XCTAssertFalse(entry.identityKnown, "前提：记下建页时身份未确认")
        let again = try XCTUnwrap(fixture.wallet.entry(for: top))
        XCTAssertTrue(again === entry, "同一导航实例同一页面")
        XCTAssertEqual(fixture.wallet.sessionKey, key, "判据不变")
        XCTAssertEqual(controller.state.owner.account, "user-a", "恢复后换上已确认身份")
        await waitUntil("恢复后摘要没有加载") { controller.state.summary != nil || controller.state.phase == .error }
        let summary = controller.state.summary
        XCTAssertNotNil(summary, "恢复后能加载")
    }

    /// RC-03（钱包）：会话世代不变、同账号 E1 → E2，换代识别那次读取成功、紧接着的下一次读取暂时失败（另读写法里正是对账那次）：
    /// E1 摘要分区照样删除；读取恢复后再核对也不留下。
    func testWalletEpochChangeWithOnlyReconcileReadFailureDeletesOldPartitionAfterRecovery() async throws {
        let fixture = make()
        let controller = try XCTUnwrap(fixture.open(WalletRoutes.wallet)?.controller as? WalletController)
        controller.load()
        await waitUntil("摘要没有到位") { controller.state.summary != nil }
        let owner = controller.state.owner
        XCTAssertNotNil(fixture.cleaner.store.read(account: owner.account, loginEpoch: owner.loginEpoch), "前提：E1 摘要")
        let generation = fixture.network.client.sessionGeneration
        try fixture.tokens.save(access: "at-e2", refresh: "rt-e2", scope: "full", account: "user-a")
        XCTAssertEqual(fixture.network.client.sessionGeneration, generation, "前提：会话世代不变")
        let fresh = try XCTUnwrap(fixture.tokens.loginEpoch)
        XCTAssertNotEqual(fresh, owner.loginEpoch)
        let start = fixture.store.reads
        fixture.store.failRead(nth: 2)
        fixture.wallet.checkSession()
        XCTAssertTrue(fixture.wallet.sessionKey.hasSuffix("#" + fresh), "前提：换代识别成功")
        fixture.wallet.checkSession()
        fixture.wallet.checkSession()
        let reads = fixture.store.reads
        XCTAssertGreaterThanOrEqual(reads - start, 2, "前提：失败的那次读取已发生")
        let stale = fixture.cleaner.store.read(account: owner.account, loginEpoch: owner.loginEpoch)
        XCTAssertNil(stale, "E1 旧分区已删")
    }
}
