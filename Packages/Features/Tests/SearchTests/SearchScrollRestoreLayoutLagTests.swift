import Foundation
import ProductSearch
@testable import Search
import UIKit
import XCTest

/// FU-IOS-0712 第 1 轮修复 R1-06（F-IOS-02 根因）：一次性对齐不按主队列轮次判完成，等真实布局确认。模型（结果条数）已就绪、列表布局
/// 滞后（模拟器的「下一轮 / 下一帧」回调之前不排版，ScrollViewProxy 不认识还没进布局的卡）时：scrollTo 没生效不结束；布局跟上后重发
/// 同一次对齐，按新布局确认视口顶部就是目标卡才结束（结束原因 aligned）。用户接管、页面失效照旧取消；等不到布局在有限帧内结束。
@MainActor
final class SearchScrollRestoreLayoutLagTests: XCTestCase {
    /// 手动推进的「下一帧」：确认阶段每一帧由测试显式执行（不排版，除非测试先调 layoutOnce）。
    @MainActor
    private final class Frames {
        var queue: [@MainActor @Sendable () -> Void] = []

        func run() {
            guard !queue.isEmpty else { return }
            queue.removeFirst()()
        }
    }

    /// 三页结果（2 + 2 + 4，目标第 4 张卡），模型逐页就绪而列表一次都没排版；返回已发出（没生效的）scrollTo、进入确认阶段的场景。
    private func laggingScenario() async -> (Scenario, Frames) {
        let scenario = Scenario(
            anchor: 3, offset: -100, cardHeight: 150,
            pages: [PageSpec(count: 2, more: true), PageSpec(count: 2, more: true), PageSpec(count: 4, more: false)]
        )
        let sim = scenario.sim
        let frames = Frames()
        sim.layoutBeforeTurn = false
        sim.tracker.nextFrame = { work in frames.queue.append(work) }
        for _ in 0..<3 {
            await eventually { scenario.api.count > scenario.answered }
            await scenario.respondNext()
            sim.tracker.refresh()
        }
        await eventually { sim.tracker.task?.phase == .finishing }
        XCTAssertEqual(scenario.answered, 3, "三页都已就绪（模型）")
        XCTAssertEqual(sim.laidOut, 0, "列表一次都没排版（布局滞后）")
        XCTAssertEqual(sim.scrollToCalls, 1, "已发出对齐")
        XCTAssertEqual(sim.scroll.contentOffset.y, 0, "scrollTo 没生效：仍在顶部")
        return (scenario, frames)
    }

    func testLayoutLagAfterModelReadyStillRestoresAnchorAndEndsOnlyAfterLayoutConfirms() async {
        let (scenario, frames) = await laggingScenario()
        let (sim, tracker, page) = (scenario.sim, scenario.sim.tracker, scenario.page)
        // 下一轮 / 下一帧到了，布局还没跟上：不结束（旧实现在这里无条件结束，之后再也不会恢复）
        frames.run()
        frames.run()
        XCTAssertTrue(tracker.restoring, "布局没跟上：任务不结束")
        XCTAssertNotNil(page.restoreTarget)
        // 布局跟上（按当前位置上报卡片框）：仍在顶部、视口顶部不是目标卡 → 重发同一次对齐（不算新的挪动）
        sim.layoutOnce()
        XCTAssertEqual(sim.scrollToCalls, 2, "布局跟上后重发同一个 scrollTo")
        XCTAssertEqual(tracker.moveCount, 1, "同一次对齐，只算一次挪动")
        XCTAssertEqual(sim.offset(of: 3), 0, accuracy: 0.5, "这次生效：目标卡顶对齐")
        XCTAssertTrue(tracker.restoring, "scrollTo 之后的布局还没上报：不结束")
        frames.run()
        XCTAssertTrue(tracker.restoring, "没有新布局：继续等")
        // scrollTo 之后的布局上报：视口顶部就是目标卡 → 结束
        sim.layoutOnce()
        XCTAssertFalse(tracker.restoring, "布局确认后结束")
        XCTAssertEqual(tracker.lastEndReason, .aligned)
        XCTAssertNil(page.restoreTarget)
        XCTAssertEqual(page.scrollAnchor, 3, "回到锚点卡，结束后照常记录")
        XCTAssertEqual(tracker.moveCount, 1)
        XCTAssertTrue(tracker.endLog.last?.hasPrefix("aligned") == true, "结束原因 Debug 可读：\(tracker.endLog)")
    }

    /// 确认阶段用户接管（拖动）：立即取消，位置交给用户；页面失效（出栈 / 新查询）同样取消。
    func testUserTakeoverAndInvalidationStillCancelDuringConfirmation() async {
        let (dragged, _) = await laggingScenario()
        dragged.sim.tracker.userBeganDragging()
        XCTAssertFalse(dragged.sim.tracker.restoring)
        XCTAssertEqual(dragged.sim.tracker.lastEndReason, .userTookOver)
        dragged.sim.layoutOnce()
        XCTAssertEqual(dragged.sim.scrollToCalls, 1, "取消之后不再发 scrollTo")

        let (left, frames) = await laggingScenario()
        left.page.leave()
        frames.run()
        left.sim.tracker.refresh()
        XCTAssertFalse(left.sim.tracker.restoring)
        XCTAssertEqual(left.sim.tracker.lastEndReason, .invalidated)
        left.sim.layoutOnce()
        XCTAssertEqual(left.sim.scrollToCalls, 1, "页面失效之后不再发 scrollTo")
    }

    /// 一直等不到布局：在有限帧内结束（not_confirmed），不挂死；结束后不按旧框记录。
    func testNeverLaidOutEndsWithinTheFrameCeiling() async {
        let (scenario, frames) = await laggingScenario()
        let tracker = scenario.sim.tracker
        var ran = 0
        while tracker.restoring, ran < SearchScrollTracker.confirmFrames + 5 {
            frames.run()
            ran += 1
        }
        XCTAssertFalse(tracker.restoring, "等满上限帧数结束")
        XCTAssertEqual(tracker.lastEndReason, .notConfirmed)
        XCTAssertEqual(ran, SearchScrollTracker.confirmFrames)
        XCTAssertEqual(scenario.page.scrollAnchor, 3, "没有可用的框：保留恢复目标作锚点")
    }

    // MARK: - 编排追加（鸿蒙同题 R1-02 / R1-03）

    /// 确认阶段区分程序定位与用户滚动：scrollTo 落定之后，同一张目标卡内的小幅滚动（不经触摸：读屏 / 键盘）立即取消，之后的布局与帧
    /// 回调不再下发任何 scrollTo；scrollTo 没生效（仍在顶部）时用户的小幅滚动同样取消、不重发。
    func testSmallNonTouchScrollAfterLandingCancelsAndNoLaterPositioning() async {
        // ① 已落定：布局跟上后重发生效（落在目标卡顶），新布局上报之前用户在同卡内往下滚 30pt
        let (landed, frames) = await laggingScenario()
        landed.sim.layoutOnce()
        XCTAssertEqual(landed.sim.scrollToCalls, 2)
        XCTAssertTrue(landed.sim.tracker.restoring)
        landed.sim.scroll.contentOffset.y += 30
        frames.run()
        XCTAssertFalse(landed.sim.tracker.restoring, "落定后位置被别人改：立即取消")
        XCTAssertEqual(landed.sim.tracker.lastEndReason, .userTookOver)
        landed.sim.layoutOnce()
        frames.run()
        XCTAssertEqual(landed.sim.scrollToCalls, 2, "取消之后不再下发定位")
        XCTAssertEqual(landed.sim.offset(of: 3), -30, accuracy: 0.5, "位置留给用户（同一张卡内）")
        XCTAssertEqual(landed.page.scrollAnchor, 3)
        XCTAssertEqual(landed.page.state().scrollOffset, -30, "记录用户的位置")

        // ② 没生效：列表仍在顶部，用户先小幅滚动 20pt（读屏），布局随后跟上
        let (noop, noopFrames) = await laggingScenario()
        noop.sim.scroll.contentOffset.y = 20
        noop.sim.layoutOnce()
        noopFrames.run()
        XCTAssertFalse(noop.sim.tracker.restoring, "用户滚动过：不重发、结束")
        XCTAssertEqual(noop.sim.scrollToCalls, 1, "没有再下发定位")
        XCTAssertEqual(noop.sim.scroll.contentOffset.y, 20, "位置留给用户")
        noop.sim.layoutOnce()
        noopFrames.run()
        XCTAssertEqual(noop.sim.scrollToCalls, 1)
    }

    /// 恢复任务等待 / 确认期间用户发起新查询：同步作废旧任务与旧目标，首次持久化就是「新条件 + 空锚点」；之后迟到的页、布局与帧回调
    /// 不再定位；按保存内容重建（进后台被杀后）也不在新查询里恢复旧目标。
    func testNewQueryDuringRestoreFirstPersistsNewConditionsWithEmptyAnchor() async throws {
        for phase in ["waiting", "finishing"] {
            let scenario: Scenario
            var frames: Frames?
            if phase == "waiting" {
                scenario = await Scenario.waitingForThirdPage()
            } else {
                let lagging = await laggingScenario()
                scenario = lagging.0
                frames = lagging.1
            }
            let (page, sim) = (scenario.page, scenario.sim)
            let callsBefore = sim.scrollToCalls
            var saved: [SearchPageState] = []
            page.onStateChange = { saved.append($0) }
            XCTAssertTrue(page.controller.submit("paper"), phase)
            // 进后台的同步保存紧接着发生（不等发布回调）
            page.flushState()
            let first = try XCTUnwrap(saved.first, "\(phase)：新查询后有一次保存")
            XCTAssertEqual(first.conditions.keyword, "paper", "\(phase)：首次持久化是新条件")
            XCTAssertNil(first.scrollAnchor, "\(phase)：首次持久化锚点为空")
            XCTAssertNil(first.scrollOffset, phase)
            XCTAssertNil(page.restoreTarget, "\(phase)：旧恢复目标同步作废")
            sim.tracker.refresh()
            XCTAssertFalse(sim.tracker.restoring, "\(phase)：旧任务作废")
            if scenario.answered == 2 {
                // 旧条件的第三页迟到返回（等待阶段那次在途的翻页）
                let late = (0..<4).map { SearchFixtures.card("tb:late-\($0)") }
                scenario.api.respond(2, SearchFixtures.envelope(0, data: SearchFixtures.page(late, more: false)))
            }
            await sim.pump()
            sim.layoutOnce()
            frames?.run()
            XCTAssertEqual(sim.scrollToCalls, callsBefore, "\(phase)：之后不再下发旧目标的定位")
            XCTAssertTrue(saved.allSatisfy { $0.scrollAnchor != 3 || $0.conditions.keyword != "paper" }, phase)
            let data = try XCTUnwrap(first.encoded())
            let rebuilt = SearchPageConfig(
                controller: SearchController(api: ManualSearchApi(), config: FakeSearchConfig()),
                history: SearchHistory(), texts: TestTexts(), initialQuery: nil, initialPlatform: nil,
                restored: SearchPageState.decode(data)
            )
            rebuilt.start()
            XCTAssertNil(rebuilt.restoreTarget, "\(phase)：重建后不在新查询里恢复旧目标")
        }
    }
}
