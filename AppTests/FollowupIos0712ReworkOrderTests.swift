@testable import Couli
import CouliNetwork
import Foundation
@testable import OrderCore
@testable import Orders
import Router
import Session
import XCTest

/// FU-IOS-0712 整体重理（订单侧）：一处身份快照 + 一套页面恢复机制，全部经生产入口（AppOrders 的 listPage / detailPage / checkSession）。
/// 异步结果一律等结算条件成立再断言；负向断言引用结算后取出的局部值。
/// 订单假服务的回答（整体重理用例共用）。
enum ReworkOrderStubs {
    static func envelope(_ data: String) -> AppStubProtocol.Reply {
        .json(status: 200, body: "{\"code\":0,\"msg\":\"\",\"data\":\(data),\"trace_id\":\"t\"}")
    }

    static let listBody = "{\"items\":[{\"order_id\":\"o1\",\"platform\":\"taobao\",\"title\":\"t\","
        + "\"image_url\":null,\"pay_amount_fen\":100,\"quantity\":1,\"order_no\":\"3712345678901234567\","
        + "\"display_status\":\"PAID\",\"reason\":null,\"est_rebate_fen\":1,\"paid_at\":\"2026-10-02T09:31:00+08:00\","
        + "\"is_other_product\":false}],\"next_cursor\":null,\"earliest_visible_date\":null}"

    static let detailBody = "{\"order_id\":\"o1\",\"platform\":\"taobao\",\"title\":\"t\",\"image_url\":null,"
        + "\"pay_amount_fen\":100,\"quantity\":1,\"order_no\":\"3712\",\"display_status\":\"PAID\",\"reason\":null,"
        + "\"est_rebate_fen\":1,\"paid_at\":null,\"is_other_product\":false,\"product_key\":\"tb:9007\","
        + "\"reason_action\":[],\"timeline\":[],\"expected_credit_period\":null,\"credit_overdue\":false,"
        + "\"actual_fen\":null,\"clawback_fen\":null,\"appeal_pending\":false,\"is_price_compare\":null}"
}

/// FU-IOS-0712 整体重理（订单侧）：一处身份快照 + 一套页面恢复机制，全部经生产入口（AppOrders 的 listPage / detailPage / checkSession）。
/// 异步结果一律等结算条件成立再断言；负向断言引用结算后取出的局部值。
extension FollowupIos0712FixR1ColdStartTests {
    /// 列表与详情都按成功回答（路径区分）。
    func serveOrders() {
        AppStubProtocol.install { request in
            ReworkOrderStubs.envelope(
                request.path.hasSuffix("/orders/o1") ? ReworkOrderStubs.detailBody : ReworkOrderStubs.listBody
            )
        }
    }

    // MARK: - 订单列表

    /// 发送前核对读失败：页面出现时那一次身份核对暂时失败 → 结算为「加载失败 +【重试】」（不是骨架）、记待补取、不发请求；身份确认
    /// （判据相同）时同一页同一轮次补取并加载出结果。
    func testReworkOrderListStartAbortedByUnknownIdentitySettlesThenResumesOnConfirmation() async {
        let fixture = OrdersAppFixture.make(suiteName: suiteName, defaults: defaults)
        serveOrders()
        let page = fixture.orders.listPage(RouteDestination(route: "OrderList"))
        let round = page.controller.snapshot.query.round
        fixture.store.failRead(nth: 1)
        page.controller.start()
        let aborted = page.controller.snapshot
        XCTAssertEqual(aborted.phase, .error, "不留无出口的加载态")
        XCTAssertTrue(aborted.identityPending, "记下身份未知中止")
        XCTAssertNil(aborted.error, "不是真的请求失败（显示「加载失败」+【重试】）")
        XCTAssertTrue(page.controller.deferral.isPending, "记待补取")
        XCTAssertEqual(AppStubProtocol.requests.count, 0, "身份未知不发请求")
        fixture.orders.checkSession()
        await waitUntil("补取后列表没有到位") { page.controller.snapshot.phase == .content }
        let loaded = page.controller.snapshot
        XCTAssertEqual(loaded.items.map(\.orderId), ["o1"], "同一页补取")
        XCTAssertEqual(loaded.query.round, round, "补取不开新轮次")
        XCTAssertFalse(loaded.identityPending)
        XCTAssertFalse(page.controller.deferral.isPending)
        XCTAssertTrue(fixture.orders.listConfig === page, "判据相同：同一页")
    }

    /// 响应核对读失败：第一页响应回来时身份核对暂时失败 → 不采用、在途标记复位、结算为可重试；【重试】按同一轮次补取并加载。
    func testReworkOrderListResponseCheckFailureSettlesAndRetryLoadsSameRound() async {
        let fixture = OrdersAppFixture.make(suiteName: suiteName, defaults: defaults)
        let store = fixture.store
        // 请求到达服务端时让之后的读取都暂时失败（响应回到主线程时的身份核对读不出）
        AppStubProtocol.install { _ in
            store.failReads(fromNth: 1)
            return ReworkOrderStubs.envelope(ReworkOrderStubs.listBody)
        }
        let page = fixture.orders.listPage(RouteDestination(route: "OrderList"))
        let round = page.controller.snapshot.query.round
        page.controller.start()
        await waitUntil("响应核对没有结算") { page.controller.snapshot.identityPending }
        store.stopFailing()
        let aborted = page.controller.snapshot
        XCTAssertEqual(aborted.phase, .error, "可重试的结算态")
        XCTAssertTrue(aborted.items.isEmpty, "核对失败的响应不采用")
        XCTAssertFalse(aborted.refreshing)
        serveOrders()
        XCTAssertTrue(page.controller.retry(), "【重试】受理")
        await waitUntil("重试后列表没有到位") { page.controller.snapshot.phase == .content }
        let loaded = page.controller.snapshot
        XCTAssertEqual(loaded.items.map(\.orderId), ["o1"])
        XCTAssertEqual(loaded.query.round, round, "身份中止后的重试不开新轮次")
    }

    /// 冷启动恢复：记录按已确认身份决策、恢复条件与锚点；第一页加载时身份暂时未知 → 恢复任务不放弃（锚点仍在）、记录不删；确认后补取，
    /// 恢复任务继续。
    func testReworkColdStartRestoreSurvivesUnknownIdentityAtFirstLoad() async throws {
        let fixture = OrdersAppFixture.make(suiteName: suiteName, defaults: defaults)
        _ = try await seedOwnedCacheAndRecord(fixture)
        let cold = coldOrders(fixture) { true }
        let page = cold.listPage(RouteDestination(route: "OrderList"))
        XCTAssertEqual(page.anchor.target, "o1", "前提：按已确认身份恢复到锚点")
        fixture.store.failRead(nth: 1)
        page.controller.start()
        var scrolled: [String] = []
        page.nextLoop = { $0() }
        page.restoreStep { scrolled.append($0) }
        XCTAssertTrue(page.anchor.restoring, "第一页身份未知中止：恢复任务不放弃")
        // 恢复任务这一步本身核对身份时也读失败：等待，不取消
        fixture.store.failRead(nth: 1)
        page.restoreStep { scrolled.append($0) }
        XCTAssertTrue(page.anchor.restoring, "恢复步身份未知：不取消")
        XCTAssertTrue(page.controller.deferral.isPending(OrderListController.anchorSlot), "恢复步登记待补做")
        XCTAssertEqual(cold.restorer.stored?.anchor, "o1", "恢复记录不删")
        serveOrders()
        cold.checkSession()
        await waitUntil("补取后列表没有到位") { page.controller.snapshot.phase == .content }
        page.restoreStep { scrolled.append($0) }
        let moved = scrolled
        XCTAssertEqual(moved, ["o1"], "确认后恢复到锚点")
    }

    // MARK: - 订单详情

    /// G54 / Android R2-03 同类：详情构造时那一次身份读取失败（固定身份未确认）→ 出现时结算为可重试（不是无出口的加载）；之后判据相同的
    /// 核对给同一页换上身份并加载（经 AppOrders 生产入口，无需手动 load）。
    func testReworkOrderDetailBuiltWhileUnknownLoadsAfterConfirmation() async throws {
        let fixture = OrdersAppFixture.make(suiteName: suiteName, defaults: defaults)
        serveOrders()
        let router = fixture.routing.router
        router.open(RouteRequest(route: "OrderDetail", values: ["order_id": .string("o1")], from: .inApp))
        let destination = try XCTUnwrap(router.path.last)
        // detailPage：判据核对（第 1 次读取，成功）→ 建页钉住的快照（第 2 次，暂时失败）
        fixture.store.failRead(nth: 2)
        let page = fixture.orders.detailPage(destination)
        XCTAssertFalse(page.controller.owner.identityKnown, "前提：构造时身份未确认")
        page.controller.start()
        let settled = page.controller.snapshot.phase
        XCTAssertEqual(settled, .error, "不留无出口的加载态")
        XCTAssertEqual(AppStubProtocol.requests.count, 0, "未确认身份不发请求")
        fixture.orders.checkSession()
        XCTAssertEqual(page.controller.owner.account, "user-a", "同一页换上已确认身份")
        await waitUntil("换上身份后详情没有到位") { page.controller.snapshot.phase == .content }
        let detail = page.controller.snapshot.detail
        XCTAssertEqual(detail?.summary.orderId, "o1")
    }

    /// 详情【重试】在身份暂时未知时：记待补取并请 App 立即核对一次——身份已恢复的就在同一次点击里换上 / 补取。
    func testReworkOrderDetailRetryWhileUnknownRechecksIdentity() async throws {
        let fixture = OrdersAppFixture.make(suiteName: suiteName, defaults: defaults)
        serveOrders()
        let router = fixture.routing.router
        router.open(RouteRequest(route: "OrderDetail", values: ["order_id": .string("o1")], from: .inApp))
        let destination = try XCTUnwrap(router.path.last)
        fixture.store.failRead(nth: 2)
        let page = fixture.orders.detailPage(destination)
        page.controller.start()
        XCTAssertEqual(page.controller.snapshot.phase, .error, "前提：结算为可重试")
        _ = page.controller.retry()
        await waitUntil("重试后详情没有到位") { page.controller.snapshot.phase == .content }
        let owner = page.controller.owner
        XCTAssertEqual(owner.account, "user-a", "重试触发核对、换上身份")
    }

    // MARK: - 换代判据

    /// 首次确认没有会话（初始化身份未知、之后确认令牌已不在）：按换代处理——共享禁用期重置、恢复记录删除、旧列表页换掉。
    func testReworkFirstConfirmedNoSessionResetsPagesAndGates() async throws {
        let fixture = OrdersAppFixture.make(suiteName: suiteName, defaults: defaults)
        _ = try await seedOwnedCacheAndRecord(fixture)
        try fixture.tokens.clear()
        // 初始化与打开订单 Tab 时身份都暂时未知（未知期间构造的列表页）
        fixture.store.failReads(fromNth: 1)
        let cold = coldOrders(fixture) { true }
        let early = cold.listPage(RouteDestination(route: "OrderList"))
        fixture.store.stopFailing()
        XCTAssertFalse(cold.sessionKey.known, "前提：身份未知")
        XCTAssertFalse(early.controller.owner.identityKnown, "前提：未知期间构造的列表页")
        XCTAssertEqual(cold.restorer.stored?.anchor, "o1", "前提：未知期间记录不删")
        cold.hub.gate.start(60000)
        cold.checkSession()
        let gateActive = cold.hub.gate.active
        XCTAssertFalse(gateActive, "共享禁用期重置")
        XCTAssertNil(cold.restorer.stored, "恢复记录删除")
        XCTAssertNil(cold.listConfig, "旧列表页换掉")
    }

    /// 身份暂时未知、会话世代已变（撤回 / 切环境竖起禁读屏障）：只作废内存显示（列表页换掉），不删恢复记录、不更新判据。
    func testReworkUnknownIdentityWithGenerationChangeOnlyInvalidatesMemory() async throws {
        let fixture = OrdersAppFixture.make(suiteName: suiteName, defaults: defaults)
        _ = try await seedOwnedCacheAndRecord(fixture)
        let key = fixture.orders.sessionKey
        XCTAssertNotNil(fixture.orders.listConfig, "前提：列表页在")
        fixture.network.client.raiseWithdrawalReadBarriers()
        fixture.orders.checkSession()
        let stored = fixture.orders.restorer.stored
        XCTAssertNil(fixture.orders.listConfig, "世代已变：旧页面作废")
        XCTAssertEqual(stored?.anchor, "o1", "身份未知：恢复记录不删")
        XCTAssertEqual(fixture.orders.sessionKey, key, "判据不更新")
    }

    // MARK: - F-X-21

    /// 缺持久化登录世代的合法旧会话：在线可用（列表加载出结果），断网缓存与恢复记录不读不写。
    func testReworkLegacySessionWithoutLoginEpochLoadsOnlineWithoutCacheOrRecord() async throws {
        let fixture = OrdersAppFixture.make(suiteName: suiteName, defaults: defaults)
        try fixture.tokens.save(access: "at", refresh: "rt", scope: "full", account: "user-a", loginEpoch: nil)
        fixture.orders.checkSession()
        serveOrders()
        let page = fixture.orders.listPage(RouteDestination(route: "OrderList"))
        XCTAssertNil(page.controller.owner.loginEpoch, "前提：缺世代")
        XCTAssertTrue(page.controller.owner.identityKnown, "缺世代不是身份未知")
        page.controller.start()
        await waitUntil("在线列表没有到位") { page.controller.snapshot.phase == .content }
        XCTAssertTrue(page.recordTop("o1"))
        fixture.orders.persist()
        let ownerFile = fixture.orders.cache.root.appendingPathComponent("owner")
        let cached = FileManager.default.fileExists(atPath: ownerFile.path)
        let stored = fixture.orders.restorer.stored
        XCTAssertEqual(page.controller.snapshot.items.map(\.orderId), ["o1"], "在线可用")
        XCTAssertFalse(cached, "不写断网缓存")
        XCTAssertNil(stored, "不写恢复记录")
    }

    // MARK: - 翻页、建页快照、撤回 / 切环境、待清理

    /// 翻页响应回来时身份核对读失败：不采用、翻页在途标记复位、记待补做；身份确认后再翻这一页。
    func testReworkOrderListLoadMoreAbortedResumesNextPage() async {
        let fixture = OrdersAppFixture.make(suiteName: suiteName, defaults: defaults)
        let store = fixture.store
        let counter = ReworkCounter()
        let firstPage = ReworkOrderStubs.listBody.replacingOccurrences(
            of: "\"next_cursor\":null", with: "\"next_cursor\":\"c2\""
        )
        let secondPage = ReworkOrderStubs.listBody.replacingOccurrences(of: "\"o1\"", with: "\"o2\"")
        AppStubProtocol.install { _ in
            if counter.next() == 1 {
                return ReworkOrderStubs.envelope(firstPage)
            }
            if counter.failing {
                store.failReads(fromNth: 1)
            }
            return ReworkOrderStubs.envelope(secondPage)
        }
        let page = fixture.orders.listPage(RouteDestination(route: "OrderList"))
        page.controller.start()
        await waitUntil("第一页没有到位") { page.controller.snapshot.phase == .content }
        counter.failing = true
        XCTAssertTrue(page.controller.loadMore(), "前提：翻页发出")
        await waitUntil("翻页响应核对没有结算") { page.controller.deferral.isPending }
        store.stopFailing()
        counter.failing = false
        let aborted = page.controller.snapshot
        XCTAssertFalse(aborted.loadingMore, "翻页在途标记复位")
        XCTAssertEqual(aborted.items.map(\.orderId), ["o1"], "核对失败的翻页不采用")
        fixture.orders.checkSession()
        await waitUntil("补做后第二页没有到位") { page.controller.snapshot.items.count == 2 }
        let items = page.controller.snapshot.items.map(\.orderId)
        XCTAssertEqual(items, ["o1", "o2"])
    }

    /// 建页只取一次身份快照：列表执行器、待跟单卡与恢复决策同一份（第 3 次读取失败不落到建页里）。
    func testReworkListPageBuildUsesOneSnapshot() {
        let fixture = OrdersAppFixture.make(suiteName: suiteName, defaults: defaults)
        AppStubProtocol.install { _ in .hold }
        // listPage：判据核对（第 1 次）→ 建页快照（第 2 次）；第 3 次读取失败不应落到建页里
        fixture.store.failRead(nth: 3)
        let page = fixture.orders.listPage(RouteDestination(route: "OrderList"))
        let card = page.pendingTrack?.owner
        XCTAssertTrue(page.controller.owner.identityKnown)
        XCTAssertTrue(page.controller.owner.member, "已登录（与账号同一次读取）")
        XCTAssertEqual(card, page.controller.owner, "待跟单卡与列表执行器同一次快照")
    }

    /// 未知期间构造的列表页上点【重试】：请 App 立即核对一次，身份已恢复就换上按已确认身份构造的新页面。
    func testReworkOrderListRetryOnUnknownBuiltPageRechecksIdentity() {
        let fixture = OrdersAppFixture.make(suiteName: suiteName, defaults: defaults)
        AppStubProtocol.install { _ in .hold }
        fixture.store.failRead(nth: 2)
        let page = fixture.orders.listPage(RouteDestination(route: "OrderList"))
        XCTAssertFalse(page.controller.owner.identityKnown, "前提：未知期间构造")
        page.controller.start()
        XCTAssertEqual(page.controller.snapshot.phase, .error, "前提：结算为可重试")
        _ = page.controller.retry()
        let replaced = fixture.orders.listConfig
        XCTAssertNil(replaced, "核对后换掉未知期间构造的页面（Tab 根按已确认身份重建）")
        XCTAssertTrue(page.controller.isLeft)
    }

    /// 撤回 / 切环境的清理回调按此刻快照重建后，判据随之记下：之后同样未知的核对不再重复作废。
    func testReworkCacheClearedAdoptsSnapshotSoNextCheckDefers() {
        let fixture = OrdersAppFixture.make(suiteName: suiteName, defaults: defaults)
        AppStubProtocol.install { _ in .hold }
        _ = fixture.orders.listPage(RouteDestination(route: "OrderList"))
        fixture.network.client.raiseWithdrawalReadBarriers()
        try? fixture.cleaner.cleanForEnvironmentSwitch()
        let epoch = fixture.orders.sessionEpoch
        fixture.orders.checkSession()
        let after = fixture.orders.sessionEpoch
        XCTAssertEqual(after, epoch, "已按此刻快照重建：不再重复作废")
    }

    /// 已登记的待清理与身份无关：会话中途身份暂时未知时，核对照样先完成清理（文件实际被删）。
    func testReworkCheckSessionCompletesPendingClearWhileUnknown() async throws {
        let fixture = OrdersAppFixture.make(suiteName: suiteName, defaults: defaults)
        let owner = try await seedOwnedCacheAndRecord(fixture)
        XCTAssertTrue(fixture.orders.cache.markPendingClear(), "前提：持久待清理标记")
        fixture.store.failRead(nth: 1)
        fixture.orders.checkSession()
        let pending = fixture.orders.cache.isPendingClear
        XCTAssertFalse(pending, "待清理已完成")
        XCTAssertNil(listCache(fixture, owner), "列表缓存实际被删")
    }
}

/// 假服务回答计数（URLProtocol 线程与测试线程共用）。
final class ReworkCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private var flag = false

    func next() -> Int {
        lock.withLock {
            count += 1
            return count
        }
    }

    var failing: Bool {
        get { lock.withLock { flag } }
        set { lock.withLock { flag = newValue } }
    }
}
