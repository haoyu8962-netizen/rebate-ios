import Foundation
@testable import Network
import Session
import XCTest

final class FuIosRestrictedRecheckReadResultTests: XCTestCase {
    /// 删掉 recheckAfterRefresh 的 .unreadable → .restricted 分支、恢复旧 scope 判定会红。
    func testAfterSuccessfulRefreshUnreadableStaysRestricted() async {
        await assertAfterRefresh(.unreadable, expected: .restricted)
    }

    /// 删掉 recheckAfterRefresh 的 .none → .cleared 分支、恢复旧 scope 判定会红。
    func testAfterSuccessfulRefreshAbsentSessionIsCleared() async {
        await assertAfterRefresh(.absent, expected: .cleared)
    }

    /// 删掉 recheckAfterRefresh 的 live.access 非空守卫会红：有 refresh 的快照仍属于 .live。
    func testAfterSuccessfulRefreshSessionWithoutAccessIsCleared() async {
        await assertAfterRefresh(.noAccess, expected: .cleared)
    }

    /// 删掉 recheckAfterRefresh 对 deletion_only 的判定、统一返回 .full 会红。
    func testAfterSuccessfulRefreshDeletionOnlyStaysRestricted() async {
        await assertAfterRefresh(.deletionOnly, expected: .restricted)
    }

    /// 删掉 recheckAfterRefresh 正常作用域的 .full 返回、统一保留受限会红。
    func testAfterSuccessfulRefreshFullSessionIsFull() async {
        await assertAfterRefresh(.full, expected: .full)
    }

    /// 删掉 recheckWithoutRefresh 的 unreadable 分类会红（会落到 .cleared）；并守住零刷新、零换代。
    func testEntryUnreadableStaysRestrictedWithoutRefresh() async {
        let tokens = MemorySessionTokens(access: "access-1", refresh: "refresh-1", scope: "deletion_only")
        tokens.failReads = .readFailed
        let harness = makeHarness(tokens: tokens)
        StubURLProtocol.install { _ in fail(10002, status: 401) }
        let before = harness.client.sessionGeneration

        let result = await harness.client.recheckRestrictedSession { true }

        XCTAssertEqual(result, .restricted)
        XCTAssertEqual(harness.client.sessionGeneration, before)
        XCTAssertEqual(harness.client.refreshCalls, 0)
        XCTAssertTrue(StubURLProtocol.requests.isEmpty)
        XCTAssertTrue(harness.recorder.effectCalls.isEmpty)
        tokens.failReads = nil
        XCTAssertEqual(tokens.accessToken, "access-1", "读不出时不能清掉原会话")
    }

    /// 删掉 recheckWithoutRefresh 无 live/access 时的 .cleared 守卫，或把 .none 与 unreadable 合并，会红。
    func testEntryAbsentSessionIsClearedWithoutRefresh() async {
        let harness = makeHarness(tokens: MemorySessionTokens())
        StubURLProtocol.install { _ in fail(10002, status: 401) }
        let before = harness.client.sessionGeneration

        let result = await harness.client.recheckRestrictedSession { true }

        XCTAssertEqual(result, .cleared)
        XCTAssertEqual(harness.client.sessionGeneration, before)
        XCTAssertEqual(harness.client.refreshCalls, 0)
        XCTAssertTrue(StubURLProtocol.requests.isEmpty)
        XCTAssertTrue(harness.recorder.effectCalls.isEmpty)
    }

    /// 删掉 recheckWithoutRefresh 的 isolated ? .cleared 特判会红；非隔离对照由原入口用例覆盖。
    func testIsolatedEntryUnreadableIsClearedWithoutRefresh() async {
        let harness = isolatedUnreadableHarness()
        let bound = harness.client.sessionGeneration

        let result = await harness.client.recheckRestrictedSession { true }

        XCTAssertEqual(result, .cleared)
        assertIsolatedReadOnly(harness, bound: bound)
    }

    /// 删掉 recheckAfterRefresh 的隔离快照或 unreadable → cleared 特判会红。
    /// 直接测刷新后读取器：真实清会话会换代，原刷新调用拿旧 bound 会先返回 cancelled。
    func testPostRefreshReaderIsolatedUnreadableIsCleared() async {
        let harness = isolatedUnreadableHarness()
        let state = await harness.client.readContext()
        let bound = harness.client.sessionGeneration

        let result = harness.client.recheckAfterRefresh(state, bound)

        XCTAssertEqual(result, .cleared)
        assertIsolatedReadOnly(harness, bound: bound)
    }

    /// 删掉读到另一份 live 时解除隔离的逻辑，或入口只看读取前 isolated 就返回 cleared，会红。
    func testEntryReplacementFullSessionLiftsIsolationAndReturnsFull() async throws {
        try await assertReplacement(scope: "full", afterRefresh: false)
    }

    /// 删掉解除隔离后入口按 deletion_only 发起复查、保留 restricted 的逻辑会红。
    func testEntryReplacementDeletionOnlySessionLiftsIsolationAndRechecksScope() async throws {
        try await assertReplacement(scope: "deletion_only", afterRefresh: false)
    }

    /// 删掉刷新后读取器对新 live 的 full 返回，或因读取前 isolated 而一律 cleared，会红。
    func testPostRefreshReaderReplacementFullSessionLiftsIsolationAndReturnsFull() async throws {
        try await assertReplacement(scope: "full", afterRefresh: true)
    }

    /// 删掉刷新后读取器对新 live 的 deletion_only 判断，或因读取前 isolated 而一律 cleared，会红。
    func testPostRefreshReaderReplacementDeletionOnlySessionLiftsIsolationAndStaysRestricted() async throws {
        try await assertReplacement(scope: "deletion_only", afterRefresh: true)
    }

    private func isolatedUnreadableHarness() -> Harness {
        let harness = makeHarness()
        harness.tokens.failClears = true
        harness.client.signOut()
        XCTAssertTrue(harness.client.lock.withLock { harness.client.revokedSession != nil })
        XCTAssertEqual(harness.tokens.accessToken, "access-1", "前提：删除失败，旧条目仍在")
        harness.tokens.failReads = .readFailed
        StubURLProtocol.install { _ in fail(10002, status: 401) }
        return harness
    }

    private func assertIsolatedReadOnly(_ harness: Harness, bound: UInt64) {
        XCTAssertEqual(harness.client.sessionGeneration, bound)
        XCTAssertTrue(harness.client.lock.withLock { harness.client.revokedSession != nil })
        XCTAssertEqual(harness.tokens.failReads, .readFailed)
        XCTAssertEqual(harness.client.refreshCalls, 0)
        XCTAssertTrue(StubURLProtocol.requests.isEmpty)
        XCTAssertTrue(harness.recorder.effectCalls.isEmpty)
        XCTAssertTrue(harness.recorder.forceUpdateCalls.isEmpty)
    }

    private func assertReplacement(
        scope: String,
        afterRefresh: Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let harness = makeHarness()
        harness.tokens.failClears = true
        harness.client.signOut()
        let bound = harness.client.sessionGeneration
        let changes = SessionChangeLog()
        harness.client.observeSessionChanges { changes.append($0, lockHeld: false) }
        // 模拟另一登录写入不同的整份会话，保留旧隔离标记，让被测读取自行识别并解除。
        // 删除继续失败，后台重试无法在测试读取之前抢先删掉新会话。
        try harness.tokens.save(access: "new-access", refresh: "new-refresh", scope: scope, account: "account-B")
        XCTAssertTrue(harness.client.lock.withLock { harness.client.revokedSession != nil }, file: file, line: line)
        StubURLProtocol.install { _ in ok(refreshData(access: "new-access-2", scope: scope)) }

        let result: RestrictedRecheck
        if afterRefresh {
            let state = await harness.client.readContext()
            result = harness.client.recheckAfterRefresh(state, bound)
        } else {
            result = await harness.client.recheckRestrictedSession { true }
        }

        XCTAssertEqual(result, scope == "full" ? .full : .restricted, file: file, line: line)
        XCTAssertTrue(harness.client.lock.withLock { harness.client.revokedSession == nil }, file: file, line: line)
        XCTAssertEqual(harness.tokens.account, "account-B", file: file, line: line)
        XCTAssertEqual(harness.tokens.scope, scope, file: file, line: line)
        XCTAssertEqual(harness.client.sessionGeneration, bound, file: file, line: line)
        let refreshes = !afterRefresh && scope == "deletion_only" ? 1 : 0
        XCTAssertEqual(harness.client.refreshCalls, refreshes, file: file, line: line)
        XCTAssertEqual(StubURLProtocol.requests.count, refreshes, file: file, line: line)
        if refreshes == 1 {
            XCTAssertEqual(StubURLProtocol.requests.first?.path, "/v1/auth/refresh", file: file, line: line)
            XCTAssertTrue(
                StubURLProtocol.requests.first?.body.contains("new-refresh") == true, file: file, line: line
            )
        }
        XCTAssertTrue(changes.values.isEmpty, file: file, line: line)
        XCTAssertTrue(harness.recorder.effectCalls.isEmpty, file: file, line: line)
    }

    private func assertAfterRefresh(
        _ read: SavedRead,
        expected: RestrictedRecheck,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let tokens = AfterSaveTokens(read: read)
        let harness = makeHarness(sessionStore: tokens)
        let changes = SessionChangeLog()
        harness.client.observeSessionChanges { changes.append($0, lockHeld: false) }
        StubURLProtocol.install { request in
            guard request.path == "/v1/auth/refresh" else {
                XCTFail("复查只能发刷新请求", file: file, line: line)
                return fail(10002, status: 401)
            }
            return ok(refreshData(access: "access-2", scope: read == .deletionOnly ? "deletion_only" : "full"))
        }
        let before = harness.client.sessionGeneration

        let result = await harness.client.recheckRestrictedSession { true }

        XCTAssertEqual(tokens.saved.value?.access, "access-2", "前提：刷新成功且保存过", file: file, line: line)
        XCTAssertEqual(StubURLProtocol.requests.count, 1, file: file, line: line)
        XCTAssertEqual(StubURLProtocol.requests.first?.path, "/v1/auth/refresh", file: file, line: line)
        XCTAssertEqual(harness.client.refreshCalls, 1, file: file, line: line)
        XCTAssertEqual(harness.client.sessionGeneration, before, "存储变化没有触发换代", file: file, line: line)
        XCTAssertEqual(result, expected, file: file, line: line)
        XCTAssertTrue(harness.recorder.effectCalls.isEmpty, file: file, line: line)
        XCTAssertTrue(changes.values.isEmpty, file: file, line: line)
    }
}

private enum SavedRead: Sendable {
    case unreadable, absent, noAccess, deletionOnly, full
}

/// 复用 MemorySessionTokens；在真正保存刷新令牌之后、save 返回之前改变存储的下一次读取结果。
/// 与现有 CountingTokens.onSave 相同的截点；不回调 ApiClient，不靠 sleep 或异步通知竞争时序。
private final class AfterSaveTokens: SessionTokens, @unchecked Sendable {
    private let inner = MemorySessionTokens(
        access: "access-1", refresh: "refresh-1", scope: "deletion_only", account: "account-A"
    )
    private let read: SavedRead
    let saved = Box<SessionSnapshot>()

    init(read: SavedRead) {
        self.read = read
    }

    func readSession() throws -> SessionSnapshot? {
        try inner.readSession()
    }

    func save(access: String, refresh: String, scope: String, account: String?, loginEpoch: String?) throws {
        try inner.save(access: access, refresh: refresh, scope: scope, account: account, loginEpoch: loginEpoch)
        saved.value = try inner.readSession()
        switch read {
        case .unreadable:
            inner.failReads = .readFailed
        case .absent:
            try inner.clear()
        case .noAccess:
            try inner.save(access: "", refresh: refresh, scope: scope, account: account, loginEpoch: loginEpoch)
        case .deletionOnly, .full:
            break
        }
    }

    func clear() throws {
        try inner.clear()
    }
}
