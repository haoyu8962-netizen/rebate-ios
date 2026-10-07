import CouliNetwork
import Foundation
@testable import Login
import Router
import Session
import XCTest

/// APP-05a iOS 第 1 轮评审 R1-03、R1-04：登录页倒计时与发码限流的显示状态（真实 LoginService + 本地假服务 + 假时钟）。
@MainActor
final class LoginReviewR1Tests: XCTestCase {
    private let phoneA = "13900000000"
    private let phoneB = "13800138000"
    private let code = "123456"

    private func makeModel(_ env: LoginHarness) -> LoginViewModel {
        LoginViewModel(config: LoginPageConfig(service: env.service, texts: KeyTexts()))
    }

    // MARK: - R1-03

    /// 发码成功进验证码页，倒计时没走完时打开协议页（页面消失、停计时）→ 超过截止时间后返回：立即按当前时钟重算，
    /// 出现重发入口；还没到截止时间就返回的，按剩余秒数显示并重启计时。
    func testReappearRecomputesSendCountdown() async {
        LoginStubProtocol.install { _ in okReply("{\"resend_after_sec\":60,\"expires_in_sec\":300}") }
        let env = LoginHarness()
        let model = makeModel(env)
        model.setPhone(phoneB)
        model.toggleAgreement()
        model.requestCode()
        await waitUntil { model.step == .code }
        XCTAssertEqual(model.resendCountdown, 60)

        // 倒计时中途打开协议页再返回：剩余秒数按当前时钟算，计时重新走起来。
        model.disappeared()
        XCTAssertNil(model.ticker)
        env.advance(seconds: 20)
        model.appeared()
        XCTAssertEqual(model.resendCountdown, 40)
        XCTAssertNotNil(model.ticker, "倒计时没走完：重启计时")

        // 再打开协议页，过了截止时间才返回：立即可重新获取。
        model.disappeared()
        env.advance(seconds: 41)
        model.appeared()
        XCTAssertEqual(model.resendCountdown, 0, "返回即按当前时钟重算，出现重发入口")
        XCTAssertFalse(model.sendRateLimited)
    }

    /// 登录收到 42901（Retry-After）后打开协议页，禁用期过后返回：登录按钮立即恢复可用。
    func testReappearRecomputesLoginRateLimit() async {
        let loginReply = MutableBox(failReply(42901, headers: ["Retry-After": "30"]))
        LoginStubProtocol.install { request in
            request.path == Paths.sms ? okReply("{\"resend_after_sec\":60,\"expires_in_sec\":300}") : loginReply.value
        }
        let env = LoginHarness()
        let model = makeModel(env)
        model.setPhone(phoneB)
        model.toggleAgreement()
        model.requestCode()
        await waitUntil { model.step == .code }
        model.setCode(code)
        model.submit()
        await waitUntil { model.loginRateLimited }
        XCTAssertFalse(model.canSubmit)

        model.disappeared()
        env.advance(seconds: 31)
        model.appeared()
        XCTAssertFalse(model.loginRateLimited, "返回即按当前时钟重算")
        XCTAssertTrue(model.canSubmit, "登录按钮恢复可用")
    }

    // MARK: - R1-04

    /// 号码 A 发码收到 42901（Retry-After 120）→ 改成没被限流的号码 B：获取验证码可用、能发出；换回 A：A 的限制仍在。
    func testSendLimitFollowsNormalizedPhone() async {
        let smsReply = MutableBox(failReply(42901, headers: ["Retry-After": "120"]))
        LoginStubProtocol.install { request in
            request.path == Paths.sms ? smsReply.value : okReply(loginData(scope: "full"))
        }
        let env = LoginHarness()
        let model = makeModel(env)
        model.setPhone(phoneA)
        model.toggleAgreement()
        model.requestCode()
        await waitUntil { model.toast != nil }
        XCTAssertTrue(model.sendRateLimited)
        XCTAssertEqual(model.resendCountdown, 120)
        XCTAssertEqual(LoginStubProtocol.requests(path: Paths.sms).count, 1)

        model.setPhone(phoneB)
        XCTAssertFalse(model.sendRateLimited, "换号：显示状态切到号码 B")
        XCTAssertEqual(model.resendCountdown, 0)
        smsReply.value = okReply("{\"resend_after_sec\":60,\"expires_in_sec\":300}")
        model.requestCode()
        await waitUntil { model.step == .code }
        XCTAssertEqual(LoginStubProtocol.requests(path: Paths.sms).count, 2, "号码 B 照常发码")
        let sentB = LoginStubProtocol.requests(path: Paths.sms).last?.body ?? ""
        XCTAssertEqual(bodyObject(sentB)["phone"] as? String, phoneB)

        model.backToPhone()
        model.setPhone("+86 139-0000-0000")
        XCTAssertTrue(model.sendRateLimited, "换回号码 A（任意写法）：旧限制仍生效")
        env.advance(seconds: 10)
        model.setPhone(phoneA)
        XCTAssertEqual(model.resendCountdown, 110)
        model.requestCode()
        XCTAssertEqual(LoginStubProtocol.requests(path: Paths.sms).count, 2, "限流期内不再发出")
    }

    // MARK: - 编排者追加（APP-05a 共性 22、23）

    /// 共性 22：号码 A 的发码请求已写出、等待响应时换成号码 B（作废并取消该请求）→ 旧请求不改当前页面；换回 A 时仍有
    /// 「继续输入验证码」入口（短信可能已发出）。
    func testCancelledWrittenSendStillAllowsCodeEntry() async {
        LoginStubProtocol.install { request in
            request.path == Paths.sms ? .hold("sms") : okReply(loginData(scope: "full"))
        }
        let env = LoginHarness()
        let model = makeModel(env)
        model.setPhone(phoneA)
        model.toggleAgreement()
        model.requestCode()
        await waitUntil { LoginStubProtocol.isHeld("sms") }

        model.setPhone(phoneB)
        await waitUntil { LoginStubProtocol.wasStopped("sms") }
        await waitUntil { !model.sending }

        XCTAssertEqual(model.step, .phone, "旧请求不改当前页面")
        XCTAssertFalse(model.canContinueCode, "号码 B 没有发过码")
        model.setPhone(phoneA)
        XCTAssertTrue(model.canContinueCode, "号码 A 的请求已写出、结果未知：可以继续输入验证码")
        model.continueCode()
        XCTAssertEqual(model.step, .code)
        XCTAssertEqual(model.resendCountdown, 0, "结果未知不计倒计时")
    }

    /// 共性 23：登出请求在途时另一次登录保存了新会话 → 登出按预期世代在锁内核对，不删新会话、不清 Router 待办。
    func testLogoutDoesNotDeleteNewerLogin() async throws {
        LoginStubProtocol.install { request in
            request.path == Paths.logout ? .hold("logout") : okReply(loginData(scope: "full"))
        }
        let env = LoginHarness()
        try env.seedSession()
        let logout = Task { await env.service.logout() }
        await waitUntil { LoginStubProtocol.isHeld("logout") }

        let login = await env.client.send(ApiCall(
            operationId: "loginBySms", body: "{\"phone\":\"\(phoneB)\",\"code\":\"\(code)\"}"
        ))
        guard case .success = login else { return XCTFail("\(login)") }
        XCTAssertEqual(env.tokens.accessToken, "at-1")
        LoginStubProtocol.release("logout", with: okReply())

        let loggedOut = await logout.value
        XCTAssertFalse(loggedOut)
        XCTAssertEqual(env.tokens.accessToken, "at-1", "新会话保留")
        XCTAssertEqual(env.client.isolatedSessionScope, "full")
    }

    /// 共性 23：ApiClient.signOut(expectedGeneration:) 的三种结果。
    func testSignOutChecksExpectedGeneration() throws {
        let env = LoginHarness()
        try env.seedSession()
        let first = env.client.sessionGeneration
        XCTAssertEqual(env.client.signOut(expectedGeneration: first &- 1), .superseded, "世代不符且有会话：不删")
        XCTAssertNotNil(env.tokens.accessToken)
        XCTAssertEqual(env.client.signOut(expectedGeneration: first), .signedOut)
        XCTAssertNil(env.tokens.accessToken)
        XCTAssertEqual(env.client.signOut(expectedGeneration: first), .alreadyCleared, "原会话已清、没有新会话")
    }
}
