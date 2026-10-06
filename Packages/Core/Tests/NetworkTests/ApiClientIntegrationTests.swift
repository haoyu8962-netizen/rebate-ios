import Foundation
import Generated
@testable import Network
import Session
import XCTest

/// ApiClient 接线测试：全部对 URLProtocol 本地假服务，不发任何真实请求、不等真实时间（退避由注入的 sleeper 记录）。
final class ApiClientIntegrationTests: XCTestCase {
    // MARK: - 单飞刷新

    func testFiveConcurrent10002ShareOneRefreshAndAllReplay() async {
        let harness = makeHarness()
        StubURLProtocol.install { request in
            if request.path == "/v1/auth/refresh" {
                return ok(refreshData(access: "access-2"))
            }
            return request.header("Authorization") == "Bearer access-2" ? ok("{\"n\":1}") : fail(10002, status: 401)
        }
        let results = await withTaskGroup(of: ApiResult.self) { group in
            for _ in 0..<5 {
                group.addTask { await harness.client.send(ApiCall(operationId: "getMe")) }
            }
            var all: [ApiResult] = []
            for await result in group {
                all.append(result)
            }
            return all
        }
        XCTAssertEqual(results.filter(\.isSuccess).count, 5)
        XCTAssertEqual(StubURLProtocol.requests(path: "/v1/auth/refresh").count, 1)
        XCTAssertEqual(harness.client.refreshCalls, 1)
        XCTAssertEqual(StubURLProtocol.requests(path: "/v1/me").filter {
            $0.header("Authorization") == "Bearer access-2"
        }.count, 5)
        XCTAssertEqual(harness.tokens.accessToken, "access-2")
        XCTAssertEqual(harness.tokens.account, "account-A", "刷新响应不带账号，沿用")
        // 刷新请求是签名请求：重新组头、带设备与签名。
        let refresh = StubURLProtocol.requests(path: "/v1/auth/refresh")[0]
        XCTAssertNotNil(refresh.header("X-Sign"))
        XCTAssertEqual(refresh.body, "{\"refresh_token\":\"refresh-1\"}")
    }

    func testLate10002WithOldTokenReusesCompletedRefresh() async {
        let harness = makeHarness()
        StubURLProtocol.install { request in
            if request.path == "/v1/auth/refresh" {
                return ok(refreshData(access: "access-2"))
            }
            return request.header("Authorization") == "Bearer access-2" ? ok() : fail(10002, status: 401)
        }
        _ = await harness.client.send(ApiCall(operationId: "getMe"))
        // 同一世代、同一旧令牌晚到的 10002：世代核对与复用在同一把锁里，直接用已换上的新令牌，不开第二次刷新。
        let outcome = await harness.client.joinRefresh(
            generation: harness.client.currentGeneration, usedToken: "access-1"
        )
        XCTAssertEqual(outcome, .refreshed("access-2"))
        XCTAssertEqual(harness.client.refreshCalls, 1)
        XCTAssertEqual(StubURLProtocol.requests(path: "/v1/auth/refresh").count, 1)
    }

    func testRefreshFailureClearsSessionOnceAndGuidesToLogin() async {
        let harness = makeHarness()
        StubURLProtocol.install { request in
            request.path == "/v1/auth/refresh" ? fail(10404, status: 401) : fail(10002, status: 401)
        }
        let results = await withTaskGroup(of: ApiResult.self) { group in
            for _ in 0..<3 {
                group.addTask { await harness.client.send(ApiCall(operationId: "getMe")) }
            }
            var all: [ApiResult] = []
            for await result in group {
                all.append(result)
            }
            return all
        }
        XCTAssertEqual(results.compactMap(\.effect?.kind), Array(repeating: .clearSessionLogin, count: 3))
        XCTAssertEqual(results.compactMap(\.effect?.route), Array(repeating: "Login", count: 3))
        XCTAssertEqual(results.compactMap(\.rejectReason), Array(repeating: "session_cleared", count: 3), "原请求不再发出")
        XCTAssertEqual(StubURLProtocol.requests(path: "/v1/auth/refresh").count, 1)
        XCTAssertNil(harness.tokens.accessToken)
    }

    func testRefreshFailureDuringForceUpdateStaysOnForceUpdate() async {
        let harness = makeHarness()
        harness.state.set(update: UpdateRaw.below)
        StubURLProtocol.install { request in
            request.path == "/v1/auth/refresh" ? fail(10404, status: 401) : fail(10002, status: 401)
        }
        let result = await harness.client.send(ApiCall(operationId: "getMe"))
        XCTAssertEqual(result.effect?.kind, .clearSessionStayForceUpdate)
        XCTAssertEqual(result.effect?.route, "ForceUpdate")
        XCTAssertNil(harness.tokens.accessToken)
    }

    func testRefreshSaveFailureStillSettlesWindow() async {
        let tokens = MemorySessionTokens(access: "access-1", refresh: "refresh-1", scope: "full", account: "account-A")
        let harness = makeHarness(tokens: tokens)
        tokens.failSaves = true
        StubURLProtocol.install { request in
            request.path == "/v1/auth/refresh" ? ok(refreshData(access: "access-2")) : fail(10002, status: 401)
        }
        let first = await harness.client.send(ApiCall(operationId: "getMe"))
        XCTAssertEqual(first.effect?.kind, .clearSessionLogin)
        XCTAssertFalse(harness.client.refreshing, "保存失败也要结算窗口")
    }

    func testLateRefreshAfterInvalidationIsDiscarded() async {
        let harness = makeHarness()
        let client = harness.client
        StubURLProtocol.install { request in
            if request.path == "/v1/auth/refresh" {
                // 刷新响应到达之前用户撤回了同意（清理入口先作废、再清令牌）。
                client.invalidateSessions()
                try? harness.tokens.clear()
                return ok(refreshData(access: "access-2"))
            }
            return fail(10002, status: 401)
        }
        let result = await client.send(ApiCall(operationId: "getMe"))
        XCTAssertNil(harness.tokens.accessToken, "迟到的刷新结果不得恢复会话")
        XCTAssertNotEqual(result.isSuccess, true)
        XCTAssertEqual(StubURLProtocol.requests(path: "/v1/me").count, 1, "作废后不再重放")
    }

    // MARK: - 超时、重试、重定向

    func testReadTimeoutRetriesOnceAfterBackoff() async {
        let harness = makeHarness()
        var calls = 0
        StubURLProtocol.install { _ in
            calls += 1
            return calls == 1 ? .error(.timedOut) : ok()
        }
        let result = await harness.client.send(ApiCall(operationId: "getMe"))
        XCTAssertTrue(result.isSuccess)
        XCTAssertEqual(StubURLProtocol.requests(path: "/v1/me").count, 2)
        XCTAssertEqual(harness.recorder.sleepCalls, [500])
        let traces = StubURLProtocol.requests.compactMap { $0.header("X-Trace-Id") }
        XCTAssertEqual(Set(traces).count, 2, "重试重新组头")
    }

    func testReadDisconnectRetriesOnlyOnce() async {
        let harness = makeHarness()
        StubURLProtocol.install { _ in .error(.networkConnectionLost) }
        let result = await harness.client.send(ApiCall(operationId: "searchProducts", query: "q=a"))
        guard case let .transportFailure(kind, _, _, _) = result else {
            return XCTFail("\(result)")
        }
        XCTAssertEqual(kind, "disconnect")
        XCTAssertEqual(StubURLProtocol.requests.count, 2)
    }

    func testReadHttp5xxWithoutEnvelopeIsNotRetried() async {
        let harness = makeHarness()
        StubURLProtocol.install { _ in .json(status: 502, headers: [:], body: "<html>bad gateway</html>") }
        let result = await harness.client.send(ApiCall(operationId: "getMe"))
        guard case let .transportFailure(kind, status, _, _) = result else {
            return XCTFail("\(result)")
        }
        XCTAssertEqual(kind, "no_envelope")
        XCTAssertEqual(status, 502)
        XCTAssertEqual(StubURLProtocol.requests.count, 1)
    }

    func testWriteTimeoutIsNotRetried() async {
        let harness = makeHarness()
        StubURLProtocol.install { _ in .error(.timedOut) }
        let result = await harness.client.send(ApiCall(
            operationId: "dismissPendingTrack",
            pathParams: ["link_id": "l1"]
        ))
        guard case let .transportFailure(kind, _, key, _) = result else {
            return XCTFail("\(result)")
        }
        XCTAssertEqual(kind, "timeout")
        XCTAssertNotNil(key)
        XCTAssertEqual(StubURLProtocol.requests.count, 1)
        XCTAssertTrue(harness.recorder.sleepCalls.isEmpty)
    }

    func testWrite503WithRetryAfterIsSentOnce() async {
        let harness = makeHarness()
        StubURLProtocol.install { _ in .json(status: 503, headers: ["Retry-After": "0"], body: "busy") }
        _ = await harness.client.send(ApiCall(operationId: "markTipRead", pathParams: ["tip_key": "t"]))
        XCTAssertEqual(StubURLProtocol.requests.count, 1)
    }

    func testRedirectIsNotFollowed() async {
        let harness = makeHarness()
        harness.state.set(privacy: PrivacyRaw.basic)
        StubURLProtocol.install { request in
            request.path == "/v1/config" ? .redirect(to: "/v1/orders") : ok()
        }
        let result = await harness.client.send(ApiCall(operationId: "getConfig"))
        XCTAssertEqual(StubURLProtocol.requests.map(\.path), ["/v1/config"], "重定向目标不得被请求")
        XCTAssertFalse(result.isSuccess)
    }

    func testInvalidationDuringBackoffCancelsRetry() async {
        let client = Box<ApiClient>()
        let harness = makeHarness(onSleep: { client.value?.invalidateSessions() })
        client.value = harness.client
        StubURLProtocol.install { _ in .error(.timedOut) }
        let result = await harness.client.send(ApiCall(operationId: "getMe"))
        XCTAssertEqual(result.rejectReason, LocalRejectReason.callCancelled)
        XCTAssertEqual(StubURLProtocol.requests.count, 1)
    }

    func testRetryRechecksPrivacyAndDropsCredentials() async {
        let state = Box<TestState>()
        let harness = makeHarness(onSleep: { state.value?.set(privacy: PrivacyRaw.basic) })
        state.value = harness.state
        var calls = 0
        StubURLProtocol.install { _ in
            calls += 1
            return calls == 1 ? .error(.timedOut) : ok()
        }
        // 白名单内的读接口：重试按新状态重新组头，不再带旧凭据。
        _ = await harness.client.send(ApiCall(operationId: "getConfig"))
        let sent = StubURLProtocol.requests
        XCTAssertEqual(sent.count, 2)
        XCTAssertNotNil(sent[0].header("Authorization"))
        XCTAssertNil(sent[1].header("Authorization"))
        XCTAssertNil(sent[1].header("X-Device-Id"))
        // 白名单外：退避期间进入基本模式后不再发出。
        state.value?.set(privacy: PrivacyRaw.full)
        calls = 0
        StubURLProtocol.install { _ in
            calls += 1
            return calls == 1 ? .error(.timedOut) : ok()
        }
        let result = await harness.client.send(ApiCall(operationId: "getMe"))
        XCTAssertEqual(result.rejectReason, LocalRejectReason.basicModeDenied)
        XCTAssertEqual(StubURLProtocol.requests.count, 1)
    }

    // MARK: - 基本模式、撤回清理、环境

    func testBasicModeStripsCredentialsAndRejectsNonAllowlistedLocally() async {
        let harness = makeHarness()
        harness.state.set(privacy: PrivacyRaw.basic)
        StubURLProtocol.install { _ in ok() }
        let allowed = await harness.client.send(ApiCall(operationId: "searchProducts", query: "q=a"))
        XCTAssertTrue(allowed.isSuccess)
        let sent = StubURLProtocol.requests[0]
        for name in ["Authorization", "X-Device-Id", "X-Sign", "X-Timestamp", "X-Nonce"] {
            XCTAssertNil(sent.header(name), name)
        }
        for name in ["X-App-Id", "X-Platform", "X-App-Version", "X-Build", "X-Channel", "X-Trace-Id"] {
            XCTAssertNotNil(sent.header(name), name)
        }
        XCTAssertEqual(sent.header("X-App-Id"), "couli")
        let denied = await harness.client.send(ApiCall(operationId: "listOrders"))
        XCTAssertEqual(denied.rejectReason, LocalRejectReason.basicModeDenied)
        XCTAssertEqual(StubURLProtocol.requests.count, 1)
    }

    func testUnfinishedWithdrawalCleanupUsesAnonymousAllowlist() async {
        let harness = makeHarness()
        harness.state.set(readable: false)
        StubURLProtocol.install { _ in ok() }
        let config = await harness.client.send(ApiCall(operationId: "getConfig"))
        XCTAssertTrue(config.isSuccess)
        XCTAssertNil(StubURLProtocol.requests[0].header("Authorization"))
        XCTAssertNil(StubURLProtocol.requests[0].header("X-Device-Id"))
        let register = await harness.client.send(ApiCall(
            operationId: "registerDevice",
            body: "{\"device_hash\":\"x\"}"
        ))
        XCTAssertEqual(register.rejectReason, LocalRejectReason.basicModeDenied)
        XCTAssertEqual(StubURLProtocol.requests.count, 1)
    }

    func testEnvironmentNotSettledSendsNothing() async {
        let harness = makeHarness()
        harness.state.set(settled: false)
        StubURLProtocol.install { _ in ok() }
        let result = await harness.client.send(ApiCall(operationId: "getConfig"))
        XCTAssertEqual(result.rejectReason, LocalRejectReason.environmentUnsettled)
        XCTAssertTrue(StubURLProtocol.requests.isEmpty)
    }

    func testSignedOperationWithoutDeviceIsDeviceNotReady() async {
        let harness = makeHarness(device: UnregisteredDevice())
        StubURLProtocol.install { _ in ok() }
        let result = await harness.client.send(ApiCall(operationId: "openLink", pathParams: ["link_id": "abc"]))
        XCTAssertEqual(result.rejectReason, LocalRejectReason.deviceNotReady)
        XCTAssertTrue(StubURLProtocol.requests.isEmpty)
    }

    // MARK: - 签名

    func testSignedRequestMatchesSharedVector() async {
        // request-sign.vectors.json 第 1 条：POST /v1/links/abc/open?src=agent。
        let harness = makeHarness()
        StubURLProtocol.install { _ in ok() }
        _ = await harness.client.send(ApiCall(
            operationId: "openLink", pathParams: ["link_id": "abc"], query: "src=agent", body: "{\"no_rebate\":false}"
        ))
        let sent = StubURLProtocol.requests[0]
        XCTAssertEqual(sent.path, "/v1/links/abc/open")
        XCTAssertEqual(sent.query, "src=agent")
        XCTAssertEqual(sent.body, "{\"no_rebate\":false}")
        XCTAssertEqual(sent.header("X-Timestamp"), "1790661600")
        XCTAssertEqual(sent.header("X-Nonce"), "b5a8f07b9dda63c3f78ed24c341d25b3")
        XCTAssertEqual(sent.header("X-Sign"), "5715b672cfc2e52a082392ba4d6997110ae6f9583dc076c6ce8b8df0bc9eeb66")
        XCTAssertEqual(sent.header("X-Device-Id"), "device-fixture")
        XCTAssertNotNil(sent.header("Idempotency-Key"))
    }

    func testInvalidSignatureWithSkewedClockResignsOnce() async {
        let harness = makeHarness()
        var calls = 0
        StubURLProtocol.install { _ in
            calls += 1
            // 服务端时间比本机快 1 小时。
            return calls == 1
                ? fail(10401, status: 401, headers: ["Date": "Tue, 29 Sep 2026 07:00:00 GMT"])
                : ok()
        }
        let result = await harness.client.send(ApiCall(
            operationId: "openLink", pathParams: ["link_id": "abc"], body: "{}"
        ))
        XCTAssertTrue(result.isSuccess)
        let sent = StubURLProtocol.requests
        XCTAssertEqual(sent.count, 2)
        XCTAssertEqual(sent[1].header("X-Timestamp"), "1790665200")
        XCTAssertNotEqual(sent[0].header("X-Sign"), sent[1].header("X-Sign"))
        XCTAssertEqual(sent[0].header("Idempotency-Key"), sent[1].header("Idempotency-Key"))
    }

    func testInvalidSignatureWithoutSkewDoesNotReplay() async {
        let harness = makeHarness()
        StubURLProtocol.install { _ in fail(10401, status: 401) }
        let result = await harness.client.send(ApiCall(operationId: "openLink", pathParams: ["link_id": "abc"]))
        XCTAssertEqual(result.effect?.kind, .toast)
        XCTAssertEqual(StubURLProtocol.requests.count, 1)
    }
}
