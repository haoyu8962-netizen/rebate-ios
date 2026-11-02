@testable import Couli
import Foundation
import Me
import MeCore
import XCTest

/// APP-12w-a 行为守卫（brief §0、§4.4、§4.5，G-S18）：页面渲染时取出的同一份回调出发，每个入口恰好一次、目标与改前一致；取消 / 关闭零动作；发起条件与次数不变。
/// 本组底版就该绿（现状已符合、加守卫），实现后还绿才算逻辑零改动。真实控件点击只留核心路径，在 `SettingsVisualUITests`。
@MainActor
final class SettingsVisualBehaviorTests: SettingsVisualTestCase {
    private func env() throws -> MeVisualEnv {
        try XCTUnwrap(page?.custom?.env, "要走包一层的页面")
    }

    /// 全部导航行：公开版注入路由，点一次恰好一次，路由与空参数不变。
    func testRowRoutesExactlyOnce() async throws {
        try await open(Setup(profile: "settings_unbound", routes: publicRoutes()))
        let expected: [(row: String, route: String)] = [
            (SettingsItems.idPhone, "BindPhone"), (SettingsItems.idAuth, "AuthManage"),
            (SettingsItems.idDelete, SettingsController.deleteAccount), (SettingsItems.idPrivacy, "PrivacyCenter"),
            (SettingsItems.idHelp, "Help"), (SettingsItems.idAbout, "About"),
        ]
        for (row, route) in expected {
            let before = try env().opened.count
            try tapRow(row)
            let opened = try env().opened
            XCTAssertEqual(opened.count, before + 1, "\(row) 恰好一次")
            XCTAssertEqual(opened.last?.route, route, row)
            XCTAssertEqual(opened.last?.params, [:], row)
        }
    }

    /// 已绑定：手机号行不可点（G07），点了零动作。
    func testBoundPhoneRowIsInert() async throws {
        try await open(Setup(routes: publicRoutes()))
        XCTAssertFalse(try row(SettingsItems.idPhone).clickable)
        try tapRow(SettingsItems.idPhone)
        XCTAssertTrue(try env().opened.isEmpty)
    }

    /// 协议半屏：一次性编号；关闭零动作；选一行恰好一次并作废，旧编号重放零动作。
    func testAgreementSheetOneShot() async throws {
        try await open(Setup(routes: publicRoutes()))
        let choices = try XCTUnwrap(try row(SettingsItems.idAgreement).choices)
        XCTAssertEqual(choices.map(\.type), ["agreement", "privacy"])
        try tapRow(SettingsItems.idAgreement)
        let first = try XCTUnwrap(try settings.state.sheet)
        try actions.closeSheet(first)
        XCTAssertNil(try settings.state.sheet)
        try actions.agreement(choices[0], first)
        XCTAssertTrue(try env().opened.isEmpty, "关闭后旧编号零动作")
        for choice in choices {
            try tapRow(SettingsItems.idAgreement)
            let sheet = try XCTUnwrap(try settings.state.sheet)
            let before = try env().opened.count
            try actions.agreement(choice, sheet)
            try actions.agreement(choice, sheet)
            let opened = try env().opened
            XCTAssertEqual(opened.count, before + 1, "\(choice.type) 恰好一次")
            XCTAssertEqual(opened.last?.route, "Agreement")
            XCTAssertEqual(opened.last?.params, ["type": choice.type])
            XCTAssertNil(try settings.state.sheet, "选中即作废")
        }
    }

    /// 清缓存：确认才清、恰一次；取消零次；旧确认框重放零次。
    func testClearCacheOnce() async throws {
        let (host, _) = try await open()
        try tapRow(SettingsItems.idClearCache)
        let first = try XCTUnwrap(try settings.state.dialog)
        try actions.cancelDialog(first)
        try actions.confirmClear(first)
        await settle()
        XCTAssertEqual(host.fixture.system.cleared, 0, "取消零次，旧确认框重放零次")
        try tapRow(SettingsItems.idClearCache)
        let second = try XCTUnwrap(try settings.state.dialog)
        try actions.confirmClear(second)
        try actions.confirmClear(second)
        await waitUntil("没有清完") { (try? self.settings.state.clearing) == false && !self.toasts.isEmpty }
        XCTAssertEqual(host.fixture.system.cleared, 1, "确认恰一次")
    }

    /// 退出：确认才走已有 logout，恰一次；取消零次；旧确认框重放零次。
    func testLogoutOnce() async throws {
        let (host, _) = try await open()
        try actions.askLogout()
        let first = try XCTUnwrap(try settings.state.dialog)
        try actions.cancelDialog(first)
        try actions.confirmLogout(first)
        await settle()
        XCTAssertTrue(host.fixture.login.loggedIn, "取消不退出")
        try actions.askLogout()
        let second = try XCTUnwrap(try settings.state.dialog)
        let controller = try settings
        let rendered = SettingsActions.make(controller, controller.state)
        rendered.confirmLogout(second)
        rendered.confirmLogout(second)
        await waitUntil("没有退出") { !host.fixture.login.loggedIn }
        await quietWindow(0.3)
        XCTAssertEqual(WalletStubProtocol.requests("POST", "/v1/auth/logout").count, 1, "恰一次")
    }

    /// 重新显示下单须知：一次请求；禁用期内页面与执行层都拦。
    func testResetTipOnceAndGate() async throws {
        let (host, _) = try await open()
        try tapRow(SettingsItems.idResetTip)
        await waitUntil("没有发出") { !self.toasts.isEmpty }
        XCTAssertEqual(WalletStubProtocol.requests("DELETE", "/v1/me/tips/jump_tip").count, 1)
        host.script.fail("DELETE /v1/me/tips/jump_tip", 42901, headers: ["Retry-After": "20"])
        try tapRow(SettingsItems.idResetTip)
        await waitUntil("没有进禁用期") { (try? self.settings.resetTipBlocked) == true }
        try tapRow(SettingsItems.idResetTip)
        await quietWindow(0.3)
        XCTAssertEqual(WalletStubProtocol.requests("DELETE", "/v1/me/tips/jump_tip").count, 2, "禁用期内不发")
    }

    /// 游客【去登录】恰一次到 Login；基本模式【开启完整功能】只重新展示首启弹窗。
    func testGuestLoginAndBasicEnable() async throws {
        try await open(Setup(level: .guest, routes: publicRoutes()))
        try actions.login()
        XCTAssertEqual(try env().opened.map(\.route), [SettingsController.login])
        XCTAssertEqual(try env().opened.last?.params, [:])
        let (host, _) = try await open(Setup(level: .basic))
        XCTAssertFalse(host.fixture.me.privacy.isPrompting)
        try actions.enableFull()
        XCTAssertTrue(host.fixture.me.privacy.isPrompting)
    }

    /// 请求不变：已登录进入 getMe 恰一次，游客、基本模式零次；进子页不多读，关子页按现状再读一次。
    func testRequestCounts() async throws {
        try await open()
        await quietWindow(0.3)
        XCTAssertEqual(meReads, 1, "已登录一次")
        try await open(Setup(level: .guest))
        await quietWindow(0.3)
        XCTAssertEqual(meReads, 0, "游客零次")
        try await open(Setup(level: .basic))
        await quietWindow(0.3)
        XCTAssertEqual(meReads, 0, "基本模式零次")
        try await openNotify()
        await quietWindow(0.3)
        XCTAssertEqual(meReads, 1, "进通知子页不读 Me")
        try actions.closeSub()
        await waitUntil("关子页没有重读") { self.meReads == 2 }
        await quietWindow(0.3)
        XCTAssertEqual(meReads, 2)
    }

    /// 通知：只查不申请；去设置只跳本 App 的通知设置；回前台重查；Release 不发开关请求。
    func testNotifyGoSettingsNeverRequests() async throws {
        try await openNotify()
        let host = try XCTUnwrap(page)
        let notify = try XCTUnwrap(try settings.notify)
        NotifyActions.make(notify, notify.state).goSettings()
        XCTAssertEqual(host.fixture.system.notificationSettingsOpened, 1, "恰一次")
        XCTAssertEqual(host.fixture.system.appSettingsOpened, 0, "不是 App 设置")
        XCTAssertEqual(host.fixture.system.permissionRequests, 0, "不申请")
        XCTAssertEqual(notify.state.systemGranted, false)
        host.fixture.system.status["push"] = "granted"
        notify.refreshSystem()
        await waitUntil("回前台没有重查") { notify.state.systemGranted == true }
    }

    /// 开关：改值恰一次；同值零次；失败回原值。
    func testNotifyToggleSemantics() async throws {
        try await openNotify(Setup(push: "granted"))
        let notify = try XCTUnwrap(try settings.notify)
        let rendered = NotifyActions.make(notify, notify.state)
        XCTAssertEqual(notify.state.service, true)
        rendered.toggle(true)
        XCTAssertFalse(notify.state.switching, "同值零次")
        rendered.toggle(false)
        rendered.toggle(true)
        XCTAssertEqual(notify.state.service, false, "切换中第二次不生效")
        await waitUntil("没有结束") { !notify.state.switching }
        XCTAssertEqual(notify.state.service, false)
    }

    /// 换身份后旧回调零动作（回调捕获渲染时的执行器与版本）；子页、半屏、确认框随旧执行器作废。
    func testStaleCallbacksAfterIdentityChange() async throws {
        let (host, _) = try await open()
        try tapRow(SettingsItems.idClearCache)
        let dialog = try XCTUnwrap(try settings.state.dialog)
        let stale = try actions
        let old = try settings
        let reset = try row(SettingsItems.idResetTip)
        host.script.ok("GET /v1/me", MeSamples.me(account: "user-b", nickname: "B 用户"))
        try host.fixture.switchAccount(to: "user-b")
        await waitUntil("身份没换代") { host.fixture.me.currentIdentity.account == "user-b" }
        XCTAssertTrue(old.hasLeft)
        XCTAssertNil(old.state.dialog, "确认框作废")
        stale.confirmClear(dialog)
        stale.row(reset)
        stale.askLogout()
        await quietWindow(0.3)
        XCTAssertEqual(host.fixture.system.cleared, 0)
        XCTAssertTrue(WalletStubProtocol.requests("DELETE", "/v1/me/tips/jump_tip").isEmpty)
        XCTAssertNil(old.state.dialog)
    }

    /// 剪贴板开关只走渲染时回调，换身份后零动作（G-S12 只动读屏）；基本模式没有这一行。
    func testClipboardRowStillDirect() async throws {
        try await open(Setup(level: .basic))
        XCTAssertFalse(try settings.model().groups.flatMap(\.rows).contains { $0.id == SettingsItems.idClipboard })
        try await open()
        XCTAssertTrue(try settings.clipboardAutoOn, "默认开启（D10-423）")
        try actions.clipboardAuto(false)
        XCTAssertNil(try settings.state.sheet, "不出弹层")
        XCTAssertNil(try settings.state.dialog, "不出确认框")
    }
}
