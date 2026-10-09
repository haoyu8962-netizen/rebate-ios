import Foundation
import ProductSearch
@testable import Search
import SwiftUI
import UIKit
import XCTest

/// 可以模拟「用户正在拖」的 UIScrollView。
final class FakeScrollView: UIScrollView {
    var userDragging = false

    override var isDragging: Bool {
        userDragging
    }

    override var isTracking: Bool {
        userDragging
    }
}

/// 模拟搜索结果列表（LazyVStack）：上内边距 16、卡高 `cardHeight`（默认 150；大字号时更高）、间距 12、底部 footer 60，
/// 视口高 600；只上报视口上下 400pt 左右以内建出的卡（顶边在 (-550, 1000) 内）。scrollTo 与 SwiftUI ScrollViewProxy
/// 一样把卡顶 / 底对齐并按内容限界。跟踪器的接线与 SearchView 相同（attach + setVisible + update / refresh）。
/// 跟踪器安排的「下一轮主循环」经 `nextTurn` 接到这里：与真机一样，两轮主循环之间先提交一次排版（`layoutOnce`）；
/// `beforeTurn` 在排版前执行，用来在任务的两个阶段之间插入用户滚动、盖住等操作。
@MainActor
final class ListSim {
    let scroll = FakeScrollView(frame: CGRect(x: 0, y: 0, width: 390, height: 600))
    let tracker = SearchScrollTracker()
    let page: SearchPageConfig
    let cardHeight: CGFloat
    /// 每轮主循环开始（排版前）执行一次。
    var beforeTurn: (() -> Void)?
    /// 不上报这些卡的框（模拟懒布局没建出、上报缺失）。
    var hiddenCards: Set<Int> = []
    /// 为假时排版不再上报卡片框（模拟框值相等、onPreferenceChange 不回调）。
    var reportsFrames = true
    /// 列表底部额外的高度（模拟页尾加载状态切换、懒布局修正估算高度引起的内容高度变化；卡片框不变）。
    var extraHeight: CGFloat = 0

    init(page: SearchPageConfig, cardHeight: CGFloat = 150) {
        self.page = page
        self.cardHeight = cardHeight
        scroll.contentInsetAdjustmentBehavior = .never
        tracker.scrollView = scroll
        tracker.nextTurn = { [weak self] work in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.beforeTurn?()
                    self?.layoutOnce()
                    work()
                }
            }
        }
        tracker.attach(page) { [weak self] index, anchor in self?.scrollTo(index, anchor: anchor) }
        tracker.setVisible(true)
    }

    private var count: Int {
        page.controller.snapshot.items.count
    }

    func cardTop(_ index: Int) -> CGFloat {
        16 + CGFloat(index) * (cardHeight + 12)
    }

    private var maxOffset: CGFloat {
        max(0, scroll.contentSize.height - scroll.bounds.height)
    }

    private func scrollTo(_ index: Int, anchor: UnitPoint) {
        let top = anchor == .bottom ? cardTop(index) + cardHeight - scroll.bounds.height : cardTop(index)
        scroll.contentOffset.y = min(max(top, 0), maxOffset)
    }

    private func frames() -> [Int: CGRect] {
        var frames: [Int: CGRect] = [:]
        for index in 0..<count {
            let minY = cardTop(index) - scroll.contentOffset.y
            if minY > -550, minY < 1000, !hiddenCards.contains(index) {
                frames[index] = CGRect(x: 16, y: minY, width: 358, height: cardHeight)
            }
        }
        return frames
    }

    /// 一次排版：按当前条数重算内容高度并上报卡片框（不让主队列跑异步的 scrollTo）。
    func layoutOnce() {
        let height = page.controller.snapshot.items.isEmpty ? 0 : cardTop(count) + 60 + extraHeight
        scroll.contentSize = CGSize(width: 390, height: height)
        if reportsFrames {
            tracker.update(frames())
        }
    }

    /// 一轮排版：执行器快照变化（refresh）后重算内容高度、上报卡片框，让主队列跑完异步的 scrollTo；重复到位置稳定。
    func pump() async {
        tracker.refresh()
        for _ in 0..<20 {
            layoutOnce()
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    /// 视口顶部那张卡顶边相对视口顶边的偏移。
    func offset(of index: Int) -> CGFloat {
        cardTop(index) - scroll.contentOffset.y
    }
}

/// 一页结果：卡数与是否还有下一页。
struct PageSpec {
    let count: Int
    let more: Bool
}

/// 恢复场景：页面（带恢复目标）、模拟列表、假接口与各页内容；`respondNext` 按请求顺序回答下一页。
@MainActor
final class Scenario {
    let page: SearchPageConfig
    let sim: ListSim
    let api = ManualSearchApi()
    private let pages: [PageSpec]
    private(set) var answered = 0

    init(anchor: Int, offset: Double, cardHeight: CGFloat, pages: [PageSpec]) {
        self.pages = pages
        let state = SearchPageState(
            conditions: SearchConditions(keyword: "milk"), input: "milk", scrollAnchor: anchor, scrollOffset: offset
        )
        page = SearchPageConfig(
            controller: SearchController(api: api, config: FakeSearchConfig()), history: SearchHistory(),
            texts: TestTexts(), initialQuery: nil, initialPlatform: nil, restored: state
        )
        page.start()
        sim = ListSim(page: page, cardHeight: cardHeight)
    }

    /// 有在途请求就回答下一页，并等执行器处理完。返回是否回答了。
    @discardableResult
    func respondNext() async -> Bool {
        guard api.count > answered, answered < pages.count else { return false }
        let spec = pages[answered]
        let keys = (0..<spec.count).map { "tb:p\(answered)-\($0)" }
        let body = SearchFixtures.page(keys.map { SearchFixtures.card($0) }, more: spec.more)
        api.respond(answered, SearchFixtures.envelope(0, data: body))
        answered += 1
        // 执行器收下这一页（条数到位；恢复可能紧接着翻下一页，所以不等「不在加载」）。
        let expected = pages.prefix(answered).reduce(0) { $0 + $1.count }
        await eventually { self.page.controller.snapshot.items.count == expected }
        return true
    }

    /// 回答所有请求并排版，直到任务结束或不再有进展（最多 `rounds` 轮）。
    func runToEnd(rounds: Int = 30) async {
        for _ in 0..<rounds {
            await respondNext()
            await sim.pump()
            if !sim.tracker.restoring, api.count == answered {
                return
            }
        }
    }

    /// 等第三页时（任务还没挪动，列表在顶部）的恢复场景。
    static func waitingForThirdPage() async -> Scenario {
        let scenario = Scenario(
            anchor: 3, offset: -100, cardHeight: 150,
            pages: [PageSpec(count: 2, more: true), PageSpec(count: 2, more: true), PageSpec(count: 4, more: false)]
        )
        for _ in 0..<6 where scenario.answered < 2 {
            await scenario.respondNext()
            await scenario.sim.pump()
        }
        XCTAssertEqual(scenario.api.count, 3, "第三页在途")
        XCTAssertTrue(scenario.sim.tracker.restoring)
        XCTAssertEqual(scenario.sim.tracker.task?.phase, .waiting)
        XCTAssertEqual(scenario.sim.tracker.baseline, 0, "位置基准：列表顶部")
        XCTAssertEqual(scenario.sim.tracker.moveCount, 0, "等待期间不挪动")
        XCTAssertEqual(scenario.sim.scroll.contentOffset.y, 0)
        return scenario
    }
}

/// 简单的可复现随机数（线性同余），让「任意快照序列」测试每次跑同样的序列、失败可复现。
final class SeededRandom {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed &* 6_364_136_223_846_793_005 &+ 1
    }

    func next(_ upperBound: Int) -> Int {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return Int((state >> 33) % UInt64(upperBound))
    }
}
