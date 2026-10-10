import Clipboard
import CouliNetwork
import Foundation
@testable import OrderCore
@testable import Orders
import SwiftUI
import UIKit
import XCTest

/// APP-08 iOS 第 3 轮后定向复核（NATIVE/APP-08/ios-recheck-r3fix.md）第二次窄修：
/// - RC-01：列表 / 详情执行器构造时一次性固定身份；会话已换代而通知还没处理时重画旧页面：不出【复制】票据、零写入；迟到响应不绑定、
///   缓存不按新账号读写（APP-09 共性第 63、65 条）；
/// - RC-03：旧 UserDefaults 记录删除后同步写盘确认，没确认保留持久待清理；
/// - RC-04：恢复记录删除失败进入持久清理单元（不依赖缓存 owner 文件），无缓存目录、同账号重启也不恢复；
/// - RC-05：待跟单票据带显示位置与卡片有效期（切走再切回、卡片消失后同 attempt 重现，旧回调不复活）。
@MainActor
final class OrderReviewR3bTests: XCTestCase {
    private var env = FakeOrderEnv()

    override func setUp() async throws {
        env = FakeOrderEnv()
    }

    private static let fullNo = "3712345678901234567"

    private struct DiskFailure: Error {}

    private func clipboard() -> (ClipboardWriter, CountingClipboard) {
        let system = CountingClipboard()
        return (
            ClipboardWriter(system: system, ledger: ClipboardWriteLedger(store: MemoryClipboardHashStore())),
            system
        )
    }

    // MARK: - RC-01 详情

    private func loadedDetail(cache: OrderCacheStore? = nil) async -> (OrderDetailController, CountingClipboard) {
        OrdersStub.install { _ in OrderFixtures.ok(OrderFixtures.detail("o1", number: Self.fullNo)) }
        let page = OrderDetailController(
            api: makeOrdersClient(), orderId: "o1", gate: OrderRateGate(), env: env, cache: cache
        )
        let (writer, system) = clipboard()
        page.copy = { writer.write($0) }
        page.start()
        await eventually { page.snapshot.phase == .content }
        return (page, system)
    }

    /// 评审场景：A 的详情已显示 → 底层会话换成 B（App 的会话通知还没处理，页面没清空）→ SwiftUI 重画旧页面、再点【复制】：
    /// 重画取不到票据，旧票据与新渲染的回调都零写入（不把 A 的完整订单号按 B 的会话写剪贴板）。
    func testDetailRedrawBeforeSessionNoticeThenCopyWritesNothing() async {
        let (page, system) = await loadedDetail()
        let before = page.copyTicket()
        XCTAssertNotNil(before, "前提：有效时有票据")
        env.account = "user-b"
        XCTAssertEqual(page.snapshot.phase, .content, "前提：会话通知还没处理，旧详情仍在")
        let redrawn = page.copyTicket()
        XCTAssertNil(redrawn, "会话已换代：重画不出票据")
        page.copyOrderNo(redrawn, rendered: Self.fullNo)
        page.copyOrderNo(before, rendered: Self.fullNo)
        XCTAssertTrue(system.writes.isEmpty, "零写入")
        XCTAssertNil(page.snapshot.copyToast)
        XCTAssertEqual(page.owner.account, "user-a", "固定身份不随当前会话变化")
    }

    /// 详情请求在途时会话换成 B，响应迟到：不绑定进页面、不写进 B（也不写进 A）的缓存；刷新入口拒绝。
    func testDetailLateResponseAfterSessionSwapNotBoundNorCached() async {
        let cache = OrderCacheStore(root: temporaryDirectory())
        OrdersStub.install { _ in .hold("d") }
        let page = OrderDetailController(
            api: makeOrdersClient(), orderId: "o1", gate: OrderRateGate(), env: env, cache: cache
        )
        page.start()
        await eventually { OrdersStub.isHeld("d") }
        env.account = "user-b"
        OrdersStub.release("d", with: OrderFixtures.ok(OrderFixtures.detail("o1", number: Self.fullNo)))
        await settle()
        XCTAssertNil(page.snapshot.detail, "迟到响应不绑定")
        XCTAssertNil(cache.readDetail(account: "user-b", orderId: "o1"), "不写进新账号的缓存")
        XCTAssertNil(cache.readDetail(account: "user-a", orderId: "o1"))
        XCTAssertFalse(page.refresh())
    }

    // MARK: - RC-01 列表

    private func loadedList(cache: OrderCacheStore? = nil) async -> (OrderListPageConfig, CountingClipboard) {
        OrdersStub.install { _ in OrderFixtures.ok(OrderFixtures.page([OrderFixtures.row("o1", number: Self.fullNo)])) }
        let controller = OrderListController(api: makeOrdersClient(), gate: OrderRateGate(), env: env, cache: cache)
        let page = OrderListPageConfig(
            controller: controller, texts: OrderDraftTexts(),
            mask: AmountMaskStore(defaults: UserDefaults(suiteName: UUID().uuidString) ?? .standard), pendingTrack: nil
        )
        let (writer, system) = clipboard()
        page.copy = { writer.write($0) }
        controller.start()
        await eventually { controller.snapshot.phase == .content }
        return (page, system)
    }

    /// 列表同一场景：会话换代通知还没处理时重画旧卡片再复制 → 零写入；翻页 / 刷新入口拒绝（不把新会话的数据接进旧列表）。
    func testListRedrawBeforeSessionNoticeThenCopyWritesNothing() async throws {
        let (page, system) = await loadedList()
        let item = try XCTUnwrap(page.controller.snapshot.items.first)
        let before = page.copyTicket(item)
        XCTAssertNotNil(before)
        env.account = "user-b"
        let redrawn = page.copyTicket(item)
        XCTAssertNil(redrawn, "会话已换代：重画不出票据")
        page.copyOrderNo(redrawn, rendered: Self.fullNo)
        page.copyOrderNo(before, rendered: Self.fullNo)
        XCTAssertTrue(system.writes.isEmpty)
        XCTAssertFalse(page.controller.refresh(), "刷新入口拒绝")
        XCTAssertFalse(page.controller.setGroup("credited"), "筛选入口拒绝")
    }

    /// 列表请求在途时会话换成 B：迟到响应不绑定、默认视图缓存不写进 B 的目录。
    func testListLateResponseAfterSessionSwapNotBoundNorCached() async {
        let cache = OrderCacheStore(root: temporaryDirectory())
        OrdersStub.install { _ in .hold("l") }
        let controller = OrderListController(api: makeOrdersClient(), gate: OrderRateGate(), env: env, cache: cache)
        controller.start()
        await eventually { OrdersStub.isHeld("l") }
        env.account = "user-b"
        OrdersStub.release(
            "l",
            with: OrderFixtures.ok(OrderFixtures.page([OrderFixtures.row("o1", number: Self.fullNo)]))
        )
        await settle()
        XCTAssertTrue(controller.snapshot.items.isEmpty, "迟到响应不绑定")
        XCTAssertNil(cache.readList(account: "user-b", scope: OrderQuery.selfScope), "不写进新账号的缓存")
    }

    // MARK: - RC-03

    private func legacyRecord() throws -> Data {
        try JSONEncoder().encode(OrderPageRecord(
            owner: OrderCacheStore.hash("a"),
            conditions: OrderConditions(scope: OrderQuery.selfScope, keyword: Self.fullNo), anchor: nil
        ))
    }

    /// 旧 UserDefaults 记录：迁移清理删除后写盘没确认 → 持久待清理保留（缓存目录之外的标记）；重启后启动核验先完成清理并确认。
    func testLegacyEraseUnconfirmedKeepsPersistentPendingUntilConfirmed() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString))
        defaults.set(try legacyRecord(), forKey: OrderPageStateFile.legacyKey)
        let root = temporaryDirectory()
        let store = OrderCacheStore(root: root, legacyPageStateDefaults: defaults)
        store.pageState.legacySync = { _ in false }
        store.migrateLegacyPageState()
        XCTAssertTrue(store.isPendingClear, "写盘没确认：保留待清理")
        XCTAssertTrue(OrderSiblingPendingFlag(root: root).isSet(), "标记在缓存目录之外（跨重启）")
        XCTAssertNil(store.readList(account: "a", scope: OrderQuery.selfScope), "待清理期间不读")
        // 重启：写盘恢复正常，启动核验先完成清理
        let restarted = OrderCacheStore(root: root, legacyPageStateDefaults: defaults)
        var synced = 0
        restarted.pageState.legacySync = { synced += 1
            return $0.synchronize()
        }
        restarted.reconcileOwner(account: "a")
        XCTAssertGreaterThan(synced, 0, "清理时同步写盘确认")
        XCTAssertFalse(restarted.isPendingClear)
        XCTAssertNil(defaults.object(forKey: OrderPageStateFile.legacyKey))
    }

    /// 恢复决策时发现旧记录、写盘没确认：不恢复，并登记进持久清理单元。
    func testDecideWithUnconfirmedLegacyEraseRegistersPersistentPending() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString))
        defaults.set(try legacyRecord(), forKey: OrderPageStateFile.legacyKey)
        let root = temporaryDirectory()
        let store = OrderCacheStore(root: root, legacyPageStateDefaults: defaults)
        store.pageState.legacySync = { _ in false }
        let restorer = OrderPageRestorer(file: store.pageState, unit: store)
        XCTAssertNil(restorer.decide(account: "a"))
        XCTAssertTrue(OrderSiblingPendingFlag(root: root).isSet(), "持久待清理")
    }

    // MARK: - RC-04

    /// 评审场景：只保存过搜索恢复记录、没有缓存目录（也就没有 owner 文件）→ 会话清理删除失败 → 归属对账 → 进程结束 → 同账号重启：
    /// 删除仍失败时不恢复；删除恢复正常后启动核验先删掉并解除待清理。
    func testEraseFailureWithoutCacheDirSameAccountRestartDoesNotRestore() {
        let root = temporaryDirectory()
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path), "前提：没有缓存目录")
        let store = OrderCacheStore(root: root)
        let restorer = OrderPageRestorer(file: store.pageState, unit: store)
        XCTAssertNil(restorer.decide(account: "a"))
        restorer.persist(
            conditions: OrderConditions(scope: OrderQuery.selfScope, keyword: Self.fullNo), anchor: nil, account: "a"
        )
        XCTAssertTrue(store.pageState.exists)
        store.pageState.remover = { _ in throw DiskFailure() }
        XCTAssertFalse(restorer.clear(), "登出：删除失败如实报告")
        store.reconcileOwner(account: nil)
        XCTAssertTrue(OrderSiblingPendingFlag(root: root).isSet(), "删除失败进入持久清理单元（不依赖 owner 文件）")

        // 同账号重启，删除故障仍在：不恢复
        let second = OrderCacheStore(root: root)
        second.pageState.remover = { _ in throw DiskFailure() }
        second.reconcileOwner(account: "a")
        let secondRestorer = OrderPageRestorer(file: second.pageState, unit: second)
        XCTAssertNil(secondRestorer.decide(account: "a"), "同账号重启：不恢复旧记录")
        XCTAssertTrue(second.pageState.exists, "前提：磁盘上的记录还在")
        secondRestorer.persist(conditions: OrderConditions(scope: OrderQuery.selfScope), anchor: nil, account: "a")
        XCTAssertEqual(secondRestorer.stored?.conditions.keyword, Self.fullNo, "待清理期间不写入新记录")

        // 再次重启，删除恢复正常：启动核验先完成清理
        let third = OrderCacheStore(root: root)
        third.reconcileOwner(account: "a")
        XCTAssertFalse(third.isPendingClear)
        XCTAssertFalse(third.pageState.exists, "启动时删掉")
        XCTAssertNil(OrderPageRestorer(file: third.pageState, unit: third).decide(account: "a"))
    }
}

/// RC-05：待跟单票据带显示位置与卡片有效期（共性第 46 条）。
@MainActor
final class OrderReviewR3bPendingTests: XCTestCase {
    private var env = FakeOrderEnv()

    override func setUp() async throws {
        env = FakeOrderEnv()
    }

    private static let fullNo = "3712345678901234567"

    // MARK: - RC-05 卡片有效期

    private func hub() throws -> OrderSessionHub {
        try OrderSessionHub(
            defaults: XCTUnwrap(UserDefaults(suiteName: UUID().uuidString)), notification: PendingTrackRaw.notDetermined
        )
    }

    private static func tracks(_ list: [OrderFixtures.Track]) -> OrdersStub.Reply {
        OrderFixtures.ok(OrderFixtures.tracks(list))
    }

    /// 评审场景：保留旧通知 / 关闭回调 → 拉取先返回空列表（卡片消失）→ 再返回同一 attempt（卡片重现）→ 执行旧回调：零动作；
    /// 新渲染的回调照常。
    func testOldCallbacksAfterCardVanishesAndSameAttemptReappearsDoNothing() async throws {
        let hub = try hub()
        var reply = Self.tracks([.init("L1", "a1", "taobao", false)])
        OrdersStub.install { request in request.method == "POST" ? OrderFixtures.ok("{}") : reply }
        let cards = PendingTrackService(api: makeOrdersClient(), hub: hub, env: env)
        cards.refresh()
        await eventually { cards.state.cards.first?.notificationRow == true }
        let old = try cards.ticket(for: XCTUnwrap(cards.state.cards.first))
        reply = Self.tracks([])
        cards.refresh()
        await eventually { cards.state.cards.isEmpty }
        reply = Self.tracks([.init("L1", "a1", "taobao", false)])
        cards.refresh()
        await eventually { !cards.state.cards.isEmpty }
        XCTAssertEqual(cards.state.cards.first?.key, old.card.key, "前提：同一 attempt 重现")
        XCTAssertFalse(cards.dismiss(old), "旧关闭回调不发")
        cards.requestNotification(old)
        await settle()
        XCTAssertFalse(hub.pushRowUsed, "旧通知回调不记「点过」")
        XCTAssertEqual(env.pushRequests, 0)
        XCTAssertTrue(OrdersStub.requests.filter { $0.method == "POST" }.isEmpty)
        cards.requestNotification(try cards.ticket(for: XCTUnwrap(cards.state.cards.first)))
        await eventually { self.env.pushRequests == 1 }
    }

    // MARK: - RC-05 真实页面

    private func hosted(_ page: OrderListPageConfig) -> (UIWindow, UIHostingController<AnyView>) {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 800))
        let host = UIHostingController(rootView: AnyView(OrdersScreen(config: page)))
        window.rootViewController = host
        window.makeKeyAndVisible()
        return (window, host)
    }

    private func pageWithCards(_ hub: OrderSessionHub) -> (OrderListPageConfig, PendingTrackService) {
        OrdersStub.install { request in
            if request.method == "POST" {
                return OrderFixtures.ok("{}")
            }
            return request.path == "/v1/orders/pending-tracks"
                ? Self.tracks([.init("L1", "a1", "taobao", false)])
                : OrderFixtures.ok(OrderFixtures.page([OrderFixtures.row("o1", number: Self.fullNo)]))
        }
        let controller = OrderListController(api: makeOrdersClient(), gate: hub.gate, env: env, cache: nil)
        let pending = PendingTrackService(api: makeOrdersClient(), hub: hub, env: env)
        let page = OrderListPageConfig(
            controller: controller, texts: OrderDraftTexts(),
            mask: AmountMaskStore(defaults: UserDefaults(suiteName: UUID().uuidString) ?? .standard),
            pendingTrack: pending
        )
        return (page, pending)
    }

    /// 真实 OrdersScreen：自购子 Tab 显示卡片 → 保留按此刻渲染取出的旧票据 → 切到分享子 Tab（卡片区视图消失）→ 切回自购（同一张卡重新
    /// 显示）→ 执行旧回调：不记「点过」、不申请、不发关闭；切回后新渲染的回调照常。
    func testRealPageSwitchAwayAndBackOldCallbacksDoNothing() async throws {
        let hub = try hub()
        let (page, pending) = pageWithCards(hub)
        let (window, _) = hosted(page)
        defer { window.isHidden = true }
        await eventually { pending.state.cards.first?.notificationRow == true && pending.displayed }
        let old = try pending.ticket(for: XCTUnwrap(pending.state.cards.first))
        XCTAssertTrue(pending.ticketValid(old), "前提：显示中票据有效")
        XCTAssertTrue(page.controller.setScope(OrderQuery.shareScope))
        await eventually { !pending.displayed }
        XCTAssertFalse(pending.ticketValid(old), "离开显示位置：旧票据同步失效")
        XCTAssertTrue(page.controller.setScope(OrderQuery.selfScope))
        await eventually { pending.displayed }
        XCTAssertEqual(pending.state.cards.first?.key, old.card.key, "前提：同一张卡重新显示")
        XCTAssertFalse(pending.dismiss(old))
        pending.requestNotification(old)
        await settle()
        XCTAssertFalse(hub.pushRowUsed)
        XCTAssertEqual(env.pushRequests, 0)
        pending.requestNotification(try pending.ticket(for: XCTUnwrap(pending.state.cards.first)))
        await eventually { self.env.pushRequests == 1 }
    }

    /// 真实 OrdersScreen：通知申请等待系统状态期间切到分享子 Tab（离开显示位置）→ 等待结束按同一张票据复核失败：不弹系统框。
    func testRealPageLeavingDisplayDuringPushWaitBlocksPrompt() async throws {
        let hub = try hub()
        let (page, pending) = pageWithCards(hub)
        let (window, _) = hosted(page)
        defer { window.isHidden = true }
        await eventually { pending.state.cards.first?.notificationRow == true && pending.displayed }
        env.holdStatus = true
        pending.requestNotification(try pending.ticket(for: XCTUnwrap(pending.state.cards.first)))
        await eventually { self.env.waitingStatus }
        XCTAssertTrue(page.controller.setScope(OrderQuery.shareScope))
        await eventually { !pending.displayed }
        env.finishStatusWait()
        await settle()
        XCTAssertEqual(env.systemPrompts, 0, "等待期间离开显示位置：不弹系统框")
    }
}
