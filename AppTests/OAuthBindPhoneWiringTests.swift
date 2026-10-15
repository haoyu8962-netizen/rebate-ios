@testable import Couli
import CouliNetwork
import DesignSystem
import Foundation
import Login
import Router
import Session
import SwiftUI
import WalletCore
import XCTest

/// 可控的第三方适配器（只替换 SDK 这一层；App 组合、Router、网络层都是真实的）。
@MainActor
final class AppFakeAuthorizer: ThirdPartyAuthorizer {
    let provider: String
    let available = true
    let installed: Bool? = true
    private var waiting: CheckedContinuation<OAuthAuthorization, Never>?

    init(_ provider: String) {
        self.provider = provider
    }

    var authorizing: Bool {
        waiting != nil
    }

    func authorize(nonce _: String) async -> OAuthAuthorization {
        await withCheckedContinuation { waiting = $0 }
    }

    func complete(_ result: OAuthAuthorization) {
        let pending = waiting
        waiting = nil
        pending?.resume(returning: result)
    }

    func abort() {}
}

/// APP-05b App 接线（真实 AppNetwork + AppRouting + AppLogin + AppMe，WalletStubProtocol 本地假服务；绑手机页放进真实宿主 UIWindow）：
/// 第三方新号 → 绑手机引导 → 绑手机 → 恢复待办；引导【暂不】/ 未绑定离开只恢复；冷启动与主动打开时手机号状态未知按未绑、先查 getMe；
/// 会话换代重建绑手机页；绑定成功清钱包全部 step-up token。
@MainActor
final class OAuthBindPhoneWiringTests: MeTestCase {
    private static let attempt = "{\"attempt_id\":\"att-1\",\"nonce\":\"nonce-for-test-0001\","
        + "\"expire_at\":\"2099-01-01T00:10:00+08:00\"}"

    private static func login(isNew: Bool) -> String {
        "{\"user_id\":\"user-oauth\",\"is_new_user\":\(isNew),\"tokens\":{\"access_token\":\"at-o\","
            + "\"refresh_token\":\"rt-o\",\"session_scope\":\"full\"}}"
    }

    override func setUpWithError() throws {
        try super.setUpWithError()
        UserDefaultsPendingBackend().delete()
        script.ok("POST /v1/auth/oauth-attempts", Self.attempt)
        script.ok("POST /v1/auth/login/wechat", Self.login(isNew: true))
        script.ok("POST /v1/auth/sms-codes", "{\"resend_after_sec\":60,\"expires_in_sec\":300}")
        script.ok("POST /v1/me/phone", "{}")
        script.install()
    }

    override func tearDown() {
        UserDefaultsPendingBackend().delete()
        super.tearDown()
    }

    /// 游客点 `route` → 登录页；第三方（微信）新号登录成功。返回适配器。
    private func oauthNewUser(_ fixture: MeAppFixture, opening route: String) async throws -> AppFakeAuthorizer {
        let wechat = AppFakeAuthorizer(OAuthProvider.wechat)
        fixture.login.oauth.authorizers = [OAuthProvider.wechat: wechat]
        fixture.router.open(RouteRequest(route: route, from: .inApp))
        XCTAssertEqual(fixture.router.path.last?.route, RoutePolicy.login)
        let model = LoginViewModel(config: fixture.login.pageConfig(restricted: false))
        XCTAssertEqual(model.providers, [OAuthProvider.wechat])
        model.toggleAgreement()
        model.startOAuth(OAuthProvider.wechat)
        await waitUntil("没有拉起授权") { wechat.authorizing }
        wechat.complete(.credential(.wechat(code: "code-from-sdk")))
        await waitUntil("没有弹绑手机引导") { fixture.login.bindGuide != nil }
        return wechat
    }

    private func bindEntry(_ fixture: MeAppFixture) throws -> BindPhoneEntry {
        let top = try XCTUnwrap(fixture.router.path.last)
        XCTAssertEqual(top.route, RoutePolicy.bindPhone)
        return fixture.login.bindEntry(for: top)
    }

    /// 第三方新号 → 引导【去绑定】→ 绑手机页（真实宿主）发码 purpose=bind、绑定成功 → 只出栈本实例、按完成前置恢复需要手机号的待办。
    func testNewUserGuideBindPhoneThenResumesPhonePending() async throws {
        let fixture = make(account: nil)
        _ = try await oauthNewUser(fixture, opening: "InviteShare")
        XCTAssertFalse(fixture.router.path.contains { $0.route == RoutePolicy.login }, "登录页已关闭")
        XCTAssertTrue(fixture.router.pendingHeld)
        XCTAssertEqual(fixture.routing.guardState.session, .loggedIn)
        let guide = try XCTUnwrap(fixture.login.bindGuide)
        fixture.login.goBindPhone(guide.id)
        let entry = try bindEntry(fixture)
        let host = HostedPage(AnyView(BindPhoneScreen(entry: entry, texts: fixture.login.texts)))
        defer { host.close() }
        await host.pump()
        let controller = entry.controller
        controller.setPhone("13800138000")
        controller.sendCode()
        await host.pump(until: { controller.resendRemaining > 0 })
        XCTAssertEqual(requests("POST", "/v1/auth/sms-codes").last?.json["purpose"] as? String, "bind")
        controller.setCode("123456")
        controller.submit()
        await host.pump(until: { fixture.router.path.last?.route == "InviteShare" })

        XCTAssertEqual(fixture.router.path.map(\.route), ["InviteShare"], "绑手机页出栈，恢复待办")
        XCTAssertFalse(fixture.router.hasPendingAction)
        XCTAssertFalse(fixture.router.pendingHeld)
        XCTAssertEqual(fixture.routing.guardState.session, .phoneBound)
        XCTAssertEqual(fixture.login.toast?.text, "手机号已绑定")
        XCTAssertNil(requests("POST", "/v1/me/phone").last?.header(HeaderNames.stepUpToken))
    }

    /// 引导【暂不】：只恢复（OrderList 只需登录 → 打开），不重置计时。
    func testGuideSkipResumesOnly() async throws {
        let fixture = make(account: nil)
        _ = try await oauthNewUser(fixture, opening: "OrderList")
        let guide = try XCTUnwrap(fixture.login.bindGuide)
        fixture.login.skipBindGuide(guide.id)
        XCTAssertNil(fixture.login.bindGuide)
        XCTAssertEqual(fixture.router.tabRoot.route, "OrderList")
        XCTAssertFalse(fixture.router.hasPendingAction)
    }

    /// 【去绑定】后未绑定就返回：出栈的同步出口释放暂缓并只恢复；需要手机号的待办按未绑保留，不再被推回绑手机页。
    func testLeavingBindPhoneUnboundResumesOnly() async throws {
        for (route, opens) in [("OrderList", true), ("InviteShare", false)] {
            UserDefaultsPendingBackend().delete()
            let fixture = make(account: nil)
            _ = try await oauthNewUser(fixture, opening: route)
            fixture.login.goBindPhone(try XCTUnwrap(fixture.login.bindGuide).id)
            let entry = try bindEntry(fixture)
            entry.controller.back()
            await waitUntil("\(route)：暂缓没有释放") { !fixture.router.pendingHeld }
            await settle()
            XCTAssertFalse(fixture.router.path.contains { $0.route == RoutePolicy.bindPhone }, route)
            if opens {
                XCTAssertEqual(fixture.router.tabRoot.route, "OrderList")
            } else {
                XCTAssertTrue(fixture.router.hasPendingAction, "\(route)：保留")
            }
            XCTAssertFalse(entry.controller.alive, "旧实例作废")
        }
    }

    /// 共性第 8 条：冷启动有会话、phone_bound 未知、有手机号级待办 → 先查 getMe；已绑 → 经守卫恢复；未绑 → 保留、不自动拉起绑手机页。
    func testColdStartChecksPhoneBeforeResumingPhonePending() async {
        for bound in [true, false] {
            UserDefaultsPendingBackend().delete()
            script.ok("GET /v1/me", MeSamples.me(phoneBound: bound))
            let pending = PendingActionStore(backend: UserDefaultsPendingBackend())
            XCTAssertTrue(pending.save(
                action: Router.openRouteAction, values: ["route": .string("InviteShare")], now: pending.now,
                origin: RouteSource.inApp.rawValue
            ))
            let fixture = make(phoneKnown: false)
            fixture.routing.launchConditionsChanged()
            await waitUntil("没有查清") {
                fixture.login.phone.bound(generation: fixture.client.sessionGeneration) != nil
            }
            XCTAssertFalse(requests("GET", "/v1/me").isEmpty, "先查 getMe")
            if bound {
                await waitUntil("没有恢复") { fixture.router.path.last?.route == "InviteShare" }
                XCTAssertEqual(fixture.router.path.last?.route, "InviteShare")
                XCTAssertFalse(fixture.router.hasPendingAction)
            } else {
                await settle()
                XCTAssertTrue(fixture.router.hasPendingAction, "未绑：保留")
                XCTAssertFalse(fixture.router.path.contains { $0.route == RoutePolicy.bindPhone }, "不自动拉起")
            }
        }
    }

    /// 共性第 13、38 条：手机号状态未知时主动打开需要手机号的页面 → 先进绑手机页（登记待办）；进页查 getMe 已绑 → 只出栈本实例并打开原目标。
    func testOpeningPhoneRouteWhileUnknownRechecksThenOpensTarget() async throws {
        let fixture = make(phoneKnown: false)
        fixture.router.open(RouteRequest(route: "InviteShare", from: .inApp))
        let entry = try bindEntry(fixture)
        XCTAssertTrue(fixture.router.hasPendingAction)
        let host = HostedPage(AnyView(BindPhoneScreen(entry: entry, texts: fixture.login.texts)))
        defer { host.close() }
        await host.pump(until: { fixture.router.path.last?.route == "InviteShare" })
        XCTAssertEqual(fixture.router.path.map(\.route), ["InviteShare"])
        XCTAssertFalse(fixture.router.hasPendingAction)
    }

    /// 共性第 6、36 条：会话换代（换账号）时作废旧绑手机页、清空输入，按新身份重建。
    func testSessionChangeRebuildsBindPage() throws {
        let fixture = make(phoneKnown: false)
        script.ok("GET /v1/me", MeSamples.me(phoneBound: false))
        fixture.router.open(RouteRequest(route: RoutePolicy.bindPhone, from: .inApp))
        let entry = try bindEntry(fixture)
        let old = entry.controller
        old.setPhone("13800138000")
        try fixture.switchAccount(to: "user-b")
        XCTAssertFalse(old.alive)
        XCTAssertEqual(old.phone, "", "旧实例清空输入")
        XCTAssertFalse(entry.controller === old)
        XCTAssertEqual(entry.controller.owner.account, "user-b")
        XCTAssertEqual(entry.controller.phone, "")
    }

    /// APP-13a 共性第 9 条：绑定成功的共享结算清钱包里全部 action 的 step-up token（App 的 connect 接线）。
    func testBindSuccessClearsAllStepUpTokens() async {
        let walletFixture = WalletAppFixture.make(suiteName: suiteName + ".wallet", defaults: defaults)
        let login = walletFixture.login
        login.connect(wallet: walletFixture.wallet)
        let tokens = walletFixture.wallet.deps.tokens
        tokens.put(action: "withdraw", account: "user-a", token: "t1", expireAtMs: .max)
        tokens.put(action: "payout_account_change", account: "user-a", token: "t2", expireAtMs: .max)
        WalletStubProtocol.install { _ in .envelope(code: 0, data: "{}", headers: [:]) }
        let log = BindPhoneHooks()
        let controller = BindPhoneController(
            owner: login.bind.identity(), entryId: UUID(), service: login.bind, texts: login.texts, hooks: log
        )
        controller.appeared()
        controller.setPhone("13800138000")
        controller.setCode("123456")
        controller.submit()
        await waitUntil("没有结算") { tokens.take(action: "withdraw", account: "user-a", nowMs: 0) == nil }
        XCTAssertNil(tokens.take(action: "payout_account_change", account: "user-a", nowMs: 0))
    }

    /// 第 1 轮 R1-02：绑定成功的共享结算启动新一轮 getMe（页面不可见 / 未出现也做），按绑定的固定归属更新共享 Me 资料；读取限流期内不发。
    func testBindSuccessRefreshesSharedMeWithFixedOwner() async {
        let fixture = make(phoneKnown: false)
        script.ok("GET /v1/me", MeSamples.me(phoneBound: true))
        let login = fixture.login
        let before = requests("GET", "/v1/me").count
        let controller = BindPhoneController(
            owner: login.bind.identity(), entryId: UUID(), service: login.bind, texts: login.texts,
            hooks: BindPhoneHooks()
        )
        controller.setPhone("13800138000")
        controller.setCode("123456")
        controller.submit()
        await waitUntil("绑定后没有刷新 getMe") { requests("GET", "/v1/me").count > before }
        await waitUntil("共享 Me 资料没有更新") { fixture.me.deps.repo.state.me != nil }
        XCTAssertEqual(fixture.me.deps.repo.state.identity?.request, controller.owner.request, "按绑定的固定归属")

        let sent = requests("GET", "/v1/me").count
        fixture.me.gates.read.start(30000)
        login.onBoundRefresh?(controller.owner)
        await settle()
        XCTAssertEqual(requests("GET", "/v1/me").count, sent, "读取限流期内不发")
    }

    /// 第 1 轮 R1-06（N-41）：Debug / Staging 不带 -CouliFakeLoginServer 也显示 Apple 按钮并走调试假授权；微信仍用正式「不可用」适配器；
    /// Release 的正式适配器由 AppleSignInSwitch 控制（关着）。
    func testDebugBuildShowsAppleWithoutFakeServerArgument() {
        let authorizers = AppLogin.authorizers(arguments: [])
        XCTAssertTrue(authorizers[OAuthProvider.apple] is DebugFakeAuthorizer, "接调试假授权")
        XCTAssertEqual(authorizers[OAuthProvider.apple]?.available, true)
        XCTAssertEqual(authorizers[OAuthProvider.wechat]?.available, false)
        XCTAssertEqual(AppLogin.releaseAuthorizers()[OAuthProvider.apple]?.available, AppleSignInSwitch.enabled)
        let fixture = make(account: nil)
        let model = LoginViewModel(config: fixture.login.pageConfig(restricted: false))
        XCTAssertEqual(model.providers, [OAuthProvider.apple], "普通 Debug 启动显示 Apple")
    }

    /// 编排补充（Android FU-AND-0716 S0，共性第 31 条）：A 绑定成功 → 绑定后的 getMe 挂起 → 退出 A、游客点需要手机号的入口、B 第三方新号
    /// 登录（引导显示、待办暂缓）→ A 的 getMe 迟到返回：B 的暂缓、待办、引导、手机号状态与守卫都不变，不打开原目标，A 的资料不写进 B。
    /// iOS 的共享收尾（记已绑、解除暂缓、守卫重算）在绑定响应结算时按固定身份同步完成，getMe 只更新 Me 快照且按发起时的身份核对。
    func testLateBindRefreshOfOldAccountLeavesNewSessionHoldIntact() async throws {
        let fixture = make(phoneKnown: false)
        let login = fixture.login
        script.on("GET /v1/me", .hold)
        let controller = BindPhoneController(
            owner: login.bind.identity(), entryId: UUID(), service: login.bind, texts: login.texts,
            hooks: BindPhoneHooks()
        )
        let ownerA = controller.owner
        let before = requests("GET", "/v1/me").count
        controller.setPhone("13800138000")
        controller.setCode("123456")
        controller.submit()
        await waitUntil("A 的绑定后 getMe 没有发出") { requests("GET", "/v1/me").count > before }
        let heldA = requests("GET", "/v1/me")[before].id
        XCTAssertEqual(login.phone.bound(generation: ownerA.request.generation), true, "A 的共享收尾已在绑定结算时完成")

        // 退出 A（会话世代推进）→ 游客点 InviteShare → B 第三方新号登录：暂缓 + 引导
        fixture.client.signOut()
        fixture.routing.sessionStateChanged(resumePending: false)
        script.ok("GET /v1/me", MeSamples.me(phoneBound: false))
        _ = try await oauthNewUser(fixture, opening: "InviteShare")
        let generationB = fixture.client.sessionGeneration
        XCTAssertNotEqual(generationB, ownerA.request.generation)
        XCTAssertTrue(fixture.router.pendingHeld)
        let guide = try XCTUnwrap(login.bindGuide)

        WalletStubProtocol.release(heldA, with: .envelope(code: 0, data: MeSamples.me(phoneBound: true), headers: [:]))
        await settle()

        XCTAssertTrue(fixture.router.pendingHeld, "B 的暂缓不被 A 的迟到结果解除")
        XCTAssertTrue(fixture.router.hasPendingAction, "B 的待办保留")
        XCTAssertEqual(login.bindGuide?.id, guide.id, "B 的引导仍在")
        XCTAssertFalse(fixture.router.path.contains { $0.route == "InviteShare" }, "不打开原目标")
        XCTAssertNotEqual(fixture.router.tabRoot.route, "InviteShare")
        XCTAssertEqual(login.phone.bound(generation: generationB), false, "B 仍按未绑手机")
        XCTAssertEqual(fixture.routing.guardState.session, .loggedIn)
        XCTAssertNotEqual(fixture.me.deps.repo.state.identity?.request, ownerA.request, "A 的资料不写进 B")
    }
}
