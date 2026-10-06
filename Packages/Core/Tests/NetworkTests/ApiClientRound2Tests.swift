import Foundation
import Generated
@testable import Network
import SecureStore
import Session
import XCTest

/// 三端第 2 轮评审共性问题（cross-platform-r1-lessons.md 第 22–34 条）的接线测试，全部对 URLProtocol 本地假服务。
final class ApiClientRound2Tests: XCTestCase {
    /// 读 install_secret 时触发钩子的设备凭据（用来在「组好头、还没 resume」之间插入撤回同意）。
    private final class HookDevice: DeviceCredentials, @unchecked Sendable {
        var onSecret: (() -> Void)?
        let deviceId: String? = "device-fixture"

        var installSecret: String? {
            onSecret?()
            return "test-only.install.device-a"
        }
    }

    private let withdrawal = "{\"amount\":1000,\"payout_account_id\":\"pa-1\"}"

    private func restricted() -> MemorySessionTokens {
        MemorySessionTokens(
            access: "access-1",
            refresh: "refresh-1",
            scope: SessionScope.deletionOnly,
            account: "account-A"
        )
    }

    private func makeUnknown(_ harness: Harness) async throws -> String {
        StubURLProtocol.install { _ in .error(.timedOut) }
        let result = await harness.client.send(ApiCall(operationId: "createWithdrawal", body: withdrawal))
        return try XCTUnwrap(result.key)
    }

    // MARK: - 22：组好头、还没真正发出的请求在撤回同意时取消

    func testInvalidationBetweenPrepareAndResumeSendsNothing() async {
        let device = HookDevice()
        let harness = makeHarness(device: device)
        let client = harness.client
        device.onSecret = { client.invalidateSessions() }
        StubURLProtocol.install { _ in ok() }
        let result = await client.send(ApiCall(operationId: "openLink", pathParams: ["link_id": "abc"], body: "{}"))
        XCTAssertFalse(result.isSuccess)
        XCTAssertTrue(StubURLProtocol.requests.isEmpty, "task 在 resume 前被取消，请求没有发出")
    }

    // MARK: - 23：登录响应绑定世代

    func testLoginResponseAfterSignOutIsDiscarded() async {
        let harness = makeHarness(tokens: MemorySessionTokens())
        StubURLProtocol.install { _ in
            harness.client.signOut()
            return ok(loginData(access: "late-access", scope: "full"))
        }
        _ = await harness.client.send(ApiCall(operationId: "loginBySms", body: "{}"))
        XCTAssertNil(harness.tokens.accessToken, "失效世代的登录响应不得写入会话")
    }

    // MARK: - 24：刷新快照

    func testRefreshUsesSnapshotAccount() async {
        let harness = makeHarness()
        StubURLProtocol.install { request in
            if request.path == "/v1/auth/refresh" {
                // 刷新执行期间「当前账号」被改写（不换代）；保存时仍以入队时的快照为准。
                try? harness.tokens.save(access: "access-1", refresh: "refresh-1", scope: "full", account: "account-X")
                return ok(refreshData(access: "access-2"))
            }
            return request.header("Authorization") == "Bearer access-2" ? ok() : fail(10002, status: 401)
        }
        let result = await harness.client.send(ApiCall(operationId: "getMe"))
        XCTAssertTrue(result.isSuccess)
        XCTAssertEqual(harness.tokens.account, "account-A")
        XCTAssertEqual(
            StubURLProtocol.requests(path: "/v1/auth/refresh").first?.body,
            "{\"refresh_token\":\"refresh-1\"}"
        )
    }

    // MARK: - 26：占用绑定调用标识

    func testStaleCallerCannotReleaseAnotherCallsHold() {
        let backend = MemoryPendingKeyBackend()
        let store = PendingKeyStore(backend: backend, clock: { 0 })
        store.coldStart(account: "account-A")
        guard case let .admitted(owner) = store.admit(
            operationId: "createWithdrawal", key: "k", body: "b", account: "account-A", summary: ""
        ) else {
            return XCTFail("not admitted")
        }
        store.release(key: "k", account: "account-A", callOwner: "stale-call")
        XCTAssertEqual(store.state(key: "k").stateRaw, "in_flight", "旧调用不能释放新调用的占用")
        store.onResponse(key: "k", kind: "no_envelope", account: "account-A", callOwner: "stale-call")
        XCTAssertEqual(store.state(key: "k").stateRaw, "in_flight")
        store.onResponse(key: "k", kind: "no_envelope", account: "account-A", callOwner: owner)
        XCTAssertEqual(store.state(key: "k").stateRaw, "unknown")
    }

    // MARK: - 27：作废接口 completed 解包 original；abandoned 单独结果

    func testAbandonCompletedUnwrapsOriginalSuccess() async throws {
        let harness = makeHarness()
        let key = try await makeUnknown(harness)
        StubURLProtocol.install { _ in
            ok("{\"outcome\":\"completed\",\"original\":"
                + "{\"code\":0,\"msg\":\"ok\",\"data\":{\"withdrawal_id\":\"w-1\"}}}")
        }
        let result = await harness.client.abandonPending(operationId: "createWithdrawal")
        guard case let .success(data, _, resultKey) = result else {
            return XCTFail("\(result)")
        }
        XCTAssertEqual(resultKey, key)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(data)) as? [String: String])
        XCTAssertEqual(object["withdrawal_id"], "w-1")
        XCTAssertNil(harness.backend.read(account: "account-A", key: key))
    }

    func testAbandonCompletedUnwrapsOriginalBusinessError() async throws {
        let harness = makeHarness()
        let key = try await makeUnknown(harness)
        StubURLProtocol.install { _ in
            ok("{\"outcome\":\"completed\",\"original\":{\"code\":30306,\"msg\":\"\",\"data\":{}}}")
        }
        let result = await harness.client.abandonPending(operationId: "createWithdrawal")
        guard case let .failure(code, _, _, _, effect, resultKey) = result else {
            return XCTFail("\(result)")
        }
        XCTAssertEqual(code, 30306)
        XCTAssertEqual(effect.kind, .disableButton, "按原操作映射 Effect")
        XCTAssertEqual(resultKey, key)
        XCTAssertNil(harness.backend.read(account: "account-A", key: key))
    }

    func testAbandonAbandonedIsItsOwnResult() async throws {
        let harness = makeHarness()
        let key = try await makeUnknown(harness)
        StubURLProtocol.install { _ in ok("{\"outcome\":\"abandoned\",\"original\":null}") }
        let result = await harness.client.abandonPending(operationId: "createWithdrawal")
        XCTAssertEqual(result, .abandoned(idempotencyKey: key))
        XCTAssertNil(harness.backend.read(account: "account-A", key: key))
    }

    // MARK: - 28：刷新成功按处理响应那一刻的强更状态

    func testRestrictedRefreshUsesLatestUpdateState() async {
        let harness = makeHarness()
        let state = harness.state
        StubURLProtocol.install { request in
            if request.path == "/v1/auth/refresh" {
                state.set(update: UpdateRaw.unknown)
                return ok(refreshData(access: "access-2", scope: SessionScope.deletionOnly))
            }
            return fail(10002, status: 401)
        }
        _ = await harness.client.send(ApiCall(operationId: "getMe"))
        XCTAssertEqual(harness.recorder.forceUpdateCalls, [nil])
    }

    // MARK: - 30：屏障等待之前绑定调用归属

    func testSessionSwitchDuringBarrierEndsOldCall() async {
        let harness = makeHarness(tokens: restricted())
        StubURLProtocol.install { request in
            if request.path == "/v1/auth/refresh" {
                harness.client.signOut()
                try? harness.tokens.save(access: "b-access", refresh: "b-refresh", scope: "full", account: "account-B")
                return ok(refreshData(access: "a-access-2", scope: "full"))
            }
            return ok()
        }
        let result = await harness.client.send(ApiCall(operationId: "getMe"))
        XCTAssertEqual(result.rejectReason, LocalRejectReason.sessionChanged)
        XCTAssertTrue(StubURLProtocol.requests(path: "/v1/me").isEmpty, "不改绑到新账号继续发出")
        XCTAssertEqual(harness.tokens.accessToken, "b-access")
    }

    // MARK: - 31：屏障按完整结果结算；强更恢复通知触发刷新

    func testBarrierRefreshTimeoutEndsCallWithoutClearingSession() async {
        let harness = makeHarness(tokens: restricted())
        StubURLProtocol.install { request in
            request.path == "/v1/auth/refresh" ? .error(.timedOut) : ok()
        }
        let first = await harness.client.send(ApiCall(operationId: "getMe"))
        guard case let .transportFailure(kind, _, _, _) = first else {
            return XCTFail("\(first)")
        }
        XCTAssertEqual(kind, "timeout")
        XCTAssertTrue(StubURLProtocol.requests(path: "/v1/me").isEmpty, "不带旧受限令牌发出")
        XCTAssertEqual(harness.tokens.accessToken, "access-1", "暂时失败不清会话")
        StubURLProtocol.install { request in
            request.path == "/v1/auth/refresh" ? ok(refreshData(access: "access-2")) : ok()
        }
        let second = await harness.client.send(ApiCall(operationId: "getMe"))
        XCTAssertTrue(second.isSuccess)
        XCTAssertEqual(StubURLProtocol.requests.map(\.path), ["/v1/auth/refresh", "/v1/me"], "屏障保留，下次再刷新")
    }

    func testRefreshTimeoutFor10002EndsCallWithNetworkError() async {
        let harness = makeHarness()
        StubURLProtocol.install { request in
            request.path == "/v1/auth/refresh" ? .error(.timedOut) : fail(10002, status: 401)
        }
        let result = await harness.client.send(ApiCall(operationId: "getMe"))
        guard case let .transportFailure(kind, _, _, _) = result else {
            return XCTFail("\(result)")
        }
        XCTAssertEqual(kind, "timeout")
        XCTAssertEqual(harness.tokens.accessToken, "access-1")
        XCTAssertEqual(StubURLProtocol.requests(path: "/v1/me").count, 1)
    }

    func testUpdateRecoveryNotificationTriggersRestrictedRefresh() async {
        let harness = makeHarness(tokens: restricted())
        let refreshed = expectation(description: "refresh")
        StubURLProtocol.install { request in
            if request.path == "/v1/auth/refresh" {
                refreshed.fulfill()
                return ok(refreshData(access: "access-2"))
            }
            return ok()
        }
        harness.client.updateStateChanged(UpdateRaw.below)
        harness.client.updateStateChanged(UpdateRaw.supported)
        await fulfillment(of: [refreshed], timeout: 5)
        XCTAssertTrue(StubURLProtocol.requests(path: "/v1/me").isEmpty, "不依附任何请求")
    }

    // MARK: - 32：未决记录先持久化后改内存

    func testUnknownWriteFailureKeepsUnknownInMemory() async throws {
        let harness = makeHarness()
        StubURLProtocol.install { _ in
            harness.backend.failWrites = true
            return .error(.timedOut)
        }
        let result = await harness.client.send(ApiCall(operationId: "createWithdrawal", body: withdrawal))
        guard case let .transportFailure(_, _, key, unknown) = result else {
            return XCTFail("\(result)")
        }
        XCTAssertTrue(unknown)
        XCTAssertEqual(harness.backend.read(account: "account-A", key: try XCTUnwrap(key))?.stateRaw, "in_flight")
        XCTAssertEqual(harness.pending.state(key: try XCTUnwrap(key)).stateRaw, "unknown", "写回失败时内存保持 unknown")
        let confirm = await harness.client.confirmPending(operationId: "createWithdrawal")
        XCTAssertEqual(confirm.rejectReason, LocalRejectReason.pendingStoreFailed, "in_flight 写不进去：明确失败")
        XCTAssertEqual(harness.pending.state(key: try XCTUnwrap(key)).stateRaw, "unknown")
        harness.backend.failWrites = false
        harness.pending.coldStart(account: "account-A")
        XCTAssertEqual(harness.backend.read(account: "account-A", key: try XCTUnwrap(key))?.stateRaw, "unknown")
    }

    // MARK: - 33：Keychain 按账号查询

    func testSecureBackendListsOnlyTheRequestedAccount() throws {
        let store = MemorySecureStore()
        let backend = SecurePendingKeyBackend(store: store)
        try backend.write(PendingKeyRecord(key: "k1", operationId: "createWithdrawal", body: "a", account: "account-A"))
        try backend.write(PendingKeyRecord(key: "k2", operationId: "createWithdrawal", body: "b", account: "account-B"))
        let listed = try backend.loadAll(account: "account-A")
        XCTAssertEqual(listed.map(\.key), ["k1"])
        XCTAssertEqual(store.queriedLabels.count, 1)
        XCTAssertTrue(store.queriedLabels[0].hasPrefix(SecurePendingKeyBackend.prefix))
        XCTAssertFalse(store.queriedLabels[0]
            .contains(Data("account-B".utf8).map { String(format: "%02x", $0) }.joined()))
    }

    // MARK: - 34：旧世代响应不改动当前会话

    func testOldGeneration10404DoesNotClearNewSession() async {
        let harness = makeHarness()
        StubURLProtocol.install { _ in
            harness.client.signOut()
            try? harness.tokens.save(access: "b-access", refresh: "b-refresh", scope: "full", account: "account-B")
            return fail(10404, status: 401)
        }
        let result = await harness.client.send(ApiCall(operationId: "getMe"))
        XCTAssertEqual(result.rejectReason, LocalRejectReason.sessionChanged)
        XCTAssertEqual(harness.tokens.accessToken, "b-access")
        XCTAssertTrue(harness.recorder.forceUpdateCalls.isEmpty)
    }
}
