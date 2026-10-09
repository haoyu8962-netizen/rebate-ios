import Foundation
import ProductSearch
@testable import Search
import UIKit
import XCTest

/// APP-06a 第 3 轮第四、五次窄修（R3H-01..03、R3I-01..04，共性 33、40–43）：滚动恢复是「一次性」任务——等目标页就绪 →
/// 比对位置基准（列表顶部）→ 一次 scrollTo 目标卡顶对齐 → 下一轮主循环收尾结束，不做卡内偏移细调。被别人滚动过即取消；
/// 任务至多挪动一次，任何快照序列下都在有限步内结束。
@MainActor
final class SearchScrollRestoreTerminationTests: XCTestCase {
    /// 保存的顶部卡是第 4 张（序号 3，上部 100pt 滚出视口），在第二页末尾；目标卡之后不够一屏时任务先翻第三页，
    /// 再一次顶对齐到位（结果多：共 12 张；大字号：卡高 300、共 8 张；卡高 230、共 14 张）；卡内偏移不恢复（共性 43）。
    func testOneShotRestoreReachesTargetForVariousCardHeights() async {
        let cases: [(height: CGFloat, third: Int)] = [(150, 8), (300, 4), (230, 10)]
        for item in cases {
            let scenario = Scenario(
                anchor: 3, offset: -100, cardHeight: item.height,
                pages: [PageSpec(count: 2, more: true), PageSpec(count: 2, more: true),
                        PageSpec(count: item.third, more: false)]
            )
            await scenario.runToEnd()
            let label = "卡高 \(item.height)，共 \(4 + item.third) 张"
            XCTAssertEqual(scenario.answered, 3, "\(label)：翻到第三页")
            XCTAssertFalse(scenario.sim.tracker.restoring, "\(label)：任务结束")
            XCTAssertNil(scenario.page.restoreTarget, label)
            XCTAssertEqual(scenario.sim.tracker.moveCount, 1, "\(label)：只 scrollTo 一次")
            XCTAssertEqual(scenario.sim.offset(of: 3), 0, accuracy: 0.5, "\(label)：回到同一张顶部卡，顶对齐")
            XCTAssertEqual(scenario.page.scrollAnchor, 3, "\(label)：结束后照常记录")
            XCTAssertEqual(scenario.page.state().scrollOffset, 0, label)
        }
    }

    /// 挪动已安排、还没执行时列表被详情盖住：不挪动，回到等待；重新可见后继续并到位。
    func testFirstMoveSkippedWhilePausedResumesAfterVisible() async {
        let scenario = Scenario(
            anchor: 10, offset: -40, cardHeight: 150, pages: [PageSpec(count: 16, more: false)]
        )
        let tracker = scenario.sim.tracker
        var covered = false
        scenario.sim.beforeTurn = {
            if !covered, tracker.task?.phase == .aligning {
                covered = true
                tracker.setVisible(false)
            }
        }
        await scenario.runToEnd(rounds: 3)
        XCTAssertTrue(covered)
        XCTAssertTrue(tracker.restoring, "被盖住：任务暂停，不结束")
        XCTAssertEqual(tracker.task?.phase, .waiting, "跳过的挪动回到等待")
        XCTAssertEqual(tracker.moveCount, 0, "暂停期间不动列表")
        XCTAssertEqual(scenario.sim.scroll.contentOffset.y, 0)
        scenario.sim.beforeTurn = nil
        tracker.setVisible(true)
        await scenario.sim.pump()
        XCTAssertFalse(tracker.restoring, "恢复可见后继续并完成")
        XCTAssertEqual(tracker.moveCount, 1)
        XCTAssertEqual(scenario.sim.offset(of: 10), 0, accuracy: 0.5)
        XCTAssertEqual(scenario.page.scrollAnchor, 10)
    }

    /// 挪动之后、收尾之前被盖住：任务照常结束、不再挪动；盖住期间不记录（锚点仍是恢复目标），重新可见后按实际视口记录。
    func testCoveredAfterMoveEndsWithoutRecordingUntilVisible() async {
        let scenario = Scenario(
            anchor: 6, offset: -70, cardHeight: 150, pages: [PageSpec(count: 16, more: false)]
        )
        let tracker = scenario.sim.tracker
        var covered = false
        scenario.sim.beforeTurn = {
            if !covered, tracker.task?.phase == .finishing {
                covered = true
                tracker.setVisible(false)
            }
        }
        await scenario.runToEnd(rounds: 3)
        XCTAssertTrue(covered)
        XCTAssertFalse(tracker.restoring, "收尾不需要可见：结束")
        XCTAssertEqual(tracker.moveCount, 1)
        XCTAssertEqual(scenario.sim.offset(of: 6), 0, accuracy: 0.5, "停在顶对齐的结果")
        XCTAssertEqual(scenario.page.scrollAnchor, 6)
        XCTAssertEqual(scenario.page.state().scrollOffset, -70, "盖住期间不记录")
        scenario.sim.beforeTurn = nil
        tracker.setVisible(true)
        await scenario.sim.pump()
        XCTAssertEqual(tracker.moveCount, 1, "不再挪动")
        XCTAssertEqual(scenario.page.state().scrollOffset, 0, "可见后按实际视口记录")
    }

    /// 新增：等补页期间用户滚动（不经拖动手势，直接改 contentOffset：VoiceOver 三指滚动、键盘 / 辅助功能滚动的效果），
    /// 第三页紧接着回来：挪动前比对基准位置发现不同 → 取消，一次都不挪动，并记录用户的位置。
    func testUserScrollWhileWaitingForPageNeverMoves() async {
        let scenario = await Scenario.waitingForThirdPage()
        let sim = scenario.sim
        XCTAssertFalse(sim.scroll.isDragging || sim.scroll.isTracking || sim.scroll.isDecelerating, "不是触摸拖动")
        sim.scroll.setContentOffset(CGPoint(x: 0, y: 40), animated: false)
        await scenario.runToEnd()
        XCTAssertEqual(scenario.answered, 3)
        XCTAssertFalse(sim.tracker.restoring, "用户接管：取消")
        XCTAssertNil(scenario.page.restoreTarget)
        XCTAssertEqual(sim.tracker.moveCount, 0, "不再挪动")
        XCTAssertEqual(sim.scroll.contentOffset.y, 40, "位置留给用户")
        XCTAssertEqual(scenario.page.scrollAnchor, 0, "恢复记录：视口顶部是第 1 张卡")
        XCTAssertEqual(scenario.page.state().scrollOffset, -24)
    }

    /// 挪动已安排、执行前（同一等待结束后的下一轮主循环之前）用户滚动：挪动执行时比对基准位置 → 取消，不挪动。
    func testUserScrollBeforeFirstMoveCancels() async {
        let scenario = Scenario(
            anchor: 5, offset: -60, cardHeight: 150, pages: [PageSpec(count: 16, more: false)]
        )
        let sim = scenario.sim
        var scrolled = false
        sim.beforeTurn = {
            if !scrolled, sim.tracker.task?.phase == .aligning {
                scrolled = true
                sim.scroll.contentOffset.y = 40
            }
        }
        await scenario.runToEnd()
        XCTAssertTrue(scrolled)
        XCTAssertFalse(sim.tracker.restoring)
        XCTAssertEqual(sim.tracker.moveCount, 0, "挪动前发现位置被改：不挪动")
        XCTAssertEqual(sim.scroll.contentOffset.y, 40)
        XCTAssertEqual(scenario.page.scrollAnchor, 0)
    }

    /// 挪动之后、收尾之前用户小幅滚动（同一张卡内）：不再挪动，收尾时记录用户的位置。
    func testUserScrollAfterMoveIsKept() async {
        let scenario = Scenario(
            anchor: 5, offset: -60, cardHeight: 150, pages: [PageSpec(count: 16, more: false)]
        )
        let sim = scenario.sim
        var scrolled = false
        sim.beforeTurn = {
            if !scrolled, sim.tracker.task?.phase == .finishing {
                scrolled = true
                sim.scroll.contentOffset.y += 30
            }
        }
        await scenario.runToEnd()
        XCTAssertTrue(scrolled)
        XCTAssertFalse(sim.tracker.restoring)
        XCTAssertEqual(sim.tracker.moveCount, 1, "只做了一次挪动")
        XCTAssertEqual(sim.scroll.contentOffset.y, sim.cardTop(5) + 30, "用户的位置不被拉回")
        XCTAssertEqual(scenario.page.scrollAnchor, 5, "记录用户的位置")
        XCTAssertEqual(scenario.page.state().scrollOffset, -30)
    }

    /// 目标卡框缺失（懒布局没上报）：任务不读框，scrollTo 一次（目标卡顶对齐）后结束，不等待、不重试。
    func testMissingTargetFrameStillEndsAfterOneMove() async {
        let scenario = Scenario(
            anchor: 5, offset: -60, cardHeight: 150, pages: [PageSpec(count: 16, more: false)]
        )
        scenario.sim.hiddenCards = [5]
        await scenario.runToEnd()
        XCTAssertFalse(scenario.sim.tracker.restoring, "框缺失：直接结束")
        XCTAssertNil(scenario.page.restoreTarget)
        XCTAssertEqual(scenario.sim.tracker.moveCount, 1)
        XCTAssertEqual(scenario.sim.offset(of: 5), 0, accuracy: 0.5, "目标卡顶对齐")
    }

    /// 挪动后卡片框不再重报（框字典没重报、位置已变：R3H-01 的情形）：照常结束，不按旧框记录。
    func testStaleFramesAfterMoveEndsWithoutRecording() async {
        let scenario = Scenario(
            anchor: 5, offset: -60, cardHeight: 150, pages: [PageSpec(count: 16, more: false)]
        )
        let sim = scenario.sim
        sim.beforeTurn = {
            // 挪动执行前起不再上报新框（模拟框值相等、onPreferenceChange 不回调）。
            if sim.tracker.task?.phase == .aligning {
                sim.reportsFrames = false
            }
        }
        await scenario.runToEnd()
        XCTAssertFalse(sim.tracker.restoring, "旧框：结束")
        XCTAssertEqual(sim.tracker.moveCount, 1)
        XCTAssertEqual(sim.offset(of: 5), 0, accuracy: 0.5)
        XCTAssertEqual(scenario.page.scrollAnchor, 5, "不按旧框记录：保留恢复目标作锚点")
        XCTAssertEqual(scenario.page.state().scrollOffset, -60)
    }

    /// 任意快照序列——随机卡高、分页、目标位置，随机穿插回答下一页、排版、被盖住 / 重新可见、用户直接改位置，
    /// 任务两个阶段之间（每轮主循环前）也随机插入这些操作；最后可见并答完所有请求后任务必然结束，且至多挪动一次。
    func testOneShotRestoreAlwaysTerminatesWithAtMostOneMove() async {
        let random = SeededRandom(seed: 20_261_009)
        let heights: [CGFloat] = [120, 150, 230, 300, 420]
        for round in 0..<32 {
            let pageCount = 1 + random.next(4)
            let pages = (0..<pageCount).map { PageSpec(count: 1 + random.next(12), more: $0 < pageCount - 1) }
            let total = pages.reduce(0) { $0 + $1.count }
            let height = heights[random.next(heights.count)]
            let anchor = random.next(total + 3)
            let offset = -Double(random.next(Int(height)))
            let scenario = Scenario(anchor: anchor, offset: offset, cardHeight: height, pages: pages)
            let sim = scenario.sim
            let tracker = sim.tracker
            let userScrolls = random.next(3) == 0
            let disturb = Self.disturbance(random, sim: sim, userScrolls: userScrolls)
            sim.beforeTurn = disturb
            for _ in 0..<(4 + random.next(8)) {
                switch random.next(5) {
                case 0: await scenario.respondNext()
                case 1: sim.layoutOnce()
                case 2: tracker.setVisible(random.next(2) == 0)
                case 3: disturb()
                default: await sim.pump()
                }
            }
            sim.beforeTurn = nil
            tracker.setVisible(true)
            await scenario.runToEnd(rounds: 20)
            let label = "第 \(round) 组：卡高 \(height)，分页 \(pages.map(\.count))，目标 \(anchor) / \(offset)"
            XCTAssertFalse(tracker.restoring, "\(label)：任务结束")
            XCTAssertNil(scenario.page.restoreTarget, label)
            XCTAssertLessThanOrEqual(tracker.moveCount, 1, "\(label)：至多挪动一次")
            // 没有用户滚动、目标卡已加载且顶对齐的位置没被列表底部截住时，顶部卡必须正确。
            let fits = sim.cardTop(min(anchor, total - 1)) <= sim.scroll.contentSize.height - 600
            if !userScrolls, anchor < total, fits {
                XCTAssertEqual(scenario.page.scrollAnchor, anchor, "\(label)：没有用户滚动时顶部卡正确")
            }
        }
    }

    /// 随机扰动：盖住 / 重新可见，或（`userScrolls` 时）用户直接改位置。
    private static func disturbance(_ random: SeededRandom, sim: ListSim, userScrolls: Bool) -> () -> Void {
        {
            switch random.next(6) {
            case 0: sim.tracker.setVisible(random.next(2) == 0)
            case 1 where userScrolls: sim.scroll.contentOffset.y += CGFloat(random.next(200))
            default: break
            }
        }
    }
}
