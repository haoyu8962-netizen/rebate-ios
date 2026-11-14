import Foundation
@testable import Network
import Session
import XCTest

/// LOCK-ios 段 2：x-auth=optional 的接口「有令牌就带、没有就不带，不等受限会话屏障，不因会话读不出本地拒绝」；
/// 调用方置 `ApiCall.requiresSession` 时按要会话处理；x-auth=none 与要会话的接口不变（编排 D10-1658 ④、D10-1682 ⑤）。
/// 全部对 URLProtocol 本地假服务。
final class LockIosOptionalAuthTests: XCTestCase {
    static let loginCode = "{\"purpose\":\"login\"}"
    static let stepUpCode = "{\"purpose\":\"step_up\",\"action\":\"account_deletion\"}"
    static let smsPath = "/v1/auth/sms-codes"
    static let refreshPath = "/v1/auth/refresh"

    /// 本机有 full 会话、但这一刻存储读不出（readFailed：会话可能存在）。
    private func unreadableHarness() -> Harness {
        let harness = makeHarness()
        harness.tokens.failReads = .readFailed
        StubURLProtocol.install { _ in ok() }
        return harness
    }

    // MARK: - 会话读不出

    /// 1. D10-1658 ④（编排点名必钉）：会话读不出时未登录发登录码不被本地拦——sendSmsCode{purpose:login} 立即发出，
    /// 不带 Authorization（拿不到可信令牌），照常带 X-Device-Id。
    /// D10-1709：会话读不出 = 身份未知，optional 缺省本地拒；登录发码在声明名单里，调用点声明 `sendsWhenIdentityUnknown` 才照发。
    func testUnreadableSessionStillSendsLoginCodeWithoutAuthorization() async {
        let harness = unreadableHarness()
        let result = await harness.client.send(ApiCall(
            operationId: "sendSmsCode", body: Self.loginCode, sendsWhenIdentityUnknown: true
        ))
        XCTAssertTrue(result.isSuccess, "optional 接口不因会话读不出本地拒绝：\(result)")
        XCTAssertEqual(StubURLProtocol.requests.map(\.path), [Self.smsPath], "只发登录码，不先刷新")
        let sent = StubURLProtocol.requests.first
        XCTAssertNil(sent?.header("Authorization"), "读不出的会话不得当成有令牌")
        XCTAssertEqual(sent?.header("X-Device-Id"), "device-fixture")
        XCTAssertEqual(sent?.body, Self.loginCode)
    }

    /// 2. D10-1658 ④：要会话的接口不变——会话读不出时 getMe 仍 session_unreadable、零发送（R2-01）。
    func testUnreadableSessionStillRejectsLoginRequiredOperation() async {
        let harness = unreadableHarness()
        let result = await harness.client.send(ApiCall(operationId: "getMe"))
        XCTAssertEqual(result.rejectReason, LocalRejectReason.sessionUnreadable)
        XCTAssertTrue(StubURLProtocol.requests.isEmpty)
    }

    /// 3. D10-1658 ④ / D10-1682 ⑤：二次验证面板的 step_up 发码置 requiresSession，会话读不出时按要会话处理——
    /// session_unreadable、零发送。
    func testUnreadableSessionRejectsStepUpCodeThatRequiresSession() async {
        let harness = unreadableHarness()
        let result = await harness.client.send(ApiCall(
            operationId: "sendSmsCode", body: "{\"purpose\":\"step_up\",\"action\":\"withdraw\"}",
            requiresSession: true
        ))
        XCTAssertEqual(result.rejectReason, LocalRejectReason.sessionUnreadable)
        XCTAssertTrue(StubURLProtocol.requests.isEmpty)
    }

    /// 8. D10-1658 ④：ingestEvents 同为 x-auth=optional，与 sendSmsCode 同规则——会话读不出照发、不带 Authorization。
    /// D10-1709：ingestEvents 在声明名单里，调用点声明 `sendsWhenIdentityUnknown` 才照发（不声明见 LockIosIdentityUnknownTests 2'）。
    func testUnreadableSessionStillSendsEvents() async {
        let harness = unreadableHarness()
        let result = await harness.client.send(ApiCall(
            operationId: "ingestEvents", body: "{\"events\":[]}", sendsWhenIdentityUnknown: true
        ))
        XCTAssertTrue(result.isSuccess, "\(result)")
        XCTAssertEqual(StubURLProtocol.requests.map(\.path), ["/v1/events"])
        XCTAssertNil(StubURLProtocol.requests.first?.header("Authorization"))
    }

    // MARK: - 有令牌就带、没有就不带

    /// 7. D10-1658 ④：optional 接口有 full 会话时带 Authorization；没有会话时不带（照常带 X-Device-Id）。
    func testOptionalCarriesTokenOnlyWhenPresent() async {
        let signedIn = makeHarness()
        StubURLProtocol.install { _ in ok() }
        let withToken = await signedIn.client.send(ApiCall(operationId: "sendSmsCode", body: Self.loginCode))
        XCTAssertTrue(withToken.isSuccess, "\(withToken)")
        XCTAssertEqual(StubURLProtocol.requests.map(\.path), [Self.smsPath])
        XCTAssertEqual(StubURLProtocol.requests.first?.header("Authorization"), "Bearer access-1")

        let anonymous = makeHarness(tokens: MemorySessionTokens())
        StubURLProtocol.install { _ in ok() }
        let withoutToken = await anonymous.client.send(ApiCall(operationId: "sendSmsCode", body: Self.loginCode))
        XCTAssertTrue(withoutToken.isSuccess, "\(withoutToken)")
        XCTAssertEqual(StubURLProtocol.requests.map(\.path), [Self.smsPath])
        XCTAssertNil(StubURLProtocol.requests.first?.header("Authorization"))
        XCTAssertEqual(StubURLProtocol.requests.first?.header("X-Device-Id"), "device-fixture")
    }

    // MARK: - requiresSession 只对 optional 生效

    /// 9a. D10-1658 ④：会话读不出时，requiresSession 加在 x-auth=none（listArticles）上照常发出、不带 Authorization，
    /// 加在要会话的接口（getMe）上照常 session_unreadable——与不加时相同。
    func testRequiresSessionIsIgnoredOutsideOptionalWhenUnreadable() async {
        for flag in [false, true] {
            let harness = unreadableHarness()
            let none = await harness.client.send(ApiCall(operationId: "listArticles", requiresSession: flag))
            XCTAssertTrue(none.isSuccess, "requiresSession=\(flag)：\(none)")
            XCTAssertEqual(StubURLProtocol.requests.map(\.path), ["/v1/articles"], "requiresSession=\(flag)")
            XCTAssertNil(StubURLProtocol.requests.first?.header("Authorization"))
            let login = await harness.client.send(ApiCall(operationId: "getMe", requiresSession: flag))
            XCTAssertEqual(login.rejectReason, LocalRejectReason.sessionUnreadable, "requiresSession=\(flag)")
            XCTAssertEqual(StubURLProtocol.requests.count, 1, "getMe 零发送（requiresSession=\(flag)）")
        }
    }

    /// 9b. D10-1658 ④：冷启动 deletion_only、屏障到期时，requiresSession 加在 x-auth=none 上不触发屏障刷新，
    /// 加在要会话的接口上照常先刷新——两种取值发出的序列与令牌相同。
    func testRequiresSessionIsIgnoredOutsideOptionalAtBarrier() async {
        var traces: [[String]] = []
        for flag in [false, true] {
            let harness = makeHarness(tokens: restrictedSession())
            StubURLProtocol.install { request in
                request.path == Self.refreshPath
                    ? ok(refreshData(access: "access-2", scope: SessionScope.deletionOnly)) : ok()
            }
            let none = await harness.client.send(ApiCall(operationId: "listArticles", requiresSession: flag))
            XCTAssertTrue(none.isSuccess, "requiresSession=\(flag)：\(none)")
            let login = await harness.client.send(ApiCall(operationId: "getMe", requiresSession: flag))
            XCTAssertTrue(login.isSuccess, "requiresSession=\(flag)：\(login)")
            traces.append(StubURLProtocol.requests.map { "\($0.path) \($0.header("Authorization") ?? "-")" })
        }
        XCTAssertEqual(traces.first, ["/v1/articles -", "\(Self.refreshPath) -", "/v1/me Bearer access-2"])
        XCTAssertEqual(traces.first, traces.last, "requiresSession 对 none / 要会话的接口不起作用")
    }
}

/// 冷启动的 deletion_only 会话（屏障到期）。
func restrictedSession() -> MemorySessionTokens {
    MemorySessionTokens(
        access: "access-1", refresh: "refresh-1", scope: SessionScope.deletionOnly, account: "account-A"
    )
}

/// LOCK-ios 段 2：受限会话刷新屏障对 optional 接口的约束（D10-1658 ④、D10-1682 ⑤）。
final class LockIosOptionalAuthBarrierTests: XCTestCase {
    private typealias Paths = LockIosOptionalAuthTests

    /// 4. D10-1658 ④：冷启动 deletion_only、屏障到期，第一个请求是登录码——不发 refresh，只发 sms-codes，带现有令牌；
    /// 屏障仍未结算，之后的要会话请求（getDeletion）先刷新再带新令牌发。
    func testLoginCodeSkipsBarrierAndLeavesItDue() async {
        let harness = makeHarness(tokens: restrictedSession())
        StubURLProtocol.install { request in
            request.path == Paths.refreshPath
                ? ok(refreshData(access: "access-2", scope: SessionScope.deletionOnly)) : ok()
        }
        let sms = await harness.client.send(ApiCall(operationId: "sendSmsCode", body: Paths.loginCode))
        XCTAssertTrue(sms.isSuccess, "\(sms)")
        XCTAssertEqual(StubURLProtocol.requests.map(\.path), [Paths.smsPath], "optional 不由屏障触发刷新")
        XCTAssertEqual(StubURLProtocol.requests.first?.header("Authorization"), "Bearer access-1", "有令牌照常带")

        let deletion = await harness.client.send(ApiCall(operationId: "getDeletion"))
        XCTAssertTrue(deletion.isSuccess, "\(deletion)")
        XCTAssertEqual(
            StubURLProtocol.requests.map(\.path), [Paths.smsPath, Paths.refreshPath, "/v1/me/deletion"],
            "屏障没被登录码结算：要会话的请求先刷新"
        )
        XCTAssertEqual(StubURLProtocol.requests.last?.header("Authorization"), "Bearer access-2")
    }

    /// 5a. D10-1658 ④ / D10-1682 ⑤：同样条件下 sendSmsCode 置 requiresSession → 先过屏障刷新，再带新令牌发码。
    func testRequiresSessionCodeWaitsForBarrierRefresh() async {
        let harness = makeHarness(tokens: restrictedSession())
        StubURLProtocol.install { request in
            request.path == Paths.refreshPath
                ? ok(refreshData(access: "access-2", scope: SessionScope.deletionOnly)) : ok()
        }
        let sms = await harness.client.send(ApiCall(
            operationId: "sendSmsCode", body: Paths.stepUpCode, requiresSession: true
        ))
        XCTAssertTrue(sms.isSuccess, "\(sms)")
        XCTAssertEqual(StubURLProtocol.requests.map(\.path), [Paths.refreshPath, Paths.smsPath])
        XCTAssertEqual(StubURLProtocol.requests.last?.header("Authorization"), "Bearer access-2", "不带旧受限令牌")
    }

    /// 5b. D10-1658 ④ / D10-1682 ⑤：requiresSession 的发码遇屏障刷新暂时失败 → 按 transportFailure 结束、不发码、不清会话。
    func testRequiresSessionCodeEndsWithTransportFailureWhenBarrierRefreshFails() async {
        let harness = makeHarness(tokens: restrictedSession())
        StubURLProtocol.install { request in
            request.path == Paths.refreshPath ? .error(.timedOut) : ok()
        }
        let sms = await harness.client.send(ApiCall(
            operationId: "sendSmsCode", body: Paths.stepUpCode, requiresSession: true
        ))
        guard case let .transportFailure(kind, _, _, _) = sms else {
            return XCTFail("\(sms)")
        }
        XCTAssertEqual(kind, "timeout")
        XCTAssertTrue(StubURLProtocol.requests(path: Paths.smsPath).isEmpty, "不带旧受限令牌发码")
        XCTAssertEqual(harness.tokens.accessToken, "access-1", "暂时失败不清会话")
    }

    /// 6. D10-1658 ④：屏障刷新在途（refresh 停在假服务）时，并发的登录码不等它，比 refresh 响应先发出并完成；
    /// 刷新放行后，等屏障的 getDeletion 带新令牌发出。
    func testLoginCodeDoesNotWaitForInFlightBarrierRefresh() async {
        let harness = makeHarness(tokens: restrictedSession())
        let client = harness.client
        StubURLProtocol.install { request in
            request.path == Paths.refreshPath ? .hold("barrier-refresh") : ok()
        }
        let deletion = Task { await client.send(ApiCall(operationId: "getDeletion")) }
        await StubURLProtocol.waitUntilHeld("barrier-refresh")

        let smsDone = expectation(description: "登录码不等屏障刷新")
        let sms = Task { () -> ApiResult in
            let result = await client.send(ApiCall(operationId: "sendSmsCode", body: Paths.loginCode))
            smsDone.fulfill()
            return result
        }
        // 等待有上限：实现若让登录码等屏障，这里超时后仍放行 refresh，用例按失败结束而不是挂死。
        let waited = await XCTWaiter().fulfillment(of: [smsDone], timeout: 5)
        let pathsBeforeRelease = StubURLProtocol.requests.map(\.path)
        StubURLProtocol.release("barrier-refresh", with: ok(refreshData(access: "access-2")))
        let smsResult = await sms.value
        let deletionResult = await deletion.value

        XCTAssertEqual(waited, .completed, "登录码在 refresh 响应之前就已完成")
        XCTAssertEqual(pathsBeforeRelease, [Paths.refreshPath, Paths.smsPath], "refresh 还没回，登录码已发出")
        XCTAssertTrue(smsResult.isSuccess, "\(smsResult)")
        XCTAssertEqual(
            StubURLProtocol.requests(path: Paths.smsPath).first?.header("Authorization"), "Bearer access-1",
            "optional 有令牌照常带出"
        )
        XCTAssertTrue(deletionResult.isSuccess, "\(deletionResult)")
        XCTAssertEqual(StubURLProtocol.requests.last?.path, "/v1/me/deletion")
        XCTAssertEqual(StubURLProtocol.requests.last?.header("Authorization"), "Bearer access-2")
        XCTAssertEqual(StubURLProtocol.requests(path: Paths.refreshPath).count, 1, "登录码没另起刷新")
    }

    /// 10. D10-1700 ②：冷启动 deletion_only、屏障未结算时，只允许 full 的 optional 接口（getPage：契约 x-auth=optional、
    /// x-session-scopes 只有 full）不由屏障触发刷新——零 /v1/auth/refresh，按 session_scope_denied 本地拒绝、零发送；
    /// 屏障仍未结算、会话不动。
    func testFullOnlyOptionalIsScopeDeniedWithoutBarrierRefresh() async {
        let harness = makeHarness(tokens: restrictedSession())
        StubURLProtocol.install { request in
            request.path == Paths.refreshPath ? ok(refreshData(access: "access-2")) : ok()
        }
        let page = await harness.client.send(ApiCall(operationId: "getPage", pathParams: ["page_key": "home"]))
        XCTAssertEqual(page.rejectReason, LocalRejectReason.sessionScopeDenied, "\(page)")
        XCTAssertTrue(StubURLProtocol.requests(path: Paths.refreshPath).isEmpty, "optional 不由屏障触发刷新")
        XCTAssertTrue(StubURLProtocol.requests.isEmpty, "受限会话不许发 getPage：零发送")
        XCTAssertEqual(harness.tokens.accessToken, "access-1", "本地拒绝不动会话")
    }

    /// 11. D10-1700 ②：接 10——之后要会话的请求（getDeletion）过屏障刷新把会话升回 full，再发 getPage 才带新令牌发出；
    /// 网络层不替被拒的 getPage 重试，重新取数由调用方负责。
    func testFullOnlyOptionalSendsAfterBarrierRefreshRestoresFull() async {
        let harness = makeHarness(tokens: restrictedSession())
        StubURLProtocol.install { request in
            request.path == Paths.refreshPath ? ok(refreshData(access: "access-2")) : ok()
        }
        let denied = await harness.client.send(ApiCall(operationId: "getPage", pathParams: ["page_key": "home"]))
        XCTAssertEqual(denied.rejectReason, LocalRejectReason.sessionScopeDenied, "\(denied)")
        let deletion = await harness.client.send(ApiCall(operationId: "getDeletion"))
        XCTAssertTrue(deletion.isSuccess, "\(deletion)")
        XCTAssertEqual(
            StubURLProtocol.requests.map(\.path), [Paths.refreshPath, "/v1/me/deletion"], "被拒的 getPage 没有自动重发"
        )
        let page = await harness.client.send(ApiCall(operationId: "getPage", pathParams: ["page_key": "home"]))
        XCTAssertTrue(page.isSuccess, "\(page)")
        XCTAssertEqual(StubURLProtocol.requests.last?.path, "/v1/pages/home")
        XCTAssertEqual(StubURLProtocol.requests.last?.header("Authorization"), "Bearer access-2")
        XCTAssertEqual(StubURLProtocol.requests(path: Paths.refreshPath).count, 1)
    }
}
