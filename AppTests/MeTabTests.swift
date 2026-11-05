import Clipboard
@testable import Couli
import CouliNetwork
import Foundation
import Generated
import Me
import MeCore
import Router
import XCTest

/// 「我的」Tab（AC-S1-62、AC-S1-84、G04–G06、G19、G28、G31、G36）：经真实 Router 进 Tab、页面渲染时取出的按钮回调出发，断言落点路由、显示结论、
/// 统一剪贴板写入口与台账；读取失败不回落游客；换代与离开 Tab 的作废。
@MainActor
final class MeTabTests: MeTestCase {
    func testRoutesRegisteredAndInRoutesJson() {
        for route in ["Me", "Settings", "PrivacyCenter", "About", "RiskNotice", "Appeal", "Messages", "InviteShare"] {
            XCTAssertNotNil(Routes.all[route], "\(route) 不在 routes.json")
            XCTAssertNotNil(RouteViewRegistry.builders[route], "\(route) 没有接页面")
        }
        for name in ["Nickname", "NotifySettings", "CsHandoff"] {
            XCTAssertNil(Routes.all[name], "\(name) 不该是路由（G32）")
        }
        // #24 test-change（升锁 00deded0ef6f）：新锁把 InviteBackfill、Favorites、ShareHub 登记为路由（routes.json）；本端没有页面——
        // Favorites / ShareHub 的 since.ios 为 null 由守卫给升级提示，InviteBackfill（since 1.0.0）按 P1
        // 走升级提示（HomePageApiP1RouteTests）
        for name in ["InviteBackfill", "Favorites", "ShareHub"] {
            XCTAssertNotNil(Routes.all[name], "\(name) 应已在新锁 routes.json")
        }
        for name in ["Favorites", "ShareHub"] {
            XCTAssertNil(Routes.all[name]?.sinceIOS, "\(name) 本端未发布")
            XCTAssertNil(RouteViewRegistry.builders[name], "\(name) 本端没有页面")
        }
    }

    /// AC-S1-62 有上级：本人邀请码与「邀请人：已绑定」，无等级与邀请人信息；铃铛无红点 → Messages；宫格按路由表裁剪（G31）。
    func testMemberProfileInviterAndGridRoutes() async throws {
        let fixture = make()
        let controller = await loadedTab(fixture)
        let snapshot = fixture.me.deps.repo.state
        let view = controller.view(snapshot, masked: false)
        XCTAssertEqual(view.inviteCode, "K7M3QX")
        XCTAssertEqual(fixture.me.deps.texts.text(try XCTUnwrap(view.inviterTextKey)), "邀请人：已绑定")
        XCTAssertEqual(view.withdrawableFen, 1234)
        XCTAssertEqual(view.estimatedFen, 5678)
        XCTAssertTrue(view.bell)
        XCTAssertFalse(view.grid.contains { $0.item == "收益看板" }, "Earnings since 为 null（G31）")
        let actions = MeTabActions.make(controller, snapshot)
        actions.bell()
        XCTAssertEqual(fixture.router.path.last?.route, "Messages")
        fixture.router.path = []
        await settle()
        for (item, route) in [("钱包", "Wallet"), ("授权管理", "AuthManage"), ("帮助中心", "Help"), ("设置", "Settings"),
                              ("邀请好友", "InviteShare"), ("余额流水", "Ledger"), ("找回订单", "FindOrder")] {
            let entered = await fixture.enterMeTab()
            let cell = try XCTUnwrap(view.grid.first { $0.item == item })
            MeTabActions.make(entered, fixture.me.deps.repo.state).tap(cell)
            XCTAssertEqual(fixture.router.lastDecision?.route, route, item)
            fixture.router.path = []
            await settle()
        }
        // 【提现】→ Wallet（G06）
        let again = await fixture.enterMeTab()
        MeTabActions.make(again, fixture.me.deps.repo.state).withdraw()
        XCTAssertEqual(fixture.router.path.last?.route, "Wallet")
    }

    /// AC-S1-62 无上级「未绑定」；invite_code=null 不显示邀请码块（G05）。
    func testUnboundAndNoInviteCode() async throws {
        script.ok("GET /v1/me", MeSamples.me(invite: nil, inviter: false))
        let fixture = make()
        let controller = await loadedTab(fixture)
        let view = controller.view(fixture.me.deps.repo.state, masked: false)
        XCTAssertNil(view.inviteCode)
        XCTAssertEqual(fixture.me.deps.texts.text(try XCTUnwrap(view.inviterTextKey)), "邀请人：未绑定")
    }

    /// AC-S1-62：【复制】邀请码只走统一写入口（先记自写 hash 并确认落盘），台账有记录（回前台不识别）；记不下就不写、提示失败。
    func testCopyInviteGoesThroughClipboardWriter() async {
        let fixture = make()
        let controller = await loadedTab(fixture)
        MeTabActions.make(controller, fixture.me.deps.repo.state).copyInvite()
        XCTAssertEqual(fixture.clipboard.last, "K7M3QX")
        XCTAssertTrue(ClipboardWriteLedger(store: fixture.ledgerStore).contains("K7M3QX"), "台账有记录")
        XCTAssertEqual(controller.toast?.key, "invite.copy_code.done")
        XCTAssertEqual(controller.toast?.assertive, false, "polite 播报")

        fixture.ledgerStore.failWrites = true
        let before = fixture.clipboard.changeCount
        MeTabActions.make(controller, fixture.me.deps.repo.state).copyInvite()
        XCTAssertEqual(fixture.clipboard.changeCount, before, "台账记不下就不写系统剪贴板")
        XCTAssertEqual(controller.toast?.key, "me.copy_failed")
    }

    /// 游客：引导登录 + 宫格只有帮助中心、设置；不请求 /v1/me（G36）；没有铃铛。
    func testGuestShowsLoginPromptWithoutRequest() async {
        let fixture = make(account: nil)
        let controller = await fixture.enterMeTab()
        await settle()
        let view = controller.view(fixture.me.deps.repo.state, masked: false)
        XCTAssertTrue(view.loginPrompt)
        XCTAssertFalse(view.bell)
        XCTAssertEqual(view.grid.map(\.item), ["帮助中心", "设置"])
        XCTAssertTrue(requests("GET", "/v1/me").isEmpty, "游客不请求 /v1/me")
        MeTabActions.make(controller, fixture.me.deps.repo.state).login()
        XCTAssertEqual(fixture.router.path.last?.route, "Login")
    }

    /// 5xxxx：加载失败态 + trace6 +【重试】，不回落游客；坏数据（未知 risk.state）同样是加载失败。
    func testServerErrorAndBadDataShowErrorNotGuest() async throws {
        script.fail("GET /v1/me", 50002)
        let fixture = make()
        let controller = await loadedTab(fixture)
        let state = fixture.me.deps.repo.state
        XCTAssertEqual(state.phase, .error)
        XCTAssertFalse(controller.view(state, masked: false).loginPrompt, "不伪装成游客")
        let message = try XCTUnwrap(state.error).message(fixture.me.deps.texts)
        XCTAssertTrue(message.contains("6789ab"), "带 trace6：\(message)")

        script.ok("GET /v1/me", MeSamples.me(risk: "future_state"))
        controller.refresh()
        await waitUntil("坏数据没有回来") { requests("GET", "/v1/me").count == 2 && !fixture.me.deps.repo.state.refreshing }
        await settle()
        XCTAssertNil(fixture.me.deps.repo.state.me, "不认识的 risk.state 不当正常")
        XCTAssertEqual(fixture.me.deps.repo.state.phase, .error)
    }

    /// 42901：Me 读取按 Retry-After 禁用（页面与执行层）；禁用期内下拉不发包，页面显示 42901。
    func testRetryAfterBlocksMeReadsAtExecutorLayer() async {
        script.fail("GET /v1/me", 42901, headers: ["Retry-After": "30"])
        let fixture = make()
        let controller = await loadedTab(fixture)
        XCTAssertTrue(fixture.me.gates.read.active)
        XCTAssertEqual(fixture.me.deps.repo.state.error?.key, "error.42901")
        let count = requests("GET", "/v1/me").count
        XCTAssertFalse(controller.refresh(pull: true))
        await settle()
        XCTAssertEqual(requests("GET", "/v1/me").count, count, "禁用期内不发")
        // 执行层：绕过页面直接交给网络层，发送前闸门同样拦住（共享截止时间，钱包实名查询也受它约束，共性第 33 条）
        let probe = fixture.me.gates.read.probe()
        let result = await fixture.client.send(ApiCall(operationId: "getMe"), isValid: { true },
                                               sendAllowed: probe.allowed, expected: nil)
        XCTAssertEqual(result.notSentReason, LocalRejectReason.sendBlocked)
        XCTAssertTrue(fixture.me.gates.read === fixture.me.gates.read)
    }

    /// 会话换代：A 的 Me 读取在途时换登 B，A 的响应不改快照；B 进入后只看到 B 的资料（APP-09 共性第 13 条）。
    func testInFlightReadFromAccountADroppedAfterSwitch() async throws {
        script.on("GET /v1/me", .hold)
        let fixture = make()
        _ = await fixture.enterMeTab()
        await waitUntil("A 的读取没有发出") { !WalletStubProtocol.heldIds.isEmpty }
        let held = try XCTUnwrap(WalletStubProtocol.heldIds.first)
        script.ok("GET /v1/me", MeSamples.me(account: "user-b", nickname: "小狸爱买买", invite: "TEST02"))
        try fixture.switchAccount(to: "user-b")
        await waitUntil("身份没有换代") { fixture.me.currentIdentity.account == "user-b" }
        WalletStubProtocol.release(held, with: .envelope(code: 0, data: MeSamples.me(), headers: [:]))
        await waitUntil("B 的资料没到") { fixture.me.deps.repo.state.me?.nickname == "小狸爱买买" }
        await settle()
        XCTAssertEqual(fixture.me.deps.repo.state.me?.inviteCode, "TEST02", "A 的迟到响应不覆盖 B")
        XCTAssertEqual(fixture.me.deps.repo.state.identity?.account, "user-b")
    }

    /// 离开 Tab 的同步出口（R2-01）：切到别的 Tab 立即撤销这一次进入的读取许可并取消在途 getMe；回来按新的一次进入重取。
    func testLeavingTabCancelsInFlightRead() async {
        script.on("GET /v1/me", .hold)
        let fixture = make()
        let first = await fixture.enterMeTab()
        await waitUntil("读取没有发出") { fixture.me.deps.repo.inFlight == 1 }
        _ = fixture.routing.selectTab(.home)
        XCTAssertTrue(first.hasLeft, "切 Tab 的同步出口立即离开")
        XCTAssertEqual(fixture.me.deps.repo.inFlight, 0, "在途 getMe 已取消")
        script.ok("GET /v1/me", MeSamples.me())
        let second = await loadedTab(fixture)
        XCTAssertFalse(first === second, "每一次进入一个执行器")
        XCTAssertNotNil(fixture.me.deps.repo.state.me)
    }

    /// AC-S1-84：拒绝后 48 小时内不显示引导条，满 48 小时显示；关闭后 6 天不显示、7 天再显示；点击只跳系统通知设置（不申请）；系统已允许不显示。
    func testGuideBarClockAndClick() async {
        let fixture = make()
        var now: Int64 = 1_760_068_800_000
        fixture.me.clock = { now }
        fixture.system.status["push"] = "permanently_denied"
        fixture.system.deniedAt["push"] = now - 47 * 3_600_000
        var controller = await loadedTab(fixture)
        controller.checkGuideBar()
        await settle()
        XCTAssertFalse(controller.guideVisible, "47 小时不显示")
        now += 3_600_000
        controller.checkGuideBar()
        await waitUntil("满 48 小时没显示") { controller.guideVisible }
        MeTabActions.make(controller, fixture.me.deps.repo.state).openGuide()
        XCTAssertEqual(fixture.system.notificationSettingsOpened, 1, "只跳系统通知设置")
        XCTAssertEqual(fixture.system.permissionRequests, 0, "不出系统授权框")
        MeTabActions.make(controller, fixture.me.deps.repo.state).closeGuide()
        XCTAssertFalse(controller.guideVisible)
        now += 6 * 86_400_000
        controller = await reenter(fixture)
        XCTAssertFalse(controller.guideVisible, "关闭后 6 天不显示")
        now += 86_400_000
        controller = await reenter(fixture)
        await waitUntil("关闭满 7 天没再显示") { controller.guideVisible }
        fixture.system.status["push"] = "granted"
        controller = await reenter(fixture)
        XCTAssertFalse(controller.guideVisible, "系统已允许不显示")
    }

    private func reenter(_ fixture: MeAppFixture) async -> MeTabController {
        _ = fixture.routing.selectTab(.home)
        let controller = await fixture.enterMeTab()
        await settle()
        return controller
    }

    /// 金额隐藏：两个金额都是「****」，读屏「金额已隐藏」；与订单、钱包页同一份偏好（键不变）。
    func testAmountMaskSharedPreference() async {
        let fixture = make()
        let controller = await loadedTab(fixture)
        MeTabActions.make(controller, fixture.me.deps.repo.state).toggleMask()
        XCTAssertTrue(fixture.me.mask.hidden)
        XCTAssertTrue(defaults.bool(forKey: "amount_mask.hidden"))
        XCTAssertTrue(controller.view(fixture.me.deps.repo.state, masked: true).masked)
        XCTAssertEqual(fixture.me.deps.texts.text("me.amount_hidden"), "金额已隐藏")
    }

    /// 旧回调（共性第 63 条）：保留换代前渲染的回调，换账号后再执行一律不生效。
    func testStaleCallbacksAfterSwitchDoNothing() async throws {
        let fixture = make()
        let controller = await loadedTab(fixture)
        let stale = MeTabActions.make(controller, fixture.me.deps.repo.state)
        try fixture.switchAccount(to: "user-b")
        await waitUntil("身份没有换代") { fixture.me.currentIdentity.account == "user-b" }
        let writes = fixture.clipboard.changeCount
        stale.copyInvite()
        stale.withdraw()
        stale.bell()
        XCTAssertEqual(fixture.clipboard.changeCount, writes, "旧回调不复制 A 的邀请码")
        XCTAssertTrue(fixture.router.path.isEmpty, "旧回调不导航")
    }
}
