import CouliNetwork
import Foundation
import Generated
@testable import HomeCore
import Router
import XCTest

/// 续：安卓 r1 S1 回归（空页续取遇限流）、D5（30701 / 断网沿用现有兜底）、下拉换页、基本模式。
@MainActor
final class HomePageApiRecoveryTests: HomeRigTestCase {
    // MARK: - 安卓 r1 S1：空页续取遇限流，闸门放开后恢复原游标，保留已用掉的续取次数

    /// 商品池卡：续取到 c3 时被本地闸门拦下（另一张卡收到 42901），到期后从 c3 接着取；已用掉的次数保留（总数仍是 1 + 3）。
    func testPoolContinuationBlockedByLocalGateResumesWithCursorAndKeepsCount() async {
        let other = Hold()
        let atC2 = Hold()
        let otherCalls = CallCounter()
        rig.port?.items = { section, cursor in
            if section == "demo-grid" {
                return otherCalls.next() == 1 ? .held(other) : .now(HomeKit.items(0..<1, next: nil))
            }
            switch cursor {
            case nil: return .now(HomePageApiPages.empty(next: "c2"))
            case "c2": return .held(atC2)
            case "c3": return .now(HomePageApiPages.empty(next: "c4"))
            case "c4": return .now(HomePageApiPages.empty(next: "c5"))
            default: return .now(HomeKit.items(0..<2, next: nil))
            }
        }
        try? rig.lkg.clearAll()
        rig.port?.setPage(HomeKit.ok(HomeKit.page(
            version: 1,
            [HomePageApiPages.demoToday(), HomePageApiPages.demoGrid()]
        )))
        let controller = rig.controller()
        controller.start()
        await waitFor("续取 c2 已发出") { self.calls("demo-today").contains("demo-today|c2") && other.entered }
        other.release(HomeKit.failure(42901, retryAfter: "1"))
        await waitFor("另一张卡的 42901 开启共享闸门") { self.rig.gate.active }
        atC2.release(HomePageApiPages.empty(next: "c3"))
        await controller.whenIdle()
        XCTAssertEqual(calls("demo-today"), ["demo-today|", "demo-today|c2"], "前提：c3 落在禁用期里，没有发出")
        rig.clock.advance(1000)
        await waitFor("闸门放开后没有从原游标恢复") { self.calls("demo-today").contains("demo-today|c3") }
        await controller.whenIdle()
        XCTAssertEqual(
            calls("demo-today"), ["demo-today|", "demo-today|c2", "demo-today|c3", "demo-today|c4"],
            "恢复要用原游标（不从头取）并保留已用掉的续取次数"
        )
        XCTAssertNil(controller.state.section("demo-today"))
    }

    /// 商品池卡：续取请求本身收到服务端 42901，到期后用同一游标重取，取到商品后显示（不需要整页刷新）。
    func testPoolContinuationServer42901ResumesWithSameCursor() async {
        let c2Calls = CallCounter()
        rig.port?.items = { _, cursor in
            if cursor == nil {
                return .now(HomePageApiPages.empty(next: "c2"))
            }
            if c2Calls.next() == 1 {
                return .now(HomeKit.failure(42901, retryAfter: "1"))
            }
            return .now(HomeKit.items(0..<2, next: nil))
        }
        let controller = await show(HomeKit.page(version: 1, [HomePageApiPages.demoToday()]))
        await controller.whenIdle()
        XCTAssertTrue(rig.gate.active, "前提：续取收到 42901")
        rig.clock.advance(1000)
        await waitFor("闸门放开后商品池卡没有恢复") { self.keys(controller, "demo-today").count == 2 }
        XCTAssertEqual(calls("demo-today"), ["demo-today|", "demo-today|c2", "demo-today|c2"], "要用原游标重取")
        XCTAssertEqual(rig.port?.pageCalls.count, 1, "恢复不靠整页刷新")
    }

    /// 信息流：首屏空页带游标，续取 c2 时落在本地禁用期里；到期后从 c2 接着取并显示。
    func testFeedContinuationBlockedByLocalGateResumesWithCursor() async {
        let other = Hold()
        let otherCalls = CallCounter()
        let first = Hold()
        rig.port?.items = { section, cursor in
            if section == "demo-today" {
                return otherCalls.next() == 1 ? .held(other) : .now(HomeKit.items(0..<1, next: nil))
            }
            return cursor == nil ? .held(first) : .now(HomeKit.items(0..<2, next: nil))
        }
        try? rig.lkg.clearAll()
        rig.port?.setPage(HomeKit.ok(HomeKit.page(
            version: 1,
            [HomePageApiPages.demoToday(), HomePageApiPages.channelsFeed()]
        )))
        let controller = rig.controller()
        controller.start()
        await waitFor("两张卡的首屏都已发出") { first.entered && other.entered }
        other.release(HomeKit.failure(42901, retryAfter: "1"))
        await waitFor("共享闸门开启") { self.rig.gate.active }
        first.release(HomePageApiPages.empty(next: "c2"))
        await controller.whenIdle()
        XCTAssertEqual(calls("feed"), ["feed|"], "前提：c2 落在禁用期里，没有发出")
        rig.clock.advance(1000)
        await waitFor("闸门放开后信息流没有恢复") { self.keys(controller, "feed").count == 2 }
        XCTAssertEqual(calls("feed"), ["feed|", "feed|c2"], "要用原游标接着取")
    }

    /// 信息流：续取请求收到服务端 42901。到期后卡片不得永久隐藏——要么自动用 c2 重取，要么露出可点的【重试】且重试用 c2。
    func testFeedContinuationServer42901IsRecoverable() async throws {
        let c2Calls = CallCounter()
        rig.port?.items = { _, cursor in
            if cursor == nil {
                return .now(HomePageApiPages.empty(next: "c2"))
            }
            if c2Calls.next() == 1 {
                return .now(HomeKit.failure(42901, retryAfter: "1"))
            }
            return .now(HomeKit.items(0..<2, next: nil))
        }
        let controller = await show(HomeKit.page(version: 1, [HomePageApiPages.channelsFeed()]))
        await controller.whenIdle()
        XCTAssertTrue(rig.gate.active, "前提：续取收到 42901")
        rig.clock.advance(1000)
        await waitFor("到期后信息流既没有自动重取，也没有可点的重试") {
            self.calls("feed").count >= 3 || controller.state.section("feed")?.feed?.failure?.retryEnabled == true
        }
        await controller.whenIdle()
        if calls("feed").count < 3 {
            let feed = try XCTUnwrap(controller.state.section("feed")?.feed)
            XCTAssertEqual(feed.ticket.cursor, "c2", "重试票据要带原游标")
            controller.retryFeed(feed.ticket)
            await controller.whenIdle()
        }
        XCTAssertEqual(calls("feed"), ["feed|", "feed|c2", "feed|c2"])
        XCTAssertEqual(keys(controller, "feed").count, 2)
    }

    // MARK: - D5：30701 / 断网沿用现有兜底

    /// e09 单卡 30701 / 断网不影响整页：不提示、不强更、不进整页失败。
    func testSingleCardFailureLeavesThePageAlone() async {
        rig.port?.items = { section, _ in
            section == "demo-today" ? .now(HomeKit.failure(30701)) : .now(HomeKit.offline)
        }
        let controller = await show(HomeKit.page(version: 1, [
            HomeKit.activity("act", titles: ["测试入口"]), HomePageApiPages.demoToday(), HomePageApiPages.demoGrid(),
        ]))
        await controller.whenIdle()
        XCTAssertEqual(controller.state.sectionIds, ["act"])
        XCTAssertNil(controller.state.toast)
        XCTAssertNil(controller.state.loadFailed)
        XCTAssertEqual(rig.forceUpdates, 0)
    }

    /// e10 页面 30701、没有 LKG：1.5 秒内不显示，之后包内默认；不取卡、不写 LKG、不提示、不强更。
    func testPage30701WithoutLkgFallsBackToBundledAfter1500() async {
        try? rig.lkg.clearAll()
        rig.port?.setPage(HomeKit.failure(30701))
        let controller = rig.controller()
        await rig.start(controller)
        rig.clock.advance(1499)
        XCTAssertNil(controller.state.source, "1.5 秒内不显示")
        rig.clock.advance(1)
        await controller.whenIdle()
        XCTAssertEqual(controller.state.source, .bundled)
        XCTAssertNil(rig.readLkgVersion(), "30701 不得写 LKG")
        XCTAssertNil(controller.state.toast)
        XCTAssertNil(controller.state.loadFailed)
        XCTAssertEqual(rig.forceUpdates, 0, "30701 不得进强更")
        XCTAssertTrue(rig.port?.itemCalls.isEmpty ?? false)
    }

    /// e11 有 LKG 照显 LKG；下拉刷新 30701 保留当前屏、提示一次（文案就是现有 HomeErrors，不新造）、不改写 LKG、不强更。
    func testPull30701KeepsLkgAndToastsExistingMessage() async throws {
        try rig.seedLkg(HomeKit.page(version: 9, [HomeKit.activity("act", titles: ["测试缓存"])]))
        let failure = HomeKit.failure(30701)
        rig.port?.setPage(failure)
        let controller = rig.controller()
        await rig.start(controller)
        XCTAssertEqual(controller.state.source, .lkg)
        controller.refresh(controller.state.render)
        await controller.whenIdle()
        XCTAssertEqual(controller.state.source, .lkg)
        XCTAssertEqual(controller.state.pageVersion, 9)
        let expected = HomeErrors.failure(failure, blocked: false, text: HomeKit.text).message
        XCTAssertEqual(controller.state.toast?.message, expected)
        XCTAssertEqual(rig.readLkgVersion(), 9)
        XCTAssertEqual(rig.forceUpdates, 0)
        XCTAssertNil(controller.state.loadFailed)
    }

    /// e13 下拉刷新换成新页面，并按新页面重新取卡。
    func testPullRefreshFetchesCardsOfTheNewPage() async {
        rig.port?.items = { _, _ in .now(HomeKit.items(0..<2, next: nil)) }
        let controller = await show(HomeKit.page(version: 1, [HomePageApiPages.demoToday()]))
        await controller.whenIdle()
        rig.port?.setPage(HomeKit.ok(HomeKit.page(version: 2, [HomePageApiPages.demoGrid()])))
        controller.refresh(controller.state.render)
        await controller.whenIdle()
        XCTAssertEqual(controller.state.pageVersion, 2)
        XCTAssertEqual(rig.port?.itemCalls, ["demo-today|", "demo-grid|"])
        XCTAssertEqual(controller.state.sectionIds, ["demo-grid"])
    }

    /// e14 基本模式照样取页、取卡，HomeCall 全部 anonymous。
    func testBasicModeFetchesPageAndCardsAnonymously() async {
        rig.port?.items = { _, _ in .now(HomeKit.items(0..<2, next: nil)) }
        let controller = await show(
            HomeKit.page(version: 1, [HomePageApiPages.demoToday(), HomePageApiPages.channelsFeed()]),
            identity: HomeKit.basic
        )
        await controller.whenIdle()
        XCTAssertEqual(rig.port?.pageCalls.map(\.anonymous), [true])
        XCTAssertEqual(rig.port?.itemCallObjects.map(\.anonymous), [true, true])
        XCTAssertEqual(keys(controller, "demo-today").count, 2)
        XCTAssertEqual(keys(controller, "feed").count, 2)
    }
}
