import Foundation
import Generated
@testable import Network
import Session
import XCTest

/// ApiClient 接线测试（受限会话、强更、登录与刷新响应）：全部对 URLProtocol 本地假服务。
final class ApiClientSessionTests: XCTestCase {
    // MARK: - 受限会话

    func testRestrictedSessionOnlySendsTheRestrictedTable() async {
        let harness = makeHarness(tokens: MemorySessionTokens(
            access: "access-1", refresh: "refresh-1", scope: SessionScope.deletionOnly, account: "account-A"
        ))
        harness.state.set(update: UpdateRaw.below)
        StubURLProtocol.install { request in
            request.path == "/v1/auth/refresh"
                ? ok(refreshData(access: "access-2", scope: SessionScope.deletionOnly)) : ok()
        }
        let blocked = await harness.client.send(ApiCall(operationId: "listOrders"))
        XCTAssertEqual(blocked.rejectReason, LocalRejectReason.sessionScopeDenied)
        let deletion = await harness.client.send(ApiCall(operationId: "getDeletion"))
        XCTAssertTrue(deletion.isSuccess)
        let noBody = await harness.client.send(ApiCall(operationId: "sendSmsCode"))
        XCTAssertEqual(noBody.rejectReason, LocalRejectReason.sessionScopeDenied, "看请求体的接口没有请求体时本地拒绝")
        let sms = await harness.client.send(ApiCall(operationId: "sendSmsCode", body: "{\"purpose\":\"login\"}"))
        XCTAssertTrue(sms.isSuccess)
        XCTAssertEqual(
            StubURLProtocol.requests.map(\.path), ["/v1/auth/refresh", "/v1/me/deletion", "/v1/auth/sms-codes"],
            "冷启动屏障在强更状态下也先刷新一次（R2-03），之后受限会话只发受限表"
        )
    }

    func testColdStartRestrictedSessionRefreshesBeforeAnyTokenRequest() async {
        let harness = makeHarness(tokens: MemorySessionTokens(
            access: "access-1", refresh: "refresh-1", scope: SessionScope.deletionOnly, account: "account-A"
        ))
        StubURLProtocol.install { request in
            request.path == "/v1/auth/refresh" ? ok(refreshData(access: "access-2")) : ok()
        }
        // getMe 本身在受限表内，也要先等屏障刷新。
        let result = await harness.client.send(ApiCall(operationId: "getMe"))
        XCTAssertTrue(result.isSuccess)
        XCTAssertEqual(StubURLProtocol.requests.map(\.path), ["/v1/auth/refresh", "/v1/me"])
        XCTAssertEqual(StubURLProtocol.requests[1].header("Authorization"), "Bearer access-2")
        _ = await harness.client.send(ApiCall(operationId: "listOrders"))
        XCTAssertEqual(StubURLProtocol.requests(path: "/v1/auth/refresh").count, 1, "屏障只做一次")
    }

    /// R2-03：冷启动保存着 deletion_only 会话、版本状态为 below → 首次带令牌请求之前也先过单飞刷新屏障；
    /// 之后恢复为受支持，再按恢复触发刷新一次。
    func testRestrictedBarrierAfterUpdateBecameSupported() async {
        let harness = makeHarness(tokens: MemorySessionTokens(
            access: "access-1", refresh: "refresh-1", scope: SessionScope.deletionOnly, account: "account-A"
        ))
        harness.state.set(update: UpdateRaw.below)
        let refreshes = Box<Int>()
        StubURLProtocol.install { request in
            guard request.path == "/v1/auth/refresh" else {
                return ok()
            }
            refreshes.value = (refreshes.value ?? 0) + 1
            return refreshes.value == 1
                ? ok(refreshData(access: "access-2", scope: SessionScope.deletionOnly))
                : ok(refreshData(access: "access-3", refresh: "refresh-3"))
        }
        let first = await harness.client.send(ApiCall(operationId: "getDeletion"))
        XCTAssertTrue(first.isSuccess)
        XCTAssertEqual(StubURLProtocol.requests.map(\.path), ["/v1/auth/refresh", "/v1/me/deletion"], "冷启动 below 也先刷新")
        XCTAssertEqual(StubURLProtocol.requests[1].header("Authorization"), "Bearer access-2", "不带旧令牌发出")
        _ = await harness.client.send(ApiCall(operationId: "getDeletion"))
        XCTAssertEqual(StubURLProtocol.requests(path: "/v1/auth/refresh").count, 1, "冷启动屏障只做一次")
        harness.state.set(update: UpdateRaw.supported)
        harness.client.updateBecameSupported()
        _ = await harness.client.send(ApiCall(operationId: "getWalletSummary"))
        XCTAssertEqual(StubURLProtocol.requests(path: "/v1/auth/refresh").count, 2, "恢复为受支持后再刷新一次")
        XCTAssertEqual(StubURLProtocol.requests.last?.path, "/v1/wallet/summary")
        XCTAssertEqual(StubURLProtocol.requests.last?.header("Authorization"), "Bearer access-3")
    }

    /// R2-03：冷启动 below 下的屏障刷新被拒 → 清会话、停在强更页，原请求不发出。
    func testColdStartBarrierUnderForceUpdateFailureStaysOnForceUpdate() async {
        let harness = makeHarness(tokens: MemorySessionTokens(
            access: "access-1", refresh: "refresh-1", scope: SessionScope.deletionOnly, account: "account-A"
        ))
        harness.state.set(update: UpdateRaw.below)
        StubURLProtocol.install { request in
            request.path == "/v1/auth/refresh" ? fail(10404, status: 401) : ok()
        }
        let result = await harness.client.send(ApiCall(operationId: "getMe"))
        XCTAssertEqual(result.rejectReason, LocalRejectReason.sessionCleared)
        XCTAssertEqual(result.effect?.kind, .clearSessionStayForceUpdate)
        XCTAssertEqual(StubURLProtocol.requests.map(\.path), ["/v1/auth/refresh"], "原请求不带旧令牌发出")
        XCTAssertNil(harness.tokens.accessToken)
    }

    func testRestrictedBarrierFailureEndsCallWithLogin() async {
        let harness = makeHarness(tokens: MemorySessionTokens(
            access: "access-1", refresh: "refresh-1", scope: SessionScope.deletionOnly, account: "account-A"
        ))
        StubURLProtocol.install { request in
            request.path == "/v1/auth/refresh" ? fail(10404, status: 401) : ok()
        }
        let result = await harness.client.send(ApiCall(operationId: "getMe"))
        XCTAssertEqual(result.effect?.kind, .clearSessionLogin)
        XCTAssertEqual(StubURLProtocol.requests.map(\.path), ["/v1/auth/refresh"], "原请求不再发出")
        XCTAssertEqual(result.rejectReason, LocalRejectReason.sessionCleared)
    }

    func testRefreshOnlyFailureGuidesToLogin() async {
        let harness = makeHarness(tokens: MemorySessionTokens(
            access: "access-1", refresh: "refresh-1", scope: SessionScope.deletionOnly, account: "account-A"
        ))
        harness.state.set(update: UpdateRaw.below)
        let refreshes = Box<Int>()
        StubURLProtocol.install { request in
            guard request.path == "/v1/auth/refresh" else {
                return fail(10405, status: 403, data: "{\"min_supported_version\":\"1.2.0\"}")
            }
            refreshes.value = (refreshes.value ?? 0) + 1
            // 第一次是冷启动屏障（成功，仍受限）；第二次是 10405 refresh_only 的刷新（被拒）。
            return refreshes.value == 1
                ? ok(refreshData(access: "access-2", scope: SessionScope.deletionOnly))
                : fail(10404, status: 401)
        }
        let result = await harness.client.send(ApiCall(operationId: "getMe"))
        XCTAssertEqual(StubURLProtocol.requests.map(\.path), ["/v1/auth/refresh", "/v1/me", "/v1/auth/refresh"])
        XCTAssertEqual(result.effect?.kind, .clearSessionStayForceUpdate)
        XCTAssertTrue(harness.recorder.forceUpdateCalls.isEmpty, "受支持版本的受限令牌不进强更")
    }

    func testForceUpdateCallsUpdateAndDoesNotReplay() async {
        let harness = makeHarness()
        StubURLProtocol.install { _ in fail(10405, status: 403, data: "{\"min_supported_version\":\"1.3.0\"}") }
        let result = await harness.client.send(ApiCall(operationId: "getMe"))
        XCTAssertEqual(result.effect?.kind, .forceUpdate)
        XCTAssertEqual(harness.recorder.forceUpdateCalls, ["1.3.0"])
        XCTAssertEqual(StubURLProtocol.requests.count, 1)
    }

    // MARK: - 登录与刷新响应

    func testLoginReadsTokensFromDataTokens() async {
        let harness = makeHarness(tokens: MemorySessionTokens())
        StubURLProtocol.install { _ in ok(loginData(access: "login-access", scope: "full")) }
        let result = await harness.client.send(ApiCall(operationId: "loginBySms", body: "{\"phone\":\"13800138000\"}"))
        XCTAssertTrue(result.isSuccess)
        XCTAssertEqual(harness.tokens.accessToken, "login-access")
        XCTAssertEqual(harness.tokens.refreshToken, "refresh-2")
        XCTAssertEqual(harness.tokens.scope, "full")
        XCTAssertEqual(harness.tokens.account, contractExampleUserId)
        XCTAssertTrue(harness.recorder.forceUpdateCalls.isEmpty)
    }

    func testLoginReturningDeletionOnlyWhileUpdateUnknownEntersForceUpdate() async {
        let harness = makeHarness(tokens: MemorySessionTokens())
        harness.state.set(update: UpdateRaw.unknown)
        StubURLProtocol.install { _ in ok(loginData(access: "login-access", scope: "deletion_only")) }
        _ = await harness.client.send(ApiCall(operationId: "loginBySms", body: "{}"))
        XCTAssertEqual(harness.tokens.scope, SessionScope.deletionOnly)
        XCTAssertEqual(harness.recorder.forceUpdateCalls, [nil])
    }

    func testFlatLoginShapeIsNotAccepted() async {
        let harness = makeHarness(tokens: MemorySessionTokens())
        StubURLProtocol.install { _ in ok(refreshData(access: "flat")) }
        _ = await harness.client.send(ApiCall(operationId: "loginBySms", body: "{}"))
        XCTAssertNil(harness.tokens.accessToken, "登录令牌只在 data.tokens")
    }
}

/// openapi LoginResponse 示例里的 user_id。
private let contractExampleUserId = "0199a3b4-5c6d-7e8f-9a0b-1c2d3e4f5a61"
