@testable import Couli
import CouliNetwork
import Foundation
import Me
import MeCore
import Router
import XCTest

/// 设置页（AC-S1-77、AC-S1-61、AC-S1-137、G01、G02、G07、G30、G32）：经真实 Router 打开、页面渲染时取出的回调出发。
@MainActor
final class MeSettingsTests: MeTestCase {
    private func settings(_ fixture: MeAppFixture) throws -> SettingsController {
        let entry = try XCTUnwrap(fixture.open("Settings"))
        entry.appeared()
        return try XCTUnwrap(entry.controller() as? SettingsController)
    }

    private func ids(_ controller: SettingsController) -> [String] {
        controller.model().groups.flatMap(\.rows).map(\.id)
    }

    /// AC-S1-77 游客：只有隐私中心、协议、关于、清除缓存、帮助（没有账号与安全、通知设置——不是置灰）；底部【去登录】；四个页面都能打开、全程无 10001。
    func testGuestItemsAndPagesOpenWithout10001() throws {
        let fixture = make(account: nil)
        let controller = try settings(fixture)
        XCTAssertEqual(ids(controller), ["隐私中心", "用户协议与隐私政策", "关于凑狸", "清除缓存", "帮助中心"])
        XCTAssertEqual(controller.model().footer, SettingsItems.footerLogin)
        for (row, route) in [("隐私中心", "PrivacyCenter"), ("关于凑狸", "About"), ("帮助中心", "Help")] {
            let current = try settings(fixture)
            let item = try XCTUnwrap(current.model().groups.flatMap(\.rows).first { $0.id == row })
            SettingsActions.make(current, current.state).row(item)
            XCTAssertEqual(fixture.router.path.last?.route, route, row)
        }
        // 协议半屏 → Agreement {type}
        fixture.router.path = []
        let page = try settings(fixture)
        let agreement = try XCTUnwrap(page.model().groups.flatMap(\.rows).first { $0.id == "用户协议与隐私政策" })
        SettingsActions.make(page, page.state).row(agreement)
        let sheet = try XCTUnwrap(page.state.sheet)
        SettingsActions.make(page, page.state).agreement(try XCTUnwrap(agreement.choices?.last), sheet)
        XCTAssertEqual(fixture.router.path.last?.route, "Agreement")
        XCTAssertEqual(fixture.router.path.last?.params, ["type": .string("privacy")])
        XCTAssertTrue(WalletStubProtocol.requests.allSatisfy { $0.path != "/v1/me" }, "游客不请求 /v1/me")
    }

    /// 基本模式：只有五项（四行 +【开启完整功能】），没有剪贴板开关与清除缓存。
    func testBasicModeFiveItems() throws {
        let fixture = make(account: nil, decision: "basic_mode")
        let controller = try settings(fixture)
        XCTAssertEqual(ids(controller), ["隐私中心", "用户协议与隐私政策", "关于凑狸", "帮助中心"])
        XCTAssertEqual(controller.model().footer, SettingsItems.footerEnableFull)
        SettingsActions.make(controller, controller.state).enableFull()
        XCTAssertTrue(fixture.me.privacy.isPrompting, "点【开启完整功能】重新展示首启弹窗")
    }

    /// 已登录三组；手机号行按 phone_bound（G07）；注销不显示（G30）。
    func testMemberGroups() async throws {
        let fixture = make()
        let controller = try settings(fixture)
        await waitUntil("Me 没到") { fixture.me.deps.repo.state.me != nil }
        let model = controller.model()
        XCTAssertEqual(model.groups.map(\.name), ["账号与安全", "隐私", "通用"])
        XCTAssertFalse(ids(controller).contains("注销账号"))
        XCTAssertFalse(ids(controller).contains(SettingsItems.idClipboard), "剪贴板开关只在 Android")
        XCTAssertEqual(model.groups[0].rows.first { $0.id == "手机号" }?.clickable, false)
        XCTAssertEqual(model.footer, SettingsItems.footerLogout)
    }

    /// 退出登录：确认框【取消】不退出；确认后只调已有 logout()，回「我的」游客态，推送不再上报。
    func testLogoutConfirmCancelAndLand() async throws {
        let fixture = make(pushToken: "t1")
        let controller = try settings(fixture)
        SettingsActions.make(controller, controller.state).askLogout()
        let dialog = try XCTUnwrap(controller.state.dialog)
        SettingsActions.make(controller, controller.state).cancelDialog(dialog)
        XCTAssertTrue(fixture.login.loggedIn, "取消不退出")
        // 旧确认框的编号用过即作废
        SettingsActions.make(controller, controller.state).confirmLogout(dialog)
        XCTAssertTrue(fixture.login.loggedIn)
        SettingsActions.make(controller, controller.state).askLogout()
        let second = try XCTUnwrap(controller.state.dialog)
        SettingsActions.make(controller, controller.state).confirmLogout(second)
        XCTAssertTrue(fixture.me.push.halted, "确认生效的同步入口立即停报")
        await waitUntil("没有回到「我的」") { fixture.router.tabRoot.route == "Me" && fixture.router.path.isEmpty }
        XCTAssertFalse(fixture.login.loggedIn)
        XCTAssertEqual(requests("POST", "/v1/auth/logout").count, 1)
        fixture.push.change("t2")
        await settle()
        XCTAssertTrue(requests("POST", "/v1/devices/push-token").isEmpty, "退出后不上报")
    }

    /// AC-S1-137：取消不清；确认后「已清除」、大小变小；仍登录、个性化仍关闭（只清图片与网页缓存）。
    func testClearCacheKeepsSessionAndPreferences() async throws {
        let fixture = make()
        fixture.local.setPersonalization(false, now: 1)
        let controller = try settings(fixture)
        await waitUntil("缓存大小没算出") { controller.state.cacheBytes != nil }
        let before = try XCTUnwrap(controller.state.cacheBytes)
        let row = try XCTUnwrap(controller.model().groups.flatMap(\.rows).first { $0.id == "清除缓存" })
        SettingsActions.make(controller, controller.state).row(row)
        SettingsActions.make(controller, controller.state).cancelDialog(try XCTUnwrap(controller.state.dialog))
        XCTAssertEqual(fixture.system.cleared, 0, "取消不清")
        SettingsActions.make(controller, controller.state).row(row)
        SettingsActions.make(controller, controller.state).confirmClear(try XCTUnwrap(controller.state.dialog))
        await waitUntil("没有清完") { controller.state.toast?.key == "settings.clear_cache.done" }
        XCTAssertLessThan(try XCTUnwrap(controller.state.cacheBytes), before)
        XCTAssertTrue(fixture.login.loggedIn, "仍登录")
        XCTAssertFalse(fixture.local.personalizationOn, "个性化仍关闭")
        XCTAssertEqual(CacheSize.text(before), "3MB")
        XCTAssertEqual(CacheSize.text(12 * 1024), "12KB")
    }

    /// 「重新显示下单须知」：DELETE /v1/me/tips/jump_tip，成功提示并推进已读缓存世代；42901 执行层与页面都拦。
    func testResetTip() async throws {
        let fixture = make()
        var resets = 0
        fixture.me.onTipsReset = { resets += 1 }
        let controller = try settings(fixture)
        let row = try XCTUnwrap(controller.model().groups.flatMap(\.rows).first { $0.id == "重新显示下单须知" })
        SettingsActions.make(controller, controller.state).row(row)
        await waitUntil("没有提示") { controller.state.toast?.key == "settings.reset_tip.done" }
        XCTAssertEqual(requests("DELETE", "/v1/me/tips/jump_tip").count, 1)
        XCTAssertEqual(resets, 1)
        script.fail("DELETE /v1/me/tips/jump_tip", 42901, headers: ["Retry-After": "20"])
        SettingsActions.make(controller, controller.state).row(row)
        await waitUntil("42901 没提示") { controller.state.toast?.key == "error.42901" }
        SettingsActions.make(controller, controller.state).row(row)
        await settle()
        XCTAssertEqual(requests("DELETE", "/v1/me/tips/jump_tip").count, 2, "禁用期内不发")
    }

    private func nicknamePage(_ fixture: MeAppFixture) async throws -> (SettingsController, NicknameController) {
        let controller = try settings(fixture)
        await waitUntil("Me 没到") { fixture.me.deps.repo.state.me != nil }
        let row = try XCTUnwrap(controller.model().groups.flatMap(\.rows).first { $0.id == "昵称" })
        XCTAssertTrue(row.clickable, "Debug 后端时昵称可改")
        SettingsActions.make(controller, controller.state).row(row)
        return (controller, try XCTUnwrap(controller.nickname))
    }

    /// AC-S1-61：3 次成功后「我的」即时显示新昵称；第 4 次 30415；敏感词 20001 子键（保留输入）；空白与 17 字素不可保存（含 emoji 组合字素）。
    func testNicknameFlow() async throws {
        let fixture = make()
        var (settings, nickname) = try await nicknamePage(fixture)
        XCTAssertEqual(nickname.state.input, "凑狸用户", "预填当前昵称")
        for name in ["小狸1", "小狸2", "小狸爱买买"] {
            script.ok("GET /v1/me", MeSamples.me(nickname: name))
            NicknameActions.make(nickname, nickname.state).input(name)
            NicknameActions.make(nickname, nickname.state).save()
            await waitUntil("保存没有结束") { settings.nickname == nil }
            XCTAssertEqual(fixture.me.deps.repo.state.me?.nickname, name, "我的 / 设置即时显示新昵称")
            XCTAssertEqual(settings.state.toast?.key, "nickname.saved")
            (settings, nickname) = try await nicknamePage(fixture)
        }
        fixture.nickname.reply(.failure(code: 30415, msg: "", data: nil, traceId: nil,
                                        effect: ErrorEffect(code: 30415, kind: .toast), idempotencyKey: nil))
        NicknameActions.make(nickname, nickname.state).input("第四次")
        NicknameActions.make(nickname, nickname.state).save()
        await waitUntil("30415 没提示") { nickname.state.error?.key == "error.30415" }
        XCTAssertEqual(nickname.state.input, "第四次", "保留输入")
        fixture.nickname.reply(.failure(
            code: 20001, msg: "", data: Data(#"{"reason":"nickname_sensitive","fields":["nickname"]}"#.utf8),
            traceId: nil, effect: ErrorEffect(code: 20001, kind: .fieldError), idempotencyKey: nil
        ))
        NicknameActions.make(nickname, nickname.state).input("敏感词")
        NicknameActions.make(nickname, nickname.state).save()
        await waitUntil("敏感词没提示") { nickname.state.error?.key == "error.20001.nickname_sensitive" }
        XCTAssertTrue(nickname.state.fieldError)
        XCTAssertEqual(nickname.state.input, "敏感词")
        for (text, enabled) in [("   ", false), (String(repeating: "狸", count: 17), false),
                                (String(repeating: "👨‍👩‍👧", count: 16), true), ("é", true)] {
            NicknameActions.make(nickname, nickname.state).input(text)
            XCTAssertEqual(nickname.state.check.saveEnabled, enabled, text)
        }
    }

    /// 昵称保存前发出的 getMe 晚于保存成功到达，不把旧昵称覆盖回来（推进读取世代）。
    func testStaleGetMeAfterNicknameSaveDoesNotOverride() async throws {
        let fixture = make()
        let (settings, nickname) = try await nicknamePage(fixture)
        script.on("GET /v1/me", .hold)
        settings.retryMe()
        await waitUntil("旧 getMe 没发出") { !WalletStubProtocol.heldIds.isEmpty }
        let held = try XCTUnwrap(WalletStubProtocol.heldIds.first)
        script.ok("GET /v1/me", MeSamples.me(nickname: "新昵称"))
        NicknameActions.make(nickname, nickname.state).input("新昵称")
        NicknameActions.make(nickname, nickname.state).save()
        await waitUntil("保存没有结束") { settings.nickname == nil }
        WalletStubProtocol.release(held, with: .envelope(code: 0, data: MeSamples.me(nickname: "凑狸用户"), headers: [:]))
        await settle(40)
        XCTAssertEqual(fixture.me.deps.repo.state.me?.nickname, "新昵称")
    }

    /// 会话失效 → 登录 B → 返回旧设置页：修改昵称子页关掉、输入清空，看到的是 B 的资料；旧子页回调不再生效。
    func testSessionSwitchClosesNicknameSubpage() async throws {
        let fixture = make()
        let (settings, nickname) = try await nicknamePage(fixture)
        NicknameActions.make(nickname, nickname.state).input("A 的草稿")
        let stale = NicknameActions.make(nickname, nickname.state)
        script.ok("GET /v1/me", MeSamples.me(account: "user-b", nickname: "B 用户"))
        try fixture.switchAccount(to: "user-b")
        await waitUntil("身份没换代") { fixture.me.currentIdentity.account == "user-b" }
        XCTAssertTrue(settings.hasLeft, "旧执行器作废")
        XCTAssertEqual(nickname.state.input, "", "昵称草稿清空")
        let fresh = try fixture.controller("Settings", as: SettingsController.self)
        XCTAssertFalse(fresh === settings)
        XCTAssertNil(fresh.nickname)
        stale.save()
        await settle()
        XCTAssertTrue(fixture.nickname.calls.isEmpty, "旧子页回调不发请求")
        await waitUntil("B 的资料没到") { fixture.me.deps.repo.state.me?.nickname == "B 用户" }
    }

    /// 42901：昵称保存按 Retry-After 禁用（执行层）。
    func testNicknameRetryAfterGate() async throws {
        let fixture = make()
        let (_, nickname) = try await nicknamePage(fixture)
        fixture.nickname.reply(.failure(code: 42901, msg: "", data: nil, traceId: nil,
                                        effect: ErrorEffect(code: 42901, kind: .disableButton, disableMillis: 30000),
                                        idempotencyKey: nil))
        NicknameActions.make(nickname, nickname.state).input("小狸")
        NicknameActions.make(nickname, nickname.state).save()
        await waitUntil("42901 没提示") { nickname.state.error?.key == "error.42901" }
        XCTAssertTrue(fixture.me.gates.nickname.active)
        NicknameActions.make(nickname, nickname.state).save()
        await settle()
        XCTAssertEqual(fixture.nickname.calls.count, 1, "禁用期内不发")
    }

    /// 通知设置（G02）：系统未开启 → 提示条；开关切换失败回到切换前的值并提示；【去设置】只跳系统设置。
    func testNotifySettings() async throws {
        let fixture = make()
        fixture.system.status["push"] = "permanently_denied"
        let controller = try settings(fixture)
        let row = try XCTUnwrap(controller.model().groups.flatMap(\.rows).first { $0.id == "通知设置" })
        SettingsActions.make(controller, controller.state).row(row)
        let notify = try XCTUnwrap(controller.notify)
        await waitUntil("开关没取到") { notify.state.service != nil && notify.state.systemGranted != nil }
        XCTAssertEqual(notify.state.systemGranted, false)
        NotifyActions.make(notify, notify.state).goSettings()
        XCTAssertEqual(fixture.system.notificationSettingsOpened, 1)
        fixture.notify.putReply = .failure(code: 50001, msg: "", data: nil, traceId: "stub-trace-0123456789ab",
                                           effect: ErrorEffect(code: 50001, kind: .genericError), idempotencyKey: nil)
        NotifyActions.make(notify, notify.state).toggle(false)
        await waitUntil("失败没回滚") { !notify.state.switching }
        XCTAssertEqual(notify.state.service, true, "回到切换前的值")
        XCTAssertNotNil(notify.state.toast)
    }

    /// 身份固定（APP-09 共性第 63、65 条）：令牌已换、换代通知还没到的窗口里，旧表单的保存不得绑定执行时的当前会话。
    func testSilentSwapRejectsNicknameSave() async throws {
        let fixture = make()
        let (_, nickname) = try await nicknamePage(fixture)
        NicknameActions.make(nickname, nickname.state).input("A 的新昵称")
        let save = NicknameActions.make(nickname, nickname.state).save
        fixture.client.signOut()
        try fixture.tokens.save(access: "at-user-b", refresh: "rt-user-b", scope: "full", account: "user-b")
        save()
        await settle()
        XCTAssertTrue(fixture.nickname.calls.isEmpty, "固定身份已不是当前会话：不发")
    }
}
