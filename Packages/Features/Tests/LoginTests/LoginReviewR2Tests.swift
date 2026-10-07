import CouliNetwork
import Foundation
@testable import Login
import Router
import Session
import XCTest

/// APP-05a iOS 第 2 轮评审（ios-review-r2.md）R2-02、R2-03：真实 ApiClient（URLProtocol 本地假服务）、真实 Router、
/// 生产出口 RouterLoginHost。
@MainActor
final class LoginReviewR2Tests: XCTestCase {
    private let phone = "13800138000"
    private let code = "123456"

    // MARK: - R2-02（共性 24）

    /// 登录响应到达，ApiClient 已核对尝试仍有效、停在写令牌之前（可控同步点）→ 此时作废尝试（换号 / 取消 / 登录页出栈）：
    /// 作废与「核对 → 写入」共用同一同步区，必须等这次提交完成才生效——不能出现「作废已完成，旧登录随后又被保存」。
    /// 提交先于作废，所以会话已保存；这次尝试按已作废处理：只同步会话状态，不关页、不恢复待办。
    func testInvalidateAfterCheckBeforeWriteWaitsForCommit() async {
        LoginStubProtocol.install { _ in okReply(loginData(scope: "full")) }
        let gate = SaveGate()
        let env = LoginHarness(saveGate: gate)
        env.guestOpensOrders()
        let login = Task {
            await env.service.login(phone: phone, code: code, consentAtMillis: 1, invite: "", restricted: false)
        }
        await gate.waitEntered()

        // 主线程在这里作废；放行写入的信号稍后从别的线程发出。
        let proceed = gate.proceed
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { proceed.signal() }
        env.service.invalidateAttempt()
        gate.record("invalidated")

        let outcome = await login.value
        XCTAssertEqual(gate.events, ["saved", "invalidated"], "作废不能插在核对之后、写入之前：返回时提交已完成")
        XCTAssertEqual(outcome.stateRaw, LoginOutcome.stale)
        XCTAssertEqual(env.client.isolatedSessionScope, "full", "提交先于作废：会话已保存")
        XCTAssertFalse(env.stateChanges.contains(true), "已作废的尝试只同步会话，不恢复待办")
        XCTAssertTrue(env.router.hasPendingAction)
        XCTAssertEqual(env.routes, ["Login"], "不关页")
    }

    // MARK: - R2-03（共性 25）

    /// 账号 A 的登出请求在途 → 另一请求收到 10404，清掉 A 会话 → 用户点「订单」，Router 新建 pending_action 并进入登录
    /// （第二次登录还没完成）→ 旧登出返回（alreadyCleared）：收尾只清 A 会话归属的待办与回查，新待办保留；之后第二次
    /// 登录成功照常恢复订单入口。
    func testLogoutAlreadyClearedKeepsNewPendingAction() async throws {
        let loginReply = MutableBox<LoginStubProtocol.Reply>(.hold("login-b"))
        LoginStubProtocol.install { request in
            switch request.path {
            case Paths.logout: .hold("logout")
            case Paths.login: loginReply.value
            default: failReply(10404)
            }
        }
        let env = LoginHarness()
        try env.seedSession()
        let logout = Task { await env.service.logout() }
        await waitUntil { LoginStubProtocol.isHeld("logout") }

        let other = await env.client.send(ApiCall(operationId: "getMe"))
        guard case let .failure(code, _, _, _, effect, _) = other else { return XCTFail("\(other)") }
        XCTAssertEqual(code, 10404)
        XCTAssertEqual(effect.kind, .clearSessionLogin)
        XCTAssertNil(env.client.isolatedSessionScope, "A 会话已被清")

        env.guestOpensOrders()
        XCTAssertTrue(env.router.hasPendingAction, "新待办已建立")
        XCTAssertEqual(env.routes, ["Login"])
        let second = Task {
            await env.service.login(phone: self.phone, code: self.code, consentAtMillis: 1, invite: "",
                                    restricted: false)
        }
        await waitUntil { LoginStubProtocol.isHeld("login-b") }

        LoginStubProtocol.release("logout", with: okReply())
        let loggedOut = await logout.value
        XCTAssertTrue(loggedOut)
        XCTAssertTrue(env.router.hasPendingAction, "旧登出不删原会话被清之后新建的待办")

        // 登出开始时作废了当时的尝试；第二次登录是之后发起的新尝试，照常完成并恢复订单入口。
        LoginStubProtocol.release("login-b", with: okReply(loginData(scope: "full")))
        let outcome = await second.value
        XCTAssertEqual(outcome.stateRaw, LoginOutcome.loggedIn)
        XCTAssertEqual(env.router.tabRoot.route, "OrderList", "第二次登录后恢复订单入口")
        XCTAssertFalse(env.router.hasPendingAction)
    }
}
