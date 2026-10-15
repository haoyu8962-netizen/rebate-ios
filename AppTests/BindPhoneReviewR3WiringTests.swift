@testable import Couli
import CouliNetwork
import Foundation
import Login
import Router
import Session
import XCTest

/// 第 3 轮评审窄修 R3-03 的 App 接线测试（真实 AppNetwork + AppRouting + AppLogin，WalletStubProtocol 本地假服务）：绑定成功通知
/// 只匹配账号时，同账号同登录世代降为 deletion_only 后重建的新绑手机页会误退出并释放待办暂缓。
@MainActor
final class BindPhoneReviewR3WiringTests: MeTestCase {
    private static let attempt = "{\"attempt_id\":\"att-1\",\"nonce\":\"nonce-for-test-0001\","
        + "\"expire_at\":\"2099-01-01T00:10:00+08:00\"}"
    private static let login = "{\"user_id\":\"user-oauth\",\"is_new_user\":true,\"tokens\":{\"access_token\":\"at-o\","
        + "\"refresh_token\":\"rt-o\",\"session_scope\":\"full\"}}"

    override func setUpWithError() throws {
        try super.setUpWithError()
        UserDefaultsPendingBackend().delete()
        script.ok("POST /v1/auth/oauth-attempts", Self.attempt)
        script.ok("POST /v1/auth/login/wechat", Self.login)
        script.on("POST /v1/me/phone", .hold)
        script.install()
    }

    override func tearDown() {
        UserDefaultsPendingBackend().delete()
        super.tearDown()
    }

    /// 游客点 InviteShare → 第三方（微信）新号登录 → 引导【去绑定】→ 绑手机页（前台、栈顶、可见）。返回该导航实例与页面。
    private func openBindPageForNewUser(_ fixture: MeAppFixture) async throws -> (RouteDestination, BindPhoneEntry) {
        let login = fixture.login
        let wechat = AppFakeAuthorizer(OAuthProvider.wechat)
        login.oauth.authorizers = [OAuthProvider.wechat: wechat]
        fixture.router.open(RouteRequest(route: "InviteShare", from: .inApp))
        let model = LoginViewModel(config: login.pageConfig(restricted: false))
        model.toggleAgreement()
        model.startOAuth(OAuthProvider.wechat)
        await waitUntil("没有拉起授权") { wechat.authorizing }
        wechat.complete(.credential(.wechat(code: "code-from-sdk")))
        await waitUntil("没有弹绑手机引导") { login.bindGuide != nil }
        let guide = try XCTUnwrap(login.bindGuide)
        login.goBindPhone(guide.id)
        let top = try XCTUnwrap(fixture.router.path.last)
        XCTAssertEqual(top.route, RoutePolicy.bindPhone)
        let entry = login.bindEntry(for: top)
        login.scenePhaseChanged(active: true)
        return (top, entry)
    }

    /// R3-03：full 会话（第三方新号，InviteShare 待办暂缓中）在绑手机页提交绑定、响应挂起 → 同账号同登录世代降为 deletion_only，
    /// 会话同步重建绑手机页（新实例的固定身份是 deletion_only）→ 原绑定成功响应迟到：旧请求只做（已被拒绝的）共享结算与未决重读；
    /// 新页面不退出、不释放暂缓、不打开原目标、不提示绑定成功，phone_bound 不记。
    func testLateBindSuccessAfterSameGenerationDowngradeKeepsNewPageAndHold() async throws {
        let fixture = make(account: nil)
        let login = fixture.login
        let (top, entry) = try await openBindPageForNewUser(fixture)
        let old = entry.controller
        XCTAssertTrue(old.owner.usable)
        XCTAssertTrue(fixture.router.pendingHeld)
        let generation = fixture.client.sessionGeneration

        let before = requests("POST", "/v1/me/phone").count
        old.setPhone("13800138000")
        old.setCode("123456")
        old.submit()
        await waitUntil("绑定没有发出") { requests("POST", "/v1/me/phone").count > before }
        let held = requests("POST", "/v1/me/phone")[before].id

        // 同账号、同登录世代降为 deletion_only（不登出），会话同步重建绑手机页
        let account = try XCTUnwrap(old.owner.account)
        try fixture.tokens.save(access: "at-r", refresh: "rt-r", scope: SessionScope.deletionOnly, account: account)
        XCTAssertEqual(fixture.client.sessionGeneration, generation, "同一登录世代")
        fixture.routing.sessionStateChanged(resumePending: false)
        let rebuilt = entry.controller
        XCTAssertFalse(rebuilt === old, "按新身份重建")
        XCTAssertEqual(rebuilt.owner.account, account, "同账号")
        XCTAssertEqual(rebuilt.owner.scope, SessionScope.deletionOnly)
        XCTAssertTrue(fixture.router.path.contains { $0.id == top.id }, "前提：新页面仍在栈上")
        let pathBefore = fixture.router.path.map(\.id)
        XCTAssertTrue(fixture.router.pendingHeld, "前提：暂缓仍在")

        WalletStubProtocol.release(held, with: .envelope(code: 0, data: "{}", headers: [:]))
        await settle()
        for _ in 0..<5 {
            await Task.yield()
            try? await Task.sleep(nanoseconds: 20_000_000)
        }

        XCTAssertTrue(rebuilt.alive, "新页面实例不被旧请求作废")
        XCTAssertEqual(fixture.router.path.map(\.id), pathBefore, "新页面不退出")
        XCTAssertTrue(fixture.router.pendingHeld, "不释放暂缓")
        XCTAssertTrue(fixture.router.hasPendingAction, "待办保留")
        XCTAssertFalse(fixture.router.path.contains { $0.route == "InviteShare" }, "不打开原目标")
        XCTAssertNotEqual(fixture.router.tabRoot.route, "InviteShare")
        XCTAssertNotEqual(login.phone.bound(generation: generation), true, "旧请求不记 phone_bound")
        XCTAssertNil(login.toast, "不提示绑定成功")
    }
}
