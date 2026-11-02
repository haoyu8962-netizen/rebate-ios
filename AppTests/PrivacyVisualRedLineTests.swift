@testable import Couli
import CouliNetwork
import Foundation
import Me
import MeCore
import XCTest

/// brief §0.1 隐私红线逐条（§5，三端同名 redLine1…5；Android `PrivacyVisualRedLineTest`）。全部从页面渲染时取出的同一份回调出发，经真实协调器、真实假服务计数。
/// 本组底版就该绿：实现后还绿才算红线未动。点遮罩、系统返回的真点在 `PrivacyVisualUITests`。
@MainActor
final class PrivacyVisualRedLineTests: PrivacyVisualTestCase {
    func testRedLine1CancelIsZeroAndDialogCloses() async throws {
        try await openPrivacy()
        let dialog = try askWithdraw()
        try centerActions.cancelWithdraw(dialog)
        await settle()
        XCTAssertNil(try center.state.dialog, "取消关闭")
        XCTAssertEqual(consentRecords, 0, "取消零次")
        XCTAssertEqual(page?.fixture.me.privacy.state.decision, .consented, "不撤回")
        try centerActions.confirmWithdraw(dialog)
        await settle()
        XCTAssertEqual(consentRecords, 0, "关闭后旧确认零次")
    }

    /// 确认恰好一次；同一确认框再点仍一次；顺序：撤回记录（设备级）→ 基本模式 → 账号数据不删（不发注销请求）。
    func testRedLine1ConfirmWithdrawsExactlyOnceAndReuseIsVoid() async throws {
        try await openPrivacy()
        let dialog = try askWithdraw()
        let actions = try centerActions
        actions.confirmWithdraw(dialog)
        actions.confirmWithdraw(dialog)
        let me = try XCTUnwrap(page?.fixture.me)
        await waitUntil("没进基本模式") { me.privacy.state.decision == .basicMode }
        XCTAssertEqual(withdrawRecords, 1, "恰好一次")
        let body = try XCTUnwrap(WalletStubProtocol.requests("POST", "/v1/consents").first).json
        XCTAssertEqual(body["accepted"] as? Bool, false)
        XCTAssertEqual(body["channel"] as? String, "privacy_center")
        XCTAssertEqual(me.currentIdentity.level, MeLevel.basic, "本机退出登录")
        XCTAssertTrue(WalletStubProtocol.requests.filter { $0.method == "DELETE" }.isEmpty, "账号与服务端数据不删除")
    }

    /// 换身份后旧确认零次（旧确认框随旧执行器作废，鸿蒙 R3-02）。
    func testRedLine1IdentityChangeVoidsTheOldConfirm() async throws {
        try await openPrivacy()
        let dialog = try askWithdraw()
        let actions = try centerActions
        let fixture = try XCTUnwrap(page?.fixture)
        try fixture.switchAccount(to: "user-b")
        await waitUntil("没换代") { fixture.me.currentIdentity.account == "user-b" }
        actions.confirmWithdraw(dialog)
        await settle()
        XCTAssertEqual(consentRecords, 0, "旧确认零次")
        XCTAssertEqual(fixture.me.privacy.state.decision, .consented)
    }

    /// 撤回进行中：不再出确认框；页面其余入口零动作。
    func testRedLine1WithdrawingDisablesAndOpensNoDialog() async throws {
        try await openPrivacy()
        let host = try XCTUnwrap(page)
        host.script.on("POST /v1/consents", .hold)
        try centerActions.confirmWithdraw(askWithdraw())
        await waitUntil("撤回记录没发出") { !WalletStubProtocol.heldIds.isEmpty }
        XCTAssertTrue(try center.withdrawing)
        let actions = try centerActions
        actions.askWithdraw()
        XCTAssertNil(try center.state.dialog, "进行中不出确认框")
        let opened = host.fixture.router.path.count
        actions.document("privacy")
        actions.permission("push")
        actions.personalization(false)
        XCTAssertEqual(host.fixture.router.path.count, opened, "清单零动作")
        XCTAssertEqual(host.fixture.system.appSettingsOpened, 0, "权限行零动作")
        XCTAssertTrue(host.fixture.local.personalizationOn, "个性化零动作")
        try WalletStubProtocol.release(XCTUnwrap(WalletStubProtocol.heldIds.first),
                                       with: .envelope(code: 0, data: "{}", headers: [:]))
    }

    /// 强更上下文：同一条撤回链；个性化执行层拒绝；不显示权限一节。
    func testRedLine1ForceUpdateContextKeepsTheSameWithdrawChain() async throws {
        try await openPrivacy(Scene(session: "privacy_force_update"))
        let model = try center.model()
        XCTAssertTrue(model.withdrawButton)
        XCTAssertFalse(model.personalizationSwitch)
        XCTAssertFalse(model.permissionSection)
        try centerActions.personalization(false)
        XCTAssertEqual(consentRecords, 0, "个性化拒绝")
        try centerActions.confirmWithdraw(askWithdraw())
        let me = try XCTUnwrap(page?.fixture.me)
        await waitUntil("没进基本模式") { me.privacy.state.decision == .basicMode }
        XCTAssertEqual(withdrawRecords, 1)
    }

    /// 基本模式：模型无开关、无撤回，节点也不存在；进入、停留期间 getMe / recordConsent / 推送上报 0 次。
    func testRedLine2BasicHasNoSwitchNoWithdrawAndZeroRequests() async throws {
        try await openPrivacy(Scene(session: "privacy_basic"), waitFor: "privacy.enableFull.button")
        let model = try center.model()
        XCTAssertFalse(model.personalizationSwitch)
        XCTAssertFalse(model.withdrawButton)
        XCTAssertTrue(model.enableFullButton)
        XCTAssertFalse(has("privacy.personalization.card"), "没有个性化卡")
        XCTAssertFalse(has("privacy.withdraw.card"), "没有撤回卡")
        await quietWindow(0.5)
        try centerActions.personalization(false)
        XCTAssertEqual(meReads, 0, "零 getMe")
        XCTAssertEqual(consentRecords, 0, "零同意记录")
        XCTAssertTrue(WalletStubProtocol.requests("POST", "/v1/devices/push-token").isEmpty, "零推送上报")
        XCTAssertTrue(try XCTUnwrap(page).fixture.local.personalizationOn, "执行层拒绝")
        let me = try XCTUnwrap(page?.fixture.me)
        XCTAssertFalse(me.privacy.isPrompting)
        try centerActions.enableFull()
        XCTAssertTrue(me.privacy.isPrompting, "【开启完整功能】重新展示首启弹窗")
    }

    /// 隐私中心与确认框没有通往注销的路径：全部回调走一遍，路由里没有 DeleteAccount。源码字面在 Guard。
    func testRedLine3NoPathLeadsToDeletion() async throws {
        try await openPrivacy()
        let actions = try centerActions
        let router = try XCTUnwrap(page).fixture.router
        let before = router.path.count
        for type in ["privacy", "sdk_list", "agreement"] {
            actions.document(type)
            XCTAssertNotEqual(router.path.last?.route, SettingsController.deleteAccount, type)
            XCTAssertEqual(router.path.count, before + 1, type)
            // 栈顶同名路由不重复压栈：用户实际是返回后再点
            router.path.removeLast()
        }
        actions.document("delete_account")
        XCTAssertEqual(router.path.count, before, "未知类型零动作")
    }

    /// 说明句是纯文字：撤回卡说明、确认框正文都只有测量，没有命中节点（`.hit`）；文案逐字。
    func testRedLine3SentencesArePlainText() async throws {
        try await openPrivacy(waitFor: "privacy.withdraw.desc")
        let texts = try center.deps.texts
        XCTAssertEqual(try text("privacy.withdraw.desc"), texts.text("privacy_center.withdraw_desc"))
        XCTAssertFalse(has("privacy.withdraw.desc.hit"))
        try askWithdraw()
        _ = try await privacyFrame("privacy.dialog.withdraw.message")
        XCTAssertEqual(try text("privacy.dialog.withdraw.message"), texts.text("privacy.withdraw.confirm.body"))
        XCTAssertFalse(has("privacy.dialog.withdraw.message.hit"))
    }

    /// 权限行：跳系统设置恰好一次，申请 0 次；iOS 契约两条（通知、相册）。
    func testRedLine4PermissionRowOpensAppSettingsOnceAndRequestsNothing() async throws {
        try await openPrivacy()
        XCTAssertEqual(try center.model().permissionRows.map(\.type).sorted(), ["photos", "push"])
        let system = try XCTUnwrap(page).fixture.system
        for (index, type) in ["push", "photos"].enumerated() {
            try centerActions.permission(type)
            XCTAssertEqual(system.appSettingsOpened, index + 1, type)
        }
        try centerActions.permission("camera")
        XCTAssertEqual(system.appSettingsOpened, 2, "未知类型零动作")
        XCTAssertEqual(system.permissionRequests, 0, "只查不申请（BR-ID-13）")
    }

    /// 客服链接逐字等于 kf.url：重试、复制同串。
    func testRedLine5LinkIsVerbatimKfUrlForRetryAndCopy() async throws {
        let kf = try PrivacyVisualData.text("cs", "kf")
        try await openCs("cs_open_failed", waitFor: nil)
        let system = try XCTUnwrap(page).fixture.system
        XCTAssertEqual(system.opened, [kf], "打开微信一次，原串")
        try csActions.openWechat()
        await waitUntil("重试没有发生") { system.opened.count == 2 }
        await settle()
        XCTAssertEqual(system.opened, [kf, kf], "重试原串")
        try csActions.copyLink()
        XCTAssertEqual(try XCTUnwrap(page).fixture.clipboard.last, kf, "复制原串")
    }

    /// 两账号、两入口拿到同一串（AC-S1-134 ④）。
    func testRedLine5TwoAccountsAndTwoEntriesGetTheSameLink() async throws {
        try await openCs("cs_wechat_missing", waitFor: nil)
        let fixture = try XCTUnwrap(page).fixture
        let first = try XCTUnwrap(fixture.me.cs.sheet?.decision.copyText)
        fixture.me.cs.open(from: "RiskNotice")
        XCTAssertEqual(fixture.me.cs.sheet?.decision.copyText, first, "换入口不带发起页")
        try fixture.switchAccount(to: "user-b")
        await waitUntil("没换代") { fixture.me.currentIdentity.account == "user-b" }
        fixture.me.cs.open(from: "Me")
        XCTAssertEqual(fixture.me.cs.sheet?.decision.copyText, first, "换账号不带账号标识")
        XCTAssertEqual(first, try PrivacyVisualData.text("cs", "kf"))
    }
}
