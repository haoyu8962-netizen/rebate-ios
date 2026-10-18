import CouliNetwork
import Foundation
import Generated
@testable import HomeCore
import Router
import XCTest

/// 物料信息流（brief §2 第 8 条；cross-platform-lessons 第 6、34、35 条）：每页只请求一次、到底即停、一页失败只停在【重试】、限流到期自动继续。
@MainActor
final class HomeFeedTests: HomeRigTestCase {
    /// 触底加载下一页：每页只请求一次，next_cursor 为空即到底、不再请求；结果按顺序追加。
    func testFeedLoadsNextPageOnceAndStopsAtTheEnd() async throws {
        let controller = await show(try HomeVectors.golden("feed_infinite"))
        await controller.whenIdle()
        var feed = try XCTUnwrap(controller.state.section("feed"))
        XCTAssertEqual(feed.items.compactMap(\.product?.productKey), (0..<4).map { "test:p\($0)" })
        let ticket = try XCTUnwrap(feed.feed?.ticket)
        controller.loadMore(ticket)
        controller.loadMore(ticket)
        await controller.whenIdle()
        feed = try XCTUnwrap(controller.state.section("feed"))
        XCTAssertEqual(feed.items.compactMap(\.product?.productKey), (0..<6).map { "test:p\($0)" })
        XCTAssertEqual(feed.feed?.exhausted, true)
        controller.loadMore(try XCTUnwrap(feed.feed?.ticket))
        await controller.whenIdle()
        XCTAssertEqual(rig.port?.itemCalls, ["feed|", "feed|p2"], "每页只请求一次、到底不再请求")
    }

    /// 一页失败：只停止加载，底部给【重试】（实际文案带 trace6），上方卡片不受影响；【重试】按原游标重取，新内容显示。
    func testFeedPageFailureShowsRetryRowWithTrace6AndRetryLoadsSameCursor() async throws {
        rig.port?.items = { _, cursor in
            cursor == nil ? .now(HomeKit.items(0..<4, next: "p2")) : .now(HomeKit.failure(
                50001,
                trace: "trace-test-FEED99"
            ))
        }
        let controller = await show(HomeKit.page(
            version: 45,
            [HomeKit.activity("act", titles: ["测试入口"]), HomeKit.feed()]
        ))
        await controller.whenIdle()
        controller.loadMore(try XCTUnwrap(controller.state.section("feed")?.feed?.ticket))
        await controller.whenIdle()
        let failure = try XCTUnwrap(controller.state.section("feed")?.feed?.failure)
        XCTAssertTrue(failure.message.contains("FEED99"), failure.message)
        XCTAssertTrue(failure.retryEnabled)
        XCTAssertEqual(controller.state.sectionIds, ["act", "feed"])
        XCTAssertEqual(controller.state.section("feed")?.items.count, 4, "已加载的条目保留")
        rig.port?.items = { _, cursor in .now(HomeKit.items(cursor == nil ? 0..<4 : 7..<9, next: nil)) }
        controller.retryFeed(try XCTUnwrap(controller.state.section("feed")?.feed?.ticket))
        await controller.whenIdle()
        XCTAssertEqual(rig.port?.itemCalls.last, "feed|p2")
        XCTAssertNil(controller.state.section("feed")?.feed?.failure)
        XCTAssertEqual(controller.state.section("feed")?.items.last?.product?.productKey, "test:p8")
    }

    /// 信息流首屏「成功但为空」隐藏卡片；首屏失败保留独立的重试行（与空区分，共性第 6 条）。
    func testFeedEmptySuccessHidesButFirstPageFailureKeepsRetryRow() async throws {
        rig.port?.items = { _, _ in .now(HomeKit.items(0..<0, next: nil)) }
        let empty = await show(try HomeVectors.golden("feed_infinite"))
        await empty.whenIdle()
        XCTAssertNil(empty.state.section("feed"))
        rig.port?.items = { _, _ in .now(HomeKit.offline) }
        let failed = await show(try HomeVectors.golden("feed_infinite"))
        await failed.whenIdle()
        let feed = try XCTUnwrap(failed.state.section("feed"), "首屏失败要保留重试行")
        XCTAssertNotNil(feed.feed?.failure)
    }

    /// 触底时正处在限流禁用期：不发请求、【重试】置灰；到期后按原票据自动继续（共性第 34 条），不需要用户再触底。
    func testFeedBottomDuringRateLimitResumesOnExpiry() async throws {
        let controller = await show(try HomeVectors.golden("feed_infinite"))
        await controller.whenIdle()
        rig.gate.start(1000)
        controller.loadMore(try XCTUnwrap(controller.state.section("feed")?.feed?.ticket))
        await controller.whenIdle()
        XCTAssertEqual(rig.port?.itemCalls, ["feed|"], "禁用期内不得发出")
        XCTAssertNil(controller.state.section("feed")?.feed?.failure, "本地拦下不算失败")
        rig.clock.advance(1000)
        await waitFor("禁用期到了自动继续加载") { rig.port?.itemCalls.contains("feed|p2") == true }
        await controller.whenIdle()
        XCTAssertEqual(controller.state.section("feed")?.items.count, 6)
    }

    /// 服务端 42901：信息流显示 42901 文案（不带编号）、【重试】随禁用期置灰，到期恢复；共享闸门写入。
    func testFeedServer42901GreysRetryUntilExpiry() async throws {
        rig.port?.items = { _, cursor in
            cursor == nil ? .now(HomeKit.items(0..<4, next: "p2")) : .now(HomeKit.failure(42901, retryAfter: "1"))
        }
        let controller = await show(try HomeVectors.golden("feed_infinite"))
        await controller.whenIdle()
        controller.loadMore(try XCTUnwrap(controller.state.section("feed")?.feed?.ticket))
        await controller.whenIdle()
        let failure = try XCTUnwrap(controller.state.section("feed")?.feed?.failure)
        XCTAssertEqual(failure.message, "error.42901")
        XCTAssertFalse(failure.retryEnabled)
        XCTAssertTrue(rig.gate.active)
        rig.clock.advance(1000)
        await waitFor("【重试】到期恢复") { controller.state.section("feed")?.feed?.failure?.retryEnabled == true }
    }

    /// 数据源请求绕过 ApiClient：收到 10405 自己接强更分流（共性第 26 条）。
    func testSectionItems10405EntersForceUpdate() async throws {
        rig.port?.items = { _, _ in .now(HomeKit.failure(10405)) }
        let controller = await show(try HomeVectors.golden("product_scroll"))
        await controller.whenIdle()
        XCTAssertEqual(rig.forceUpdates, 1)
        XCTAssertNil(controller.state.section("scroll"))
    }

    /// 每张卡的数据源请求只收最新：替换页面（下拉）之后，旧渲染发出的商品池请求迟到，不覆盖新渲染取到的内容（brief §0）。
    func testLatePoolResponseFromReplacedRenderIsDropped() async throws {
        let first = Hold()
        let calls = CallCounter()
        rig.port?.items = { _, _ in
            calls.next() == 1 ? .held(first) : .now(HomeKit.items(7..<9, next: nil))
        }
        try rig.seedLkg(HomeKit.page(version: 50, [HomeKit.pool("scroll")]))
        let controller = rig.controller()
        controller.start()
        await waitFor("旧渲染的商品池请求已发出") { rig.port?.itemCalls.count == 1 }
        rig.port?.setPage(HomeKit.ok(HomeKit.page(version: 51, [HomeKit.pool("scroll")])))
        controller.refresh(controller.state.render)
        await waitFor("新渲染取到商品") {
            controller.state.section("scroll")?.items.compactMap(\.product?.productKey) == ["test:p7", "test:p8"]
        }
        first.release(HomeKit.items(0..<4, next: nil))
        await controller.whenIdle()
        XCTAssertEqual(controller.state.pageVersion, 51)
        XCTAssertEqual(
            controller.state.section("scroll")?.items.compactMap(\.product?.productKey), ["test:p7", "test:p8"],
            "旧渲染的迟到结果覆盖了新内容"
        )
    }

    /// 信息流同样不过滤零返利商品：两页混排，数量、顺序、标识完整保留（评审 T-23）。
    func testZeroRebateProductsAreNeverFilteredFromFeed() async throws {
        rig.port?.items = { _, cursor in
            cursor == nil ? .now(HomeKit.mixedRebateItems(next: "p2")) : .now(HomeKit.ok([
                "items": [HomeKit.zeroRebateProduct(6), HomeKit.product(7)], "next_cursor": NSNull(),
            ]))
        }
        let controller = await show(try HomeVectors.golden("feed_infinite"))
        await controller.whenIdle()
        controller.loadMore(try XCTUnwrap(controller.state.section("feed")?.feed?.ticket))
        await controller.whenIdle()
        XCTAssertEqual(
            controller.state.section("feed")?.items.compactMap(\.product?.productKey),
            HomeKit.mixedRebateKeys + ["test:z6", "test:p7"]
        )
    }

    /// 首屏被本地限流拦下（还没发出）：到期自动重做，取到的内容被采用，不需要下拉（共性第 34 条、A31；评审 T-20）。
    func testGatedFirstLoadsOfPoolAndApiNoticeResumeOnExpiry() async throws {
        rig.port?.items = { _, _ in .now(HomeKit.items(7..<9, next: nil)) }
        rig.articles.fallback = HomeKit.notices([HomeKit.noticeItem("late", text: "测试到期后的公告")])
        // 页面来自 LKG（立即显示），只有两个数据源的首屏请求落在禁用期里
        try rig.seedLkg(HomeKit.page(version: 44, [HomeKit.pool("scroll"), HomeKit.noticeApi("nb")]))
        rig.gate.start(1000)
        let controller = rig.controller()
        controller.start()
        await controller.whenIdle()
        XCTAssertTrue(rig.port?.itemCalls.isEmpty ?? false, "禁用期内发了商品池请求")
        XCTAssertTrue(rig.articles.calls.isEmpty, "禁用期内发了公告请求")
        rig.clock.advance(1000)
        await waitFor("禁用期到了首屏数据没有自动重做") {
            controller.state.section("scroll")?.items.compactMap(\.product?.productKey) == ["test:p7", "test:p8"]
                && controller.state.section("nb")?.items.compactMap(\.title) == ["测试到期后的公告"]
        }
    }

    /// 商品池首屏收到服务端 42901：到期后自动重做，新内容被采用，不需要下拉（评审 T-20）。
    func testServer42901OnPoolFirstLoadRetriesOnExpiry() async {
        let poolCalls = CallCounter()
        rig.port?.items = { _, _ in
            poolCalls.next() == 1 ? .now(HomeKit.failure(42901, retryAfter: "1")) : .now(HomeKit.items(
                7..<9,
                next: nil
            ))
        }
        let controller = await show(HomeKit.page(version: 45, [HomeKit.pool("scroll")]))
        await controller.whenIdle()
        XCTAssertNil(controller.state.section("scroll"), "前提：首屏 42901 时整卡隐藏")
        XCTAssertTrue(rig.gate.active)
        rig.clock.advance(1000)
        await waitFor("禁用期到了商品池没有自动重做") {
            controller.state.section("scroll")?.items.compactMap(\.product?.productKey) == ["test:p7", "test:p8"]
        }
        await controller.whenIdle()
        XCTAssertEqual(rig.port?.pageCalls.count, 1, "恢复靠到期重做，不是重新拉页面")
    }

    /// api 公告首屏收到服务端 42901：到期后自动重做，新内容被采用（评审 T-20）。
    func testServer42901OnApiNoticeFirstLoadRetriesOnExpiry() async {
        rig.articles.queue(.now(HomeKit.failure(42901, retryAfter: "1")))
        rig.articles.fallback = HomeKit.notices([HomeKit.noticeItem("again", text: "测试重做后的公告")])
        let controller = await show(HomeKit.page(version: 46, [HomeKit.noticeApi("nb")]))
        await controller.whenIdle()
        XCTAssertNil(controller.state.section("nb"), "前提：首屏 42901 时整卡隐藏")
        XCTAssertTrue(rig.gate.active)
        rig.clock.advance(1000)
        await waitFor("禁用期到了公告没有自动重做") {
            controller.state.section("nb")?.items.compactMap(\.title) == ["测试重做后的公告"]
        }
        await controller.whenIdle()
        XCTAssertEqual(rig.port?.pageCalls.count, 1, "恢复靠到期重做，不是重新拉页面")
    }
}

/// 线程安全的调用计数（端口替身里按第几次给应答）。
final class CallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func next() -> Int {
        lock.withLock {
            count += 1
            return count
        }
    }
}
