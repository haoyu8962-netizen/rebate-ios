import CouliNetwork
import Foundation
@testable import HomeCore
import XCTest

/// 三级兜底（TECH-10，F-HOME-04，G16 ①–⑧；AC-HOME-01、AC-HOME-04；brief §2 第 19 条「AC-HOME-04 / 三级兜底」）。
/// 经生产 `HomeController`（端口换替身、计时手动推进）。完成信号是生产的 `whenIdle()`（等本控制器发起的全部任务，含端口请求）；
/// 有请求被测试挂住时不能等它，只做正向等待（条件成立即止），负向断言都在 `whenIdle()` 之后或在挂住期间不可能变化的状态上。
@MainActor
final class HomeFallbackTests: HomeRigTestCase {
    // MARK: - 无 LKG

    /// 无 LKG、网络 500 → 不白屏、不弹整页错误：1.5 秒前不显示包内默认（还在等网络），满 1.5 秒显示包内默认；不提示。
    func testNoLkgAnd500ShowsBundledDefaultAt1500WithoutErrorOrToast() async {
        rig.port?.setPage(HomeKit.failure(50001))
        let controller = rig.controller()
        await rig.start(controller)
        XCTAssertEqual(rig.port?.pageCalls.count, 1)
        rig.clock.advance(1499)
        await controller.whenIdle()
        XCTAssertNil(controller.state.source, "1.5 秒内不应提前显示包内默认")
        XCTAssertNil(controller.state.loadFailed)
        rig.clock.advance(1)
        await controller.whenIdle()
        XCTAssertEqual(controller.state.source, .bundled)
        XCTAssertEqual(controller.state.sectionIds, ["default_icons", "default_activities"])
        XCTAssertNil(controller.state.loadFailed, "包内默认可用时不显示整页错误")
        XCTAssertNil(controller.state.toast, "冷启动后台拉取失败不提示（G16）")
        XCTAssertNil(rig.readLkgVersion(), "失败不写 LKG")
    }

    /// 无 LKG、网络 1 秒内到达 → 直接显示网络版并写 LKG；之后 1.5 秒计时不再换成包内默认。
    func testNoLkgNetworkWithin1500ShowsNetworkAndWritesLkg() async {
        let hold = Hold()
        rig.port?.queuePage(.held(hold))
        let controller = rig.controller()
        await startHeld(controller)
        rig.clock.advance(1000)
        XCTAssertNil(controller.state.source, "1 秒时还没有任何一级可显示")
        hold.release(HomeKit.ok(page(2)))
        await controller.whenIdle()
        XCTAssertEqual(controller.state.source, .network)
        XCTAssertEqual(controller.state.pageVersion, 2)
        XCTAssertEqual(rig.readLkgVersion(), 2)
        rig.clock.advance(1000)
        await controller.whenIdle()
        XCTAssertEqual(controller.state.source, .network, "1.5 秒计时到期不得把网络版换回包内默认")
    }

    /// 无 LKG、网络 2 秒到达、用户没交互 → 替换一次（网络版 + 写 LKG）；之后再来的网络版只写 LKG。
    func testLateNetworkReplacesBundledDefaultOnceWhenUserHasNotInteracted() async {
        let hold = Hold()
        rig.port?.queuePage(.held(hold))
        let controller = rig.controller()
        await startHeld(controller)
        rig.clock.advance(1500)
        await waitFor("满 1.5 秒显示包内默认") { controller.state.source == .bundled }
        rig.clock.advance(500)
        hold.release(HomeKit.ok(page(2)))
        await controller.whenIdle()
        XCTAssertEqual(controller.state.source, .network)
        XCTAssertEqual(controller.state.pageVersion, 2)
        XCTAssertEqual(rig.readLkgVersion(), 2)
    }

    /// 无 LKG、网络 2 秒到达、用户已在首页滚动 / 点击 → 不替换、只写 LKG；下次冷启动显示它（AC-HOME-01 同一路径）。
    func testLateNetworkAfterInteractionOnlyWritesLkgAndNextColdStartShowsIt() async {
        let hold = Hold()
        rig.port?.queuePage(.held(hold))
        let controller = rig.controller()
        await startHeld(controller)
        rig.clock.advance(1500)
        await waitFor("满 1.5 秒显示包内默认") { controller.state.source == .bundled }
        let shown = controller.state.render
        controller.interacted(shown)
        hold.release(HomeKit.ok(page(2)))
        await controller.whenIdle()
        XCTAssertEqual(controller.state.source, .bundled, "用户交互过就不替换当前屏")
        XCTAssertEqual(rig.readLkgVersion(), 2, "但要写成 LKG")
        // 下次冷启动：立即显示 LKG（网络还没回）
        let hold2 = Hold()
        rig.port?.queuePage(.held(hold2))
        let next = rig.controller()
        await startHeld(next, calls: 2)
        await waitFor("下次冷启动立即显示 LKG（网络未回）") { next.state.source == .lkg }
        XCTAssertEqual(next.state.pageVersion, 2)
        hold2.release(HomeKit.ok(page(3)))
        await next.whenIdle()
    }

    /// 旧渲染世代的「交互」回调不阻止替换（票据比较，共性第 1 条）。
    func testInteractionTicketFromAnotherControllerIsIgnored() async {
        // 另一个控制器（游客作用域，不影响会员 A 的 LKG）
        let other = rig.controller(HomeKit.guest)
        await rig.start(other)
        rig.clock.advance(1500)
        await other.whenIdle()
        let foreign = other.state.render
        other.invalidate()

        let hold = Hold()
        rig.port?.queuePage(.held(hold))
        let controller = rig.controller()
        await startHeld(controller, calls: 2)
        rig.clock.advance(1500)
        await waitFor("满 1.5 秒显示包内默认") { controller.state.source == .bundled }
        controller.interacted(foreign)
        hold.release(HomeKit.ok(page(4)))
        await controller.whenIdle()
        XCTAssertEqual(controller.state.source, .network)
    }

    // MARK: - 有 LKG

    /// 有 LKG → 立即显示 LKG（网络未回）；网络版到达只写 LKG、不换屏（AC-HOME-01：当前运行不换屏）。
    func testLkgShownImmediatelyAndNetworkOnlyWritesLkg() async throws {
        try rig.seedLkg(page(5, title: "测试缓存版"))
        let hold = Hold()
        rig.port?.queuePage(.held(hold))
        let controller = rig.controller()
        await startHeld(controller)
        await waitFor("有 LKG 立即显示（网络未回）") { controller.state.source == .lkg }
        XCTAssertEqual(controller.state.pageVersion, 5)
        hold.release(HomeKit.ok(page(6)))
        await controller.whenIdle()
        XCTAssertEqual(controller.state.source, .lkg, "网络版不替换当前屏")
        XCTAssertEqual(controller.state.pageVersion, 5)
        XCTAssertEqual(rig.readLkgVersion(), 6)
        rig.clock.advance(5000)
        await controller.whenIdle()
        XCTAssertEqual(controller.state.pageVersion, 5, "计时不应换屏")
    }

    /// 下拉刷新成功 → 替换当前屏并写 LKG；结果被采用（内容与刷新前不同）。
    func testPullRefreshReplacesScreenAndWritesLkg() async throws {
        try rig.seedLkg(page(5, title: "测试缓存版"))
        let controller = rig.controller()
        await rig.start(controller)
        XCTAssertEqual(controller.state.pageVersion, 5)
        rig.port?.setPage(HomeKit.ok(page(7, title: "测试刷新版")))
        controller.refresh(controller.state.render)
        XCTAssertTrue(controller.state.refreshing)
        await controller.whenIdle()
        XCTAssertFalse(controller.state.refreshing)
        XCTAssertEqual(controller.state.source, .network)
        XCTAssertEqual(controller.state.pageVersion, 7)
        XCTAssertEqual(controller.state.sectionIds, ["act_7"])
        XCTAssertEqual(controller.state.section("act_7")?.items.first?.title, "测试刷新版")
        XCTAssertEqual(rig.readLkgVersion(), 7)
    }

    /// 下拉 5xxxx → 保留当前屏、提示一次（带 trace6，经统一错误消息）；不清 LKG。
    func testPullFailureKeepsScreenAndToastsWithTrace6() async throws {
        try rig.seedLkg(page(5))
        let controller = rig.controller()
        await rig.start(controller)
        let lkgBefore = rig.readLkgVersion()
        XCTAssertNotNil(lkgBefore)
        rig.port?.setPage(HomeKit.failure(50001, trace: "trace-test-ABC123"))
        controller.refresh(controller.state.render)
        await controller.whenIdle()
        XCTAssertEqual(controller.state.pageVersion, 5)
        XCTAssertEqual(controller.state.source, .lkg)
        let toast = try XCTUnwrap(controller.state.toast, "下拉失败要提示")
        XCTAssertTrue(toast.message.hasPrefix("error.50001"), toast.message)
        XCTAssertTrue(toast.message.contains("ABC123"), "5xxxx 带 trace6：\(toast.message)")
        XCTAssertFalse(controller.state.refreshing)
        XCTAssertEqual(rig.readLkgVersion(), lkgBefore, "失败不清 LKG")
        controller.consumeToast(toast.id)
        XCTAssertNil(controller.state.toast)
    }

    /// 下拉超时 / 断网 / 整页无效：保留当前屏，提示一次 error.50001（没有 trace 不追加编号；H04）。
    func testPullTransportFailureOrInvalidPageToastsWithoutTrace() async throws {
        try rig.seedLkg(page(5))
        let controller = rig.controller()
        await rig.start(controller)
        let lkgBefore = rig.readLkgVersion()
        let invalid = HomeKit.ok(["page_key": "home", "version": 0, "sections": [] as [Any]])
        for result in [HomeKit.timeout, HomeKit.offline, invalid] {
            rig.port?.setPage(result)
            controller.refresh(controller.state.render)
            await controller.whenIdle()
            let toast = try XCTUnwrap(controller.state.toast, "\(result)")
            XCTAssertEqual(toast.message, "error.50001", "\(result)")
            XCTAssertEqual(controller.state.pageVersion, 5)
            controller.consumeToast(toast.id)
        }
        XCTAssertEqual(rig.readLkgVersion(), lkgBefore, "失败不改 LKG")
    }

    /// 网络版整页无效（G07）→ 当作这一级失败，继续显示当前那一级（LKG / 包内默认），不写 LKG。
    func testInvalidNetworkPageKeepsCurrentLevelAndIsNotWritten() async throws {
        try rig.seedLkg(page(5))
        rig.port?.setPage(HomeKit.ok(["page_key": "home", "version": 9, "sections": [:] as [String: Any]]))
        let controller = rig.controller()
        await rig.start(controller)
        XCTAssertEqual(controller.state.source, .lkg)
        XCTAssertEqual(rig.readLkgVersion(), 5, "无效页不写 LKG")
    }

    /// G16 ①：整页有效但一张卡都没解码成功 → 不写 LKG。
    func testPageWithZeroDecodedCardsIsNotWrittenAsLkg() async {
        rig.port?.setPage(HomeKit.ok(HomeKit.page(version: 3, [["id": "x", "type": "future_card", "version": 1]])))
        let controller = rig.controller()
        await rig.start(controller)
        rig.clock.advance(1500)
        await controller.whenIdle()
        XCTAssertEqual(rig.port?.pageCalls.count, 1, "前提：网络版已取回")
        XCTAssertNil(rig.readLkgVersion())
    }

    /// LKG 文件损坏 → 当作无 LKG（等网络，1.5 秒后包内默认）；坏文件被删，下次不再读到。
    func testCorruptLkgIsTreatedAsNoLkg() async throws {
        let key = try XCTUnwrap(HomeKit.memberA.lkgScope)
        XCTAssertTrue(rig.lkg.write(key, Data("{not json".utf8), ticket: rig.lkg.ticket()))
        rig.port?.setPage(HomeKit.offline)
        let controller = rig.controller()
        await rig.start(controller)
        XCTAssertNotEqual(controller.state.source, .lkg)
        rig.clock.advance(1500)
        await controller.whenIdle()
        XCTAssertEqual(controller.state.source, .bundled)
        XCTAssertNil(rig.lkg.read(key), "坏 LKG 应删掉")
    }

    /// 包内默认坏了且无网络 → StateLoadFailed +【重试】（最后防线）；【重试】后网络可用 → 显示网络版。
    func testBadBundledDefaultAndOfflineShowsLoadFailedThenRetryLoads() async throws {
        rig.bundled = Data("{broken".utf8)
        rig.port?.setPage(HomeKit.offline)
        let controller = rig.controller()
        await rig.start(controller)
        rig.clock.advance(1500)
        await controller.whenIdle()
        let failed = try XCTUnwrap(controller.state.loadFailed, "最后防线要显示 StateLoadFailed")
        XCTAssertTrue(failed.retryEnabled)
        XCTAssertTrue(controller.state.sections.isEmpty)
        rig.port?.setPage(HomeKit.ok(page(8)))
        controller.retryLoadFailed(controller.state.render)
        await controller.whenIdle()
        XCTAssertNil(controller.state.loadFailed)
        XCTAssertEqual(controller.state.source, .network)
        XCTAssertEqual(controller.state.pageVersion, 8)
    }
}
