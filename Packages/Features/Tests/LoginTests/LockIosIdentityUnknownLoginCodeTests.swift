import CouliNetwork
import Foundation
@testable import Login
import Session
import XCTest

/// LOCK-ios 段 2（编排 D10-1709 ③）：调用点层面——登录页发码（LoginService.sendCode，sendSmsCode purpose=login）声明
/// 「身份未知也可发」：本机存着会话但这一刻读不出时照常发码、不带 Authorization，不被 session_unreadable 拦在登录页。
@MainActor
final class LockIosIdentityUnknownLoginCodeTests: XCTestCase {
    func testLoginCodeSendsWhenStoredSessionIsUnreadable() async throws {
        LoginStubProtocol.install { $0.path == Paths.sms ? okReply("{\"resend_after_sec\":60,\"expires_in_sec\":300}")
            : failReply(50001)
        }
        let env = LoginHarness()
        try env.seedSession()
        env.tokens.failReads = .readFailed
        let sent = await env.service.sendCode("13800138000")
        XCTAssertEqual(sent.stateRaw, SmsCountdown.stateSent, "\(sent)")
        let requests = LoginStubProtocol.requests(path: Paths.sms)
        XCTAssertEqual(requests.count, 1)
        XCTAssertNil(requests.first?.headers["Authorization"], "读不出的会话不得当成有令牌")
        XCTAssertEqual(bodyObject(requests.first?.body ?? "")["purpose"] as? String, "login")
    }
}
