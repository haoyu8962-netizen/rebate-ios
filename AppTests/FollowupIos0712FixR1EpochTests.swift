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

/// FU-IOS-0712 第 1 轮修复 R1-01（S0）：按「账号 + 持久化登录世代」分区的本机数据，归属一律来自执行器 / 页面构造时固定的身份，写入时
/// 不再读当前世代。交错点：旧响应（或旧页面的保存）已通过最后一次身份核对、实际写入之前（写入路径里第一次核对缓存目录之外的待清理标记时）
/// 同账号重新登录（新世代）。断言：新世代的分区读不到旧数据（内存与重建进程两种）；会话换代对账不保留这份旧数据。
@MainActor
final class FollowupIos0712FixR1EpochTests: WalletFlowTestCase {
    private static let fullOrderNo = "3712345678901234567"

    private static func envelope(_ data: String) -> AppStubProtocol.Reply {
        .json(status: 200, body: "{\"code\":0,\"msg\":\"\",\"data\":\(data),\"trace_id\":\"t\"}")
    }

    private static let listBody = "{\"items\":[{\"order_id\":\"o1\",\"platform\":\"taobao\",\"title\":\"t\","
        + "\"image_url\":null,\"pay_amount_fen\":100,\"quantity\":1,\"order_no\":\"\(fullOrderNo)\","
        + "\"display_status\":\"PAID\",\"reason\":null,\"est_rebate_fen\":1,\"paid_at\":\"2026-10-02T09:31:00+08:00\","
        + "\"is_other_product\":false}],\"next_cursor\":null,\"earliest_visible_date\":null}"

    override func tearDown() {
        AppStubProtocol.reset()
        try? FileManager.default
            .removeItem(at: FileManager.default.temporaryDirectory.appendingPathComponent(suiteName))
        super.tearDown()
    }

    private func orders(_ flag: InterleavingFlag) -> OrdersAppFixture {
        OrdersAppFixture.make(suiteName: suiteName, defaults: defaults, cacheFlag: flag)
    }

    private func wallet(_ flag: InterleavingFlag) -> WalletAppFixture {
        WalletAppFixture.make(suiteName: suiteName, defaults: defaults, cacheFlag: flag)
    }

    /// 同账号重新登录（新世代）：退出（会话世代 +1）后同一账号再登录，令牌存储换新的登录世代。返回新世代。
    private static func relogin(_ client: ApiClient, _ tokens: MemorySessionTokens) -> String? {
        client.signOut()
        try? tokens.save(access: "at-relogin", refresh: "rt-relogin", scope: "full", account: "user-a")
        return tokens.loginEpoch
    }

    /// 根目录下的分区目录（不含 owner 文件与标记）。
    private func partitions(_ root: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []).filter {
            $0 != "owner" && $0 != "pending_clear"
        }
    }

    // MARK: - 订单列表断网缓存

    func testLateOrderListWriteAfterSameAccountReloginStaysOutOfTheNewLoginPartition() async throws {
        let flag = InterleavingFlag()
        let fixture = orders(flag)
        AppStubProtocol.install { _ in Self.envelope(Self.listBody) }
        let list = fixture.orders.listPage(RouteDestination(route: "OrderList"))
        let fixed = try XCTUnwrap(list.controller.owner.loginEpoch, "前提：页面固定了登录世代")
        var newEpoch: String?
        // 结算里的身份核对（ownerCurrent）已经通过、snapshot 已是 content，接下来就是写缓存：此时同账号重新登录
        flag.hook = { [list, fixture] in
            guard list.controller.snapshot.phase == .content else { return false }
            newEpoch = Self.relogin(fixture.network.client, fixture.tokens)
            return true
        }
        list.controller.start()
        for _ in 0..<400 where list.controller.snapshot.phase != .content {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertEqual(list.controller.snapshot.phase, .content)
        XCTAssertTrue(flag.fired, "前提：交错发生在写入路径里")
        let fresh = try XCTUnwrap(newEpoch)
        XCTAssertNotEqual(fresh, fixed)
        let cache = fixture.orders.cache
        let scope = OrderQuery.selfScope
        XCTAssertEqual(fixture.orders.currentOwner().loginEpoch, fresh, "此刻打开的页面固定的是新世代")
        // 内存：新世代的分区读不到；旧数据只落在它自己那一代
        XCTAssertNil(cache.readList(account: "user-a", loginEpoch: fresh, scope: scope), "新世代读不到旧响应")
        XCTAssertNotNil(cache.readList(account: "user-a", loginEpoch: fixed, scope: scope), "旧响应只写进旧世代的分区")
        // 重建进程：同一目录上的新存储
        let rebuilt = OrderCacheStore(root: cache.root)
        rebuilt.partitionedByLoginEpoch = true
        XCTAssertNil(rebuilt.readList(account: "user-a", loginEpoch: fresh, scope: scope), "重建后新世代仍读不到")
        // 会话换代对账（AppOrders.sessionChanged）：归属是旧世代，整体删除，不保留
        fixture.orders.checkSession()
        XCTAssertNil(cache.readList(account: "user-a", loginEpoch: fixed, scope: scope), "对账删掉旧世代的缓存")
        XCTAssertEqual(partitions(cache.root), [], "盘上不留旧世代分区")
        let again = OrderCacheStore(root: cache.root)
        again.partitionedByLoginEpoch = true
        XCTAssertNil(again.readList(account: "user-a", loginEpoch: fresh, scope: scope))
        XCTAssertNil(again.readList(account: "user-a", loginEpoch: fixed, scope: scope))
    }

    // MARK: - 订单恢复记录

    func testLateRestoreRecordSaveAfterSameAccountReloginIsNotRestoredByTheNewLogin() throws {
        let flag = InterleavingFlag()
        let fixture = orders(flag)
        AppStubProtocol.install { _ in .hold }
        let list = fixture.orders.listPage(RouteDestination(route: "OrderList"))
        let fixed = try XCTUnwrap(list.controller.owner.loginEpoch)
        list.controller.updateSearchText(Self.fullOrderNo)
        list.controller.submitSearch()
        var newEpoch: String?
        // 保存入口的页面身份核对（page.isCurrent）已通过，接下来核对待清理状态、写记录：此时同账号重新登录
        flag.hook = { [fixture] in
            newEpoch = Self.relogin(fixture.network.client, fixture.tokens)
            return true
        }
        fixture.orders.persist()
        XCTAssertTrue(flag.fired, "前提：交错发生在保存路径里")
        let fresh = try XCTUnwrap(newEpoch)
        let cache = fixture.orders.cache
        if let stored = fixture.orders.restorer.stored {
            XCTAssertEqual(
                stored.owner, cache.partitionKey(account: "user-a", loginEpoch: fixed), "写下的只能是旧世代的归属"
            )
        }
        XCTAssertNotEqual(
            fixture.orders.restorer.stored?.owner, cache.partitionKey(account: "user-a", loginEpoch: fresh),
            "不按新世代补绑"
        )
        // 重建进程：新世代的页面决策不恢复旧页面的搜索词
        let restarted = OrderPageRestorer(file: OrderPageStateFile(url: cache.pageState.url), unit: nil)
        restarted.partitionKey = { cache.partitionKey(account: $0, loginEpoch: $1) }
        XCTAssertNil(restarted.decide(account: "user-a", loginEpoch: fresh), "重建后新世代不恢复")
        // 内存：会话换代后新页面也不恢复
        fixture.orders.checkSession()
        let next = fixture.orders.listPage(RouteDestination(route: "OrderList"))
        XCTAssertEqual(next.controller.owner.loginEpoch, fresh)
        XCTAssertNotEqual(next.controller.snapshot.query.conditions.keyword, Self.fullOrderNo, "新世代页面不带旧搜索词")
        XCTAssertNil(fixture.orders.restorer.stored, "换代对账删掉旧记录")
    }

    // MARK: - 钱包摘要

    func testLateWalletSummaryWriteAfterSameAccountReloginStaysOutOfTheNewLoginPartition() async throws {
        let flag = InterleavingFlag()
        let fixture = wallet(flag)
        let controller = try XCTUnwrap(fixture.open(WalletRoutes.wallet)?.controller as? WalletController)
        let fixed = try XCTUnwrap(controller.state.owner.loginEpoch)
        var newEpoch: String?
        // 回调里的身份核对（isCurrent）已通过，onResult 写缓存时：同账号重新登录
        flag.hook = { [fixture] in
            newEpoch = Self.relogin(fixture.network.client, fixture.tokens)
            return true
        }
        controller.load()
        await waitUntil("摘要没有到位") { controller.state.summary != nil }
        XCTAssertTrue(flag.fired, "前提：交错发生在写入路径里")
        let fresh = try XCTUnwrap(newEpoch)
        XCTAssertNotEqual(fresh, fixed)
        let store = fixture.cleaner.store
        XCTAssertEqual(fixture.wallet.currentOwner().loginEpoch, fresh)
        XCTAssertNil(store.read(account: "user-a", loginEpoch: fresh), "新世代读不到旧响应")
        XCTAssertNotNil(store.read(account: "user-a", loginEpoch: fixed), "旧响应只写进旧世代的分区")
        let rebuilt = WalletCacheStore(root: store.root)
        rebuilt.partitionedByLoginEpoch = true
        XCTAssertNil(rebuilt.read(account: "user-a", loginEpoch: fresh), "重建后新世代仍读不到")
        fixture.wallet.checkSession()
        XCTAssertNil(store.read(account: "user-a", loginEpoch: fixed), "换代对账删掉旧世代的缓存")
        XCTAssertEqual(partitions(store.root), [])
    }

    // MARK: - 提现金额草稿

    func testLateAmountDraftWriteAfterSameAccountReloginIsNotRestoredByTheNewLogin() async throws {
        let flag = InterleavingFlag()
        let fixture = wallet(flag)
        let controller = try await withdraw(fixture)
        let fixed = try XCTUnwrap(controller.flow.owner.loginEpoch)
        var newEpoch: String?
        // saveDraft 的表单身份核对（ownsForm）已通过，写草稿时：同账号重新登录
        flag.hook = { [fixture] in
            newEpoch = Self.relogin(fixture.network.client, fixture.tokens)
            return true
        }
        actions(controller).amount("8.5")
        XCTAssertTrue(flag.fired, "前提：交错发生在写入路径里")
        let fresh = try XCTUnwrap(newEpoch)
        let store = fixture.cleaner.store
        XCTAssertNil(store.readDraft(account: "user-a", loginEpoch: fresh), "新世代读不到旧草稿")
        XCTAssertEqual(store.readDraft(account: "user-a", loginEpoch: fixed), "8.5", "旧草稿只写进旧世代的分区")
        let rebuilt = WalletCacheStore(root: store.root)
        rebuilt.partitionedByLoginEpoch = true
        XCTAssertNil(rebuilt.readDraft(account: "user-a", loginEpoch: fresh), "重建后新世代仍不恢复")
        fixture.wallet.checkSession()
        XCTAssertNil(store.readDraft(account: "user-a", loginEpoch: fixed), "换代对账删掉旧世代的草稿")
        XCTAssertEqual(partitions(store.root), [])
    }

    // MARK: - 第 2 轮修复 R2-02：最后一次身份核对通过之后、写入参数求值之前同账号重登

    /// 交错点在 App 的身份核对（`identityCheckPassed`）：核对已通过、调用方接着求值写入参数。固定身份的写法读到的是 E1；
    /// 若写入参数改成读当前身份（变异 a～c），就会取到 E2，把旧数据写进新世代——下面的「新世代读回 / 重建读回」断言随即失败。
    func testOrderListWriteArgumentsAfterTheLastIdentityCheckUseTheFixedLoginEpoch() async throws {
        let fixture = orders(InterleavingFlag())
        AppStubProtocol.install { _ in Self.envelope(Self.listBody) }
        let list = fixture.orders.listPage(RouteDestination(route: "OrderList"))
        let fixed = try XCTUnwrap(list.controller.owner.loginEpoch)
        var newEpoch: String?
        fixture.orders.identityCheckPassed = { [list, fixture] in
            // 结算里写缓存之前的那次核对（snapshot 已是 content）
            guard newEpoch == nil, list.controller.snapshot.phase == .content else { return }
            newEpoch = Self.relogin(fixture.network.client, fixture.tokens)
        }
        list.controller.start()
        for _ in 0..<400 where list.controller.snapshot.phase != .content {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        let fresh = try XCTUnwrap(newEpoch, "前提：交错发生在最后一次核对之后")
        XCTAssertNotEqual(fresh, fixed)
        let scope = OrderQuery.selfScope
        XCTAssertNil(fixture.orders.cache.readList(account: "user-a", loginEpoch: fresh, scope: scope), "新世代读不回")
        let rebuilt = OrderCacheStore(root: fixture.orders.cache.root)
        rebuilt.partitionedByLoginEpoch = true
        XCTAssertNil(rebuilt.readList(account: "user-a", loginEpoch: fresh, scope: scope), "重建后新世代读不回")
        XCTAssertNotNil(
            fixture.orders.cache.readList(account: "user-a", loginEpoch: fixed, scope: scope), "旧数据只在旧世代"
        )
    }

    func testWalletSummaryWriteArgumentsAfterTheLastIdentityCheckUseTheFixedLoginEpoch() async throws {
        let fixture = wallet(InterleavingFlag())
        let controller = try XCTUnwrap(fixture.open(WalletRoutes.wallet)?.controller as? WalletController)
        let fixed = try XCTUnwrap(controller.state.owner.loginEpoch)
        controller.load()
        // 请求已发出；下一次核对是响应回调里的那次（通过后紧接着 onResult 写缓存）
        var newEpoch: String?
        fixture.wallet.identityCheckPassed = { [fixture] in
            guard newEpoch == nil else { return }
            newEpoch = Self.relogin(fixture.network.client, fixture.tokens)
        }
        await waitUntil("摘要没有到位") { controller.state.summary != nil }
        let fresh = try XCTUnwrap(newEpoch)
        XCTAssertNotEqual(fresh, fixed)
        let store = fixture.cleaner.store
        XCTAssertNil(store.read(account: "user-a", loginEpoch: fresh), "新世代读不回")
        let rebuilt = WalletCacheStore(root: store.root)
        rebuilt.partitionedByLoginEpoch = true
        XCTAssertNil(rebuilt.read(account: "user-a", loginEpoch: fresh), "重建后新世代读不回")
        XCTAssertNotNil(store.read(account: "user-a", loginEpoch: fixed), "旧数据只在旧世代")
    }

    func testAmountDraftWriteArgumentsAfterTheLastIdentityCheckUseTheFixedLoginEpoch() async throws {
        let fixture = wallet(InterleavingFlag())
        let controller = try await withdraw(fixture)
        let owner = controller.flow.owner
        let fixed = try XCTUnwrap(owner.loginEpoch)
        actions(controller).amount("8.5")
        var newEpoch: String?
        fixture.wallet.identityCheckPassed = { [fixture] in
            guard newEpoch == nil else { return }
            newEpoch = Self.relogin(fixture.network.client, fixture.tokens)
        }
        // 保存草稿：表单身份核对（ownsForm）通过之后、写入参数求值之前同账号重登
        controller.saveDraft(owner)
        let fresh = try XCTUnwrap(newEpoch)
        let store = fixture.cleaner.store
        XCTAssertNil(store.readDraft(account: "user-a", loginEpoch: fresh), "新世代读不回旧草稿")
        let rebuilt = WalletCacheStore(root: store.root)
        rebuilt.partitionedByLoginEpoch = true
        XCTAssertNil(rebuilt.readDraft(account: "user-a", loginEpoch: fresh), "重建后新世代读不回")
        XCTAssertEqual(store.readDraft(account: "user-a", loginEpoch: fixed), "8.5", "旧草稿只在旧世代")
    }
}

/// 缓存目录之外的待清理标记（内存版），带一次性交错钩子：写入路径第一次核对待清理状态时执行 `hook`（返回 true 才算执行过、之后不再执行）。
final class InterleavingFlag: OrderPendingClearFlag, @unchecked Sendable {
    var hook: (@MainActor () -> Bool)?
    private(set) var fired = false
    private var value = false

    func isSet() -> Bool {
        if let hook, !fired {
            fired = MainActor.assumeIsolated { hook() }
        }
        return value
    }

    func set() -> Bool {
        value = true
        return true
    }

    func clear() -> Bool {
        value = false
        return true
    }
}
