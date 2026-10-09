import Foundation
import ProductSearch
@testable import Search
import UIKit
import XCTest

/// APP-06a 第 3 轮第四、五次窄修（R3H-01..03、R3I-01..04，共性 40–43）：一次性滚动恢复——等目标页就绪 → 比对位置基准
/// （列表顶部）→ 一次 scrollTo 目标卡顶对齐 → 结束。不做卡内偏移细调；补页在途时的非触摸滚动即取消；进后台、出栈取消时
/// 冻结锚点记录。
@MainActor
final class SearchScrollRestoreOneShotTests: XCTestCase {
    /// scrollTo 之后、收尾之前列表被读屏 / 键盘滚动（不经拖动手势）：任务不再挪动，收尾时记录用户的位置。
    func testUserScrollRightAfterScrollToIsNotPulledBack() async {
        let scenario = Scenario(
            anchor: 5, offset: -60, cardHeight: 150, pages: [PageSpec(count: 16, more: false)]
        )
        let sim = scenario.sim
        var scrolled = false
        sim.beforeTurn = {
            if !scrolled, sim.tracker.task?.phase == .finishing {
                scrolled = true
                XCTAssertEqual(sim.scroll.contentOffset.y, sim.cardTop(5), "挪动已执行")
                sim.scroll.contentOffset.y += 300
            }
        }
        await scenario.runToEnd()
        XCTAssertTrue(scrolled)
        XCTAssertFalse(sim.tracker.restoring)
        XCTAssertNil(scenario.page.restoreTarget)
        XCTAssertEqual(sim.tracker.moveCount, 1, "只做了一次 scrollTo")
        XCTAssertEqual(sim.scroll.contentOffset.y, sim.cardTop(5) + 300, "用户的位置不被拉回")
        XCTAssertEqual(scenario.page.scrollAnchor, 6, "记录用户的位置")
        XCTAssertEqual(scenario.page.state().scrollOffset, -138)
    }

    /// 第五次窄修（R3I-02 的情形从结构上消失）：scrollTo 之后用户经非触摸翻页回到顶部 / 翻到底部——任务没有第二次挪动，
    /// 不会把用户拉回目标卡。
    func testUserScrollToTopOrBottomAfterScrollToIsNotPulledBack() async {
        for toTop in [true, false] {
            let scenario = Scenario(
                anchor: 3, offset: -100, cardHeight: 150, pages: [PageSpec(count: 16, more: false)]
            )
            let sim = scenario.sim
            var scrolled = false
            sim.beforeTurn = {
                if !scrolled, sim.tracker.task?.phase == .finishing {
                    scrolled = true
                    sim.scroll.contentOffset.y = toTop ? 0 : sim.scroll.contentSize.height - 600
                }
            }
            await scenario.runToEnd()
            let label = toTop ? "回到顶部" : "翻到底部"
            let expected = toTop ? 0 : sim.scroll.contentSize.height - 600
            XCTAssertTrue(scrolled, label)
            XCTAssertFalse(sim.tracker.restoring, label)
            XCTAssertEqual(sim.tracker.moveCount, 1, "\(label)：只做了一次 scrollTo")
            XCTAssertEqual(sim.scroll.contentOffset.y, expected, "\(label)：位置留给用户")
            XCTAssertNotEqual(scenario.page.scrollAnchor, 3, "\(label)：记录用户的位置")
        }
    }

    /// 第五次窄修（R3I-04）：保存与恢复时卡高不同（大字号下保存、调小字号后恢复，或反过来）：一次顶对齐，顶部卡仍是目标卡，
    /// 不按旧偏移把它滚走。
    func testCardHeightChangedSinceSaveKeepsTopCard() async {
        let cases: [(saved: Double, height: CGFloat)] = [(-350, 150), (-40, 420), (-149, 120)]
        for item in cases {
            let scenario = Scenario(
                anchor: 5, offset: item.saved, cardHeight: item.height, pages: [PageSpec(count: 16, more: false)]
            )
            await scenario.runToEnd()
            let label = "保存偏移 \(item.saved)，现卡高 \(item.height)"
            XCTAssertFalse(scenario.sim.tracker.restoring, label)
            XCTAssertEqual(scenario.sim.tracker.moveCount, 1, "\(label)：只顶对齐一次")
            XCTAssertEqual(scenario.sim.offset(of: 5), 0, accuracy: 0.5, "\(label)：目标卡顶对齐")
            XCTAssertEqual(scenario.page.scrollAnchor, 5, "\(label)：顶部卡正确")
            XCTAssertEqual(scenario.page.state().scrollOffset, 0, "\(label)：卡内偏移不恢复（共性 43）")
        }
    }

    /// 第五次窄修（R3I-01）：目标卡在第二页，首屏回来后执行器自动补页（在途），此时还没有任何别的事件就插入非触摸滚动
    /// （读屏 / 键盘）：补页回来后不 scrollTo，位置留给用户。基准从任务建立起就是列表顶部，不等补页结束。
    func testNonTouchScrollWhileTargetPageLoadingIsNotPulledBack() async {
        let scenario = Scenario(
            anchor: 20, offset: -40, cardHeight: 150,
            pages: [PageSpec(count: 16, more: true), PageSpec(count: 16, more: false)]
        )
        let sim = scenario.sim
        await eventually { scenario.api.count == 1 }
        await scenario.respondNext()
        sim.layoutOnce()
        await eventually { scenario.api.count == 2 }
        XCTAssertTrue(scenario.page.controller.snapshot.loadingMore, "目标页在途")
        XCTAssertTrue(sim.tracker.restoring)
        XCTAssertEqual(sim.tracker.baseline, 0, "补页在途时已有位置基准")
        XCTAssertEqual(sim.tracker.moveCount, 0)
        sim.scroll.contentOffset.y = 300
        await scenario.runToEnd()
        XCTAssertEqual(scenario.answered, 2, "补页回来了")
        XCTAssertFalse(sim.tracker.restoring, "用户接管：取消")
        XCTAssertNil(scenario.page.restoreTarget)
        XCTAssertEqual(sim.tracker.moveCount, 0, "补页回来也不 scrollTo")
        XCTAssertEqual(sim.scroll.contentOffset.y, 300, "位置留给用户")
        XCTAssertEqual(scenario.page.scrollAnchor, 1, "记录用户的位置")
        XCTAssertEqual(scenario.page.state().scrollOffset, -122)
    }

    /// 等补页时内容高度变化（页尾状态切换 / 懒布局修正）与读屏滚动相邻发生：高度变化不豁免位移，补页回来后也不抢回。
    func testHeightChangeAdjacentToAccessibilityScrollWhileWaitingDoesNotSnapBack() async {
        let scenario = await Scenario.waitingForThirdPage()
        let sim = scenario.sim
        sim.extraHeight = 80
        sim.layoutOnce()
        sim.scroll.contentOffset.y = 150
        await scenario.runToEnd()
        XCTAssertEqual(scenario.answered, 3)
        XCTAssertFalse(sim.tracker.restoring)
        XCTAssertEqual(sim.tracker.moveCount, 0, "一次都不挪动")
        XCTAssertEqual(sim.scroll.contentOffset.y, 150, "位置留给用户")
    }

    /// 列表从头到尾都不上报卡片框（框值相等、onPreferenceChange 不回调的极端情形）：任务不等框，scrollTo 一次后结束，
    /// 顶部卡由 scrollTo 保证。
    func testNoFrameReportsAtAllStillTerminatesWithTopCardAligned() async {
        let scenario = Scenario(
            anchor: 5, offset: -60, cardHeight: 150, pages: [PageSpec(count: 16, more: false)]
        )
        scenario.sim.reportsFrames = false
        await scenario.runToEnd()
        XCTAssertFalse(scenario.sim.tracker.restoring, "不等框：结束")
        XCTAssertNil(scenario.page.restoreTarget)
        XCTAssertEqual(scenario.sim.tracker.moveCount, 1)
        XCTAssertEqual(scenario.sim.offset(of: 5), 0, accuracy: 0.5, "顶部卡正确")
        XCTAssertEqual(scenario.page.scrollAnchor, 5, "没有框可记：保留恢复目标作锚点")
    }

    /// 第五次窄修（R3I-03）：等补页时进后台：任务结束、不再挪动，并冻结记录——之后补页迟到返回、排版上报新框、同步保存、
    /// 按保存内容重建，锚点都仍是恢复目标；回到前台不解冻，用户实际滚动后才恢复记录。
    func testBackgroundCancelFreezesAnchorThroughLatePageFramesSaveAndRebuild() async throws {
        let scenario = await Scenario.waitingForThirdPage()
        let (sim, page) = (scenario.sim, scenario.page)
        var saved: [SearchPageState] = []
        page.onStateChange = { saved.append($0) }
        sim.tracker.appDidEnterBackground()
        page.flushState()
        XCTAssertFalse(sim.tracker.restoring, "进后台：结束")
        XCTAssertNil(page.restoreTarget)
        await scenario.runToEnd()
        XCTAssertEqual(scenario.answered, 3, "补页迟到返回")
        sim.layoutOnce()
        page.flushState()
        XCTAssertEqual(sim.tracker.moveCount, 0, "补页回来也不挪动")
        XCTAssertEqual(sim.scroll.contentOffset.y, 0)
        XCTAssertEqual(page.scrollAnchor, 3, "锚点仍是恢复目标")
        XCTAssertEqual(page.state().scrollOffset, -100)
        XCTAssertTrue(saved.allSatisfy { $0.scrollAnchor == 3 && $0.scrollOffset == -100 }, "保存的锚点没被改写")
        let data = try XCTUnwrap(page.state().encoded())
        let rebuilt = SearchPageConfig(
            controller: SearchController(api: ManualSearchApi(), config: FakeSearchConfig()), history: SearchHistory(),
            texts: TestTexts(), initialQuery: nil, initialPlatform: nil, restored: SearchPageState.decode(data)
        )
        rebuilt.start()
        XCTAssertEqual(rebuilt.restoreTarget?.index, 3, "重建后恢复同一张卡")
        XCTAssertEqual(rebuilt.restoreTarget?.offset, -100)
        // 回到前台：迟到的排版不解冻；用户读屏 / 键盘滚动后照常记录。
        sim.tracker.appWillEnterForeground()
        sim.layoutOnce()
        XCTAssertEqual(page.scrollAnchor, 3, "回到前台、用户没操作：仍冻结")
        sim.scroll.contentOffset.y = 400
        sim.layoutOnce()
        XCTAssertEqual(page.scrollAnchor, 2, "用户滚动后恢复记录")
        XCTAssertEqual(page.state().scrollOffset, -60)
    }

    /// 第五次窄修（R3I-03，共性 42）：等补页时页面出栈：恢复取消，迟到的补页与框上报不改写锚点。
    func testLeaveDuringRestoreFreezesAnchor() async {
        let scenario = await Scenario.waitingForThirdPage()
        scenario.page.leave()
        await scenario.runToEnd()
        XCTAssertEqual(scenario.answered, 3)
        XCTAssertFalse(scenario.sim.tracker.restoring, "出栈：结束")
        XCTAssertEqual(scenario.sim.tracker.moveCount, 0)
        XCTAssertEqual(scenario.page.scrollAnchor, 3, "锚点不被迟到的框改写")
        XCTAssertEqual(scenario.page.state().scrollOffset, -100)
    }

    /// 目标页加载失败：任务以最后一张已加载卡为准挪动后结束，不重试、不永久等待。
    func testLoadMoreFailureEndsAtLastLoadedCard() async {
        let scenario = Scenario(
            anchor: 6, offset: -30, cardHeight: 150,
            pages: [PageSpec(count: 3, more: true)]
        )
        let sim = scenario.sim
        await eventually { scenario.api.count == 1 }
        await scenario.respondNext()
        await sim.pump()
        await eventually { scenario.api.count == 2 }
        XCTAssertTrue(sim.tracker.restoring, "目标页在途：等待")
        scenario.api.respond(1, SearchFixtures.envelope(50401, data: "{}"))
        await eventually { scenario.page.controller.snapshot.loadMoreFailed }
        await sim.pump()
        XCTAssertFalse(sim.tracker.restoring, "加载失败：结束")
        XCTAssertNil(scenario.page.restoreTarget)
        XCTAssertLessThanOrEqual(sim.tracker.moveCount, 1)
        XCTAssertEqual(scenario.api.count, 2, "不自动重试")
    }
}
