import CouliNetwork
import Foundation
@testable import HomeCore
import XCTest

/// 首页弹窗（F-HOME-08 = AC-HOME-08，TECH-12，G14 ①–⑨；brief §0 红线 5；cross-platform-lessons 第 1、2、17、18、21、22、27、28 条）。
/// 弹窗界面的 onAppear 回调是 `popupShown(ticket)`（真正显示后才计数，H06）；这里以「界面已出现」调用它，模态承载与读屏顺序见快照与开发验收。
@MainActor
final class HomePopupTests: HomeRigTestCase {
    private func popupPage(_ popup: [String: Any] = HomeKit.popup(), version: Int = 80) -> [String: Any] {
        HomeKit.page(version: version, [HomeKit.activity("act", titles: ["测试入口"]), popup])
    }

    private func launch(_ page: [String: Any]? = nil,
                        identity: HomeIdentity = HomeKit.memberA) async -> HomeController {
        // 每次都是没有 LKG 的冷启动（显示的就是这一页的网络版）
        try? rig.lkg.clearAll()
        rig.port?.setPage(HomeKit.ok(page ?? popupPage()))
        let controller = rig.controller(identity)
        await rig.start(controller)
        return controller
    }

    private func shown() -> Int {
        rig.prefs.shownToday(sectionId: "popup", nowMs: rig.clock.now)
    }

    /// 关闭按钮与弹窗同时出现（同一个 UI 模型里，没有前置条件），点一次就关；真正显示后才计数（+1）。
    func testPopupAppearsWithCloseAndOneTapClosesAndCountsOnceShown() async throws {
        let controller = await launch()
        let popup = try XCTUnwrap(controller.state.popup, "冷启动渲染后、图片就绪、无阻挡项时要弹")
        XCTAssertEqual(popup.image, "https://img.example.com/popup.png")
        XCTAssertEqual(shown(), 0, "还没真正显示就计数了")
        controller.popupShown(popup.ticket)
        XCTAssertEqual(shown(), 1)
        controller.closePopup(popup.ticket)
        XCTAssertNil(controller.state.popup, "点一次关闭就关")
        controller.popupShown(popup.ticket)
        XCTAssertEqual(shown(), 1, "关闭后的迟到回调不再计数")
    }

    /// 点图片执行 items[0].action（经 open，入口由 App 定为 in_app），执行即关闭；action 缺失时图片不可点。
    func testTapImageRunsActionAndCloses() async throws {
        let controller = await launch()
        let popup = try XCTUnwrap(controller.state.popup)
        XCTAssertTrue(popup.clickable)
        controller.popupShown(popup.ticket)
        controller.tapPopup(popup.ticket)
        XCTAssertNil(controller.state.popup)
        XCTAssertEqual(rig.opened.last?.target.route, "AuthSheet")
        XCTAssertEqual(rig.opened.last?.target.params, ["platform": .string("taobao")])

        let plain = HomeRig(name: "plain")
        defer { plain.tearDown() }
        plain.port?.setPage(HomeKit.ok(popupPage(HomeKit.popup(action: nil))))
        let other = plain.controller()
        await plain.start(other)
        let noAction = try XCTUnwrap(other.state.popup)
        XCTAssertFalse(noAction.clickable)
        other.tapPopup(noAction.ticket)
        XCTAssertTrue(plain.opened.isEmpty)
    }

    /// daily_max=1：同日第二次冷启动不弹；次日（推进时钟到上海次日）再弹。
    func testDailyMaxSameDayAndNextShanghaiDay() async throws {
        let first = await launch()
        let popup = try XCTUnwrap(first.state.popup)
        first.popupShown(popup.ticket)
        first.closePopup(popup.ticket)
        let second = await launch()
        XCTAssertNil(second.state.popup, "同日已达 daily_max")
        // 推进到次日 10:00（上海）
        rig.clock.jump(22 * 3_600_000)
        let third = await launch()
        XCTAssertNotNil(third.state.popup, "次日应再弹")
    }

    /// 时间段外不弹（含起点不含终点）；跨零点时间段的 popup 被丢弃（解码失败，记 bad_value）。
    func testOutsideTimeWindowAndCrossMidnightNeverShow() async {
        let early = await launch(popupPage(HomeKit.popup(window: ["13:00", "22:00"])))
        XCTAssertNil(early.state.popup)
        let crossing = await launch(popupPage(HomeKit.popup(window: ["22:00", "09:00"]), version: 81))
        XCTAssertNil(crossing.state.popup)
        XCTAssertEqual(rig.cardErrors.compactMap { $0.fields["reason"] }, [.string("bad_value")])
        XCTAssertEqual(shown(), 0)
    }

    /// 基本模式不弹、不计数（G14 ⑥）；游客照常（人群由服务端定）。
    func testBasicModeNeverShowsGuestShows() async {
        let basic = await launch(identity: HomeKit.basic)
        XCTAssertNil(basic.state.popup)
        let guest = await launch(identity: HomeKit.guest)
        XCTAssertNotNil(guest.state.popup)
    }

    /// 图片加载失败：不弹（不显示只有关闭按钮的空框），不计数。
    func testImageFailureNeverShowsNorCounts() async {
        rig.images.fail("https://img.example.com/popup.png")
        let controller = await launch()
        XCTAssertTrue(rig.images.loads.contains("https://img.example.com/popup.png"), "前提：试过加载弹窗图片")
        XCTAssertNil(controller.state.popup)
        XCTAssertEqual(shown(), 0)
    }

    /// 阻挡项（隐私弹窗、强更、可选更新提示、剪贴板提示条、半屏 / 对话框）在时不弹；结束后若仍满足条件才弹（不经下拉、不重启）。
    func testBlockersDeferPopupUntilTheyEnd() async {
        for blocker in ["privacy_dialog", "force_update", "update_prompt", "clipboard_prompt", "sheet_open"] {
            let rig = HomeRig(name: "blocker-\(blocker)")
            defer { rig.tearDown() }
            rig.signals.blocking = [blocker]
            rig.port?.setPage(HomeKit.ok(popupPage()))
            let controller = rig.controller()
            await rig.start(controller)
            XCTAssertNil(controller.state.popup, "\(blocker) 在时弹了")
            rig.signals.blocking = []
            await controller.whenIdle()
            XCTAssertNotNil(controller.state.popup, "\(blocker) 结束后应弹")
        }
    }

    /// 阻挡项结束时已过时间段：不再弹（「仍满足条件才弹」）。
    func testBlockerEndingAfterTimeWindowDoesNotShow() async {
        rig.signals.blocking = ["update_prompt"]
        let controller = await launch(popupPage(HomeKit.popup(window: ["09:00", "12:30"])))
        XCTAssertNil(controller.state.popup)
        rig.clock.jump(31 * 60_000)
        rig.signals.blocking = []
        await controller.whenIdle()
        XCTAssertNil(controller.state.popup)
        XCTAssertEqual(shown(), 0)
    }

    /// 图片加载中切走 Tab（首页不可见），图片随后就绪：不弹；回到首页才弹（共性第 18、22 条）。
    func testImageArrivingWhileHomeHiddenWaitsUntilVisible() async {
        rig.images.hold("https://img.example.com/popup.png")
        let controller = await launchWithoutIdle()
        await waitFor("弹窗图片加载没挂到替身上") { rig.images.waiting("https://img.example.com/popup.png") }
        rig.signals.visible = false
        rig.images.release("https://img.example.com/popup.png", true)
        await controller.whenIdle()
        XCTAssertNil(controller.state.popup, "首页不可见时弹了")
        rig.signals.visible = true
        await controller.whenIdle()
        XCTAssertNotNil(controller.state.popup)
    }

    private func launchWithoutIdle() async -> HomeController {
        rig.port?.setPage(HomeKit.ok(popupPage()))
        let controller = rig.controller()
        controller.start()
        return controller
    }

    /// 弹窗已出现（界面还没 onAppear、未计数）时来了阻挡项：收起、退回等待；阻挡结束再弹时是新的实例编号，旧实例的回调一律无效（共性第 21、28 条）。
    func testReshownPopupGetsNewInstanceTicketAndOldCallbacksAreIgnored() async throws {
        let controller = await launch()
        let first = try XCTUnwrap(controller.state.popup)
        rig.signals.blocking = ["sheet_open"]
        await controller.whenIdle()
        XCTAssertNil(controller.state.popup, "已出现的弹窗遇到新阻挡项要收起")
        rig.signals.blocking = []
        await controller.whenIdle()
        let second = try XCTUnwrap(controller.state.popup)
        XCTAssertNotEqual(first.ticket, second.ticket)
        controller.closePopup(first.ticket)
        controller.tapPopup(first.ticket)
        XCTAssertNotNil(controller.state.popup, "旧实例的关闭回调关掉了新弹窗")
        XCTAssertTrue(rig.opened.isEmpty)
        controller.popupShown(first.ticket)
        XCTAssertEqual(shown(), 0, "旧实例的 onAppear 计了数")
        controller.popupShown(second.ticket)
        XCTAssertEqual(shown(), 1)
    }

    /// 已真正显示过（已计数）的弹窗遇到阻挡项：按关闭处理，之后不再弹（每次冷启动最多一次，H28）。
    func testShownPopupInterruptedByBlockerIsTreatedAsClosed() async throws {
        let controller = await launch(popupPage(HomeKit.popup(dailyMax: 3)))
        let popup = try XCTUnwrap(controller.state.popup)
        controller.popupShown(popup.ticket)
        rig.signals.blocking = ["sheet_open"]
        await controller.whenIdle()
        XCTAssertNil(controller.state.popup)
        rig.signals.blocking = []
        await controller.whenIdle()
        XCTAssertNil(controller.state.popup, "本次冷启动已经弹过")
        XCTAssertEqual(shown(), 1)
    }

    /// 弹窗只在冷启动渲染时安排：下拉刷新换来的页面带 popup 也不弹（共性第 2 条）。
    func testPullRefreshNeverSchedulesANewPopup() async {
        let controller = await launch(HomeKit.page(version: 82, [HomeKit.activity("act", titles: ["测试入口"])]))
        XCTAssertNil(controller.state.popup)
        rig.port?.setPage(HomeKit.ok(popupPage(version: 83)))
        controller.refresh(controller.state.render)
        await controller.whenIdle()
        XCTAssertEqual(controller.state.pageVersion, 83, "前提：下拉结果已显示")
        XCTAssertNil(controller.state.popup)
        XCTAssertTrue(rig.images.loads.isEmpty, "下拉刷新后不应预载弹窗图片")
    }

    /// 包内默认之后才到的网络版（G16 ③ 替换一次）带 popup：替换属于冷启动渲染，可以弹。
    func testColdStartReplacementCanSchedulePopup() async {
        let hold = Hold()
        rig.port?.queuePage(.held(hold))
        let controller = rig.controller()
        controller.start()
        await waitFor("请求没发出") { rig.port?.pageCalls.count == 1 }
        rig.clock.advance(1500)
        await waitFor("满 1.5 秒显示包内默认") { controller.state.source == .bundled }
        hold.release(HomeKit.ok(popupPage()))
        await controller.whenIdle()
        XCTAssertEqual(controller.state.source, .network)
        XCTAssertNotNil(controller.state.popup)
    }

    /// 页里有多个 popup：只用第一个解码成功的（G14 ③）。
    func testOnlyFirstDecodedPopupIsUsed() async {
        let controller = await launch(HomeKit.page(version: 84, [
            HomeKit.popup("first", image: "https://img.example.com/p1.png"),
            HomeKit.popup("second", image: "https://img.example.com/p2.png"),
        ]))
        XCTAssertEqual(controller.state.popup?.image, "https://img.example.com/p1.png")
        XCTAssertEqual(controller.state.popup?.sectionId, "first")
        XCTAssertFalse(rig.images.loads.contains("https://img.example.com/p2.png"))
    }

    /// 弹窗显示中控制器作废（会话失效 / 换账号 / 撤回）：立即关闭、不计数；作废后的 onAppear 也不计数。
    func testInvalidateClosesPopupWithoutCounting() async throws {
        let controller = await launch()
        let popup = try XCTUnwrap(controller.state.popup)
        controller.invalidate()
        XCTAssertNil(controller.state.popup)
        controller.popupShown(popup.ticket)
        XCTAssertEqual(shown(), 0)
        controller.tapPopup(popup.ticket)
        XCTAssertTrue(rig.opened.isEmpty, "作废后点图片仍执行了动作")
    }

    /// 预览：草稿里的 popup 立即弹一次（忽略次数与时间段），不计数（G24 ⑤⑥）。
    func testPreviewDraftPopupShowsOnceWithoutCounting() async throws {
        let preview = rig.controller(HomeKit.memberA, preview: true)
        preview.showDraft(HomeVectors.data(popupPage(HomeKit.popup(window: ["00:00", "01:00"]))))
        await preview.whenIdle()
        let popup = try XCTUnwrap(preview.state.popup, "预览草稿的 popup 要立即弹")
        preview.popupShown(popup.ticket)
        XCTAssertEqual(shown(), 0, "预览计数了")
        preview.closePopup(popup.ticket)
        XCTAssertNil(preview.state.popup)
    }

    /// 冷启动有弹窗候选、图片加载挂起时下拉换成没有弹窗的页面：旧候选清除，旧图片随后成功 / 失败都不弹、不计数、不执行旧动作（共性第 2 条）。
    func testPullReplacementDropsOldCandidateAndLateImage() async {
        for ok in [true, false] {
            let rig = HomeRig(name: "late-image-\(ok)")
            defer { rig.tearDown() }
            rig.images.hold("https://img.example.com/popup.png")
            rig.port?.setPage(HomeKit.ok(popupPage()))
            let controller = rig.controller()
            controller.start()
            await waitFor("弹窗图片加载没挂到替身上") { rig.images.waiting("https://img.example.com/popup.png") }
            rig.port?.setPage(HomeKit.ok(HomeKit.page(version: 90, [HomeKit.activity("act", titles: ["测试入口"])])))
            controller.refresh(controller.state.render)
            await waitFor("下拉结果没显示") { controller.state.pageVersion == 90 }
            rig.images.release("https://img.example.com/popup.png", ok)
            await controller.whenIdle()
            XCTAssertNil(controller.state.popup, "图片\(ok ? "成功" : "失败")：已被替换的旧弹窗弹出来了")
            XCTAssertEqual(rig.prefs.shownToday(sectionId: "popup", nowMs: rig.clock.now), 0)
            XCTAssertTrue(rig.opened.isEmpty)
        }
    }

    /// 对照：新页面也带弹窗（不同 id、同一图片地址），旧图片迟到也不弹——下拉不安排新弹窗，旧候选已清。
    func testPullReplacementWithSameImageUrlStillDropsOldCandidate() async {
        rig.images.hold("https://img.example.com/popup.png")
        rig.port?.setPage(HomeKit.ok(popupPage()))
        let controller = rig.controller()
        controller.start()
        await waitFor("弹窗图片加载没挂到替身上") { rig.images.waiting("https://img.example.com/popup.png") }
        rig.port?.setPage(HomeKit.ok(HomeKit.page(version: 91, [HomeKit.popup("popup_new")])))
        controller.refresh(controller.state.render)
        await waitFor("下拉结果没显示") { controller.state.pageVersion == 91 }
        rig.images.release("https://img.example.com/popup.png", true)
        await controller.whenIdle()
        XCTAssertNil(controller.state.popup)
        XCTAssertEqual(rig.prefs.shownToday(sectionId: "popup", nowMs: rig.clock.now), 0)
        XCTAssertEqual(rig.prefs.shownToday(sectionId: "popup_new", nowMs: rig.clock.now), 0)
    }
}
