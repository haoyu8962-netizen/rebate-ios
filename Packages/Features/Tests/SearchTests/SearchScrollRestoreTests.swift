import Foundation
import ProductSearch
@testable import Search
import SwiftUI
import UIKit
import XCTest

/// 恢复进行中的页面、模拟列表与假接口。
@MainActor
private struct Restoring {
    let page: SearchPageConfig
    let sim: ListSim
    let api: ManualSearchApi
}

/// APP-06a 第 3 轮第二次窄修（R3F-01..03，共性 33）：滚动恢复任务按加载状态等待（没有固定超时）、用户拖动即取消、
/// 新查询取消旧恢复；不等延迟保存就能同步保存最新偏移（进后台）。
@MainActor
final class SearchScrollRestoreTests: XCTestCase {
    private func cards(_ keys: [String], more: Bool) -> String {
        SearchFixtures.envelope(0, data: SearchFixtures.page(keys.map { SearchFixtures.card($0) }, more: more))
    }

    /// 进程回收后重建：保存的顶部卡是第 4 张（序号 3，上部 100pt 已滚出视口），它在第二页末尾；恢复时前两页加载完后
    /// 内容还不够长（原位置被列表底部截住），需要第三页撑开。返回 (页面, 列表, 假接口)，此时第三页请求在途。
    private func restoreWaitingForThirdPage() async throws -> Restoring {
        let api = ManualSearchApi()
        let state = SearchPageState(
            conditions: SearchConditions(keyword: "milk"), input: "milk", scrollAnchor: 3, scrollOffset: -100
        )
        let page = SearchPageConfig(
            controller: SearchController(api: api, config: FakeSearchConfig()), history: SearchHistory(),
            texts: TestTexts(), initialQuery: nil, initialPlatform: nil, restored: state
        )
        page.start()
        let sim = ListSim(page: page)
        await eventually { api.count == 1 }
        api.respond(0, cards(["tb:a", "tb:b"], more: true))
        await eventually { api.count == 2 }
        api.respond(1, cards(["tb:c", "tb:d"], more: true))
        await eventually { page.controller.snapshot.items.count == 4 && !page.controller.snapshot.loadingMore }
        await sim.pump()
        XCTAssertEqual(api.count, 3, "原位置被列表底部截住：恢复任务翻下一页撑开内容")
        XCTAssertTrue(page.controller.snapshot.loadingMore)
        XCTAssertTrue(sim.tracker.restoring, "下一页在途：任务保持")
        XCTAssertNotNil(page.restoreTarget)
        XCTAssertEqual(sim.scroll.contentOffset.y, 0, "一次性恢复（共性 40）：等目标页就绪前不挪动")
        XCTAssertEqual(sim.tracker.moveCount, 0)
        return Restoring(page: page, sim: sim, api: api)
    }

    /// R3F-01：下一页 3.5 秒后才回来，恢复仍完成（等待按加载状态，不按固定超时）；完成后照常记录。
    func testRestoreCompletesWhenNextPageTakesLongerThanThreeSeconds() async throws {
        let restoring = try await restoreWaitingForThirdPage()
        let (page, sim, api) = (restoring.page, restoring.sim, restoring.api)
        try await Task.sleep(nanoseconds: 3_500_000_000)
        await sim.pump()
        XCTAssertTrue(sim.tracker.restoring, "3.5 秒后仍在等下一页，没有放弃")
        api.respond(2, cards(["tb:e", "tb:f", "tb:g", "tb:h"], more: false))
        await eventually { page.controller.snapshot.items.count == 8 }
        await sim.pump()
        XCTAssertEqual(sim.offset(of: 3), 0, accuracy: 0.5, "回到同一张顶部卡（顶对齐，共性 43）")
        XCTAssertFalse(sim.tracker.restoring)
        XCTAssertNil(page.restoreTarget, "任务结束")
        XCTAssertEqual(page.scrollAnchor, 3)
        XCTAssertEqual(page.state().scrollOffset, 0)
    }

    /// R3F-02：恢复中用户开始拖动，任务立即取消；之后下一页回来也不再把列表拉回旧目标，并记录用户的位置。
    func testUserDragDuringRestoreStopsCorrection() async throws {
        let restoring = try await restoreWaitingForThirdPage()
        let (page, sim, api) = (restoring.page, restoring.sim, restoring.api)
        sim.scroll.userDragging = true
        sim.scroll.contentOffset.y = 40
        await sim.pump()
        sim.scroll.userDragging = false
        XCTAssertFalse(sim.tracker.restoring, "用户拖动：取消恢复")
        XCTAssertNil(page.restoreTarget)
        api.respond(2, cards(["tb:e", "tb:f", "tb:g", "tb:h"], more: false))
        await eventually { page.controller.snapshot.items.count == 8 }
        await sim.pump()
        XCTAssertEqual(sim.scroll.contentOffset.y, 40, "不再校正，位置留给用户")
        XCTAssertEqual(page.scrollAnchor, 0, "恢复记录：视口顶部是第 1 张卡")
        XCTAssertEqual(page.state().scrollOffset, -24)
    }

    /// R3F-02：恢复中用户开始新查询，旧恢复取消，新结果不被拉到旧目标。
    func testNewQueryCancelsPendingRestore() async throws {
        let restoring = try await restoreWaitingForThirdPage()
        let (page, sim, api) = (restoring.page, restoring.sim, restoring.api)
        XCTAssertTrue(page.controller.submit("paper"))
        // 新一轮查询：列表回到顶部（SearchView 在 queryRound 变化时 scrollTo 顶部）。
        sim.scroll.contentOffset.y = 0
        await sim.pump()
        XCTAssertFalse(sim.tracker.restoring, "新查询：取消旧恢复")
        await eventually { api.count == 4 }
        api.respond(3, cards(["tb:p1", "tb:p2", "tb:p3", "tb:p4", "tb:p5", "tb:p6"], more: false))
        await eventually { page.controller.snapshot.phase == .content }
        await sim.pump()
        XCTAssertEqual(sim.scroll.contentOffset.y, 0, "新结果从顶部开始")
        XCTAssertNil(page.restoreTarget)
        XCTAssertEqual(page.scrollAnchor, 0)
    }

    /// R3F-03：同一张卡内继续滚动后立刻进后台（不等 0.2 秒的延迟保存）：flushState 同步保存最新偏移；
    /// 被取消的延迟保存之后不再写。
    func testFlushSavesLatestOffsetWithoutWaitingForDelayedSave() async {
        let api = ManualSearchApi()
        let page = SearchPageConfig(
            controller: SearchController(api: api, config: FakeSearchConfig()), history: SearchHistory(),
            texts: TestTexts(), initialQuery: "milk", initialPlatform: nil
        )
        var saved: [SearchPageState] = []
        page.onStateChange = { saved.append($0) }
        page.start()
        await eventually { api.count == 1 }
        api.respond(0, cards(["tb:a", "tb:b", "tb:c"], more: false))
        await eventually { page.controller.snapshot.phase == .content }
        page.topResultCardChanged(index: 1, offset: -40)
        await eventually { saved.last?.scrollOffset == -40 }
        page.topResultCardChanged(index: 1, offset: -90)
        XCTAssertEqual(saved.last?.scrollOffset, -40, "同一张卡内滚动：延迟保存还没执行")
        page.flushState()
        XCTAssertEqual(saved.last?.scrollOffset, -90, "进后台：同步保存最新偏移")
        XCTAssertEqual(saved.last?.scrollAnchor, 1)
        let count = saved.count
        try? await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertEqual(saved.count, count, "被取消的延迟保存不再执行")
    }
}
