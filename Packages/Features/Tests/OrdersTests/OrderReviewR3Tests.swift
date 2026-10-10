import Clipboard
import CouliNetwork
import Foundation
@testable import OrderCore
@testable import Orders
import XCTest

/// APP-08 iOS 第 3 轮评审（NATIVE/APP-08/ios-review-r3.md）：
/// - R3-01：恢复记录放在报告成败的原子文件里；删除没确认（removeItem 失败）时保留待清理 / 禁止恢复与写入并重试；旧 UserDefaults 记录只删不读
///   （共性第 40 条）；
/// - R3-02：列表与详情【复制】回调携带渲染时票据（页面、会话版本、查询轮次 / 详情版本、单号），换代后执行零写入（共性第 41 条）；
/// - R3-03：待跟单卡通知与关闭入口携带渲染时票据；换代并重新显示同一张卡后执行旧回调：不记「点过」、不申请、不发关闭（共性第 42 条）。
@MainActor
final class OrderReviewR3Tests: XCTestCase {
    private var env = FakeOrderEnv()

    override func setUp() async throws {
        env = FakeOrderEnv()
    }

    private static let fullNo = "3712345678901234567"

    private func record(_ account: String = "a", keyword: String = OrderReviewR3Tests.fullNo) -> OrderPageRecord {
        OrderPageRecord(
            owner: OrderCacheStore.hash(account),
            conditions: OrderConditions(scope: OrderQuery.selfScope, keyword: keyword), anchor: "o8"
        )
    }

    private struct DiskFailure: Error {}

    // MARK: - R3-01

    /// 评审场景：恢复记录删不掉（磁盘删除失败），缓存目录能正常清理 → 清理不算完成、待清理标记保留（不删外部标记）；重启后先完成清理。
    func testPageStateRemoveFailureKeepsPendingFlag() throws {
        let root = temporaryDirectory()
        let store = OrderCacheStore(root: root)
        try store.pageState.save(JSONEncoder().encode(record()))
        store.pageState.remover = { _ in throw DiskFailure() }
        XCTAssertThrowsError(try store.clearAll(), "恢复记录没确认删除：清理不算完成")
        XCTAssertTrue(store.isPendingClear, "缓存目录之外的待清理标记保留")
        XCTAssertTrue(OrderSiblingPendingFlag(root: root).isSet())
        XCTAssertTrue(store.pageState.exists, "前提：磁盘上的记录还在")
        // 重启（新的实例，删除恢复正常）：第一次核验先完成清理
        let restarted = OrderCacheStore(root: root)
        XCTAssertTrue(restarted.isPendingClear)
        restarted.reconcileOwner(account: "a")
        XCTAssertFalse(restarted.isPendingClear)
        XCTAssertFalse(restarted.pageState.exists)
    }

    /// 会话换代的删除没确认：之后不恢复、不写入；删除恢复正常后，下一次保存先重试删除再写。
    func testRestorerEraseFailureBlocksRestoreAndPersistUntilRetried() throws {
        let file = OrderPageStateFile.beside(root: temporaryDirectory())
        try file.save(JSONEncoder().encode(record()))
        let restorer = OrderPageRestorer(file: file)
        XCTAssertEqual(restorer.decide(account: "a"), record(), "前提：同账号恢复")
        file.remover = { _ in throw DiskFailure() }
        XCTAssertFalse(restorer.clear(), "删除失败如实报告")
        XCTAssertTrue(restorer.eraseOutstanding)
        restorer.persist(
            conditions: OrderConditions(scope: OrderQuery.selfScope, keyword: "x"),
            anchor: nil,
            account: "b"
        )
        XCTAssertEqual(restorer.stored, record(), "删除没确认：不写入新记录（磁盘上仍是旧的，等重试删除）")
        // 另一实例读到别的账号的记录要删、删不掉：不恢复，并记下待重试
        let other = OrderPageRestorer(file: file)
        XCTAssertNil(other.decide(account: "b"))
        XCTAssertTrue(other.eraseOutstanding)
        file.remover = { url in try FileManager.default.removeItem(at: url) }
        restorer.persist(conditions: OrderConditions(scope: OrderQuery.selfScope), anchor: nil, account: "b")
        XCTAssertFalse(restorer.eraseOutstanding, "重试删除成功")
        XCTAssertEqual(restorer.stored?.owner, OrderCacheStore.hash("b"))
        XCTAssertNil(restorer.stored?.conditions.keyword, "旧账号的完整订单号已删")
    }

    /// 旧版本留在 UserDefaults 的记录（含完整订单号）：不迁移、不恢复，决策时删除；清理单元也删。
    func testLegacyUserDefaultsRecordNeverRestoredAndErased() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString))
        defaults.set(try JSONEncoder().encode(record()), forKey: OrderPageStateFile.legacyKey)
        let root = temporaryDirectory()
        let store = OrderCacheStore(root: root, legacyPageStateDefaults: defaults)
        let restorer = OrderPageRestorer(file: store.pageState)
        XCTAssertNil(restorer.decide(account: "a"), "旧记录不用来恢复")
        XCTAssertNil(defaults.object(forKey: OrderPageStateFile.legacyKey), "决策时删掉旧记录")
        defaults.set(try JSONEncoder().encode(record()), forKey: OrderPageStateFile.legacyKey)
        try store.clearAll()
        XCTAssertNil(defaults.object(forKey: OrderPageStateFile.legacyKey), "撤回 / 切环境的清理一并删除旧记录")
    }

    /// 记录读不出（I/O 故障，不是「没有文件」）：不恢复。
    func testUnreadableRecordIsNotRestored() throws {
        let file = OrderPageStateFile.beside(root: temporaryDirectory())
        try FileManager.default.createDirectory(at: file.url, withIntermediateDirectories: true)
        XCTAssertThrowsError(try file.load())
        let restorer = OrderPageRestorer(file: file)
        XCTAssertNil(restorer.decide(account: "a"))
    }

    // MARK: - R3-02 列表

    private func loadedPage() async -> (OrderListPageConfig, CountingClipboard) {
        let body = OrderFixtures.page([
            OrderFixtures.row("o1", number: Self.fullNo), OrderFixtures.row("s1", masked: "3712****67"),
        ])
        OrdersStub.install { _ in OrderFixtures.ok(body) }
        let controller = OrderListController(api: makeOrdersClient(), gate: OrderRateGate(), env: env, cache: nil)
        let page = OrderListPageConfig(controller: controller, texts: OrderDraftTexts(), mask: AmountMaskStore(
            defaults: UserDefaults(suiteName: UUID().uuidString) ?? .standard
        ), pendingTrack: nil)
        let system = CountingClipboard()
        let writer = ClipboardWriter(system: system, ledger: ClipboardWriteLedger(store: MemoryClipboardHashStore()))
        page.copy = { writer.write($0) }
        controller.start()
        await eventually { controller.snapshot.phase == .content }
        return (page, system)
    }

    /// 与 OrdersScreen 的 ForEach 同一写法：渲染这一刻取票据，回调只捕获它。
    private func renderedCopy(_ page: OrderListPageConfig, _ id: String) throws -> () -> Void {
        let item = try XCTUnwrap(page.controller.snapshot.items.first { $0.orderId == id })
        let ticket = page.copyTicket(item)
        let rendered = OrderNumberDisplay.view(item).text ?? ""
        return { page.copyOrderNo(ticket, rendered: rendered) }
    }

    func testListCopyWritesOnceWhenValidAndShareHasNoTicket() async throws {
        let (page, system) = await loadedPage()
        try renderedCopy(page, "o1")()
        XCTAssertEqual(system.writes, [Self.fullNo], "对照：有效时经统一写入口写一次")
        XCTAssertEqual(page.toastKey?.key, "order_detail.copy.done")
        let share = try XCTUnwrap(page.controller.snapshot.items.first { $0.orderId == "s1" })
        XCTAssertNil(page.copyTicket(share), "分享单没有复制路径")
    }

    /// 保留旧卡片的【复制】回调 → 会话 / 隐私 / 环境版本换代（页面配置本身还在）→ 执行：零写入、不提示。
    func testOldListCopyCallbackAfterAppTicketChangeWritesNothing() async throws {
        let (page, system) = await loadedPage()
        let old = try renderedCopy(page, "o1")
        env.appTicket += 1
        old()
        XCTAssertTrue(system.writes.isEmpty, "换代后旧回调零写入")
        XCTAssertNil(page.toastKey)
    }

    /// 保留旧回调 → 页面失效（invalidate、执行器 leave）→ 执行：零写入。
    func testOldListCopyCallbackAfterInvalidateWritesNothing() async throws {
        let (page, system) = await loadedPage()
        let old = try renderedCopy(page, "o1")
        page.invalidate()
        page.controller.leave()
        old()
        XCTAssertTrue(system.writes.isEmpty)
    }

    /// 保留旧回调 → 新一轮查询（刷新）重新显示同一张卡 → 执行旧回调：零写入；新渲染的回调照常写。
    func testOldListCopyCallbackAfterNewRoundRedisplayWritesNothing() async throws {
        let (page, system) = await loadedPage()
        let old = try renderedCopy(page, "o1")
        let round = page.controller.snapshot.query.round
        _ = page.controller.refresh()
        await eventually { page.controller.snapshot.query.round != round && !page.controller.snapshot.refreshing }
        XCTAssertNotNil(page.controller.snapshot.items.first { $0.orderId == "o1" }, "前提：同一张卡重新显示")
        old()
        XCTAssertTrue(system.writes.isEmpty, "旧轮次的回调零写入")
        try renderedCopy(page, "o1")()
        XCTAssertEqual(system.writes, [Self.fullNo], "新渲染的回调照常")
    }

    // MARK: - R3-02 详情

    private func loadedDetail() async -> (OrderDetailController, CountingClipboard) {
        OrdersStub.install { _ in OrderFixtures.ok(OrderFixtures.detail("o1", number: Self.fullNo)) }
        let page = OrderDetailController(
            api: makeOrdersClient(),
            orderId: "o1",
            gate: OrderRateGate(),
            env: env,
            cache: nil
        )
        let system = CountingClipboard()
        let writer = ClipboardWriter(system: system, ledger: ClipboardWriteLedger(store: MemoryClipboardHashStore()))
        page.copy = { writer.write($0) }
        page.start()
        await eventually { page.snapshot.phase == .content }
        return (page, system)
    }

    func testOldDetailCopyCallbackAfterTicketChangeOrSessionWritesNothing() async {
        let (page, system) = await loadedDetail()
        let ticket = page.copyTicket()
        let old = { page.copyOrderNo(ticket, rendered: Self.fullNo) }
        env.appTicket += 1
        old()
        XCTAssertTrue(system.writes.isEmpty, "会话 / 环境版本换代：零写入")
        env.appTicket -= 1
        old()
        XCTAssertEqual(system.writes.count, 1, "对照：版本一致时写一次")
        page.sessionChanged()
        old()
        XCTAssertEqual(system.writes.count, 1, "清空后零写入")
    }

    /// 保留旧回调 → 刷新换了内容（单号不同）→ 执行：零写入（不按旧单号写）。
    func testOldDetailCopyCallbackAfterContentChangeWritesNothing() async {
        let (page, system) = await loadedDetail()
        let ticket = page.copyTicket()
        let old = { page.copyOrderNo(ticket, rendered: Self.fullNo) }
        OrdersStub.install { _ in OrderFixtures.ok(OrderFixtures.detail("o1", number: "3799999999999999999")) }
        XCTAssertTrue(page.refresh())
        await eventually { page.snapshot.detail?.summary.orderNo == "3799999999999999999" }
        old()
        XCTAssertTrue(system.writes.isEmpty)
    }
}

/// R3-03：待跟单卡通知与关闭入口的渲染时票据（共性第 42 条）。
@MainActor
final class OrderReviewR3PendingTests: XCTestCase {
    private var env = FakeOrderEnv()

    override func setUp() async throws {
        env = FakeOrderEnv()
    }

    // MARK: - R3-03

    private func hub() throws -> OrderSessionHub {
        try OrderSessionHub(
            defaults: XCTUnwrap(UserDefaults(suiteName: UUID().uuidString)), notification: PendingTrackRaw.notDetermined
        )
    }

    private func shownCards(_ hub: OrderSessionHub) async -> PendingTrackService {
        OrdersStub.install { request in
            request.method == "POST" ? OrderFixtures.ok("{}")
                : OrderFixtures.ok(OrderFixtures.tracks([.init("L1", "a1", "taobao", false)]))
        }
        let cards = PendingTrackService(api: makeOrdersClient(), hub: hub, env: env, platform: "taobao")
        cards.refresh()
        await eventually { cards.state.cards.first?.notificationRow == true }
        return cards
    }

    /// 评审场景：保留旧通知按钮回调 → 会话换代（同账号重新登录）→ 同一 slot 再次拉到同一 link_id / attempt_id 的卡 → 执行旧回调：
    /// 不记设备级「点过」、不申请系统通知；新渲染的回调照常。
    func testOldNotifyCallbackAfterSessionChangeAndRedisplayDoesNothing() async throws {
        let hub = try hub()
        let cards = await shownCards(hub)
        let old = try cards.ticket(for: XCTUnwrap(cards.state.cards.first))
        hub.sessionChanged()
        XCTAssertTrue(cards.state.cards.isEmpty)
        cards.refresh()
        await eventually { cards.state.cards.first?.notificationRow == true }
        XCTAssertEqual(cards.state.cards.first?.key, old.card.key, "前提：同一张卡重新显示")
        cards.requestNotification(old)
        await settle()
        XCTAssertFalse(hub.pushRowUsed, "旧回调不写「点过」")
        XCTAssertEqual(env.pushRequests, 0, "旧回调不申请")
        XCTAssertEqual(cards.state.cards.first?.notificationRow, true)
        cards.requestNotification(try cards.ticket(for: XCTUnwrap(cards.state.cards.first)))
        await eventually { self.env.pushRequests == 1 }
        XCTAssertTrue(hub.pushRowUsed)
    }

    /// App 侧版本换代（撤回 / 切环境 / 会话世代）而卡片没重画：旧回调同样零动作。
    func testOldNotifyCallbackAfterAppTicketChangeDoesNothing() async throws {
        let hub = try hub()
        let cards = await shownCards(hub)
        let old = try cards.ticket(for: XCTUnwrap(cards.state.cards.first))
        env.appTicket += 1
        cards.requestNotification(old)
        await settle()
        XCTAssertFalse(hub.pushRowUsed)
        XCTAssertEqual(env.pushRequests, 0)
    }

    /// 异步等待沿用点击时的票据：等待期间 App 侧版本变了又变回去之外的任何变化都让复核失败（这里：会话换代后同一张卡重新显示）。
    func testPushWaitKeepsClickTicket() async throws {
        let hub = try hub()
        let cards = await shownCards(hub)
        env.holdStatus = true
        cards.requestNotification(try cards.ticket(for: XCTUnwrap(cards.state.cards.first)))
        await eventually { self.env.waitingStatus }
        hub.sessionChanged()
        cards.refresh()
        await eventually { !cards.state.cards.isEmpty }
        env.finishStatusWait()
        await settle()
        XCTAssertEqual(env.systemPrompts, 0, "等待结束按点击时的票据复核：不弹系统框")
    }

    /// 关闭入口：保留旧回调 → 会话换代并重新显示同一张卡 → 执行：不发关闭；新回调照常发。
    func testOldDismissCallbackAfterSessionChangeAndRedisplaySendsNothing() async throws {
        let hub = try hub()
        let cards = await shownCards(hub)
        let old = try cards.ticket(for: XCTUnwrap(cards.state.cards.first))
        hub.sessionChanged()
        cards.refresh()
        await eventually { !cards.state.cards.isEmpty }
        let posts = OrdersStub.requests.filter { $0.method == "POST" }.count
        XCTAssertFalse(cards.dismiss(old))
        await settle()
        XCTAssertEqual(OrdersStub.requests.filter { $0.method == "POST" }.count, posts, "旧回调不发关闭")
        XCTAssertTrue(cards.dismiss(try cards.ticket(for: XCTUnwrap(cards.state.cards.first))))
    }
}
