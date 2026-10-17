import Foundation
@testable import Network
import SecureStore
import Session
import XCTest

/// iOS 第 2 轮评审（ios-review-r2.md）R2-01、R2-04、R2-05 的复现测试（R2-03 见 ApiClientSessionTests，R2-06 见
/// ErrorActionExplicitActionTests）。全部对 URLProtocol 本地假服务。
final class ApiClientReviewR2Tests: XCTestCase {
    private static let skewedDate = ["Date": "Tue, 29 Sep 2026 07:00:00 GMT"]

    private func secureSession(_ store: MemorySecureStore, scope: String = SessionScope.full) throws
        -> SecureSessionTokens {
        let tokens = SecureSessionTokens(store: store)
        try tokens.save(access: "access-1", refresh: "refresh-1", scope: scope, account: "account-A")
        return tokens
    }

    // MARK: - R2-01：读取失败不等于没有会话

    /// 生产 SecureSessionTokens 一次读出完整会话，区分不存在、读取失败与内容损坏。
    func testSecureSessionTokensDistinguishesMissingReadFailureAndCorruption() throws {
        let store = MemorySecureStore()
        let tokens = SecureSessionTokens(store: store)
        XCTAssertNil(try tokens.readSession(), "不存在 → nil")
        try tokens.save(access: "a", refresh: "r", scope: SessionScope.deletionOnly, account: "account-A")
        // FU-IOS-0712：快照另带持久化登录世代（保存时新生成），按读出的世代比较其余字段
        let epoch = try XCTUnwrap(try tokens.readSession()?.loginEpoch)
        XCTAssertEqual(
            try tokens.readSession(),
            SessionSnapshot(
                access: "a", refresh: "r", scope: SessionScope.deletionOnly, account: "account-A", loginEpoch: epoch
            )
        )
        store.failReads = true
        XCTAssertThrowsError(try tokens.readSession()) { error in
            XCTAssertEqual(error as? SessionReadError, .readFailed)
        }
        store.failReads = false
        try store.set(Data("not-json".utf8), forAccount: SecureSessionTokens.keychainAccount)
        XCTAssertThrowsError(try tokens.readSession()) { error in
            XCTAssertEqual(error as? SessionReadError, .corrupted)
        }
    }

    /// 原场景：清会话时删除失败 → 旧令牌隔离 → 随后读取暂时失败。旧实现把读取失败当成没有会话、解除隔离，
    /// 存储恢复后又带着旧令牌发出。现在：读取失败时需要会话的接口本地拒绝；存储恢复后仍隔离、不带旧令牌；
    /// 删除成功后才解除。
    func testReadFailureKeepsQuarantineAndNeverResendsRevokedToken() async throws {
        let store = MemorySecureStore()
        let tokens = try secureSession(store)
        let harness = makeHarness(sessionStore: tokens)
        StubURLProtocol.install { _ in ok() }

        store.failWrites = true
        harness.client.signOut()
        store.failReads = true
        let unreadable = await harness.client.send(ApiCall(operationId: "getMe"))
        XCTAssertEqual(unreadable.rejectReason, LocalRejectReason.sessionUnreadable, "读取失败不得当成没有会话")
        XCTAssertTrue(StubURLProtocol.requests.isEmpty)

        // 存储恢复可读，但删除仍失败：旧会话保持隔离，不带旧令牌。
        store.failReads = false
        _ = await harness.client.send(ApiCall(operationId: "getMe"))
        XCTAssertFalse(StubURLProtocol.requests.isEmpty)
        XCTAssertTrue(
            StubURLProtocol.requests.allSatisfy { $0.header("Authorization") == nil },
            "隔离中的旧令牌不得再发出"
        )
        XCTAssertNotNil(try tokens.readSession(), "删除仍失败，条目还在")

        // 删除恢复：下一次读取完成删除，隔离解除。
        store.failWrites = false
        _ = await harness.client.send(ApiCall(operationId: "getMe"))
        XCTAssertNil(try tokens.readSession())
        XCTAssertTrue(StubURLProtocol.requests.allSatisfy { $0.header("Authorization") == nil })
    }

    /// 读取失败期间删除能成功时：确认删除后解除隔离（之后按没有会话）。
    func testReadFailureWhileQuarantinedRetriesDeletion() async throws {
        let store = MemorySecureStore()
        let tokens = try secureSession(store)
        let harness = makeHarness(sessionStore: tokens)
        StubURLProtocol.install { _ in ok() }
        store.failWrites = true
        harness.client.signOut()
        store.failReads = true
        store.failWrites = false
        let unreadable = await harness.client.send(ApiCall(operationId: "getMe"))
        XCTAssertEqual(unreadable.rejectReason, LocalRejectReason.sessionUnreadable, "存储仍读不了：不发")
        store.failReads = false
        XCTAssertNil(try tokens.readSession(), "读取失败时照样重试删除，删除成功")
        let after = await harness.client.send(ApiCall(operationId: "getMe"))
        XCTAssertTrue(after.isSuccess, "确认删除后按没有会话：\(after)")
        XCTAssertEqual(StubURLProtocol.requests.count, 1)
        XCTAssertTrue(StubURLProtocol.requests.allSatisfy { $0.header("Authorization") == nil })
    }

    /// 受限会话读取失败：不会按 full 判定、带 deletion_only 令牌发表外接口（旧实现四项分开读，scope 读失败时按 full）。
    func testRestrictedSessionReadFailureDoesNotSendWithCredentials() async throws {
        let store = MemorySecureStore()
        let tokens = try secureSession(store, scope: SessionScope.deletionOnly)
        let harness = makeHarness(sessionStore: tokens)
        StubURLProtocol.install { _ in ok() }
        store.failReads = true
        for operation in ["listOrders", "getMe", "getDeletion"] {
            let result = await harness.client.send(ApiCall(operationId: operation))
            XCTAssertEqual(result.rejectReason, LocalRejectReason.sessionUnreadable, operation)
        }
        XCTAssertTrue(StubURLProtocol.requests.isEmpty)
        store.failReads = false
        XCTAssertEqual(try tokens.readSession()?.access, "access-1", "读取失败不清会话")
    }

    /// 内容损坏的会话不能使用：不带任何令牌，并删除损坏条目。
    func testCorruptedSessionIsNotUsedAndIsDeleted() async throws {
        let store = MemorySecureStore()
        try store.set(Data("{\"access\":1}".utf8), forAccount: SecureSessionTokens.keychainAccount)
        let harness = makeHarness(sessionStore: SecureSessionTokens(store: store))
        StubURLProtocol.install { _ in ok() }
        _ = await harness.client.send(ApiCall(operationId: "getMe"))
        XCTAssertTrue(StubURLProtocol.requests.allSatisfy { $0.header("Authorization") == nil })
        XCTAssertNil(try store.data(forAccount: SecureSessionTokens.keychainAccount), "损坏条目已删除")
    }

    // MARK: - R2-04：内部刷新也做 10401 校时重签

    /// 原场景：getMe 返回 10002 → 内部刷新收到 10401 与可校时的 Date → 旧实现直接判刷新被拒、清会话跳登录。
    /// 现在：校时后用新的 X-Timestamp、X-Nonce 重签刷新一次，成功后重放原请求。
    func testInternalRefreshResignsOnceAfterClockSkew() async {
        let harness = makeHarness()
        let refreshes = Box<Int>()
        StubURLProtocol.install { request in
            if request.path == "/v1/auth/refresh" {
                refreshes.value = (refreshes.value ?? 0) + 1
                return refreshes.value == 1
                    ? fail(10401, status: 401, headers: Self.skewedDate)
                    : ok(refreshData(access: "access-2"))
            }
            return request.header("Authorization") == "Bearer access-2" ? ok() : fail(10002, status: 401)
        }
        let result = await harness.client.send(ApiCall(operationId: "getMe"))
        XCTAssertTrue(result.isSuccess, "\(result)")
        let refreshCalls = StubURLProtocol.requests(path: "/v1/auth/refresh")
        XCTAssertEqual(refreshCalls.count, 2, "校时重签 1 次")
        XCTAssertEqual(refreshCalls[1].header("X-Timestamp"), "1790665200", "按服务端时间重签")
        XCTAssertNotEqual(refreshCalls[0].header("X-Sign"), refreshCalls[1].header("X-Sign"))
        XCTAssertEqual(refreshCalls[0].body, refreshCalls[1].body, "同一窗口的请求体不变")
        XCTAssertEqual(harness.client.refreshCalls, 1, "仍是同一个刷新窗口")
        XCTAssertEqual(harness.tokens.accessToken, "access-2")
        XCTAssertFalse(harness.recorder.effectCalls.contains { $0.kind == .clearSessionLogin }, "不清会话、不跳登录")
    }

    /// 刷新的校时重签只有 1 次：再次 10401 按刷新被拒结算。
    func testInternalRefreshResignsAtMostOnce() async {
        let harness = makeHarness()
        StubURLProtocol.install { request in
            request.path == "/v1/auth/refresh"
                ? fail(10401, status: 401, headers: Self.skewedDate)
                : fail(10002, status: 401)
        }
        let result = await harness.client.send(ApiCall(operationId: "getMe"))
        XCTAssertEqual(StubURLProtocol.requests(path: "/v1/auth/refresh").count, 2)
        XCTAssertEqual(result.rejectReason, LocalRejectReason.sessionCleared)
    }

    // MARK: - R2-05：校时重签不占用重放预算

    /// 原场景：签名请求先 10401（时钟偏差）→ 校时重签 → 10002。旧实现把重签当成重放，10002 直接给通用错误。
    /// 现在：校时重签与前置动作重放分开计，10002 照常刷新后沿用原键、原请求体重放一次。
    func testResignDoesNotConsumeReplayBudget() async {
        let harness = makeHarness()
        let calls = Box<Int>()
        StubURLProtocol.install { request in
            if request.path == "/v1/auth/refresh" {
                return ok(refreshData(access: "access-2"))
            }
            calls.value = (calls.value ?? 0) + 1
            switch calls.value {
            case 1:
                return fail(10401, status: 401, headers: Self.skewedDate)
            case 2:
                return fail(10002, status: 401)
            default:
                return ok()
            }
        }
        let body = "{\"url\":\"https://item.example.invalid/1\"}"
        let result = await harness.client.send(ApiCall(operationId: "convertLink", body: body))
        XCTAssertTrue(result.isSuccess, "\(result)")
        let sent = StubURLProtocol.requests(path: "/v1/links/convert")
        XCTAssertEqual(sent.count, 3)
        XCTAssertEqual(Set(sent.compactMap { $0.header("Idempotency-Key") }).count, 1, "沿用原键")
        XCTAssertEqual(Set(sent.map(\.body)), [body], "沿用原请求体")
        XCTAssertEqual(sent[2].header("Authorization"), "Bearer access-2")
        XCTAssertEqual(StubURLProtocol.requests(path: "/v1/auth/refresh").count, 1)
    }

    /// 一次逻辑调用里校时重签至多 1 次：重放之后再遇 10401 不再重签。
    func testResignBudgetIsOncePerLogicalCall() async {
        let harness = makeHarness()
        let calls = Box<Int>()
        StubURLProtocol.install { request in
            if request.path == "/v1/auth/refresh" {
                return ok(refreshData(access: "access-2"))
            }
            calls.value = (calls.value ?? 0) + 1
            return calls.value == 2 ? fail(10002, status: 401) : fail(10401, status: 401, headers: Self.skewedDate)
        }
        let result = await harness.client.send(ApiCall(operationId: "convertLink", body: "{}"))
        XCTAssertEqual(StubURLProtocol.requests(path: "/v1/links/convert").count, 3)
        XCTAssertEqual(result.effect?.code, 10401)
    }
}
