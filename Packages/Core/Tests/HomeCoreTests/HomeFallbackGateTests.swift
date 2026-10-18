import CouliNetwork
import Foundation
@testable import HomeCore
import XCTest

/// 三级兜底的限流、强更、请求归属、Release 与当前版本（G16 ⑤、G31；brief §0「Retry-After」「10405」「同一首页的页面拉取按请求序号只收最新一次」；
/// cross-platform-lessons 第 4、26、32、34 条；H03、H04）。经生产 HomeController。
@MainActor
final class HomeFallbackGateTests: HomeRigTestCase {
    /// 下拉收到 42901：提示 error.42901、按 Retry-After 禁用下拉；期间再下拉不发出（执行层拦截），结束动画并再提示一次；
    /// 到期后入口自动恢复（订阅禁用状态，共性第 34 条），再下拉照常发出、结果被采用。
    func testPull42901DisablesRefreshAndBlocksAtExecutionLayer() async throws {
        try rig.seedLkg(page(5))
        let controller = rig.controller()
        await rig.start(controller)
        let before = rig.port?.pageCalls.count ?? 0
        rig.port?.setPage(HomeKit.failure(42901, retryAfter: "1"))
        controller.refresh(controller.state.render)
        await controller.whenIdle()
        XCTAssertEqual(rig.port?.pageCalls.count, before + 1)
        let first = try XCTUnwrap(controller.state.toast)
        XCTAssertEqual(first.message, "error.42901", "42901 不带编号")
        XCTAssertTrue(controller.state.refreshDisabled)
        XCTAssertTrue(rig.gate.active, "共享闸门要写入")
        XCTAssertEqual(rig.gate.remainingMillis, 1000)
        controller.consumeToast(first.id)

        rig.port?.setPage(HomeKit.ok(page(6)))
        controller.refresh(controller.state.render)
        await controller.whenIdle()
        XCTAssertEqual(rig.port?.pageCalls.count, before + 1, "禁用期内不得发出")
        XCTAssertFalse(controller.state.refreshing, "被拦下要结束刷新动画")
        XCTAssertEqual(controller.state.toast?.message, "error.42901", "被本地限流拦下提示一次 42901")
        XCTAssertEqual(controller.state.pageVersion, 5)

        rig.clock.advance(1000)
        await waitFor("禁用期到了下拉入口自动恢复") { !controller.state.refreshDisabled }
        controller.refresh(controller.state.render)
        await controller.whenIdle()
        XCTAssertEqual(rig.port?.pageCalls.count, before + 2)
        XCTAssertEqual(controller.state.pageVersion, 6)
    }

    /// 执行层闸门：下拉已发起、实际发出之前进入禁用期（例如另一个首页接口刚收到 42901）→ 不得发出；结束动画并提示一次 42901。
    /// 页面层的入口置灰挡不住这一段，只能靠每次实际发出前核对（brief §0「执行层与页面两处都生效」）。
    func testGateStartingBetweenDecisionAndSendBlocksAtExecutionLayer() async throws {
        try rig.seedLkg(page(5))
        let controller = rig.controller()
        await rig.start(controller)
        let before = rig.port?.pageCalls.count ?? 0
        rig.port?.setPage(HomeKit.ok(page(6)))
        // 替身在「实际发出前」设屏障：确认下拉请求已到屏障（已决定发出、还没核对发送前闸门）再开启禁用期
        rig.port?.armBarrier()
        controller.refresh(controller.state.render)
        await waitFor("下拉请求没到发送屏障") { rig.port?.atBarrier == true }
        rig.gate.start(5000)
        rig.port?.openBarrier()
        await controller.whenIdle()
        XCTAssertEqual(rig.port?.pageCalls.count, before, "禁用期内实际发出了")
        XCTAssertFalse(controller.state.refreshing)
        XCTAssertEqual(controller.state.pageVersion, 5)
        XCTAssertEqual(controller.state.toast?.message, "error.42901")
    }

    /// Retry-After 缺省或非法按 5 秒。
    func testRetryAfterMissingOrInvalidIsFiveSeconds() async throws {
        for header in [nil, "invalid"] as [String?] {
            let rig = HomeRig(name: "retry-\(header ?? "nil")")
            defer { rig.tearDown() }
            try rig.seedLkg(page(5))
            let controller = rig.controller()
            await rig.start(controller)
            rig.port?.setPage(HomeKit.failure(42901, retryAfter: header))
            controller.refresh(controller.state.render)
            await controller.whenIdle()
            XCTAssertEqual(rig.gate.remainingMillis, 5000, "Retry-After=\(header ?? "缺省")")
        }
    }

    /// 冷启动后台拉取被限流：不提示，但写入共享闸门（下拉随之禁用，H04）；继续用当前显示的那一级。
    func testBackground42901IsSilentButStartsTheSharedGate() async throws {
        try rig.seedLkg(page(5))
        rig.port?.setPage(HomeKit.failure(42901, retryAfter: "9"))
        let controller = rig.controller()
        await rig.start(controller)
        XCTAssertNil(controller.state.toast)
        XCTAssertEqual(controller.state.source, .lkg)
        XCTAssertTrue(rig.gate.active)
        XCTAssertEqual(rig.gate.remainingMillis, 9000)
        XCTAssertTrue(controller.state.refreshDisabled)
    }

    /// 端口（绕过 ApiClient）收到 10405：自己接强更分流（共性第 26 条），保留当前屏。
    func testPort10405EntersForceUpdate() async throws {
        try rig.seedLkg(page(5))
        let controller = rig.controller()
        await rig.start(controller)
        rig.port?.setPage(HomeKit.failure(10405))
        controller.refresh(controller.state.render)
        await controller.whenIdle()
        XCTAssertEqual(rig.forceUpdates, 1)
        XCTAssertEqual(controller.state.pageVersion, 5)
    }

    /// 冷启动拉取在途时下拉：冷启动结果（较旧）只写 LKG、不替换下拉结果，也不被当成下拉结果。
    func testSupersededColdFetchOnlyWritesLkgAndNeverReplacesPullResult() async throws {
        try rig.seedLkg(page(5))
        let cold = Hold()
        let pull = Hold()
        rig.port?.queuePage(.held(cold), .held(pull))
        let controller = rig.controller()
        await startHeld(controller)
        await waitFor("显示 LKG") { controller.state.source == .lkg }
        controller.refresh(controller.state.render)
        await waitFor("下拉请求已发出") { rig.port?.pageCalls.count == 2 }
        // 冷启动结果先到：不当成下拉结果（不换屏、刷新动画不结束）
        cold.release(HomeKit.ok(page(6, title: "测试冷启动版")))
        // 单个请求的结算信号：冷启动这一份响应已处理完（下拉仍挂着，不能等 whenIdle）
        await waitFor("冷启动结果没有结算") { controller.settledPageResults == 1 }
        XCTAssertEqual(rig.readLkgVersion(), 6, "下拉发出后先到的冷启动结果只写 LKG")
        XCTAssertEqual(controller.state.pageVersion, 5)
        XCTAssertTrue(controller.state.refreshing)
        pull.release(HomeKit.ok(page(7, title: "测试下拉版")))
        await controller.whenIdle()
        XCTAssertEqual(controller.state.pageVersion, 7)
        XCTAssertEqual(rig.readLkgVersion(), 7)
        XCTAssertFalse(controller.state.refreshing)
    }

    /// 对照：下拉结果先到、冷启动结果后到 → 屏上仍是下拉版，LKG 不被旧版覆盖（接受顺序，共性第 32 条）。
    func testColdFetchArrivingAfterPullNeitherReplacesScreenNorOverwritesLkg() async throws {
        try rig.seedLkg(page(5))
        let cold = Hold()
        rig.port?.queuePage(.held(cold), .now(HomeKit.ok(page(7))))
        let controller = rig.controller()
        await startHeld(controller)
        await waitFor("显示 LKG") { controller.state.source == .lkg }
        controller.refresh(controller.state.render)
        await waitFor("下拉结果已显示") { controller.state.pageVersion == 7 }
        cold.release(HomeKit.ok(page(6)))
        await controller.whenIdle()
        XCTAssertEqual(controller.state.pageVersion, 7)
        XCTAssertEqual(rig.readLkgVersion(), 7)
    }

    /// 没有待定 operation 的端口（Release）：不发请求、不等 1.5 秒，直接显示 LKG / 包内默认；下拉只结束动画，不提示（A14）。
    func testWithoutPortShowsBundledDefaultImmediatelyAndPullOnlyEndsAnimation() async {
        let rig = HomeRig(port: nil)
        defer { rig.tearDown() }
        let controller = rig.controller()
        await rig.start(controller)
        // 「不等 1.5 秒」：不推进时钟（零延时的排程允许，advance(0) 执行到点的计时）
        rig.clock.advance(0)
        await controller.whenIdle()
        XCTAssertEqual(controller.state.source, .bundled)
        controller.refresh(controller.state.render)
        await controller.whenIdle()
        XCTAssertFalse(controller.state.refreshing)
        XCTAssertNil(controller.state.toast)
        XCTAssertEqual(controller.state.source, .bundled)
    }

    /// HomeStore.currentVersion：当前显示页面的 version 与来源级别；没有显示中的页面为 nil。
    func testCurrentVersionFollowsDisplayedPageAndSource() async {
        let hold = Hold()
        rig.port?.queuePage(.held(hold))
        let controller = rig.controller()
        await startHeld(controller)
        XCTAssertNil(controller.currentVersion, "没有显示中的页面")
        rig.clock.advance(1500)
        await waitFor("满 1.5 秒显示包内默认") { controller.state.source == .bundled }
        XCTAssertEqual(controller.currentVersion?.version, 1)
        XCTAssertEqual(controller.currentVersion?.source, .bundled)
        hold.release(HomeKit.ok(page(12)))
        await controller.whenIdle()
        XCTAssertEqual(controller.currentVersion?.version, 12)
        XCTAssertEqual(controller.currentVersion?.source, .network)
    }
}
