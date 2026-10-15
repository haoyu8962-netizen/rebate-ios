@testable import Couli
import CouliNetwork
import Foundation
import Me
import MeCore
import Privacy
import Router
import XCTest

/// 隐私中心与撤回同意（AC-S1-77、AC-S1-135、G03、G24、G25、G26、G29；F-HM-24）。
@MainActor
final class MePrivacyTests: MeTestCase {
    private func center(_ fixture: MeAppFixture) throws -> PrivacyCenterController {
        let entry = try XCTUnwrap(fixture.open("PrivacyCenter"))
        entry.appeared()
        return try XCTUnwrap(entry.controller() as? PrivacyCenterController)
    }

    /// AC-S1-135：iOS 系统权限一节列通知与相册，状态随系统设置变化（只查不申请）；点条目只跳系统设置。基本模式同样能看。
    func testSystemPermissionsSectionFollowsSystem() async throws {
        let fixture = make()
        fixture.system.status = ["push": "permanently_denied", "photos": "granted"]
        let controller = try center(fixture)
        await waitUntil("状态没查到") { controller.state.permissionStatus.count == 2 }
        let rows = controller.model().permissionRows
        XCTAssertEqual(Set(rows.map(\.type)), ["push", "photos"])
        XCTAssertEqual(rows.first { $0.type == "push" }?.statusKey, "privacy.system_permissions.status.denied")
        XCTAssertEqual(rows.first { $0.type == "photos" }?.statusKey, "privacy.system_permissions.status.granted")
        PrivacyCenterActions.make(controller, controller.state).permission("push")
        XCTAssertEqual(fixture.system.appSettingsOpened, 1)
        fixture.system.status["push"] = "granted"
        controller.refresh()
        await waitUntil("状态没跟随系统") { controller.state.permissionStatus["push"] == "granted" }

        let basic = make(account: nil, decision: "basic_mode")
        let readonly = try center(basic)
        XCTAssertEqual(readonly.model().permissionRows.count, 2)
        XCTAssertFalse(readonly.model().personalizationSwitch)
        XCTAssertFalse(readonly.model().withdrawButton)
        XCTAssertTrue(readonly.model().enableFullButton)
    }

    /// G03：关闭个性化 → 本机先保存、记 recordConsent {personalization, accepted:false, privacy_center}，之后的请求带 X-Personalization:
    /// off。
    func testPersonalizationSwitchHeaderAndConsent() async throws {
        let fixture = make()
        await fixture.loadConfig()
        let controller = try center(fixture)
        PrivacyCenterActions.make(controller, controller.state).personalization(false)
        XCTAssertFalse(fixture.local.personalizationOn)
        await waitUntil("同意记录没发") { !self.requests("POST", "/v1/consents").isEmpty }
        let body = try XCTUnwrap(requests("POST", "/v1/consents").first).json
        XCTAssertEqual(body["type"] as? String, "personalization")
        XCTAssertEqual(body["accepted"] as? Bool, false)
        XCTAssertEqual(body["channel"] as? String, "privacy_center")
        XCTAssertEqual(body["version"] as? Int, 3)
        _ = await fixture.enterMeTab()
        await waitUntil("Me 没请求") { !self.requests("GET", "/v1/me").isEmpty }
        XCTAssertEqual(requests("GET", "/v1/me").last?.header("X-Personalization"), "off")
        // 同步失败不回滚，提示一次
        script.fail("POST /v1/consents", 50001)
        let again = try center(fixture)
        PrivacyCenterActions.make(again, again.state).personalization(true)
        await waitUntil("没提示") { again.state.toast?.key == PrivacyCenterController.failedKey }
        XCTAssertTrue(fixture.local.personalizationOn, "不回滚")
    }

    /// 撤回同意：确认框【取消】不撤回；确认后一条设备级 recordConsent {privacy, false, privacy_center}，进入基本模式，推送不再发出，
    /// 撤回清理名单含本任务新增项（设备级偏好、会话级内存）。
    func testWithdrawCancelThenConfirm() async throws {
        let fixture = make(pushToken: "t1")
        fixture.local.markGuideClosed(5)
        let controller = try center(fixture)
        PrivacyCenterActions.make(controller, controller.state).askWithdraw()
        let dialog = try XCTUnwrap(controller.state.dialog)
        PrivacyCenterActions.make(controller, controller.state).cancelWithdraw(dialog)
        XCTAssertEqual(fixture.me.privacy.state.decision, .consented, "取消不撤回")
        PrivacyCenterActions.make(controller, controller.state).confirmWithdraw(dialog)
        XCTAssertFalse(fixture.me.deps.withdraw.busy, "旧确认框编号用过即作废")
        PrivacyCenterActions.make(controller, controller.state).askWithdraw()
        PrivacyCenterActions.make(controller, controller.state).confirmWithdraw(try XCTUnwrap(controller.state.dialog))
        XCTAssertTrue(fixture.me.push.withdrawHalted, "确认生效的同步入口立即停报")
        await waitUntil("没进基本模式") { fixture.me.privacy.state.decision == .basicMode }
        let consents = requests("POST", "/v1/consents")
        XCTAssertEqual(consents.count, 1)
        let body = try XCTUnwrap(consents.first).json
        XCTAssertEqual(body["type"] as? String, "privacy")
        XCTAssertEqual(body["accepted"] as? Bool, false)
        XCTAssertEqual(body["channel"] as? String, "privacy_center")
        XCTAssertTrue(fixture.withdrawal.registeredNames.contains(MeLocalCleaner.name))
        XCTAssertTrue(fixture.withdrawal.registeredNames.contains(MeSessionCleaner.withdrawalName))
        XCTAssertNil(fixture.local.guideClosedAt, "设备级偏好已清")
        XCTAssertEqual(fixture.me.currentIdentity.level, MeLevel.basic)
        XCTAssertNil(fixture.me.deps.repo.state.me, "内存里的 Me 快照已清")
        XCTAssertGreaterThan(fixture.push.stopped, 0, "令牌来源已停")
        fixture.push.change("t2")
        await settle()
        XCTAssertTrue(requests("POST", "/v1/devices/push-token").isEmpty, "撤回后不上报")
        XCTAssertTrue(fixture.router.path.isEmpty)
        XCTAssertEqual(fixture.router.tabRoot.route, "Home", "回基本模式首页")
    }

    /// G24：断网撤回同样进入基本模式；G25：设备未注册不发请求，直接本地撤回。
    func testOfflineAndUnregisteredWithdrawStillLocal() async throws {
        script.on("POST /v1/consents", .disconnect)
        let fixture = make()
        let controller = try center(fixture)
        PrivacyCenterActions.make(controller, controller.state).askWithdraw()
        PrivacyCenterActions.make(controller, controller.state).confirmWithdraw(try XCTUnwrap(controller.state.dialog))
        await waitUntil("断网没进基本模式") { fixture.me.privacy.state.decision == .basicMode }

        WalletStubProtocol.reset()
        script.install()
        let guest = make(account: nil, registered: false)
        let page = try center(guest)
        PrivacyCenterActions.make(page, page.state).askWithdraw()
        PrivacyCenterActions.make(page, page.state).confirmWithdraw(try XCTUnwrap(page.state.dialog))
        await waitUntil("游客没进基本模式") { guest.me.privacy.state.decision == .basicMode }
        XCTAssertTrue(requests("POST", "/v1/consents").isEmpty, "设备未注册不发")
    }

    /// F-HM-24：撤回进行中状态在应用级；控制器重建后继承忙状态、完成前拒绝重复启动。
    func testWithdrawBusyInheritedAcrossRebuild() async throws {
        script.on("POST /v1/consents", .hold)
        let fixture = make()
        let controller = try center(fixture)
        PrivacyCenterActions.make(controller, controller.state).askWithdraw()
        PrivacyCenterActions.make(controller, controller.state).confirmWithdraw(try XCTUnwrap(controller.state.dialog))
        await waitUntil("撤回记录没发出") { !WalletStubProtocol.heldIds.isEmpty }
        XCTAssertTrue(fixture.me.deps.withdraw.busy)
        // 会话归属变了：页面重建执行器，新执行器继承忙状态，不能再发起一次
        fixture.me.syncIdentity()
        let fresh = try fixture.controller("PrivacyCenter", as: PrivacyCenterController.self)
        XCTAssertTrue(fresh.withdrawing)
        PrivacyCenterActions.make(fresh, fresh.state).askWithdraw()
        XCTAssertNil(fresh.state.dialog, "进行中不再出确认框")
        fixture.me.withdrawConsent(fixture.me.computeIdentity())
        WalletStubProtocol.release(try XCTUnwrap(WalletStubProtocol.heldIds.first),
                                   with: .envelope(code: 0, data: "{}", headers: [:]))
        await waitUntil("没进基本模式") { fixture.me.privacy.state.decision == .basicMode }
        XCTAssertEqual(requests("POST", "/v1/consents").count, 1, "只一次")
    }

    /// 基本模式：全程只发匿名请求（不带 Authorization、X-Device-Id、签名），不发 /v1/me。
    func testBasicModeSendsNoCredentials() async throws {
        let fixture = make(account: "user-a", decision: "basic_mode")
        _ = await fixture.enterMeTab()
        _ = try center(fixture)
        await settle()
        XCTAssertTrue(requests("GET", "/v1/me").isEmpty)
        for request in WalletStubProtocol.requests {
            XCTAssertNil(request.header("Authorization"))
            XCTAssertNil(request.header("X-Device-Id"))
            XCTAssertNil(request.header("X-Sign"))
            XCTAssertNil(request.header("X-Personalization"))
        }
    }

    /// 落盘失败：撤回清理有项没清掉 → 「撤回没有生效」提示 +【重试】；重试成功收起。
    func testWithdrawPersistFailureShowsRetry() async throws {
        let fixture = make()
        fixture.local.markGuideClosed(5)
        fixture.localFile.failDelete = true
        let controller = try center(fixture)
        PrivacyCenterActions.make(controller, controller.state).askWithdraw()
        PrivacyCenterActions.make(controller, controller.state).confirmWithdraw(try XCTUnwrap(controller.state.dialog))
        await waitUntil("没提示撤回没有生效") { fixture.me.deps.withdraw.failed != nil }
        XCTAssertEqual(fixture.me.privacy.state.decision, .basicMode, "仍按基本模式")
        XCTAssertNil(fixture.local.guideClosedAt, "待清理期间不读回旧数据")
        fixture.localFile.failDelete = false
        fixture.me.retryWithdrawal = { fixture.runner.retryIfPending() }
        fixture.me.retryWithdrawCleanup(try XCTUnwrap(fixture.me.deps.withdraw.failed))
        XCTAssertNil(fixture.me.deps.withdraw.failed)
    }
}
