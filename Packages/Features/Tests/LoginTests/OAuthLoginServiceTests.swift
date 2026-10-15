import CouliNetwork
import Foundation
@testable import Login
import Router
import Session
import XCTest

/// 第三方登录执行器的集成测试（APP-05b 任务书 §2.1、§2.6；共性第 1–3、8、9、13、14 条）：真实 ApiClient + 本地假服务 + 真实 Router，
/// 只把第三方 SDK 换成可控适配器。
@MainActor
final class OAuthLoginServiceTests: XCTestCase {
    private let consent: Int64 = 1_700_000_000_000

    override func setUp() {
        super.setUp()
        LoginStubProtocol.install { request in
            switch request.path {
            case Paths.attempts: okReply(attemptData)
            case Paths.wechat, Paths.apple: okReply(loginData(scope: "full", isNew: true))
            case Paths.me: okReply(meData(phoneBound: true))
            default: okReply()
            }
        }
    }

    private func start(_ harness: OAuthHarness,
                       _ provider: String = OAuthProvider.wechat) -> Task<OAuthOutcome, Never> {
        Task { @MainActor in await harness.oauth.start(provider: provider, consentAtMillis: consent) }
    }

    /// 第三方新号：只上送 attempt_id + code + 协议版本与勾选时刻；保存会话；待办暂缓（重置计时、不执行），关登录页，弹绑手机引导；守卫按
    /// 「已登录未绑手机」；【暂不】只恢复（OrderList 只需登录 → 打开）。
    func testWechatNewUserHoldsPendingAndPresentsGuide() async throws {
        let harness = OAuthHarness()
        harness.guestOpens("OrderList")
        XCTAssertEqual(harness.routes, ["Login"])
        let task = start(harness)
        await harness.waitAuthorizing(harness.wechat)
        XCTAssertEqual(harness.wechat.nonces, ["nonce-for-test-0001"], "nonce 原样交给 SDK")
        let created = bodyObject(try XCTUnwrap(LoginStubProtocol.requests(path: Paths.attempts).first).body)
        XCTAssertEqual(created["provider"] as? String, "wechat")
        XCTAssertEqual(created["purpose"] as? String, "login")
        harness.wechat.complete(.credential(.wechat(code: "code-from-sdk")))
        let outcome = await task.value

        XCTAssertEqual(outcome.stateRaw, LoginOutcome.loggedIn)
        XCTAssertEqual(outcome.route, OAuthLoginRoute.bindPhoneGuide)
        let body = bodyObject(try XCTUnwrap(LoginStubProtocol.requests(path: Paths.wechat).first).body)
        XCTAssertEqual(Set(body.keys), ["attempt_id", "code", "legal_versions", "consent_at"], "只上送规定字段")
        XCTAssertEqual(body["attempt_id"] as? String, "att-1")
        XCTAssertEqual(body["code"] as? String, "code-from-sdk")
        XCTAssertEqual(harness.tokens.scope, Session.SessionScope.full)
        XCTAssertEqual(harness.guideSessions, [harness.client.sessionGeneration])
        XCTAssertEqual(harness.routes, [], "登录页已关闭")
        XCTAssertTrue(harness.router.pendingHeld, "待办暂缓")
        XCTAssertTrue(harness.router.hasPendingAction)
        XCTAssertNotEqual(harness.router.tabRoot.route, "OrderList")
        XCTAssertEqual(harness.router.currentGuardState.session, .loggedIn, "新号记未绑手机")
        XCTAssertEqual(harness.oauth.submittedCount, 1)

        harness.router.releasePendingHold(.resumeOnly, session: harness.client.sessionGeneration)
        XCTAssertEqual(harness.router.tabRoot.route, "OrderList", "只需登录的待办照常打开")
        XCTAssertFalse(harness.router.hasPendingAction)
    }

    /// 暂缓是持续状态（共性第 9 条）：引导期间的启动协调、会话同步都只保留记录。
    func testHoldSurvivesLaunchCoordination() async {
        let harness = OAuthHarness()
        harness.guestOpens("OrderList")
        let task = start(harness)
        await harness.waitAuthorizing(harness.wechat)
        harness.wechat.complete(.credential(.wechat(code: "code-from-sdk")))
        _ = await task.value
        for _ in 0..<3 {
            harness.router.launchConditionsChanged(
                readiness: LaunchReadiness(environmentSettled: true, privacy: .consented, update: .finished(.ok)),
                shellReady: true, now: harness.clock.value
            )
            harness.router.resumePending()
        }
        XCTAssertTrue(harness.router.hasPendingAction, "引导结束前不执行")
        XCTAssertNotEqual(harness.router.tabRoot.route, "OrderList")
    }

    /// 第三方老用户（Apple）：手机号状态未知不当已绑——先查 getMe，查清已绑后经 Router 守卫恢复需要手机号的待办（InviteShare）。
    func testAppleExistingUserChecksPhoneBeforeResumingPhonePending() async throws {
        LoginStubProtocol.install { request in
            switch request.path {
            case Paths.attempts: okReply(attemptData)
            case Paths.apple: okReply(loginData(scope: "full", isNew: false))
            case Paths.me: .hold("me")
            default: okReply()
            }
        }
        let harness = OAuthHarness()
        harness.guestOpens("InviteShare")
        let task = start(harness, OAuthProvider.apple)
        await harness.waitAuthorizing(harness.apple)
        harness.apple.complete(.credential(.apple(identityToken: "id-token-1", authorizationCode: "auth-code-1")))
        let outcome = await task.value
        XCTAssertEqual(outcome.route, OAuthLoginRoute.done)
        let body = bodyObject(try XCTUnwrap(LoginStubProtocol.requests(path: Paths.apple).first).body)
        XCTAssertEqual(
            Set(body.keys),
            ["attempt_id", "identity_token", "authorization_code", "legal_versions", "consent_at"]
        )
        await waitUntil { LoginStubProtocol.isHeld("me") }
        XCTAssertTrue(harness.guideSessions.isEmpty, "老用户不弹引导")
        XCTAssertTrue(harness.router.hasPendingAction, "getMe 回来之前不恢复")
        XCTAssertEqual(harness.router.currentGuardState.session, .loggedIn, "未知按未绑手机")

        LoginStubProtocol.release("me", with: okReply(meData(phoneBound: true)))
        await waitUntil { !harness.router.hasPendingAction }
        XCTAssertEqual(harness.router.currentGuardState.session, .phoneBound)
        XCTAssertEqual(harness.routes.last.flatMap(\.self), "InviteShare", "查清已绑后经守卫恢复")
    }

    /// 共性第 14 条：老用户 getMe 失败 → 解除暂缓，登录级待办正常恢复；手机号级待办按未验证保留（不自动拉起绑手机页）。
    func testExistingUserGetMeFailureResumesLoginLevelOnly() async {
        for (route, opens) in [("OrderList", true), ("InviteShare", false)] {
            LoginStubProtocol.install { request in
                switch request.path {
                case Paths.attempts: okReply(attemptData)
                case Paths.wechat: okReply(loginData(scope: "full", isNew: false))
                case Paths.me: failReply(50001)
                default: okReply()
                }
            }
            let harness = OAuthHarness()
            harness.guestOpens(route)
            let task = start(harness)
            await harness.waitAuthorizing(harness.wechat)
            harness.wechat.complete(.credential(.wechat(code: "code-from-sdk")))
            _ = await task.value
            await waitUntil { !harness.router.pendingHeld }
            if opens {
                XCTAssertEqual(harness.router.tabRoot.route, "OrderList", route)
                XCTAssertFalse(harness.router.hasPendingAction, route)
            } else {
                XCTAssertTrue(harness.router.hasPendingAction, "\(route)：保留待办")
                XCTAssertFalse(harness.routes.contains("BindPhone"), "\(route)：不自动拉起绑手机页")
                XCTAssertNil(harness.phone.bound(generation: harness.client.sessionGeneration), "仍按未知")
            }
        }
    }

    /// 用户在授权界面取消：attempt 终止，不发登录请求，静默。
    func testUserCancelSendsNoLogin() async {
        let harness = OAuthHarness()
        let task = start(harness)
        await harness.waitAuthorizing(harness.wechat)
        harness.wechat.complete(.cancelled)
        let outcome = await task.value
        XCTAssertEqual(outcome.stateRaw, OAuthOutcome.cancelled)
        XCTAssertTrue(LoginStubProtocol.requests(path: Paths.wechat).isEmpty)
        XCTAssertNil(harness.tokens.scope)
    }

    /// 离开登录页（同步出口）：等待立即结束，第三方界面收起；之后才到的凭证记为丢弃，不提交、不保存。
    func testLateCallbackAfterLeaveIsDropped() async {
        let harness = OAuthHarness()
        harness.guestOpens("OrderList")
        let task = start(harness)
        await harness.waitAuthorizing(harness.wechat)
        harness.router.removeRoute(RoutePolicy.login)
        let outcome = await task.value
        XCTAssertEqual(outcome.stateRaw, LoginOutcome.stale)
        XCTAssertEqual(harness.wechat.aborts, 1, "第三方界面收起")
        harness.wechat.complete(.credential(.wechat(code: "late-code")))
        await waitUntil { !harness.oauth.dropped.isEmpty }
        XCTAssertEqual(harness.oauth.dropped.count, 1)
        XCTAssertEqual(harness.oauth.submittedCount, 0)
        XCTAssertTrue(LoginStubProtocol.requests(path: Paths.wechat).isEmpty)
        XCTAssertNil(harness.tokens.scope)
    }

    /// 超时：attempt 按 timeout 终止，提示重新授权；迟到回调丢弃。
    func testTimeoutTerminatesAttempt() async {
        let harness = OAuthHarness()
        harness.oauth.timeoutMillis = 50
        let task = start(harness)
        await harness.waitAuthorizing(harness.wechat)
        let outcome = await task.value
        XCTAssertEqual(outcome.stateRaw, OAuthLoginErrorAction.reauthorize)
        XCTAssertEqual(outcome.textKey, "error.20004")
        harness.wechat.complete(.credential(.wechat(code: "late-code")))
        await waitUntil { harness.oauth.dropped.count == 1 }
        XCTAssertTrue(LoginStubProtocol.requests(path: Paths.wechat).isEmpty)
    }

    /// 共性第 1 条（H-R1-01）：授权等待期间别处保存了另一账号会话 → 整个 attempt 终止，不发登录请求，另一账号的会话不被覆盖。
    func testAnotherSessionSavedDuringAuthorizationAborts() async throws {
        let harness = OAuthHarness()
        let task = start(harness)
        await harness.waitAuthorizing(harness.wechat)
        try harness.seedSession(account: "other")
        harness.wechat.complete(.credential(.wechat(code: "code-from-sdk")))
        let outcome = await task.value
        XCTAssertEqual(outcome.stateRaw, LoginOutcome.stale)
        XCTAssertTrue(LoginStubProtocol.requests(path: Paths.wechat).isEmpty, "不发登录请求")
        XCTAssertEqual(harness.tokens.account, "other")
    }

    /// 登录请求在途时另一会话保存：响应到达时世代已变，不保存（不覆盖另一账号），按迟到处理。
    func testSessionChangedWhileLoginInFlightNotSaved() async throws {
        LoginStubProtocol.install { request in
            switch request.path {
            case Paths.attempts: okReply(attemptData)
            case Paths.wechat: .hold("login")
            default: okReply()
            }
        }
        let harness = OAuthHarness()
        let task = start(harness)
        await harness.waitAuthorizing(harness.wechat)
        harness.wechat.complete(.credential(.wechat(code: "code-from-sdk")))
        await waitUntil { LoginStubProtocol.isHeld("login") }
        try harness.seedSession(account: "other")
        LoginStubProtocol.release("login", with: okReply(loginData(scope: "full", isNew: true)))
        let outcome = await task.value
        XCTAssertEqual(outcome.stateRaw, LoginOutcome.stale)
        XCTAssertEqual(harness.tokens.account, "other")
        XCTAssertTrue(harness.guideSessions.isEmpty)
    }

    /// 未勾选协议不能发起（BR-ID-04）：不取授权尝试、不拉起 SDK。
    func testAgreementRequiredWithoutConsent() async {
        let harness = OAuthHarness()
        let outcome = await harness.oauth.start(provider: OAuthProvider.wechat, consentAtMillis: nil)
        XCTAssertEqual(outcome.stateRaw, LoginOutcome.agreementRequired)
        XCTAssertTrue(LoginStubProtocol.requests(path: Paths.attempts).isEmpty)
        XCTAssertTrue(harness.wechat.nonces.isEmpty)
    }

    /// 错误码：20004 重新授权、50305 保留其他方式、44001 风控、42901 按 Retry-After 禁用该方式；都不自动重试。
    func testLoginErrorsMapToActions() async {
        let cases: [ErrorCase] = [
            ErrorCase(code: 20004, action: OAuthLoginErrorAction.reauthorize),
            ErrorCase(code: 50305, action: OAuthLoginErrorAction.providerUnavailable),
            ErrorCase(code: 44001, action: OAuthLoginErrorAction.riskBlocked),
            ErrorCase(code: 42901, headers: ["Retry-After": "30"], action: OAuthLoginErrorAction.retryAfter),
            ErrorCase(code: 50001, action: OAuthLoginErrorAction.serviceError),
        ]
        for item in cases {
            let (code, headers, action) = (item.code, item.headers, item.action)
            LoginStubProtocol.install { request in
                switch request.path {
                case Paths.attempts: okReply(attemptData)
                case Paths.wechat: failReply(code, headers: headers)
                default: okReply()
                }
            }
            let harness = OAuthHarness()
            let task = start(harness)
            await harness.waitAuthorizing(harness.wechat)
            harness.wechat.complete(.credential(.wechat(code: "code-from-sdk")))
            let outcome = await task.value
            XCTAssertEqual(outcome.stateRaw, action, "\(code)")
            XCTAssertEqual(LoginStubProtocol.requests(path: Paths.wechat).count, 1, "\(code)：不自动重试")
            XCTAssertNil(harness.tokens.scope, "\(code)")
            if code == 42901 {
                XCTAssertTrue(harness.oauth.rateLimited(OAuthProvider.wechat, now: harness.clock.value))
                let again = await harness.oauth.start(provider: OAuthProvider.wechat, consentAtMillis: consent)
                XCTAssertEqual(again.stateRaw, OAuthOutcome.rateLimited)
                XCTAssertEqual(LoginStubProtocol.requests(path: Paths.attempts).count, 1, "禁用期内不再取尝试")
            }
            if code == 50001 {
                XCTAssertEqual(outcome.trace6, "a1b2c3")
            }
        }
    }

    /// 按钮：正式微信适配器恒不可用 → 不显示；未知安装状态照常显示（再与可用性相与）；受限登录同样按适配器显示（第 2 轮 R2-01 改）。
    func testVisibleProviders() {
        let harness = OAuthHarness()
        XCTAssertEqual(harness.oauth.visibleProviders(restricted: false), ["wechat", "apple"])
        harness.wechat.installed = nil
        XCTAssertEqual(harness.oauth.visibleProviders(restricted: false), ["wechat", "apple"], "未知照常显示")
        harness.wechat.installed = false
        XCTAssertEqual(harness.oauth.visibleProviders(restricted: false), ["apple"])
        XCTAssertEqual(harness.oauth.visibleProviders(restricted: true), ["apple"], "受限登录照样显示（R2-01）")
        harness.oauth.authorizers = [
            OAuthProvider.wechat: UnavailableWechatAuthorizer(),
            OAuthProvider.apple: AppleSignInAuthorizer(enabled: false),
        ]
        XCTAssertEqual(harness.oauth.visibleProviders(restricted: false), [], "正式适配器：都不显示")
    }

    /// 凭证不进日志：脱敏描述里没有凭证本身。
    func testCredentialRedacted() {
        let credential = OAuthCredential.apple(identityToken: "id-token-1", authorizationCode: "auth-code-1")
        XCTAssertFalse(credential.redacted.contains("id-token-1"))
        XCTAssertFalse(credential.redacted.contains("auth-code-1"))
        XCTAssertFalse(OAuthCredential.wechat(code: "code-x").redacted.contains("code-x"))
    }
}

private struct ErrorCase {
    let code: Int
    var headers: [String: String] = [:]
    let action: String
}
