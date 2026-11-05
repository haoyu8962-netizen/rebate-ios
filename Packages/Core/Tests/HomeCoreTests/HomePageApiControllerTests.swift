import CouliNetwork
import Foundation
import Generated
@testable import HomeCore
import Router
import XCTest

/// FU-X-HOME-PAGE-API-ios 控制器口径（brief §2.2 第 3、4 条，§3「控制器」；D10-607 D2 / D4 / D5 / D6）：
/// 页面用契约形状（activity_entry 静态、notice_bar api、ops 07:14 回读的 staging home v1 两张商品池卡、只带 channels 的信息流）。
/// 只换端口替身（FakePort）；控制器、存储、策略都是生产实现。对应安卓 e01–e14 与安卓 r1 S1（空页续取遇限流）回归。
@MainActor
final class HomePageApiControllerTests: HomeRigTestCase {
    // MARK: - D2：channels / platforms 两种都认

    /// j01 只带 channels 的契约信息流：解码保留，不进 dropped。
    func testChannelsOnlyFeedIsKept() throws {
        let data = HomeVectors.data(HomeKit.page(version: 1, [HomePageApiPages.channelsFeed()]))
        let page = try XCTUnwrap(HomeJson.parse(data, platform: "ios", appVersion: "1.10.0"))
        XCTAssertEqual(page.sections.map(\.id), ["feed"])
        XCTAssertTrue(page.dropped.isEmpty, "channels 形状被丢弃：\(page.dropped)")
    }

    /// j03 旧 platforms 形状（goldenPages / 本机假服务仍用它，D2 / FU-X-GOLDEN-CHANNELS）照旧能解。
    func testPlatformsFeedStillDecodes() throws {
        let page = try XCTUnwrap(HomeJson.parse(
            HomeVectors.data(HomeKit.page(version: 1, [HomeKit.feed()])), platform: "ios", appVersion: "1.10.0"
        ))
        XCTAssertEqual(page.sections.map(\.id), ["feed"])
        XCTAssertTrue(page.dropped.isEmpty)
    }

    // MARK: - 冷启动：两种数据源都发卡片取数

    /// e01 契约形状页面：取页 1 次；demo-today、demo-grid、feed 各取数 1 次、都不带游标；公告 api 卡仍走 listArticles 1 次；
    /// 三张商品卡都显示；不提示、不强更。
    func testColdStartFetchesEveryDataSourceOnce() async {
        rig.port?.items = { _, _ in .now(HomeKit.items(0..<3, next: nil)) }
        let controller = await show(HomeKit.page(version: 1, [
            HomeKit.activity("act", titles: ["测试入口"]), HomeKit.noticeApi("nb"), HomePageApiPages.demoToday(),
            HomePageApiPages.demoGrid(),
            HomePageApiPages.channelsFeed(),
        ]))
        await controller.whenIdle()
        XCTAssertEqual(rig.port?.pageCalls.count, 1)
        XCTAssertEqual(rig.port?.itemCalls.sorted(), ["demo-grid|", "demo-today|", "feed|"])
        XCTAssertEqual(rig.articles.calls.map(\.operationId), ["listArticles"], "公告 api 卡仍走 listArticles")
        XCTAssertEqual(rig.articles.calls.first?.query, "category=notice")
        for id in ["demo-today", "demo-grid", "feed"] {
            XCTAssertEqual(keys(controller, id).count, 3, "\(id) 没显示")
        }
        XCTAssertNil(controller.state.toast)
        XCTAssertEqual(rig.forceUpdates, 0)
    }

    /// e02 / D6 商品池卡只取一页：有 next_cursor 也不翻页。
    func testPoolTakesOnlyOnePage() async {
        rig.port?.items = { _, _ in .now(HomeKit.items(0..<3, next: "more")) }
        let controller = await show(HomeKit.page(version: 1, [HomePageApiPages.demoToday()]))
        await controller.whenIdle()
        XCTAssertEqual(calls("demo-today"), ["demo-today|"])
        XCTAssertEqual(keys(controller, "demo-today").count, 3)
    }

    // MARK: - D4：只在还没有任何商品时，对「items 空但带游标」接着取，最多 3 次

    /// e04 信息流首屏 `items: []` 带游标：不等触底，自己接着取，取到后显示。
    func testEmptyFirstFeedPageWithCursorContinuesByItself() async {
        rig.port?.items = { _, cursor in
            cursor == nil ? .now(HomePageApiPages.empty(next: "c2")) : .now(HomeKit.items(0..<2, next: nil))
        }
        let controller = await show(HomeKit.page(version: 1, [HomePageApiPages.channelsFeed()]))
        await controller.whenIdle()
        XCTAssertEqual(calls("feed"), ["feed|", "feed|c2"])
        XCTAssertEqual(keys(controller, "feed"), ["test:p0", "test:p1"])
    }

    /// e05 D4 上限：连续空页带游标 c2→c5，请求恰为 feed|、c2、c3、c4（1 + 3），第 4 次不取；卡隐藏、不提示。
    func testFeedContinuesAtMostThreeTimes() async {
        rig.port?.items = { _, cursor in
            switch cursor {
            case nil: .now(HomePageApiPages.empty(next: "c2"))
            case "c2": .now(HomePageApiPages.empty(next: "c3"))
            case "c3": .now(HomePageApiPages.empty(next: "c4"))
            case "c4": .now(HomePageApiPages.empty(next: "c5"))
            default: .now(HomeKit.items(0..<2, next: nil))
            }
        }
        let controller = await show(HomeKit.page(version: 1, [HomePageApiPages.channelsFeed()]))
        await controller.whenIdle()
        XCTAssertEqual(calls("feed"), ["feed|", "feed|c2", "feed|c3", "feed|c4"], "D4：恰好 1 + 3 次")
        XCTAssertNil(controller.state.section("feed"), "续取用完仍没有商品：卡隐藏")
        XCTAssertNil(controller.state.toast)
    }

    /// 同一上限对商品池卡：pool|、c2、c3、c4，之后不再取。
    func testPoolContinuesAtMostThreeTimes() async {
        rig.port?.items = { _, cursor in
            switch cursor {
            case nil: .now(HomePageApiPages.empty(next: "c2"))
            case "c2": .now(HomePageApiPages.empty(next: "c3"))
            case "c3": .now(HomePageApiPages.empty(next: "c4"))
            case "c4": .now(HomePageApiPages.empty(next: "c5"))
            default: .now(HomeKit.items(0..<2, next: nil))
            }
        }
        let controller = await show(HomeKit.page(version: 1, [HomePageApiPages.demoToday()]))
        await controller.whenIdle()
        XCTAssertEqual(calls("demo-today"), ["demo-today|", "demo-today|c2", "demo-today|c3", "demo-today|c4"])
        XCTAssertNil(controller.state.section("demo-today"))
    }

    /// e06 D4「只在还没有商品时」：信息流已有商品后，下一页空但带游标，不自己续取；保留商品、仍可触底；下一次触底才取。
    func testFeedWithItemsDoesNotAutoContinueOnEmptyPage() async throws {
        rig.port?.items = { _, cursor in
            switch cursor {
            case nil: .now(HomeKit.items(0..<4, next: "p2"))
            case "p2": .now(HomePageApiPages.empty(next: "p3"))
            default: .now(HomeKit.items(4..<6, next: nil))
            }
        }
        let controller = await show(HomeKit.page(version: 1, [HomePageApiPages.channelsFeed()]))
        await controller.whenIdle()
        controller.loadMore(try XCTUnwrap(controller.state.section("feed")?.feed?.ticket))
        await controller.whenIdle()
        XCTAssertEqual(calls("feed"), ["feed|", "feed|p2"], "已有商品时空页不得自己续取")
        XCTAssertEqual(keys(controller, "feed").count, 4, "已有商品保留")
        let feed = try XCTUnwrap(controller.state.section("feed")?.feed)
        XCTAssertFalse(feed.exhausted, "带游标的空页不是到底")
        controller.loadMore(feed.ticket)
        await controller.whenIdle()
        XCTAssertEqual(calls("feed"), ["feed|", "feed|p2", "feed|p3"])
        XCTAssertEqual(keys(controller, "feed").count, 6)
    }

    /// e07 D4 同样适用于商品池卡；取到一页商品之后不再翻页（D6）。
    func testPoolEmptyFirstPageContinuesThenStopsAfterItems() async {
        rig.port?.items = { _, cursor in
            cursor == nil ? .now(HomePageApiPages.empty(next: "c2")) : .now(HomeKit.items(0..<3, next: "c3"))
        }
        let controller = await show(HomeKit.page(version: 1, [HomePageApiPages.demoGrid()]))
        await controller.whenIdle()
        XCTAssertEqual(calls("demo-grid"), ["demo-grid|", "demo-grid|c2"])
        XCTAssertEqual(keys(controller, "demo-grid").count, 3)
    }

    /// e08 空数据源只隐藏自己那一张（宫格、信息流）；空且无游标不续取。
    func testEmptySourcesWithoutCursorHideOnlyThemselves() async {
        rig.port?.items = { _, _ in .now(HomePageApiPages.empty(next: nil)) }
        let controller = await show(HomeKit.page(version: 1, [
            HomeKit.activity("act", titles: ["测试入口"]), HomePageApiPages.demoGrid(), HomePageApiPages.channelsFeed(),
        ]))
        await controller.whenIdle()
        XCTAssertEqual(rig.port?.itemCalls.sorted(), ["demo-grid|", "feed|"])
        XCTAssertEqual(controller.state.sectionIds, ["act"])
    }
}

/// 契约形状的页面与数据（两个测试类共用）。
enum HomePageApiPages {
    /// ops 07:14 回读的 demo-today（product_scroll，props 只有 title）。
    static func demoToday() -> [String: Any] {
        [
            "id": "demo-today", "type": "product_scroll", "version": 1, "props": ["title": "演示 · 今日推荐"],
            "data_source": ["kind": "product_pool", "limit": 10, "pool_id": "01a1a33a-f20f-7c9d-84c7-28db459b845f"],
        ]
    }

    /// ops 07:14 回读的 demo-grid（product_grid，columns 2）。
    static func demoGrid() -> [String: Any] {
        [
            "id": "demo-grid", "type": "product_grid", "version": 1, "props": ["title": "演示 · 精选好物", "columns": 2],
            "data_source": ["kind": "product_pool", "limit": 20, "pool_id": "01a1a33a-f20f-7c9d-84c7-28db459b845f"],
        ]
    }

    /// 契约 fixture home-golden/union-material.json（00deded0ef6f）里 feed 那一张：只有 channels，没有 platforms。
    static func channelsFeed(_ id: String = "feed") -> [String: Any] {
        [
            "id": id, "type": "feed_infinite", "version": 1,
            "data_source": [
                "kind": "union_material",
                "channels": [
                    ["platform": "taobao", "channel_id": "demo_channel_1"],
                    ["platform": "jd", "channel_id": "demo_channel_2"],
                ],
                "mix": "interleave",
            ] as [String: Any],
        ]
    }

    static func empty(next: String?) -> ApiResult {
        HomeKit.items(0..<0, next: next)
    }
}

extension HomeRigTestCase {
    func calls(_ section: String) -> [String] {
        (rig.port?.itemCalls ?? []).filter { $0.hasPrefix(section + "|") }
    }

    func keys(_ controller: HomeController, _ section: String) -> [String] {
        controller.state.section(section)?.items.compactMap(\.product?.productKey) ?? []
    }
}
