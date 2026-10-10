import DesignSystem
import Foundation
@testable import OrderCore
import Orders
import SwiftUI
import UIKit
import XCTest

/// APP-08 iOS 第 2 轮评审（NATIVE/APP-08/ios-review-r2.md）：
/// - R2-01：恢复记录与断网缓存同属一个清理单元：撤回 / 切环境的 clearAll 一并删除并确认；删不掉保留待清理、报失败，重启后先完成（共性第 36 条）；
/// - R2-02：主 Tab 切走再切回（新的列表视图实例挂上同一份配置）以切走前的锚点做一次顶对齐，首次排版不覆盖旧锚点（共性第 37 条）。
@MainActor
final class OrderReviewR2Tests: XCTestCase {
    private var env = FakeOrderEnv()

    override func setUp() async throws {
        env = FakeOrderEnv()
    }

    private func storeRecord(_ file: OrderPageStateFile) throws {
        let record = OrderPageRecord(
            owner: OrderCacheStore.hash("a"),
            conditions: OrderConditions(scope: OrderQuery.selfScope, keyword: "3712345678901234567"), anchor: "o8"
        )
        try file.save(JSONEncoder().encode(record))
    }

    // MARK: - R2-01

    func testClearAllErasesPageState() throws {
        let store = OrderCacheStore(root: temporaryDirectory())
        try storeRecord(store.pageState)
        try store.clearAll()
        XCTAssertFalse(store.pageState.exists, "恢复记录（完整订单号搜索词）随缓存一起删")
        XCTAssertFalse(store.isPendingClear)
    }

    /// 删不掉：保留待清理（标记在缓存目录之外）并报失败；「重启」后的第一次核验先完成清理。
    func testPageStateEraseFailureKeepsPendingUntilRetried() throws {
        let root = temporaryDirectory()
        let store = OrderCacheStore(root: root)
        try storeRecord(store.pageState)
        store.pageStateEraser = { false }
        XCTAssertThrowsError(try store.clearAll(), "恢复记录没确认删除：清理不算完成")
        XCTAssertTrue(store.isPendingClear, "保留待清理")
        let restarted = OrderCacheStore(root: root)
        XCTAssertTrue(restarted.isPendingClear, "重启后仍是待清理")
        restarted.reconcileOwner(account: "a")
        XCTAssertFalse(restarted.isPendingClear)
        XCTAssertFalse(restarted.pageState.exists, "重启后先完成清理")
    }

    func testEraseConfirmsRemoval() throws {
        let file = OrderPageStateFile.beside(root: temporaryDirectory())
        try storeRecord(file)
        XCTAssertTrue(file.erase())
        XCTAssertFalse(file.exists)
        XCTAssertTrue(file.erase(), "本来就没有：算删除成功")
    }

    // MARK: - R2-02

    @MainActor
    private final class Deferred {
        var works: [@MainActor () -> Void] = []

        func run() {
            let pending = works
            works = []
            pending.forEach { $0() }
        }
    }

    private func loadedPage(_ ids: [String]) async -> (OrderListPageConfig, Deferred) {
        // 回复先在主线程备好：桩的处理闭包在网络线程上执行
        let body = OrderFixtures.page(ids.map { OrderFixtures.row($0) })
        OrdersStub.install { _ in OrderFixtures.ok(body) }
        let controller = OrderListController(api: makeOrdersClient(), gate: OrderRateGate(), env: env, cache: nil)
        let page = OrderListPageConfig(controller: controller, texts: OrderDraftTexts(), mask: AmountMaskStore(
            defaults: UserDefaults(suiteName: UUID().uuidString) ?? .standard
        ), pendingTrack: nil)
        let deferred = Deferred()
        page.nextLoop = { work in deferred.works.append(work) }
        controller.start()
        await eventually { controller.snapshot.phase == .content }
        return (page, deferred)
    }

    /// 首个视图实例：不对齐。第二个实例（Tab 切回）：以已记录的锚点开始恢复；新视图首次排版报告的顶部卡不覆盖旧锚点；对齐一次。
    func testRemountRestoresRecordedAnchorWithoutOverwrite() async {
        let (page, deferred) = await loadedPage((1...10).map { "o\($0)" })
        page.viewMounted()
        XCTAssertFalse(page.anchor.restoring, "第一次挂载不对齐")
        XCTAssertTrue(page.recordTop("o8"), "用户滚到第 8 条")
        // 切到首页 Tab 再切回：Tab 外壳重建了视图
        page.viewMounted()
        XCTAssertTrue(page.anchor.restoring, "新视图实例：以切走前的锚点恢复")
        XCTAssertFalse(page.recordTop("o1"), "新视图首次排版（列表在顶部）不覆盖旧锚点")
        XCTAssertEqual(page.anchor.recorded, "o8")
        var scrolled: [String] = []
        page.restoreStep { scrolled.append($0) }
        deferred.run()
        XCTAssertEqual(scrolled, ["o8"], "对齐到切走前的顶部订单")
        XCTAssertFalse(page.anchor.restoring)
        XCTAssertTrue(page.recordTop("o9"), "对齐后照常记录")
    }

    /// 冷启动的进程恢复正在进行时再挂载：不重开任务（不改任务编号）。失效页面挂载：不恢复。
    func testRemountKeepsRunningRestoreAndIgnoresInvalidPage() async {
        let (page, _) = await loadedPage(["o1", "o2"])
        page.anchor.begin(target: "o2")
        let task = page.anchor.taskId
        page.viewMounted()
        page.viewMounted()
        XCTAssertEqual(page.anchor.taskId, task, "恢复进行中：不重开")
        let (other, _) = await loadedPage(["o1", "o2"])
        other.viewMounted()
        XCTAssertTrue(other.recordTop("o2"))
        other.invalidate()
        other.viewMounted()
        XCTAssertFalse(other.anchor.restoring, "页面已失效：不恢复")
    }

    /// 共性第 39 条：已安排延迟对齐后，用户在同一张卡内小幅滚动（顶部条目不变，只有偏移变化）→ 对齐执行前的复核放弃，不把用户拉走。
    func testSmallScrollWithinSameCardBeforeDelayedAlignCancels() async {
        let (page, deferred) = await loadedPage(["o1", "o2", "o3"])
        page.anchor.begin(target: "o3")
        page.scrolled(offset: 0)
        var scrolled: [String] = []
        page.restoreStep { scrolled.append($0) }
        XCTAssertEqual(deferred.works.count, 1, "已安排对齐")
        page.scrolled(offset: -12)
        deferred.run()
        XCTAssertTrue(scrolled.isEmpty, "偏移变了（哪怕顶部条目没变）：不对齐")
        XCTAssertFalse(page.anchor.restoring)
    }

    /// 视图层：同一份配置先挂一个 OrdersScreen 实例，滚到列表中段后换成新实例（模拟 Tab 外壳重建），顶部那张卡不变、没回到顶部。
    func testRealViewRemountKeepsTopOrder() async throws {
        let ids = (1...14).map { "o\($0)" }
        let (page, _) = await loadedPage(ids)
        page.nextLoop = { work in DispatchQueue.main.async { MainActor.assumeIsolated { work() } } }
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 700))
        let host = UIHostingController(rootView: AnyView(OrdersScreen(config: page).id(1)))
        window.rootViewController = host
        window.makeKeyAndVisible()
        try await Task.sleep(nanoseconds: 400_000_000)
        let scroll = try XCTUnwrap(Self.scrollView(in: host.view), "找到列表的 UIScrollView")
        // 用户滚动到列表中段
        scroll.setContentOffset(CGPoint(x: 0, y: 900), animated: false)
        for _ in 0..<50 where page.anchor.recorded == nil || page.anchor.recorded == "o1" {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        try await Task.sleep(nanoseconds: 300_000_000)
        let before = try XCTUnwrap(page.anchor.recorded)
        XCTAssertNotEqual(before, "o1", "前提：已滚离顶部")
        // 切到别的 Tab 再切回：换一个视图实例（新身份）
        host.rootView = AnyView(Color.clear)
        try await Task.sleep(nanoseconds: 200_000_000)
        host.rootView = AnyView(OrdersScreen(config: page).id(2))
        for _ in 0..<60 where page.anchor.restoring {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertFalse(page.anchor.restoring)
        XCTAssertEqual(page.anchor.recorded, before, "切回后顶部订单不变")
        let fresh = try XCTUnwrap(Self.scrollView(in: host.view))
        XCTAssertGreaterThan(fresh.contentOffset.y, 100, "没有回到顶部")
        window.isHidden = true
    }

    private static func scrollView(in view: UIView) -> UIScrollView? {
        if let scroll = view as? UIScrollView, scroll.contentSize.height > scroll.bounds.height {
            return scroll
        }
        for child in view.subviews {
            if let found = scrollView(in: child) {
                return found
            }
        }
        return nil
    }
}
