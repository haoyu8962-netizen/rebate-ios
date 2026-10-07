import CouliNetwork
import Foundation
@testable import Login
import Router
import Session
import XCTest

/// 登录集成测试（任务书 §2.5；APP-05a 共性 1–12）：真实 ApiClient（URLProtocol 本地假服务）、真实 Router、
/// 生产出口 RouterLoginHost。不连任何真实地址。
@MainActor
final class LoginIntegrationTests: XCTestCase {
    private let phone = "13800138000"
    private let code = "123456"

    // MARK: - 发码

    /// §2.5 发码成功并倒计时；共性 5：倒计时按规范化号码维护，换写法、返回再点都不再发出。
    func testSendCodeStartsCountdownPerNormalizedPhone() async {
        LoginStubProtocol.install { $0.path == Paths.sms ? okReply("{\"resend_after_sec\":60,\"expires_in_sec\":300}")
            : failReply(50001)
        }
        let env = LoginHarness()
        let sent = await env.service.sendCode(phone)
        XCTAssertEqual(sent.stateRaw, SmsCountdown.stateSent)
        XCTAssertEqual(sent.countdownSec, 60)
        let body = bodyObject(LoginStubProtocol.requests(path: Paths.sms)[0].body)
        XCTAssertEqual(body["phone"] as? String, phone)
        XCTAssertEqual(body["purpose"] as? String, "login")
        env.advance(seconds: 5)
        let again = await env.service.sendCode("+86 138-0013-8000")
        XCTAssertEqual(again.stateRaw, SendCodeOutcome.countdownActive)
        XCTAssertEqual(again.countdownSec, 55)
        XCTAssertTrue(again.hasReceivedCode)
        XCTAssertEqual(LoginStubProtocol.requests(path: Paths.sms).count, 1, "倒计时内同一号码不再发码")
        env.advance(seconds: 56)
        let later = await env.service.sendCode(phone)
        XCTAssertEqual(later.stateRaw, SmsCountdown.stateSent)
        XCTAssertEqual(LoginStubProtocol.requests(path: Paths.sms).count, 2)
    }

    /// §2.5 42901 带 Retry-After：按响应头禁用发码入口，期间不再发出。
    func testSendRateLimitedUsesRetryAfter() async {
        LoginStubProtocol.install { _ in failReply(42901, headers: ["Retry-After": "120"]) }
        let env = LoginHarness()
        let limited = await env.service.sendCode(phone)
        XCTAssertEqual(limited.stateRaw, SmsCountdown.stateRateLimited)
        XCTAssertEqual(limited.countdownSec, 120)
        XCTAssertEqual(limited.textKey, "error.42901")
        XCTAssertFalse(limited.hasReceivedCode)
        env.advance(seconds: 10)
        let again = await env.service.sendCode(phone)
        XCTAssertEqual(again.stateRaw, SmsCountdown.stateRateLimited)
        XCTAssertEqual(again.countdownSec, 110)
        XCTAssertEqual(LoginStubProtocol.requests(path: Paths.sms).count, 1)
    }

    // MARK: - 登录

    /// §2.5 验证码错误、过期。
    func testWrongAndExpiredCode() async {
        let reply = MutableBox(failReply(20002))
        LoginStubProtocol.install { _ in reply.value }
        let env = LoginHarness()
        let wrong = await env.service.login(phone: phone, code: code, consentAtMillis: 1, invite: "", restricted: false)
        XCTAssertEqual(wrong.stateRaw, "code_error")
        XCTAssertEqual(wrong.textKey, "error.20002")
        reply.value = failReply(20003)
        let expired = await env.service.login(phone: phone, code: code, consentAtMillis: 1, invite: "",
                                              restricted: false)
        XCTAssertEqual(expired.stateRaw, "code_expired")
        XCTAssertEqual(expired.textKey, "error.20003")
        XCTAssertNil(env.client.isolatedSessionScope)
    }

    /// §2.5 登录成功后恢复 pending_action；请求带包内协议版本、勾选时刻与规范化的邀请码；先保存会话再关登录页、交 Router。
    func testLoginResumesPendingAction() async throws {
        LoginStubProtocol.install { _ in okReply(loginData(scope: "full", isNew: true,
                                                           invite: "{\"result\":\"bound\",\"code\":null}")) }
        let env = LoginHarness()
        env.guestOpensOrders()
        XCTAssertEqual(env.routes, ["Login"])
        XCTAssertTrue(env.router.hasPendingAction)
        let outcome = await env.service.login(phone: "+86 138 0013 8000", code: code,
                                              consentAtMillis: 1_700_000_000_000, invite: " k7m2qx ",
                                              restricted: false)
        XCTAssertEqual(outcome.stateRaw, LoginOutcome.loggedIn)
        XCTAssertEqual(outcome.actions, ["save_session", "resume_pending"])
        XCTAssertEqual(outcome.inviteResult, "bound")
        XCTAssertEqual(env.client.isolatedSessionScope, "full")
        XCTAssertEqual(env.routes, [], "登录页已关闭")
        XCTAssertEqual(env.router.tabRoot.route, "OrderList", "回到原意图")
        XCTAssertFalse(env.router.hasPendingAction)
        let body = bodyObject(try XCTUnwrap(LoginStubProtocol.requests(path: Paths.login).first).body)
        XCTAssertEqual(body["phone"] as? String, phone)
        XCTAssertEqual(body["invite_code"] as? String, "K7M2QX")
        let legal = try XCTUnwrap(body["legal_versions"] as? [String: Any])
        XCTAssertEqual(legal["privacy"] as? Int, LegalVersions.bundled.privacy)
        XCTAssertEqual(legal["agreement"] as? Int, LegalVersions.bundled.agreement)
        XCTAssertEqual(body["consent_at"] as? String, "2023-11-14T22:13:20.000Z")
    }

    /// 共性 1：取消或换号作废本次尝试后，迟到的成功响应不保存会话、不恢复待办；传输层请求随之取消。
    func testLateLoginResponseAfterInvalidateIsDropped() async {
        LoginStubProtocol.install { _ in .hold("login") }
        let env = LoginHarness()
        env.guestOpensOrders()
        let task = Task { await env.service.login(phone: phone, code: code, consentAtMillis: 1, invite: "",
                                                  restricted: false) }
        await waitUntil { LoginStubProtocol.isHeld("login") }
        env.service.invalidateAttempt()
        LoginStubProtocol.release("login", with: okReply(loginData(scope: "full")))
        let outcome = await task.value
        XCTAssertEqual(outcome.stateRaw, LoginOutcome.stale)
        XCTAssertNil(env.client.isolatedSessionScope, "迟到响应不保存会话")
        XCTAssertTrue(env.router.hasPendingAction, "待办没有被恢复或消费")
        XCTAssertEqual(env.routes, ["Login"])
        XCTAssertFalse(env.stateChanges.contains(true))
        await waitUntil { LoginStubProtocol.wasStopped("login") }
    }

    /// 共性 9：登录页一出栈（导航栈移除 Login 的同步出口，不等 onDisappear）就作废本次尝试。
    func testLoginPageRemovalInvalidatesAttempt() async {
        LoginStubProtocol.install { _ in .hold("login") }
        let env = LoginHarness()
        env.guestOpensOrders()
        let task = Task { await env.service.login(phone: phone, code: code, consentAtMillis: 1, invite: "",
                                                  restricted: false) }
        await waitUntil { LoginStubProtocol.isHeld("login") }
        env.router.path = [] // 侧滑返回 / 清栈：NavigationStack 改写 path
        LoginStubProtocol.release("login", with: okReply(loginData(scope: "full")))
        let outcome = await task.value
        XCTAssertEqual(outcome.stateRaw, LoginOutcome.stale)
        XCTAssertNil(env.client.isolatedSessionScope)
        XCTAssertTrue(env.router.hasPendingAction)
        XCTAssertNotEqual(env.router.tabRoot.route, "OrderList")
    }

    /// 共性 2：从强更页进入的受限登录成功后明确移除 Login，落回强更页；请求不带邀请码（受限登录不显示业务输入）。
    func testRestrictedLoginFromForceUpdateClosesLogin() async throws {
        LoginStubProtocol.install { _ in okReply(loginData(scope: "deletion_only")) }
        let env = LoginHarness()
        env.update.value = .below
        env.router.enterForceUpdate()
        env.router.openFromForceUpdatePage(RouteRequest(route: "Login", from: .inApp))
        XCTAssertEqual(env.routes, ["ForceUpdate", "Login"])
        XCTAssertTrue(env.router.path.last?.fromForceUpdatePage ?? false)
        let outcome = await env.service.login(phone: phone, code: code, consentAtMillis: 1, invite: "K7M2QX",
                                              restricted: true)
        XCTAssertEqual(outcome.stateRaw, LoginOutcome.loggedIn)
        XCTAssertEqual(outcome.actions, ["save_session", "enter_force_update"])
        XCTAssertEqual(env.routes, ["ForceUpdate"], "登录页已移除，停在强更页")
        XCTAssertEqual(env.client.isolatedSessionScope, "deletion_only")
        XCTAssertEqual(env.router.currentGuardState.session, .restricted)
        let body = bodyObject(try XCTUnwrap(LoginStubProtocol.requests(path: Paths.login).first).body)
        XCTAssertNil(body["invite_code"])
    }

    /// §2.5 登录拿到 deletion_only 且强更状态未知：网络层按「低于」进强更页；待办不恢复，随后由 Router 守卫丢弃。
    func testDeletionOnlyWhileUpdateUnknownEntersForceUpdate() async {
        LoginStubProtocol.install { _ in okReply(loginData(scope: "deletion_only")) }
        let env = LoginHarness()
        env.update.value = .unknown
        env.guestOpensOrders()
        let outcome = await env.service.login(phone: phone, code: code, consentAtMillis: 1, invite: "",
                                              restricted: false)
        XCTAssertEqual(env.forceUpdateHookCalls, 1)
        XCTAssertEqual(env.client.isolatedSessionScope, "deletion_only", "会话已保存")
        XCTAssertEqual(env.routes, ["ForceUpdate"])
        XCTAssertNotEqual(env.router.tabRoot.route, "OrderList", "受限会话不恢复业务待办")
        // 强更页替换导航栈即移除了登录页（共性 9）：执行器只同步会话、不恢复待办；待办由守卫按强更结论处理。
        XCTAssertTrue([LoginOutcome.stale, LoginOutcome.loggedIn].contains(outcome.stateRaw))
        XCTAssertFalse(env.stateChanges.contains(true))
        env.router.launchConditionsChanged(
            readiness: LaunchReadiness(environmentSettled: true, privacy: .consented, update: .finished(.belowMin)),
            shellReady: true, now: env.clock.value
        )
        XCTAssertFalse(env.router.hasPendingAction, "强更状态下守卫删除业务待办")
    }

    /// 共性 4：deletion_only 与 supported 并存时不删待办；显式复查后变成 full，交 Router 恢复待办。
    func testDeletionOnlyWithSupportedRechecksThenResumes() async {
        LoginStubProtocol.install { request in
            request.path == Paths.refresh ? okReply(refreshData(scope: "full"))
                : okReply(loginData(scope: "deletion_only"))
        }
        let env = LoginHarness()
        env.guestOpensOrders()
        let outcome = await env.service.login(phone: phone, code: code, consentAtMillis: 1, invite: "",
                                              restricted: false)
        XCTAssertEqual(outcome.actions, ["save_session", "refresh_restricted", "resume_pending"])
        XCTAssertEqual(LoginStubProtocol.requests(path: Paths.refresh).count, 1)
        // 共性 14：刷新成功后发出带会话世代的通知（App 核对世代后同步 Router）。
        XCTAssertEqual(env.refreshedGenerations.value, [env.client.sessionGeneration])
        XCTAssertEqual(env.refreshOrigins.value, [.other], "登录尝试的复查：通知只同步状态，待办由登录流程自己恢复（共性 19）")
        XCTAssertEqual(env.client.isolatedSessionScope, "full")
        XCTAssertEqual(env.router.tabRoot.route, "OrderList")
        XCTAssertFalse(env.router.hasPendingAction)
    }

    /// 共性 4：复查后仍受限：hold_pending——待办保留、登录页关闭、不走会恢复待办的状态同步。
    func testDeletionOnlyWithSupportedStillRestrictedHoldsPending() async {
        LoginStubProtocol.install { request in
            request.path == Paths.refresh ? okReply(refreshData(scope: "deletion_only"))
                : okReply(loginData(scope: "deletion_only"))
        }
        let env = LoginHarness()
        env.guestOpensOrders()
        let outcome = await env.service.login(phone: phone, code: code, consentAtMillis: 1, invite: "",
                                              restricted: false)
        XCTAssertEqual(outcome.stateRaw, LoginOutcome.loggedIn)
        XCTAssertEqual(outcome.actions, ["save_session", "refresh_restricted", "hold_pending"])
        XCTAssertTrue(env.router.hasPendingAction, "待办保留")
        XCTAssertEqual(env.routes, [])
        XCTAssertEqual(env.stateChanges, [false])
    }

    /// 共性 10：复查带本次尝试的 owner；取消时立即结束等待、取消刷新请求，不恢复也不消费待办。
    func testRecheckCancelledDoesNotResumePending() async {
        LoginStubProtocol.install { request in
            request.path == Paths.refresh ? .hold("refresh") : okReply(loginData(scope: "deletion_only"))
        }
        let env = LoginHarness()
        env.guestOpensOrders()
        let task = Task { await env.service.login(phone: phone, code: code, consentAtMillis: 1, invite: "",
                                                  restricted: false) }
        await waitUntil { LoginStubProtocol.isHeld("refresh") }
        env.service.invalidateAttempt()
        let outcome = await task.value
        XCTAssertEqual(outcome.stateRaw, LoginOutcome.stale)
        await waitUntil { LoginStubProtocol.wasStopped("refresh") }
        XCTAssertTrue(env.router.hasPendingAction)
        XCTAssertNotEqual(env.router.tabRoot.route, "OrderList")
        XCTAssertFalse(env.stateChanges.contains(true), "失效分支只同步会话，不允许恢复待办")
    }

    /// §2.5 注销中的账号：10007 processing → LoginDeletionProcessing，不保存会话。
    func testDeletionProcessingAccount() async {
        LoginStubProtocol.install { _ in failReply(10007, data: "{\"stage\":\"processing\"}") }
        let env = LoginHarness()
        let outcome = await env.service.login(phone: phone, code: code, consentAtMillis: 1, invite: "",
                                              restricted: false)
        XCTAssertEqual(outcome.stateRaw, "deletion_processing")
        XCTAssertEqual(outcome.textKey, "error.10007")
        XCTAssertNil(env.client.isolatedSessionScope)
    }

    /// 没有勾选时刻不发登录请求（BR-ID-04）。
    func testLoginWithoutConsentIsNotSent() async {
        LoginStubProtocol.install { _ in okReply(loginData(scope: "full")) }
        let env = LoginHarness()
        let outcome = await env.service.login(phone: phone, code: code, consentAtMillis: nil, invite: "",
                                              restricted: false)
        XCTAssertEqual(outcome.stateRaw, LoginOutcome.agreementRequired)
        XCTAssertTrue(LoginStubProtocol.requests(path: Paths.login).isEmpty)
    }

    // MARK: - 登出

    /// §2.5 登出后回到游客状态：吊销当前会话、清本机会话与 pending_action。
    func testLogoutReturnsToGuest() async throws {
        LoginStubProtocol.install { _ in okReply() }
        let env = LoginHarness()
        try env.seedSession()
        env.router.open(RouteRequest(route: "Settings", from: .inApp))
        XCTAssertEqual(env.router.currentGuardState.session, .phoneBound)
        let done = await env.service.logout()
        XCTAssertTrue(done)
        XCTAssertEqual(LoginStubProtocol.requests(path: Paths.logout).count, 1)
        XCTAssertNil(env.client.isolatedSessionScope)
        XCTAssertEqual(env.router.currentGuardState.session, .guest)
        env.guestOpensOrders()
        XCTAssertEqual(env.routes.last, "Login", "游客再点订单要先登录")
    }

    /// 共性 3：登出时会话已失效（10404 清会话）：仍完成 Router.sessionEnded，旧待办全部失效。
    func testLogoutAfterSessionClearedStillEndsSession() async throws {
        LoginStubProtocol.install { _ in failReply(10404) }
        let env = LoginHarness()
        try env.seedSession()
        _ = env.pending.save(action: Router.openRouteAction, values: ["route": .string("OrderList")],
                             now: env.pending.now)
        XCTAssertTrue(env.router.hasPendingAction)
        let done = await env.service.logout()
        XCTAssertTrue(done)
        XCTAssertNil(env.client.isolatedSessionScope)
        XCTAssertFalse(env.router.hasPendingAction, "sessionEnded 清掉旧待办")
    }
}

/// 测试用文案：直接回键名（只核对流程，不核对文字）。
@MainActor
struct KeyTexts: LoginTexts {
    func text(_ key: String) -> String {
        key
    }

    func format(_ key: String, _: [String: String]) -> String {
        key
    }
}
