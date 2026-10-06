import Foundation
import Generated
@testable import Network
import SecureStore
import Session
import XCTest

/// iOS 第 1 轮评审（NATIVE/APP-03a/ios-review-r1.md）R1-03…R1-12 的复现测试，全部对 URLProtocol 本地假服务。
/// 需要「请求在途时」插入动作的，用桩的 hold / release 把请求停在假服务里（模拟还在等服务端），再按需回应。
final class ApiClientReviewR1Tests: XCTestCase {
    private let withdrawal = "{\"amount\":1000,\"payout_account_id\":\"pa-1\"}"

    private func withdraw(_ harness: Harness, key: String? = nil) async -> ApiResult {
        await harness.client.send(ApiCall(
            operationId: "createWithdrawal", body: withdrawal, idempotencyKey: key, stepUpToken: "step-up-1"
        ))
    }

    /// 提现超时：键进入结果未知；返回键。
    private func makeUnknown(_ harness: Harness) async throws -> String {
        StubURLProtocol.install { _ in .error(.timedOut) }
        let first = await withdraw(harness)
        guard case let .transportFailure(_, _, key, unknown) = first else {
            XCTFail("\(first)")
            throw NSError(domain: "review-r1", code: 1)
        }
        XCTAssertTrue(unknown)
        return try XCTUnwrap(key)
    }

    /// 等到没有进行中的刷新窗口。
    private func waitUntilNoRefresh(_ client: ApiClient) async {
        for _ in 0..<500 where client.refreshing {
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        XCTAssertFalse(client.refreshing)
    }

    // MARK: - R1-03：刷新窗口按账号与会话世代隔离

    /// A 的刷新还在途 → 退出并登录 B → B 的请求收到 10002：B 开自己的窗口刷新并重放成功；A 的迟到结果丢弃，
    /// A 的调用按 session_changed 结束，B 的会话不受影响。
    func testNewSessionDoesNotJoinOldSessionsRefreshWindow() async {
        let harness = makeHarness()
        let client = harness.client
        StubURLProtocol.install { request in
            if request.path == "/v1/auth/login/sms" {
                return ok(loginData(access: "b-access", scope: "full", user: "account-B"))
            }
            if request.path == "/v1/auth/refresh" {
                // A 的刷新停在假服务里；B 的刷新（refresh-2，来自登录响应）立即成功。
                if request.body.contains("refresh-1") {
                    return .hold("refresh-A")
                }
                return ok(refreshData(access: "b-access-2", refresh: "b-refresh-2"))
            }
            if request.header("Authorization") == "Bearer b-access-2" {
                return ok("{\"who\":\"B\"}")
            }
            return fail(10002, status: 401)
        }
        let oldCall = Task { await client.send(ApiCall(operationId: "getMe")) }
        await StubURLProtocol.waitUntilHeld("refresh-A")
        client.signOut()
        let login = await client.send(ApiCall(operationId: "loginBySms", body: "{}"))
        XCTAssertTrue(login.isSuccess)
        let newCall = await client.send(ApiCall(operationId: "getMe"))
        XCTAssertTrue(newCall.isSuccess, "B 不并入 A 的窗口：\(newCall)")
        XCTAssertEqual(client.refreshCalls, 2)
        XCTAssertEqual(harness.tokens.accessToken, "b-access-2")

        StubURLProtocol.release("refresh-A", with: ok(refreshData(access: "a-access-2")))
        let oldResult = await oldCall.value
        XCTAssertEqual(oldResult.rejectReason, LocalRejectReason.sessionChanged)
        XCTAssertEqual(harness.tokens.accessToken, "b-access-2", "A 的迟到结果不得覆盖 B")
        XCTAssertEqual(harness.tokens.account, "account-B")
        XCTAssertFalse(harness.recorder.effectCalls.contains { $0.kind == .clearSessionLogin }, "不给 B 发跳登录")
    }

    /// 入队后、刷新任务读状态之前存储被换成别的令牌：刷新仍用入队那一刻的快照（refresh_token 与账号）。
    func testRefreshSnapshotIsFixedWhenTheWindowOpens() async {
        let harness = makeHarness()
        let tokens = harness.tokens
        StubURLProtocol.install { request in
            if request.path == "/v1/auth/refresh" {
                return ok(refreshData(access: "access-2"))
            }
            return request.header("Authorization") == "Bearer access-2" ? ok() : fail(10002, status: 401)
        }
        // 第 1 次读：发送前；第 2 次：解包 10002；第 3 次：刷新任务发请求之前（窗口已开）。
        harness.state.onRead = { count in
            if count == 3 {
                try? tokens.save(access: "x-access", refresh: "x-refresh", scope: "full", account: "account-X")
            }
        }
        let result = await harness.client.send(ApiCall(operationId: "getMe"))
        harness.state.onRead = nil
        XCTAssertTrue(result.isSuccess)
        XCTAssertEqual(
            StubURLProtocol.requests(path: "/v1/auth/refresh").map(\.body),
            ["{\"refresh_token\":\"refresh-1\"}"]
        )
        XCTAssertEqual(tokens.account, "account-A", "按快照账号保存")
    }

    // MARK: - R1-04：每个等待者拿到所在窗口不可变的完整结果

    /// 刷新超时后下一轮刷新立即开始：上一轮的等待者仍按网络错误（timeout）结束，不被误判成会话已清。
    func testWaiterKeepsItsWindowsTimeoutWhileNextWindowIsInFlight() async {
        let harness = makeHarness()
        let client = harness.client
        let refreshes = Box<Int>()
        StubURLProtocol.install { request in
            switch request.path {
            case "/v1/auth/refresh":
                let count = (refreshes.value ?? 0) + 1
                refreshes.value = count
                return .hold("refresh-\(count)")
            case "/v1/wallet/summary":
                return request.header("Authorization") == "Bearer access-2" ? ok() : .hold("wallet")
            default:
                return fail(10002, status: 401)
            }
        }
        let first = Task { await client.send(ApiCall(operationId: "getMe")) }
        await StubURLProtocol.waitUntilHeld("refresh-1")
        let second = Task { await client.send(ApiCall(operationId: "getWalletSummary")) }
        await StubURLProtocol.waitUntilHeld("wallet")

        StubURLProtocol.release("refresh-1", with: .error(.timedOut))
        await waitUntilNoRefresh(client)
        StubURLProtocol.release("wallet", with: fail(10002, status: 401))
        // 第二轮刷新已开始、还在途。
        await StubURLProtocol.waitUntilHeld("refresh-2")

        let firstResult = await first.value
        guard case let .transportFailure(kind, _, _, _) = firstResult else {
            return XCTFail("上一轮等待者应按网络错误结束：\(firstResult)")
        }
        XCTAssertEqual(kind, "timeout")
        XCTAssertEqual(harness.tokens.accessToken, "access-1", "暂时失败不清会话")
        XCTAssertFalse(harness.recorder.effectCalls.contains { $0.kind == .clearSessionLogin })

        StubURLProtocol.release("refresh-2", with: ok(refreshData(access: "access-2")))
        let secondResult = await second.value
        XCTAssertTrue(secondResult.isSuccess, "\(secondResult)")
        XCTAssertEqual(client.refreshCalls, 2)
    }

    // MARK: - R1-05：同世代因刷新失败被清后，晚到的 10002 复用那次失败

    func testLate10002AfterRefreshFailureReusesThatFailureWithoutClearingAgain() async {
        let harness = makeHarness()
        let client = harness.client
        StubURLProtocol.install { request in
            switch request.path {
            case "/v1/auth/refresh":
                fail(10404, status: 401)
            case "/v1/wallet/summary":
                .hold("late")
            case "/v1/auth/login/sms":
                ok(loginData(access: "b-access", scope: "full", user: "account-B"))
            default:
                fail(10002, status: 401)
            }
        }
        // 用同一旧令牌发出、响应晚到的请求。
        let late = Task { await client.send(ApiCall(operationId: "getWalletSummary")) }
        await StubURLProtocol.waitUntilHeld("late")
        let first = await client.send(ApiCall(operationId: "getMe"))
        XCTAssertEqual(first.rejectReason, LocalRejectReason.sessionCleared)
        XCTAssertNil(harness.tokens.accessToken)
        // 用户随即重新登录（新会话）。
        let login = await client.send(ApiCall(operationId: "loginBySms", body: "{}"))
        XCTAssertTrue(login.isSuccess)

        StubURLProtocol.release("late", with: fail(10002, status: 401))
        let lateResult = await late.value
        XCTAssertEqual(lateResult.rejectReason, LocalRejectReason.sessionCleared, "复用那次刷新失败，不是 session_changed")
        XCTAssertEqual(lateResult.effect?.kind, .clearSessionLogin)
        XCTAssertEqual(client.refreshCalls, 1)
        XCTAssertEqual(StubURLProtocol.requests(path: "/v1/auth/refresh").count, 1)
        XCTAssertEqual(harness.tokens.accessToken, "b-access", "不得再清一次（新会话保留）")
        XCTAssertEqual(
            harness.recorder.effectCalls.filter { $0.kind == .clearSessionLogin }.count, 1, "会话 Effect 只发一次"
        )
    }

    /// 用户换了会话（不是刷新失败）：晚到的 10002 按 session_changed 结束，两种情况分开。
    func testLate10002AfterSignOutIsSessionChanged() async {
        let harness = makeHarness()
        StubURLProtocol.install { request in
            request.path == "/v1/me" ? .hold("me") : ok()
        }
        let call = Task { await harness.client.send(ApiCall(operationId: "getMe")) }
        await StubURLProtocol.waitUntilHeld("me")
        harness.client.signOut()
        StubURLProtocol.release("me", with: fail(10002, status: 401))
        let result = await call.value
        XCTAssertEqual(result.rejectReason, LocalRejectReason.sessionChanged)
        XCTAssertEqual(harness.client.refreshCalls, 0)
    }

    // MARK: - R1-07：未决记录读不出来不当成没有

    func testUnreadablePendingStoreBlocksNewSubmission() async throws {
        let harness = makeHarness()
        let key = try await makeUnknown(harness)
        StubURLProtocol.install { _ in ok("{\"withdrawal_id\":\"w-2\"}") }
        harness.backend.failReads = true
        let blocked = await withdraw(harness, key: "k2")
        XCTAssertEqual(blocked.rejectReason, LocalRejectReason.pendingStoreFailed)
        XCTAssertTrue(StubURLProtocol.requests.isEmpty, "无法确认未决状态：新键不发出")
        let status = await harness.client.pendingStatus(operationId: "createWithdrawal")
        XCTAssertEqual(status, .unreadable)
        let confirm = await harness.client.confirmPending(operationId: "createWithdrawal")
        XCTAssertEqual(confirm.rejectReason, LocalRejectReason.pendingStoreFailed)
        XCTAssertEqual(harness.pending.state(key: key).stateRaw, PendingKeyStore.unknown, "本进程确认过的内容照常可见")

        // 存储恢复：原键仍未终结，新键照样被挡。
        harness.backend.failReads = false
        let still = await withdraw(harness, key: "k2")
        XCTAssertEqual(still.rejectReason, LocalRejectReason.pendingKeyUnresolved)
        XCTAssertTrue(StubURLProtocol.requests.isEmpty)
        XCTAssertNil(harness.backend.read(account: "account-A", key: "k2"))
    }

    func testCorruptKeychainRecordIsAReadFailure() throws {
        let store = MemorySecureStore()
        let backend = SecurePendingKeyBackend(store: store)
        try backend.write(PendingKeyRecord(key: "k1", operationId: "createWithdrawal", body: "a", account: "account-A"))
        let label = SecurePendingKeyBackend.prefix + Data("account-A".utf8).map { String(format: "%02x", $0) }.joined()
            + "."
        let slot = try XCTUnwrap(store.accounts(withLabel: label).first)
        try store.set(Data("garbage".utf8), forAccount: slot, label: label)
        XCTAssertThrowsError(try backend.loadAll(account: "account-A"))
        XCTAssertThrowsError(try backend.load(account: "account-A", key: "k1"))
        XCTAssertNil(try backend.load(account: "account-A", key: "missing"), "确实没有才是 nil")

        let pending = PendingKeyStore(backend: backend, clock: { 0 })
        XCTAssertEqual(pending.lookup(operationId: "createWithdrawal"), .none, "没有当前账号时不读")
        XCTAssertFalse(
            pending.beforeSend(operationId: "createWithdrawal", key: "k2", body: "b", account: "account-A"),
            "损坏的记录不当成没有：不放行新键"
        )
        XCTAssertEqual(pending.lookup(operationId: "createWithdrawal"), .unreadable)
    }

    // MARK: - R1-08：未知键收到非终结 2xxxx 不输出换新键

    func testUnknownKeyConfirmedWith20901KeepsPendingConfirmActions() async throws {
        let harness = makeHarness()
        let key = try await makeUnknown(harness)
        StubURLProtocol.install { _ in fail(20901) }
        let result = await harness.client.confirmPending(operationId: "createWithdrawal")
        let effect = try XCTUnwrap(result.effect)
        XCTAssertEqual(effect.kind, .pageAction)
        XCTAssertEqual(effect.action, ErrorPageAction.pendingConfirm)
        XCTAssertNotEqual(effect.action, ErrorPageAction.newKeyResubmit)
        XCTAssertEqual(effect.textKey, "pending_confirm.cannot_confirm")
        XCTAssertEqual(effect.replay, ReplayMode.none)
        XCTAssertTrue(effect.pendingKeyUnknown)
        XCTAssertEqual(harness.backend.read(account: "account-A", key: key)?.stateRaw, PendingKeyStore.unknown)
        XCTAssertEqual(StubURLProtocol.requests.first?.header("Idempotency-Key"), key)
    }

    // MARK: - R1-09：清会话时删除失败，旧令牌继续被阻断并重试删除

    func testFailedSessionDeleteKeepsOldTokensBlockedAndRetries() async {
        let tokens = MemorySessionTokens(access: "access-1", refresh: "refresh-1", scope: "full", account: "account-A")
        tokens.failClears = true
        let harness = makeHarness(tokens: tokens)
        StubURLProtocol.install { request in
            if request.path == "/v1/auth/refresh" {
                return fail(10404, status: 401)
            }
            return request.header("Authorization") == nil ? fail(10001, status: 401) : fail(10002, status: 401)
        }
        let first = await harness.client.send(ApiCall(operationId: "getMe"))
        XCTAssertEqual(first.rejectReason, LocalRejectReason.sessionCleared)
        XCTAssertEqual(tokens.accessToken, "access-1", "删除失败：条目还在存储里")

        _ = await harness.client.send(ApiCall(operationId: "getMe"))
        let sent = StubURLProtocol.requests(path: "/v1/me")
        XCTAssertEqual(sent.count, 2)
        XCTAssertNil(sent[1].header("Authorization"), "已作废的旧令牌不再带出")
        XCTAssertEqual(harness.client.refreshCalls, 1, "也不再拿旧 refresh_token 刷新")

        // 删除恢复：下一次读会话时重试删除成功。
        tokens.failClears = false
        _ = await harness.client.send(ApiCall(operationId: "getMe"))
        XCTAssertNil(tokens.accessToken)
        XCTAssertNil(tokens.refreshToken)
    }

    func testSignOutWithFailedDeleteStillBlocksAndNewLoginReplacesIt() async {
        let tokens = MemorySessionTokens(access: "access-1", refresh: "refresh-1", scope: "full", account: "account-A")
        tokens.failClears = true
        let harness = makeHarness(tokens: tokens)
        StubURLProtocol.install { request in
            request.path == "/v1/auth/login/sms" ? ok(loginData(access: "b-access", scope: "full", user: "account-B"))
                : ok()
        }
        harness.client.signOut()
        _ = await harness.client.send(ApiCall(operationId: "getMe"))
        XCTAssertNil(StubURLProtocol.requests(path: "/v1/me").last?.header("Authorization"))
        let pending = await harness.client.pendingFor(operationId: "createWithdrawal")
        XCTAssertNil(pending, "作废的会话没有可信账号")
        _ = await harness.client.send(ApiCall(operationId: "loginBySms", body: "{}"))
        _ = await harness.client.send(ApiCall(operationId: "getMe"))
        XCTAssertEqual(StubURLProtocol.requests(path: "/v1/me").last?.header("Authorization"), "Bearer b-access")
    }

    // MARK: - R1-10：旧世代的 10001 不跳登录、不登记待办

    func testOldGeneration10001DoesNotGuideNewSessionToLogin() async {
        let harness = makeHarness()
        StubURLProtocol.install { request in
            switch request.path {
            case "/v1/me":
                .hold("me")
            case "/v1/auth/login/sms":
                ok(loginData(access: "b-access", scope: "full", user: "account-B"))
            default:
                ok()
            }
        }
        let call = Task { await harness.client.send(ApiCall(operationId: "getMe")) }
        await StubURLProtocol.waitUntilHeld("me")
        harness.client.signOut()
        _ = await harness.client.send(ApiCall(operationId: "loginBySms", body: "{}"))
        StubURLProtocol.release("me", with: fail(10001, status: 401))
        let result = await call.value
        XCTAssertEqual(result.rejectReason, LocalRejectReason.sessionChanged)
        XCTAssertNil(result.effect)
        XCTAssertTrue(harness.recorder.effectCalls.isEmpty, "旧响应不交付跳登录 / 登记待办")
        XCTAssertEqual(harness.tokens.accessToken, "b-access")
    }

    // MARK: - R1-11：登录令牌保存失败不返回登录成功

    func testLoginTokenSaveFailureIsNotLoginSuccess() async {
        let tokens = MemorySessionTokens(access: "access-1", refresh: "refresh-1", scope: "full", account: "account-A")
        let harness = makeHarness(tokens: tokens)
        tokens.failSaves = true
        StubURLProtocol.install { _ in ok(loginData(access: "b-access", scope: "full", user: "account-B")) }
        let result = await harness.client.send(ApiCall(operationId: "loginBySms", body: "{}"))
        guard case let .sessionNotSaved(reason, traceId) = result else {
            return XCTFail("\(result)")
        }
        XCTAssertEqual(reason, LocalRejectReason.sessionSaveFailed)
        XCTAssertNotNil(traceId)
        XCTAssertFalse(result.isSuccess)
        XCTAssertEqual(tokens.accessToken, "access-1", "原会话不变")
    }

    func testLoginWithoutTokensIsNotLoginSuccess() async {
        let harness = makeHarness(tokens: MemorySessionTokens())
        StubURLProtocol.install { _ in ok("{\"user_id\":\"account-B\",\"is_new_user\":false}") }
        let result = await harness.client.send(ApiCall(operationId: "loginBySms", body: "{}"))
        XCTAssertEqual(
            result,
            .sessionNotSaved(reason: LocalRejectReason.invalidSessionTokens, traceId: "trace-0001-abcdef")
        )
    }

    // MARK: - R1-12：getLink / getSharePage 的 30144 用 link_landing.invalid

    func test30144OnLinkOperationsUsesLinkLandingTextByDefault() throws {
        for operation in ["getLink", "getSharePage"] {
            // ApiCall 的缺省 fromProductCard = true。
            let effect = ErrorActionMapper.map(ErrorActionInput(
                code: 30144, data: [:], operation: try XCTUnwrap(ApiOperations.byId(operation)), headers: [:],
                isReplay: false,
                state: ErrorActionState(update: "supported", sessionScope: "full", appVersion: "1.2.0"),
                fromProductCard: ApiCall(operationId: operation).fromProductCard
            ))
            XCTAssertEqual(effect.kind, .pageAction, operation)
            XCTAssertEqual(effect.action, ErrorPageAction.emptyState, operation)
            XCTAssertEqual(effect.textKey, "link_landing.invalid", operation)
            XCTAssertEqual(effect.replay, ReplayMode.none, operation)
        }
    }
}
