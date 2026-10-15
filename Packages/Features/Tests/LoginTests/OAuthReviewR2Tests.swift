import CouliNetwork
import Foundation
@testable import Login
import Router
import Session
import XCTest

/// 第 2 轮评审修复（APP-05b ios-review-r2 R2-01）的回归测试：受限登录（从强更页进入）照样按适配器可用性显示第三方入口；仅第三方身份的
/// 已有账号在受限登录里取得 deletion_only 会话，走 APP-05a 的受限分流（不暂缓、不弹绑手机引导、不查手机号）。
@MainActor
final class OAuthReviewR2Tests: XCTestCase {
    private let consent: Int64 = 1_700_000_000_000

    /// 受限登录的登录页：第三方按钮按适配器显示（邀请码等业务输入由登录页隐藏，不在这里）。
    func testRestrictedLoginStillShowsAvailableProviders() {
        let harness = OAuthHarness()
        XCTAssertEqual(harness.oauth.visibleProviders(restricted: true), ["wechat", "apple"])
        harness.wechat.available = false
        XCTAssertEqual(harness.oauth.visibleProviders(restricted: true), ["apple"], "仍与适配器可用性相与")

        let config = LoginPageConfig(service: harness.service, texts: KeyTexts())
        config.restricted = true
        config.oauth = harness.oauth
        XCTAssertEqual(LoginViewModel(config: config).providers, ["apple"], "受限登录页显示 Apple 入口")
    }

    /// 仅 Apple 登录、未绑手机的已有账号从强更页进受限登录：协议校验照旧（未勾不发起）；登录得 deletion_only → 保存受限会话，
    /// 按 APP-05a 受限分流（复查受限会话），不暂缓待办、不弹引导、不查 getMe；请求体不带邀请码。
    func testExistingThirdPartyAccountRestrictedLoginGetsDeletionOnly() async throws {
        LoginStubProtocol.install { request in
            switch request.path {
            case Paths.attempts: okReply(attemptData)
            case Paths.apple: okReply(loginData(scope: Session.SessionScope.deletionOnly, isNew: false))
            case Paths.refresh: okReply(refreshData(scope: Session.SessionScope.deletionOnly))
            default: okReply()
            }
        }
        let harness = OAuthHarness()
        let refused = await harness.oauth.start(provider: OAuthProvider.apple, consentAtMillis: nil, restricted: true)
        XCTAssertEqual(refused.stateRaw, LoginOutcome.agreementRequired, "协议校验照旧")
        XCTAssertTrue(LoginStubProtocol.requests(path: Paths.attempts).isEmpty)

        let task = Task { @MainActor in
            await harness.oauth.start(provider: OAuthProvider.apple, consentAtMillis: self.consent, restricted: true)
        }
        await harness.waitAuthorizing(harness.apple)
        harness.apple.complete(.credential(.apple(identityToken: "id-token-1", authorizationCode: "auth-code-1")))
        let outcome = await task.value

        XCTAssertEqual(outcome.stateRaw, LoginOutcome.loggedIn)
        XCTAssertEqual(harness.tokens.scope, Session.SessionScope.deletionOnly, "取得 deletion_only 会话")
        let body = bodyObject(try XCTUnwrap(LoginStubProtocol.requests(path: Paths.apple).first).body)
        XCTAssertNil(body["invite_code"], "不带邀请码")
        XCTAssertTrue(Set(body.keys).isSuperset(of: ["attempt_id", "legal_versions", "consent_at"]))
        XCTAssertTrue(harness.guideSessions.isEmpty, "不弹绑手机引导")
        XCTAssertFalse(harness.router.pendingHeld, "不走第三方 full 会话的暂缓")
        XCTAssertTrue(LoginStubProtocol.requests(path: Paths.me).isEmpty, "不查手机号")
        XCTAssertEqual(harness.router.currentGuardState.session, .restricted)
    }

    /// 编排补充（鸿蒙 RC-01，共性第 31 条）：第三方老用户登录后查 getMe 挂起 → 同账号同登录世代、作用域从 full 变成 deletion_only →
    /// getMe 迟到返回 phone_bound=true：发起时的归属已失效，不记手机号状态、不释放 / 解除暂缓、不恢复待办。
    func testLatePhoneQueryAfterScopeDowngradeKeepsHold() async throws {
        LoginStubProtocol.install { request in
            switch request.path {
            case Paths.attempts: okReply(attemptData)
            case Paths.wechat: okReply(loginData(scope: Session.SessionScope.full, isNew: false))
            case Paths.me: .hold("me-old-user")
            default: okReply()
            }
        }
        let harness = OAuthHarness()
        harness.guestOpens("InviteShare")
        let task = Task { @MainActor in
            await harness.oauth.start(provider: OAuthProvider.wechat, consentAtMillis: self.consent)
        }
        await harness.waitAuthorizing(harness.wechat)
        harness.wechat.complete(.credential(.wechat(code: "code-from-sdk")))
        _ = await task.value
        await waitUntil { LoginStubProtocol.isHeld("me-old-user") }
        let generation = harness.client.sessionGeneration
        XCTAssertTrue(harness.router.pendingHeld)

        try harness.tokens.save(
            access: "at-r", refresh: "rt-r", scope: Session.SessionScope.deletionOnly, account: "u1"
        )
        XCTAssertEqual(harness.client.sessionGeneration, generation, "同一登录世代")
        XCTAssertEqual(harness.client.isolatedSessionScope, Session.SessionScope.deletionOnly)
        LoginStubProtocol.release("me-old-user", with: okReply(meData(phoneBound: true)))
        for _ in 0..<5 {
            await Task.yield()
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertNil(harness.phone.bound(generation: generation), "不记手机号状态")
        XCTAssertTrue(harness.router.pendingHeld, "不释放、不解除暂缓")
        XCTAssertTrue(harness.router.hasPendingAction, "待办保留")
        XCTAssertNotEqual(harness.router.tabRoot.route, "InviteShare")
        XCTAssertFalse(harness.routes.contains("InviteShare"))
    }
}
