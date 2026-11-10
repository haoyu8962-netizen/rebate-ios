@testable import Couli
import Foundation
import OrderCore
import Router
import SwiftUI
import UIKit
import XCTest

/// FU-IOS-NATIVE-TABBAR 测试 v7（评审 r1 S1-1；实现 r5 交回 r5-2「变异是被前提失败杀的，不算有效杀死」）：进程内直接驱动订单列表
/// 滚动视图的位置序列，钉住恢复对齐之后「补对齐」（`OrdersScreen.settleRestore`）的取消逻辑。UI 用例里系统重置约在对齐后 1 秒，
/// 用户动作很难赶在它之前；这里不等系统重置，对齐一完成就按需要的序列直接改滚动视图位置，与时机无关。
///
/// 宿主：真实 App 组装的订单列表（OrderVisualHost：生产 `OrderListRouteView` → `OrdersScreen`，只换网络）。冷启动恢复 = 页面配置
/// 建好后、列表视图第一次挂上前开始恢复任务（与 AppOrders 读到恢复记录后 `anchor.begin` 同一入口）；Tab 切回 = 同一份配置换一个新的
/// 列表视图实例（`remount`，与 Tab 外壳重建视图同一入口 `viewMounted`）。
///
/// 位置序列（滚动视图 contentOffset，顶 = −adjustedContentInset.top）：
/// - 用户拖回顶部：对齐位 → 逐步经过中间位置 → 顶；点状态栏回顶：带动画滚到顶（与 scrollsToTop 同一条带动画的滚动）。
///   判据：之后 2.5 秒一直在顶，没有被拉回目标。去掉「用户一动就取消」（m13）应变红。
/// - 系统重置：对齐位 → 正值（内容顶边在视口顶边以下）→ 顶，没有中间值。冷启动恢复：应补对齐回目标（原有恢复语义不退）；
///   Tab 切回：不开补对齐窗口，应一直在顶（Tab 切回也开窗口（m14）应变红）。
/// 前提（不成立时明确失败，不当作通过）：对齐确实发生（离开顶部、目标卡在视口顶部）；从看到对齐到序列走完不超过 1.5 秒（补对齐窗口 2 秒）；
/// 序列开始前位置仍是对齐位（没有先被别的原因挪动）。
@MainActor
final class OrdersRestoreSettleSequenceTests: OrderVisualTestCase {
    /// 恢复目标（24 张卡里的第 13 张，离顶部足够远）。
    private let target = "R12"
    private let count = 24
    /// 补对齐窗口是对齐后 2 秒：序列须在这之前走完，留出余量。
    private let budget: TimeInterval = 1.5

    // MARK: - 冷启动恢复：用户回顶不被拉回（m13）

    /// 冷启动恢复对齐后，用户拖回顶部（逐步经过中间位置）：一直在顶，不被拉回目标。
    func testColdRestoreUserDragToTopIsNotPulledBack() async throws {
        let restored = try await coldRestored()
        let (page, scroller, aligned) = (restored.page, restored.scroller, restored.aligned)
        let top = topOffset(scroller)
        let steps = (1...16).map { aligned - (aligned - top) * CGFloat($0) / 16 }
        try await drive(page, scroller, steps, from: aligned)
        try await assertStaysAtTop(page, scroller, "冷启动恢复后用户拖回顶部")
    }

    /// 冷启动恢复对齐后，点状态栏回顶（带动画滚到顶，连续经过中间位置）：一直在顶，不被拉回目标。
    /// 惰性列表在动画途中按实高回调位置，一次动画会停在离顶约 690 处（v7 实测，补对齐取消与否都一样，与产品无关）；停下没到顶就再发一次
    /// 带动画回顶（最多 5 次）。补对齐只在到顶那一刻触发，重发动画不会盖掉它。
    func testColdRestoreAnimatedScrollToTopIsNotPulledBack() async throws {
        let restored = try await coldRestored()
        let (page, scroller, aligned) = (restored.page, restored.scroller, restored.aligned)
        let started = Date()
        try precondition(scroller, at: aligned)
        let window = try XCTUnwrap(page.window)
        let top = topOffset(scroller)
        var animations = 0
        while animations < 5, abs(scroller.contentOffset.y - top) > 0.5 {
            animations += 1
            scroller.setContentOffset(CGPoint(x: scroller.contentOffset.x, y: top), animated: true)
            // 等这次动画停下：到顶，或连续 5 次取样（约 50ms）位置不变
            var previous = scroller.contentOffset.y
            var still = 0
            for _ in 0..<80 where abs(scroller.contentOffset.y - top) > 0.5 && still < 5 {
                window.layoutIfNeeded()
                try await Task.sleep(for: .milliseconds(10))
                let offset = scroller.contentOffset.y
                still = offset == previous ? still + 1 : 0
                previous = offset
            }
        }
        try timing(started)
        XCTAssertLessThanOrEqual(abs(scroller.contentOffset.y - top), 0.5,
                                 "前提不成立：带动画回顶 \(animations) 次仍没到顶（\(scroller.contentOffset.y)）")
        try await assertStaysAtTop(page, scroller, "冷启动恢复后点状态栏回顶（带动画 \(animations) 次）")
    }

    // MARK: - 冷启动恢复：系统重置仍补对齐（原有语义）

    /// 冷启动恢复对齐后被系统重置（对齐位 → 正值 → 顶，没有中间值；实现 r5 实测 −1201 → +3003 → 0）：补对齐回目标。
    func testColdRestoreSystemResetStillRealigns() async throws {
        let restored = try await coldRestored()
        let top = topOffset(restored.scroller)
        try await drive(restored.page, restored.scroller, [top - 300, top], from: restored.aligned, pause: false)
        try await assertRealigned(restored, "系统重置（对齐位 → 正值 → 顶）")
    }

    /// 冷启动恢复对齐后被直接跳回顶部（对齐位 → 顶，没有中间值）：补对齐回目标。
    func testColdRestoreJumpToTopStillRealigns() async throws {
        let restored = try await coldRestored()
        try await drive(restored.page, restored.scroller, [topOffset(restored.scroller)], from: restored.aligned)
        try await assertRealigned(restored, "直接跳回顶部（对齐位 → 顶）")
    }

    private func assertRealigned(_ restored: Restored, _ how: String) async throws {
        let back = await waitUntil(seconds: 2) {
            self.targetNearTop(restored.page, restored.scroller, id: self.target)
        }
        XCTAssertTrue(
            back,
            "\(how)后没有补对齐回目标 \(target)（对齐位 \(restored.aligned)，现在 \(restored.scroller.contentOffset.y)）"
        )
    }

    // MARK: - Tab 切回：不开补对齐窗口（m14）

    /// Tab 切回（同一份配置换新的列表视图实例）做一次性顶对齐后，同样形状的系统重置序列：不补对齐，一直在顶。
    func testTabSwitchBackResetIsNotRealigned() async throws {
        let page = try fresh(script())
        await page.showList()
        let config = try XCTUnwrap(page.orders.listConfig, "没有列表配置")
        _ = await page.stable { _, _ in config.controller.snapshot.items.count == self.count }
        let first = try XCTUnwrap(page.window.flatMap(OrderListVisualReviewR2Tests.listScrollView(in:)))
        let away: CGFloat = 1500
        first.setContentOffset(CGPoint(x: first.contentOffset.x, y: away), animated: false)
        page.window?.layoutIfNeeded()
        let recorded = await waitUntil(seconds: 5) {
            config.anchor.recorded.map { $0 != "R00" } ?? false
        }
        XCTAssertTrue(recorded, "前提不成立：滚下去后没有记下顶部订单（\(config.anchor.recorded ?? "nil")）")
        let anchor = try XCTUnwrap(config.anchor.recorded)
        // 等第一次挂载留下的一切过去（第一次挂载没有恢复任务，本来就不开窗口；这里只是让时间与冷启动无关）
        try await Task.sleep(for: .milliseconds(2500))

        await page.remount(OrderVisualHost.Canvas())
        XCTAssertEqual(config.mounts, 2, "前提：同一份配置挂上了第二个列表视图实例（Tab 切回）")
        XCTAssertFalse(config.firstMount, "前提：Tab 切回不是本进程第一次挂载")
        let (scroller, aligned) = try await waitAligned(page, to: anchor, "Tab 切回后一次性顶对齐到 \(anchor)")
        let top = topOffset(scroller)
        try await drive(page, scroller, [top - 300, top], from: aligned, pause: false)
        try await assertStaysAtTop(page, scroller, "Tab 切回对齐后同形状的系统重置")
    }

    // MARK: - 工具

    /// 24 张卡一页（都由 list_self 第一张卡派生、卡高一致，编号 R00…R23、订单号各不相同；没有下一页）。卡高一致是为了惰性列表的
    /// 估高与实高相同：卡高不一时，直接改位置跳过未排版的卡会让列表按实高回调位置（v7 诊断实测从顶被挪到约 660），与产品无关。
    private func script() throws -> OrderVisualStub.Script {
        let base = try OrderVisualData.items(OrderVisualData.page("list_self"))
        XCTAssertFalse(base.isEmpty)
        let items: [[String: Any]] = (0..<count).map { index in
            OrderVisualData.change(base[0], [
                "order_id": String(format: "R%02d", index),
                "order_no": String(format: "37412345678900%05d", index),
            ])
        }
        let list: [String: Any] = [
            "items": items, "next_cursor": NSNull(), "earliest_visible_date": NSNull(), "claim_entry_pinned": false,
        ]
        return try listScript(extra: ["self": .data(list)])
    }

    /// 冷启动恢复：页面配置建好、恢复任务开始（目标 R12）之后才第一次挂上列表视图；等对齐完成。
    private struct Restored {
        let page: OrderVisualHost
        let scroller: UIScrollView
        /// 对齐位（滚动视图 contentOffset.y）。
        let aligned: CGFloat
    }

    private func coldRestored() async throws -> Restored {
        let page = try fresh(script())
        let config = page.orders.listPage(RouteDestination(route: "OrderList", params: [:]))
        config.anchor.begin(target: target)
        await page.showList()
        XCTAssertEqual(config.mounts, 1, "前提：列表视图第一次挂上（冷启动）")
        XCTAssertTrue(config.firstMount)
        let (scroller, aligned) = try await waitAligned(page, to: target, "冷启动恢复对齐到 \(target)")
        return Restored(page: page, scroller: scroller, aligned: aligned)
    }

    /// 等对齐：滚动视图离开顶部、两次取样位置相同，且目标卡在视口顶部。返回滚动视图与对齐位。
    private func waitAligned(_ page: OrderVisualHost, to id: String,
                             _ what: String) async throws -> (UIScrollView, CGFloat) {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(15))
        var previous: CGFloat?
        while clock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
            guard let window = page.window, let scroller = OrderListVisualReviewR2Tests.listScrollView(in: window)
            else { continue }
            let offset = scroller.contentOffset.y
            defer { previous = offset }
            guard offset > topOffset(scroller) + 200, offset == previous else { continue }
            if targetNearTop(page, scroller, id: id) {
                return (scroller, offset)
            }
        }
        let offset = page.window.flatMap(OrderListVisualReviewR2Tests.listScrollView(in:))?.contentOffset.y
        throw unmet("前提不成立：\(what) 15 秒内没有完成（位置 \(offset.map { "\($0)" } ?? "无滚动视图")）——不当作通过")
    }

    /// 目标卡（测量 order.card.<id>）的上沿离列表视口上沿不超过 40pt。
    private func targetNearTop(_ page: OrderVisualHost, _ scroller: UIScrollView, id: String) -> Bool {
        guard let card = page.probes["order.card.\(id)"]?.rect, let window = page.window else { return false }
        let viewportTop = scroller.convert(scroller.bounds, to: window).minY + scroller.adjustedContentInset.top
        return abs(card.minY - viewportTop) < 40
    }

    /// 前提不成立：记一条失败并结束用例（不跳过、不当作通过）。
    private func unmet(_ message: String, file: StaticString = #filePath, line: UInt = #line) -> Error {
        XCTFail(message, file: file, line: line)
        return PreconditionUnmet()
    }

    private struct PreconditionUnmet: Error {}

    private func topOffset(_ scroller: UIScrollView) -> CGFloat {
        -scroller.adjustedContentInset.top
    }

    /// 序列开始前位置仍是对齐位（没有先被系统重置或别的原因挪动）。
    private func precondition(_ scroller: UIScrollView, at aligned: CGFloat) throws {
        guard abs(scroller.contentOffset.y - aligned) <= 0.5 else {
            throw unmet("前提不成立：动手前位置已从对齐位 \(aligned) 变成 \(scroller.contentOffset.y)（先被别的原因挪动）——不当作通过")
        }
    }

    private func timing(_ started: Date) throws {
        let elapsed = Date().timeIntervalSince(started)
        if elapsed > budget {
            XCTFail("前提不成立：看到对齐到序列走完用了 \(elapsed) 秒，超出 \(budget) 秒（补对齐窗口 2 秒），测不出取消逻辑（请重跑）")
        }
    }

    /// 逐个把滚动视图改到序列里的位置，每步排版（列表在排版里报告位置）；`pause` 时每步再等两帧（拖动：逐个位置都送到）。
    /// 不等（系统重置）：同一轮主循环里连续改完，与系统重置一样中间不让别的滚动插进来。
    private func drive(_ page: OrderVisualHost, _ scroller: UIScrollView, _ offsets: [CGFloat],
                       from aligned: CGFloat, pause: Bool = true) async throws {
        let started = Date()
        try precondition(scroller, at: aligned)
        let window = try XCTUnwrap(page.window)
        for offset in offsets {
            scroller.setContentOffset(CGPoint(x: scroller.contentOffset.x, y: offset), animated: false)
            window.layoutIfNeeded()
            if pause {
                try await Task.sleep(for: .milliseconds(34))
            }
        }
        try timing(started)
    }

    /// 之后 2.5 秒每 50ms 取样：一直在顶（离顶不超过 1pt）。
    private func assertStaysAtTop(_ page: OrderVisualHost, _ scroller: UIScrollView, _ how: String) async throws {
        let window = try XCTUnwrap(page.window)
        let top = topOffset(scroller)
        XCTAssertLessThanOrEqual(abs(scroller.contentOffset.y - top), 1, "前提不成立：\(how)，序列走完没有到顶")
        var pulled: [CGFloat] = []
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .milliseconds(2500))
        while clock.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
            window.layoutIfNeeded()
            let offset = scroller.contentOffset.y
            if abs(offset - top) > 1 {
                pulled.append(offset)
            }
        }
        XCTAssertTrue(pulled.isEmpty,
                      "\(how)后被拉回（补对齐与用户抢滚动 / Tab 切回不该补对齐）：离顶取样 \(pulled.prefix(8))")
    }

    private func waitUntil(seconds: Int, _ condition: () -> Bool) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(seconds))
        while clock.now < deadline {
            if condition() {
                return true
            }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }
}
