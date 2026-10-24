import Foundation
import HomeCore
import XCTest

/// S1-2：初始商品已显示；加载行保持原地时仍自动消费新游标，不能靠测试主动 loadMore 或滚动唤醒。
@MainActor
final class HomeVisualFeedPagingTests: XCTestCase {
    override func setUp() {
        HomeColorBlockImages.install()
    }

    override func tearDown() {
        HomeColorBlockImages.uninstall()
    }

    func testEmptyNextPageWithNewCursorContinuesWithoutMovingLoadingRow() async throws {
        try await consecutivePages(fillsPair: false)
    }

    func testOneNewProductCompletingTwoColumnRowContinuesWithoutMovingLoadingRow() async throws {
        try await consecutivePages(fillsPair: true)
    }

    private func consecutivePages(fillsPair: Bool) async throws {
        let port = try HomeVisualPagingPort(fillsPair: fillsPair)
        let fixture = try HomeVisualFixture(portOverride: port)
        addTeardownBlock { @MainActor in await fixture.close() }
        defer { port.releaseAll() }
        await fixture.start()
        XCTAssertEqual(fixture.controller.state.source, .network)
        XCTAssertEqual(port.itemCalls, ["feed|"], "未挂视图时只请求第一页，不能由替身替视图连续翻页")
        XCTAssertEqual(fixture.controller.state.section("feed")?.items.count, port.initialCount)

        let view = HomeVisualFeedHost(controller: fixture.controller)
        defer { view.close() }
        try await until("真实视图自动请求 p2") { port.itemCalls.contains("feed|p2") }
        let before = try await stableGeometry(view, count: port.initialCount)
        XCTAssertTrue(before.viewport.contains(before.status), "加载圈必须真实进入可视区")
        XCTAssertGreaterThan(before.status.height, 0)
        try await assertCallsRemain(port, expected: ["feed|", "feed|p2"])

        port.release("p2")
        try await until("原地加载行自动请求新游标 p3") { port.itemCalls.contains("feed|p3") }
        let after = try await stableGeometry(view, count: port.afterSecondCount)
        XCTAssertEqual(after.status.minY, before.status.minY, accuracy: 0.5, "前提：加载行 top 没有移动")
        XCTAssertEqual(after.status.height, before.status.height, accuracy: 0.5)
        XCTAssertEqual(after.offset, before.offset, "不允许通过改变滚动位置救活翻页")
        XCTAssertEqual(after.viewport, before.viewport, "测试期间不能靠视口变化触发")
        XCTAssertTrue(after.viewport.contains(after.status))
        XCTAssertEqual(after.cards.count, 2)
        XCTAssertEqual(after.cards[0].minY, after.cards[1].minY, accuracy: 0.5, "必须是同一个双列行")
        XCTAssertGreaterThan(after.cards[1].minX, after.cards[0].maxX)
        XCTAssertEqual(after.cards[0].height, before.cards[0].height, accuracy: 0.5)
        if !fillsPair {
            XCTAssertEqual(after.cards, before.cards, "空页不改变商品布局")
        }
        XCTAssertEqual(fixture.controller.state.section("feed")?.items.count, port.afterSecondCount)
        try await assertCallsRemain(port, expected: ["feed|", "feed|p2", "feed|p3"])

        port.release("p3")
        try await until("第三页真正合入并到尾") {
            let feed = fixture.controller.state.section("feed")
            return feed?.feed?.exhausted == true && feed?.feed?.loading == false
        }
        XCTAssertEqual(
            fixture.controller.state.section("feed")?.items.compactMap(\.product?.productKey),
            port.finalKeys
        )
        XCTAssertNil(fixture.controller.state.section("feed")?.feed?.failure)
        try await assertCallsRemain(port, expected: ["feed|", "feed|p2", "feed|p3"])
        XCTAssertEqual(Set(port.itemCalls).count, port.itemCalls.count, "同一游标不得重复请求")
        XCTAssertEqual(port.pageCalls, 1, "全过程不刷新页面")
        XCTAssertTrue(HomeColorBlockImages.unexpected.isEmpty)
    }

    private func stableGeometry(_ view: HomeVisualFeedHost, count: Int) async throws -> HomeVisualFeedHost.Geometry {
        var previous: HomeVisualFeedHost.Geometry?
        var stable = 0
        try await until("真实加载圈与商品布局连续三次稳定") {
            guard let current = view.geometry(), current.cards.count == count else {
                previous = nil
                stable = 0
                return false
            }
            stable = current == previous ? stable + 1 : 1
            previous = current
            return stable >= 3
        }
        return try XCTUnwrap(previous)
    }

    private func assertCallsRemain(_ port: HomeVisualPagingPort, expected: [String]) async throws {
        // 在途、结算后都持续观察；仅看某一瞬间的计数会漏掉晚到的重复请求。
        for _ in 0..<6 {
            XCTAssertEqual(port.itemCalls, expected)
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    private func until(_ message: String, _ condition: () -> Bool) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(5))
        while !condition() {
            guard clock.now < deadline else {
                XCTFail("等待超时：\(message)")
                throw PagingTimeout()
            }
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    private struct PagingTimeout: Error {}
}
