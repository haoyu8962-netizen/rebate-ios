import Config
import Foundation
import Generated
@testable import Network
import Session
import XCTest

/// 三端第 1 轮评审共性问题（NATIVE/APP-03a/cross-platform-r1-lessons.md）的接线测试。
/// 全部对 URLProtocol 本地假服务；需要「请求在途时」插入动作的，在桩的处理函数里做（桩在后台线程同步执行）。
final class ApiClientLessonsTests: XCTestCase {
    private let withdrawal = "{\"amount\":1000,\"payout_account_id\":\"pa-1\"}"

    private func withdraw(_ harness: Harness, stepUp: String? = "step-up-1") async -> ApiResult {
        await harness.client.send(ApiCall(operationId: "createWithdrawal", body: withdrawal, stepUpToken: stepUp))
    }

    /// 发一次没有统一外壳的提现，让键进入结果未知；返回键。
    private func makeUnknown(_ harness: Harness) async throws -> String {
        StubURLProtocol.install { _ in .error(.timedOut) }
        let first = await withdraw(harness)
        guard case let .transportFailure(_, _, key, unknown) = first else {
            XCTFail("\(first)")
            throw NSError(domain: "lessons", code: 1)
        }
        XCTAssertTrue(unknown)
        return try XCTUnwrap(key)
    }

    // MARK: - 9：账号来自可信会话；未决记录落盘是发送前置

    func testStepUpWithoutSessionAccountIsRejectedLocally() async {
        let harness = makeHarness(tokens: MemorySessionTokens(access: "access-1", refresh: "refresh-1", scope: "full"))
        StubURLProtocol.install { _ in ok() }
        let result = await withdraw(harness)
        XCTAssertEqual(result.rejectReason, LocalRejectReason.accountUnknown)
        XCTAssertTrue(StubURLProtocol.requests.isEmpty)
    }

    func testPendingRecordWriteFailureBlocksSend() async {
        let harness = makeHarness()
        harness.backend.failWrites = true
        StubURLProtocol.install { _ in ok() }
        let result = await withdraw(harness)
        XCTAssertEqual(result.rejectReason, LocalRejectReason.pendingStoreFailed)
        XCTAssertTrue(StubURLProtocol.requests.isEmpty)
    }

    // MARK: - 10：结果未知后 10003，二次验证后同键同体继续

    func testUnknownThen10003ContinuesWithSameKeyAndBodyAfterStepUp() async throws {
        let harness = makeHarness()
        let key = try await makeUnknown(harness)
        let blocked = await harness.client.send(ApiCall(operationId: "createWithdrawal", body: "{\"amount\":1}"))
        XCTAssertEqual(blocked.rejectReason, LocalRejectReason.pendingKeyUnresolved, "结果未知期间不得换键新提交")

        StubURLProtocol.install { _ in fail(10003, status: 403) }
        let confirm = await harness.client.confirmPending(operationId: "createWithdrawal")
        XCTAssertEqual(confirm.effect?.kind, .stepUp)
        XCTAssertEqual(confirm.effect?.replay, .sameKey)
        XCTAssertEqual(confirm.effect?.registerPending, false)
        XCTAssertEqual(confirm.effect?.pendingKeyUnknown, true)
        XCTAssertEqual(harness.pending.state(key: key).stateRaw, "unknown")

        StubURLProtocol.install { _ in ok("{\"withdrawal_id\":\"w-1\"}") }
        let resumed = await harness.client.confirmPending(operationId: "createWithdrawal", stepUpToken: "step-up-2")
        XCTAssertTrue(resumed.isSuccess)
        let sent = StubURLProtocol.requests[0]
        XCTAssertEqual(sent.header("Idempotency-Key"), key)
        XCTAssertEqual(sent.body, withdrawal)
        XCTAssertEqual(sent.header("X-Step-Up-Token"), "step-up-2")
        XCTAssertNil(harness.backend.read(account: "account-A", key: key))
    }

    // MARK: - 11：确认请求本地被拒时恢复为 unknown

    func testConfirmRejectedLocallyRestoresUnknown() async throws {
        let harness = makeHarness()
        let key = try await makeUnknown(harness)
        harness.state.set(settled: false)
        StubURLProtocol.install { _ in ok() }
        let rejected = await harness.client.confirmPending(operationId: "createWithdrawal")
        XCTAssertEqual(rejected.rejectReason, LocalRejectReason.environmentUnsettled)
        XCTAssertEqual(harness.pending.state(key: key).stateRaw, "unknown", "没发出：不能停在 in_flight")
        XCTAssertTrue(StubURLProtocol.requests.isEmpty)
        harness.state.set(settled: true)
        let again = await harness.client.confirmPending(operationId: "createWithdrawal")
        XCTAssertTrue(again.isSuccess, "恢复为 unknown 后可再次确认")
    }

    // MARK: - 12：作废请求遇到 10001/10004/10005 只引导

    func testAbandonWithPrerequisiteCodeOnlyGuides() async throws {
        for code in [10001, 10004, 10005] {
            let harness = makeHarness()
            let key = try await makeUnknown(harness)
            StubURLProtocol.install { _ in fail(code, status: 401, data: "{\"consent_type\":\"privacy\"}") }
            let result = await harness.client.abandonPending(operationId: "createWithdrawal")
            XCTAssertEqual(result.effect?.kind, .guideOnly, "\(code)")
            XCTAssertEqual(result.effect?.replay, ReplayMode.none, "\(code)")
            XCTAssertEqual(result.effect?.registerPending, false, "\(code)")
            XCTAssertEqual(StubURLProtocol.requests.count, 1, "\(code) 不自动重放")
            XCTAssertEqual(StubURLProtocol.requests[0].body, "{\"action\":\"withdraw\",\"idempotency_key\":\"\(key)\"}")
            XCTAssertEqual(harness.pending.state(key: key).stateRaw, "unknown", "\(code) 保持待确认")
        }
    }

    // MARK: - 13：同进程恢复不动在途请求；进程重启才把遗留 in_flight 改为 unknown

    func testRestoreInSameProcessKeepsInFlightRequest() async {
        let harness = makeHarness()
        let observed = Box<String>()
        StubURLProtocol.install { request in
            let key = request.header("Idempotency-Key") ?? ""
            // 回前台：同一进程里恢复当前账号的记录。
            harness.pending.coldStart(account: "account-A")
            observed.value = harness.pending.state(key: key).stateRaw
            // 进程重启：新的 Store 读同一个后端，遗留在途改为 unknown。
            let relaunched = PendingKeyStore(backend: harness.backend, clock: { 0 })
            relaunched.coldStart(account: "account-A")
            observed.value = (observed.value ?? "") + "/" + relaunched.state(key: key).stateRaw
            return ok()
        }
        _ = await withdraw(harness)
        XCTAssertEqual(observed.value, "in_flight/unknown")
    }

    // MARK: - 14：请求绑定账号与会话世代

    func testLate10002AfterAccountSwitchDoesNotReplayForNewAccount() async {
        let harness = makeHarness()
        StubURLProtocol.install { request in
            guard request.path == "/v1/me" else {
                return ok()
            }
            // 请求在途时退出并登录了另一个账号；旧请求随后收到 10002。
            harness.client.signOut()
            try? harness.tokens.save(access: "b-access", refresh: "b-refresh", scope: "full", account: "account-B")
            return fail(10002, status: 401)
        }
        let result = await harness.client.send(ApiCall(operationId: "getMe"))
        XCTAssertEqual(result.rejectReason, LocalRejectReason.sessionChanged)
        XCTAssertEqual(StubURLProtocol.requests(path: "/v1/me").count, 1, "不得用新账号的令牌重放旧请求")
        XCTAssertEqual(StubURLProtocol.requests(path: "/v1/auth/refresh").count, 0)
        XCTAssertEqual(harness.tokens.account, "account-B")
        XCTAssertEqual(harness.tokens.accessToken, "b-access")
    }

    func testRefreshResultArrivingAfterAccountSwitchIsDiscardedAndKeepsNewSession() async {
        let harness = makeHarness()
        StubURLProtocol.install { request in
            switch request.path {
            case "/v1/me":
                return fail(10002, status: 401)
            case "/v1/auth/refresh":
                harness.client.signOut()
                try? harness.tokens.save(access: "b-access", refresh: "b-refresh", scope: "full", account: "account-B")
                return ok(refreshData(access: "a-access-2"))
            default:
                return ok()
            }
        }
        let result = await harness.client.send(ApiCall(operationId: "getMe"))
        XCTAssertEqual(result.rejectReason, LocalRejectReason.sessionChanged)
        XCTAssertEqual(harness.tokens.accessToken, "b-access", "旧会话的刷新结果不得覆盖新会话，刷新失败也不得清掉它")
        XCTAssertEqual(harness.tokens.account, "account-B")
        XCTAssertEqual(StubURLProtocol.requests(path: "/v1/me").count, 1)
    }

    func testLoginSuccessStartsNewGenerationForRetries() async {
        let client = Box<ApiClient>()
        let harness = makeHarness(asyncSleep: {
            // 读接口退避期间经管线登录成功（换代）。
            _ = await client.value?.send(ApiCall(operationId: "loginBySms", body: "{}"))
        })
        client.value = harness.client
        StubURLProtocol.install { request in
            request.path == "/v1/auth/login/sms"
                ? ok(loginData(access: "b-access", scope: "full", user: "account-B"))
                : .error(.timedOut)
        }
        let result = await harness.client.send(ApiCall(operationId: "getMe"))
        XCTAssertEqual(result.rejectReason, LocalRejectReason.sessionChanged, "重试不跨会话世代")
        XCTAssertEqual(StubURLProtocol.requests(path: "/v1/me").count, 1)
        XCTAssertEqual(harness.tokens.account, "account-B")
    }

    // MARK: - 15：未决键的查询、确认、放弃核对账号；结算绑定原账号

    func testPendingActionsCheckSessionAccount() async throws {
        let harness = makeHarness()
        let key = try await makeUnknown(harness)
        let found = await harness.client.pendingFor(operationId: "createWithdrawal")
        XCTAssertEqual(found?.key, key)
        StubURLProtocol.install { _ in ok(loginData(access: "b-access", scope: "full", user: "account-B")) }
        _ = await harness.client.send(ApiCall(operationId: "loginBySms", body: "{}"))
        let otherAccount = await harness.client.pendingFor(operationId: "createWithdrawal")
        XCTAssertNil(otherAccount)
        let confirm = await harness.client.confirmPending(operationId: "createWithdrawal")
        XCTAssertEqual(confirm.rejectReason, LocalRejectReason.pendingKeyUnresolved)
        let abandon = await harness.client.abandonPending(operationId: "createWithdrawal")
        XCTAssertEqual(abandon.rejectReason, LocalRejectReason.pendingKeyUnresolved)
        XCTAssertEqual(StubURLProtocol.requests.map(\.path), ["/v1/auth/login/sms"])
        XCTAssertEqual(harness.backend.read(account: "account-A", key: key)?.stateRaw, "unknown")
    }

    func testConfirmRechecksAccountRightBeforeSending() async throws {
        let harness = makeHarness()
        let key = try await makeUnknown(harness)
        StubURLProtocol.install { _ in ok() }
        let tokens = harness.tokens
        // confirmPending 读第 1 次状态核对账号；管线读第 2 次之前会话换成了另一个账号。
        harness.state.onRead = { count in
            if count == 2 {
                try? tokens.save(access: "b-access", refresh: "b-refresh", scope: "full", account: "account-B")
            }
        }
        let result = await harness.client.confirmPending(operationId: "createWithdrawal")
        harness.state.onRead = nil
        XCTAssertEqual(result.rejectReason, LocalRejectReason.accountMismatch)
        XCTAssertTrue(StubURLProtocol.requests.isEmpty)
        XCTAssertEqual(harness.backend.read(account: "account-A", key: key)?.stateRaw, "unknown")
    }

    func testResponseSettlesOnOriginalAccountAfterSwitch() async {
        let harness = makeHarness()
        let tokens = harness.tokens
        let pending = harness.pending
        let keyBox = Box<String>()
        StubURLProtocol.install { request in
            keyBox.value = request.header("Idempotency-Key")
            // 请求在途时切换了账号。
            try? tokens.save(access: "b-access", refresh: "b-refresh", scope: "full", account: "account-B")
            pending.coldStart(account: "account-B")
            return ok("{\"withdrawal_id\":\"w-1\"}")
        }
        let result = await withdraw(harness)
        XCTAssertTrue(result.isSuccess)
        let key = keyBox.value ?? ""
        XCTAssertNil(harness.backend.read(account: "account-A", key: key), "成功结算到原账号的记录上")
    }

    // MARK: - 16、17：刷新收尾顺序；收尾期间新来的等待者随失败结算且只结算一次

    func testRefreshFailureClearsBeforeSettlingAndLateJoinersSettleOnce() throws {
        let operation = try XCTUnwrap(ApiOperations.byId("getMe"))
        var completions: [(String?) -> Void] = []
        var events: [String] = []
        var coordinator: RefreshCoordinator!
        coordinator = RefreshCoordinator(
            refresh: { completions.append($0) },
            replay: { request, _ in events.append("replay:\(request.id)") },
            clearSession: {
                events.append("clear")
                // 清会话进行中又来了一个 10002：并入本窗口，随失败结算，不开新窗口。
                coordinator.join(
                    request: RefreshRequest(id: "late", operation: operation, key: nil, body: ""),
                    usedToken: "old", forceUpdate: false
                )
                events.append("refreshing:\(coordinator.refreshing)")
            },
            clock: { 0 },
            onFailure: { requests in events += requests.map { "fail:\($0.id)" } }
        )
        coordinator.join(
            request: RefreshRequest(id: "first", operation: operation, key: nil, body: ""),
            usedToken: "old", forceUpdate: false
        )
        coordinator.awaitRefresh(usedToken: "old", forceUpdate: false) { token in
            events.append("listener:\(token ?? "nil")")
        }
        XCTAssertEqual(completions.count, 1)
        completions[0](nil)
        completions[0](nil)
        XCTAssertEqual(events, ["clear", "refreshing:true", "fail:first", "fail:late", "listener:nil"])
        XCTAssertEqual(coordinator.refreshCalls, 1)
        XCTAssertFalse(coordinator.refreshing)
        XCTAssertEqual(coordinator.effectRaw, ErrorEffectKind.clearSessionLogin.rawValue)
    }

    // MARK: - 20：刷新失败读结算那一刻的强更状态

    func testRefreshFailureUsesForceUpdateStateAtSettlement() async {
        let harness = makeHarness()
        let state = harness.state
        StubURLProtocol.install { request in
            if request.path == "/v1/auth/refresh" {
                // 刷新进行中强更检查得出「低于」。
                state.set(update: UpdateRaw.below)
                return fail(10404, status: 401)
            }
            return fail(10002, status: 401)
        }
        let result = await harness.client.send(ApiCall(operationId: "getMe"))
        XCTAssertEqual(result.effect?.kind, .clearSessionStayForceUpdate)
        XCTAssertEqual(result.effect?.route, "ForceUpdate")
    }

    // MARK: - 19：受限会话屏障自动接入强更恢复

    func testRestrictedBarrierAutomaticallyArmsWhenUpdateRecovers() async {
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
        _ = await harness.client.send(ApiCall(operationId: "getDeletion"))
        // 冷启动屏障在 below 时也执行（R2-03），刷新后仍是受限会话。
        XCTAssertEqual(StubURLProtocol.requests(path: "/v1/auth/refresh").count, 1)
        // 只改状态、不调任何手动入口。
        harness.state.set(update: UpdateRaw.supported)
        let result = await harness.client.send(ApiCall(operationId: "getWalletSummary"))
        XCTAssertTrue(result.isSuccess)
        XCTAssertEqual(StubURLProtocol.requests.map(\.path).suffix(2), ["/v1/auth/refresh", "/v1/wallet/summary"])
        XCTAssertEqual(StubURLProtocol.requests(path: "/v1/auth/refresh").count, 2)
        XCTAssertEqual(StubURLProtocol.requests.last?.header("Authorization"), "Bearer access-3")
    }

    // MARK: - 1：撤回同意 / 切换环境的清理项作废在途请求及其重试

    @MainActor
    func testInvalidationCleanerRunsFirstAndCancelsRetry() async {
        let entered = expectation(description: "backoff")
        let gate = AsyncGate()
        let harness = makeHarness(asyncSleep: {
            entered.fulfill()
            await gate.wait()
        })
        let cleaner = NetworkInvalidationCleaner(client: harness.client)
        let registry = EnvironmentSwitchCleanerRegistry(cleaners: [SessionTokensCleaner(tokens: harness.tokens)])
        registry.registerFirst(cleaner)
        XCTAssertEqual(registry.registeredNames, [NetworkInvalidationCleaner.name, SessionTokensCleaner.name])

        StubURLProtocol.install { _ in .error(.timedOut) }
        let client = harness.client
        let task = Task { await client.send(ApiCall(operationId: "getMe")) }
        await fulfillment(of: [entered], timeout: 5)
        XCTAssertTrue(registry.cleanAll().isEmpty)
        await gate.open()
        let result = await task.value
        XCTAssertEqual(result.rejectReason, LocalRejectReason.callCancelled)
        XCTAssertEqual(StubURLProtocol.requests.count, 1, "作废后不重试")
        XCTAssertNil(harness.tokens.accessToken)
    }
}
