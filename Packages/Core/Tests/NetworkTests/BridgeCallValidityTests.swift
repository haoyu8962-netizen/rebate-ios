import Foundation
@testable import Network
import Session
import XCTest

/// APP-04 三端共性第 22 条：桥发出的请求带上调用有效性；页面关闭或导航后（有效性为假）不再发出，等待结束、重试前都要再查。
final class BridgeCallValidityTests: XCTestCase {
    func testInvalidCallIsNeverSent() async {
        let harness = makeHarness()
        StubURLProtocol.install { _ in ok() }
        let result = await harness.client.send(ApiCall(operationId: "getMe"), isValid: { false })
        XCTAssertEqual(result.rejectReason, LocalRejectReason.callCancelled)
        XCTAssertTrue(StubURLProtocol.requests.isEmpty, "调用已失效：一个请求都不发")
    }

    /// 读接口超时退避期间页面关闭：等待结束后不再重试。
    @MainActor
    func testValidityRevokedDuringBackoffStopsRetry() async {
        let entered = expectation(description: "backoff")
        let gate = AsyncGate()
        let harness = makeHarness(asyncSleep: {
            entered.fulfill()
            await gate.wait()
        })
        StubURLProtocol.install { _ in .error(.timedOut) }
        let valid = Box<Bool>()
        valid.value = true
        let client = harness.client
        let task = Task { await client.send(ApiCall(operationId: "getMe"), isValid: { valid.value ?? false }) }
        await fulfillment(of: [entered], timeout: 5)
        valid.value = false
        await gate.open()
        let result = await task.value
        XCTAssertEqual(result.rejectReason, LocalRejectReason.callCancelled)
        XCTAssertEqual(StubURLProtocol.requests.count, 1, "失效后不重试")
    }

    func testValidCallIsSentNormally() async {
        let harness = makeHarness()
        StubURLProtocol.install { _ in ok() }
        let result = await harness.client.send(ApiCall(operationId: "getMe"), isValid: { true })
        XCTAssertTrue(result.isSuccess)
        XCTAssertEqual(StubURLProtocol.requests.count, 1)
    }

    // MARK: - 迟到响应不启动恢复链（第 1 轮评审 R1-05，三端共性第 30 条）

    /// 原场景：auth.getUser 已发出，页面关闭使调用失效，随后收到 10002 → 不得发出 POST /v1/auth/refresh，也不重放。
    func testLate10002AfterRevokeStartsNoRefresh() async {
        let harness = makeHarness()
        let valid = Box<Bool>()
        valid.value = true
        StubURLProtocol.install { request in
            guard request.path == "/v1/me" else {
                return ok(refreshData(access: "access-2"))
            }
            // 请求已在服务端；响应回来之前页面关闭。
            valid.value = false
            return fail(10002, status: 401)
        }
        let result = await harness.client.send(ApiCall(operationId: "getMe"), isValid: { valid.value ?? false })
        XCTAssertEqual(result.rejectReason, LocalRejectReason.callCancelled)
        XCTAssertEqual(StubURLProtocol.requests(path: "/v1/auth/refresh").count, 0, "失效调用不得启动刷新")
        XCTAssertEqual(harness.client.refreshCalls, 0)
        XCTAssertEqual(StubURLProtocol.requests(path: "/v1/me").count, 1, "不重放")
        XCTAssertEqual(harness.tokens.accessToken, "access-1", "会话不动")
    }

    /// 对照：仍有效的调用收到 10002 照常刷新并重放（证明上面那条拦下的是失效检查，不是别的原因）。
    func testValid10002StillRefreshesAndReplays() async {
        let harness = makeHarness()
        StubURLProtocol.install { request in
            switch request.path {
            case "/v1/auth/refresh":
                return ok(refreshData(access: "access-2"))
            default:
                if request.header("Authorization") == "Bearer access-2" {
                    return ok()
                }
                return fail(10002, status: 401)
            }
        }
        let result = await harness.client.send(ApiCall(operationId: "getMe"), isValid: { true })
        XCTAssertTrue(result.isSuccess)
        XCTAssertEqual(StubURLProtocol.requests(path: "/v1/auth/refresh").count, 1)
        XCTAssertEqual(StubURLProtocol.requests(path: "/v1/me").count, 2)
    }

    /// 失效调用收到 10402：不重新注册设备、不重放；有效调用照常重新注册（对照）。
    func testLate10402AfterRevokeDoesNotReRegister() async {
        let registrations = Box<Int>()
        registrations.value = 0
        let client = makeClient(reRegister: {
            registrations.value = (registrations.value ?? 0) + 1
            return true
        })
        let valid = Box<Bool>()
        valid.value = true
        StubURLProtocol.install { _ in
            valid.value = false
            return fail(10402, status: 401)
        }
        let result = await client.send(ApiCall(operationId: "getMe"), isValid: { valid.value ?? false })
        XCTAssertEqual(result.rejectReason, LocalRejectReason.callCancelled)
        XCTAssertEqual(registrations.value, 0, "失效调用不得重新注册")
        XCTAssertEqual(StubURLProtocol.requests.count, 1)

        var replied = false
        StubURLProtocol.install { _ in
            defer { replied = true }
            return replied ? ok() : fail(10402, status: 401)
        }
        let control = await client.send(ApiCall(operationId: "getMe"), isValid: { true })
        XCTAssertTrue(control.isSuccess)
        XCTAssertEqual(registrations.value, 1)
    }

    /// 失效调用收到 10401（带可校时的 Date）：不校时、不重签再发。
    func testLate10401AfterRevokeDoesNotResign() async {
        let harness = makeHarness()
        let valid = Box<Bool>()
        valid.value = true
        StubURLProtocol.install { _ in
            valid.value = false
            return fail(10401, status: 401, headers: ["Date": "Tue, 29 Sep 2026 07:00:00 GMT"])
        }
        let result = await harness.client.send(ApiCall(operationId: "getMe"), isValid: { valid.value ?? false })
        XCTAssertEqual(result.rejectReason, LocalRejectReason.callCancelled)
        XCTAssertEqual(StubURLProtocol.requests.count, 1, "不重签再发")
        XCTAssertEqual(harness.client.clockOffsetMillis, 0, "不校时")
    }

    /// 共享刷新窗口：A、B 都收到 10002 并入同一次刷新；刷新期间 B 失效 → 只刷新一次，A 重放成功，B 不重放。
    func testSharedRefreshContinuesOnlyForValidCallers() async {
        let harness = makeHarness()
        let meCount = Box<Int>()
        meCount.value = 0
        StubURLProtocol.install { request in
            switch request.path {
            case "/v1/auth/refresh":
                return .hold("shared-refresh")
            default:
                meCount.value = (meCount.value ?? 0) + 1
                return request.header("Authorization") == "Bearer access-2" ? ok() : fail(10002, status: 401)
            }
        }
        let client = harness.client
        let validB = Box<Bool>()
        validB.value = true
        let first = Task { await client.send(ApiCall(operationId: "getMe"), isValid: { true }) }
        await StubURLProtocol.waitUntilHeld("shared-refresh")
        let second = Task { await client.send(ApiCall(operationId: "getMe"), isValid: { validB.value ?? false }) }
        // 等 B 的 10002 也到达并入窗口。
        for _ in 0..<200 where (meCount.value ?? 0) < 2 {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        try? await Task.sleep(nanoseconds: 200_000_000)
        validB.value = false
        StubURLProtocol.release("shared-refresh", with: ok(refreshData(access: "access-2")))
        let resultA = await first.value
        let resultB = await second.value
        XCTAssertTrue(resultA.isSuccess, "仍有效的调用方照常重放")
        XCTAssertEqual(resultB.rejectReason, LocalRejectReason.callCancelled)
        XCTAssertEqual(StubURLProtocol.requests(path: "/v1/auth/refresh").count, 1, "只刷新一次")
        XCTAssertEqual(StubURLProtocol.requests(path: "/v1/me").count, 3, "A 原请求 + B 原请求 + A 重放")
    }

    // MARK: - 共享刷新窗口登记有效调用方（第 2 轮评审 R2-02，三端共性第 41 条）

    private static let skewedDate = ["Date": "Tue, 29 Sep 2026 07:00:00 GMT"]

    /// 只有一个调用方 A 的 getMe 收到 10002，刷新请求在途时 A 失效。返回 A 的结果。
    private func runRefreshWhileOnlyCallerInvalidates(
        _ client: ApiClient,
        refreshReply: StubURLProtocol.Reply
    ) async -> ApiResult {
        StubURLProtocol.install { request in
            request.path == "/v1/auth/refresh" ? .hold("lonely-refresh") : fail(10002, status: 401)
        }
        let valid = Box<Bool>()
        valid.value = true
        let call = Task { await client.send(ApiCall(operationId: "getMe"), isValid: { valid.value ?? false }) }
        await StubURLProtocol.waitUntilHeld("lonely-refresh")
        // 刷新已发出、响应未到：页面关闭，唯一的调用方失效。
        valid.value = false
        StubURLProtocol.release("lonely-refresh", with: refreshReply)
        return await call.value
    }

    /// 原场景之一：刷新响应 10401（带可校时的 Date）→ 窗口里已没有有效调用方，不校时、不重签再发刷新。
    func testRefreshDoesNotResignAfterAllCallersInvalidate() async {
        let harness = makeHarness()
        let result = await runRefreshWhileOnlyCallerInvalidates(
            harness.client, refreshReply: fail(10401, status: 401, headers: Self.skewedDate)
        )
        XCTAssertEqual(result.rejectReason, LocalRejectReason.callCancelled)
        XCTAssertEqual(StubURLProtocol.requests(path: "/v1/auth/refresh").count, 1, "不再续发刷新")
        XCTAssertEqual(harness.client.clockOffsetMillis, 0, "不校时")
        XCTAssertEqual(StubURLProtocol.requests(path: "/v1/me").count, 1, "不重放")
        XCTAssertEqual(harness.tokens.accessToken, "access-1", "会话不动")
        XCTAssertFalse(harness.recorder.effectCalls.contains { $0.kind == .clearSessionLogin }, "不清会话")
    }

    /// 原场景之二：刷新响应 10402 → 窗口里已没有有效调用方，不重新注册设备、不重放刷新。
    func testRefreshDoesNotReRegisterAfterAllCallersInvalidate() async {
        let registrations = Box<Int>()
        registrations.value = 0
        let client = makeClient(reRegister: {
            registrations.value = (registrations.value ?? 0) + 1
            return true
        })
        let result = await runRefreshWhileOnlyCallerInvalidates(client, refreshReply: fail(10402, status: 401))
        XCTAssertEqual(result.rejectReason, LocalRejectReason.callCancelled)
        XCTAssertEqual(registrations.value, 0, "没有有效调用方：不重新注册")
        XCTAssertEqual(StubURLProtocol.requests(path: "/v1/auth/refresh").count, 1)
        XCTAssertEqual(StubURLProtocol.requests(path: "/v1/me").count, 1)
    }

    /// 对照：A、B 并入同一窗口，刷新期间只有 B 失效 → 刷新照常校时重签、A 重放成功，B 不重放。
    func testRefreshResignsWhileAnotherCallerIsStillValid() async {
        let harness = makeHarness()
        let meCount = Box<Int>()
        meCount.value = 0
        let refreshes = Box<Int>()
        refreshes.value = 0
        StubURLProtocol.install { request in
            switch request.path {
            case "/v1/auth/refresh":
                refreshes.value = (refreshes.value ?? 0) + 1
                return refreshes.value == 1 ? .hold("shared-skew") : ok(refreshData(access: "access-2"))
            default:
                meCount.value = (meCount.value ?? 0) + 1
                return request.header("Authorization") == "Bearer access-2" ? ok() : fail(10002, status: 401)
            }
        }
        let client = harness.client
        let validB = Box<Bool>()
        validB.value = true
        let first = Task { await client.send(ApiCall(operationId: "getMe"), isValid: { true }) }
        await StubURLProtocol.waitUntilHeld("shared-skew")
        let second = Task { await client.send(ApiCall(operationId: "getMe"), isValid: { validB.value ?? false }) }
        for _ in 0..<200 where (meCount.value ?? 0) < 2 {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        try? await Task.sleep(nanoseconds: 200_000_000)
        validB.value = false
        StubURLProtocol.release("shared-skew", with: fail(10401, status: 401, headers: Self.skewedDate))
        let resultA = await first.value
        let resultB = await second.value
        XCTAssertTrue(resultA.isSuccess, "仍有有效调用方：照常校时重签并恢复")
        XCTAssertEqual(resultB.rejectReason, LocalRejectReason.callCancelled)
        XCTAssertEqual(StubURLProtocol.requests(path: "/v1/auth/refresh").count, 2, "校时重签 1 次")
        XCTAssertEqual(harness.client.refreshCalls, 1, "仍是同一个刷新窗口")
        XCTAssertEqual(harness.tokens.accessToken, "access-2")
    }

    // MARK: - 截止时间取消网络请求（第 3 轮，三端共性第 45 条）

    /// 桥调用到截止时间（BridgeHost 结算并取消执行它的 Task）：在途的 HTTP 请求随之取消，不等它自己超时，也不重试。
    func testCancellingBridgeCallTaskCancelsInFlightRequest() async {
        let harness = makeHarness()
        StubURLProtocol.install { _ in .hold("deadline-me") }
        let client = harness.client
        let call = Task { await client.send(ApiCall(operationId: "getMe"), isValid: { true }) }
        await StubURLProtocol.waitUntilHeld("deadline-me")
        call.cancel()
        let result = await call.value
        for _ in 0..<100 where !StubURLProtocol.wasStopped("deadline-me") {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertTrue(StubURLProtocol.wasStopped("deadline-me"), "在途请求已取消")
        XCTAssertFalse(result.isSuccess)
        XCTAssertEqual(StubURLProtocol.requests.count, 1, "不重试")
    }

    /// 对照：原生请求（没有调用有效性）不随 Task 取消而中断，行为与 APP-03a 相同。
    func testCancellingNativeTaskDoesNotCancelRequest() async {
        let harness = makeHarness()
        StubURLProtocol.install { _ in .hold("native-me") }
        let client = harness.client
        let call = Task { await client.send(ApiCall(operationId: "getMe")) }
        await StubURLProtocol.waitUntilHeld("native-me")
        call.cancel()
        try? await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertFalse(StubURLProtocol.wasStopped("native-me"))
        StubURLProtocol.release("native-me", with: ok())
        let result = await call.value
        XCTAssertTrue(result.isSuccess)
    }

    // MARK: - 到期取消共享刷新（第 3 轮评审 R3-01，三端共性第 54 条）

    /// 桥调用到期：BridgeHost 先撤销有效性、再取消执行它的 Task。
    private func expire(_ valid: Box<Bool>, _ call: Task<ApiResult, Never>) {
        valid.value = false
        call.cancel()
    }

    /// 唯一的调用方收到 10002、刷新在途时到期 → 在途的刷新请求被取消，窗口按 transient(call_cancelled) 结算，不清会话。
    func testDeadlineOfOnlyCallerCancelsSharedRefresh() async {
        let harness = makeHarness()
        StubURLProtocol.install { request in
            request.path == "/v1/auth/refresh" ? .hold("expiring-refresh") : fail(10002, status: 401)
        }
        let client = harness.client
        let valid = Box<Bool>()
        valid.value = true
        let call = Task { await client.send(ApiCall(operationId: "getMe"), isValid: { valid.value ?? false }) }
        await StubURLProtocol.waitUntilHeld("expiring-refresh")
        expire(valid, call)
        // 刷新请求的超时远大于 2 秒：这里看到的取消只能来自到期，不是请求自己超时。
        for _ in 0..<100 where !StubURLProtocol.wasStopped("expiring-refresh") || client.refreshing {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertTrue(StubURLProtocol.wasStopped("expiring-refresh"), "在途的刷新请求已取消")
        XCTAssertFalse(client.refreshing, "窗口已结算")
        let result = await call.value
        XCTAssertEqual(result.rejectReason, LocalRejectReason.callCancelled)
        XCTAssertEqual(StubURLProtocol.requests(path: "/v1/auth/refresh").count, 1)
        XCTAssertEqual(StubURLProtocol.requests(path: "/v1/me").count, 1, "不重放")
        XCTAssertEqual(harness.tokens.accessToken, "access-1", "会话不动")
        XCTAssertEqual(harness.tokens.refreshToken, "refresh-1")
        XCTAssertFalse(harness.recorder.effectCalls.contains { $0.kind == .clearSessionLogin }, "不清会话")
    }

    /// 对照：A、B 并入同一刷新窗口，B 到期 → 刷新照常进行（不取消），A 拿到新令牌重放成功，B 按 call_cancelled 结束。
    func testDeadlineOfOneCallerKeepsSharedRefreshForOthers() async {
        let harness = makeHarness()
        let meCount = Box<Int>()
        meCount.value = 0
        StubURLProtocol.install { request in
            switch request.path {
            case "/v1/auth/refresh":
                return .hold("kept-refresh")
            default:
                meCount.value = (meCount.value ?? 0) + 1
                return request.header("Authorization") == "Bearer access-2" ? ok() : fail(10002, status: 401)
            }
        }
        let client = harness.client
        let validA = Box<Bool>()
        validA.value = true
        let validB = Box<Bool>()
        validB.value = true
        let first = Task { await client.send(ApiCall(operationId: "getMe"), isValid: { validA.value ?? false }) }
        await StubURLProtocol.waitUntilHeld("kept-refresh")
        let second = Task { await client.send(ApiCall(operationId: "getMe"), isValid: { validB.value ?? false }) }
        for _ in 0..<200 where (meCount.value ?? 0) < 2 {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        try? await Task.sleep(nanoseconds: 200_000_000)
        expire(validB, second)
        let resultB = await second.value
        try? await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertFalse(StubURLProtocol.wasStopped("kept-refresh"), "A 仍有效：刷新不取消")
        StubURLProtocol.release("kept-refresh", with: ok(refreshData(access: "access-2")))
        let resultA = await first.value
        XCTAssertTrue(resultA.isSuccess, "A 照常重放")
        XCTAssertEqual(resultB.rejectReason, LocalRejectReason.callCancelled)
        XCTAssertEqual(StubURLProtocol.requests(path: "/v1/auth/refresh").count, 1)
        XCTAssertEqual(harness.tokens.accessToken, "access-2")
    }

    private func makeClient(reRegister: @escaping @Sendable () async -> Bool) -> ApiClient {
        let state = TestState()
        return ApiClient(
            identity: ClientIdentity(
                appId: "couli", platform: "ios", appVersion: "1.2.0", build: "120", channel: "app_store"
            ),
            context: { state.read() },
            device: TestDevice(),
            tokens: MemorySessionTokens(access: "access-1", refresh: "refresh-1", scope: "full", account: "account-A"),
            pendingKeys: PendingKeyStore(backend: MemoryPendingKeyBackend(), clock: { 0 }),
            hooks: NetworkHooks(reRegisterDevice: { _, _ in await reRegister() }),
            configuration: StubURLProtocol.configuration(),
            clock: { 1_790_661_600_000 },
            sleeper: { _ in },
            nonce: { "b5a8f07b9dda63c3f78ed24c341d25b3" }
        )
    }
}
