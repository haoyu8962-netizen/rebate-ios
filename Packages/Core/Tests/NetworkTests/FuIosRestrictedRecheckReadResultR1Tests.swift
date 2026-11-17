import Foundation
@testable import Network
import Session
import XCTest

final class FuIosRestrictedReadR1Tests: XCTestCase {
    /// 删掉入口凭据可读性守卫或 nil → cancelled 会红；isValid 在 context 取得后竖起屏障。
    func testEntryWithdrawalAfterContextCancelsWithoutTokenRead() async {
        let rig = makeRig()
        let client = rig.client
        let bound = client.sessionGeneration

        let result = await client.recheckRestrictedSession {
            client.invalidateSessions()
            return true
        }

        XCTAssertEqual(result, .cancelled)
        XCTAssertTrue(client.withdrawalReadBarrierRaised)
        XCTAssertEqual(rig.store.reads, 0, "禁读后不得接触令牌存储")
        assertNoRefreshSideEffects(rig, bound: bound &+ 1, changes: [])
        XCTAssertTrue(StubURLProtocol.requests.isEmpty)
    }

    /// 删掉 credentialsReadableLocked 的 readEpoch 比较会红：屏障已由新快照放下，只剩旧快照过期。
    func testEntryStaleContextCancelsAfterFreshContextLowersBarrier() async {
        let state = TestState()
        let entered = AsyncGate()
        let resume = AsyncGate()
        let first = Box<Bool>()
        first.value = true
        let rig = makeRig(context: {
            let snapshot = state.read()
            if first.value == true {
                first.value = false
                await entered.open()
                await resume.wait()
            }
            return snapshot
        })
        let client = rig.client
        let bound = client.sessionGeneration
        let oldEpoch = client.invalidationTicket
        let recheck = Task { await client.recheckRestrictedSession { true } }
        await entered.wait()
        client.invalidateSessions()
        XCTAssertTrue(client.withdrawalReadBarrierRaised)
        let fresh = await client.readContext()
        XCTAssertEqual(fresh.readEpoch, oldEpoch &+ 1)
        XCTAssertFalse(client.withdrawalReadBarrierRaised, "前提：新的可信 context 已经放下屏障")
        await resume.open()

        let result = await recheck.value

        XCTAssertEqual(result, .cancelled)
        XCTAssertFalse(client.withdrawalReadBarrierRaised)
        XCTAssertEqual(rig.store.reads, 0, "旧 context 不得读令牌，即使屏障已放下")
        assertNoRefreshSideEffects(rig, bound: bound &+ 1, changes: [])
        XCTAssertTrue(StubURLProtocol.requests.isEmpty)
    }

    /// 删掉 readSessionNotingIsolation 读取后 generation == bound 的复核会红：损坏清理后不能当 cleared。
    func testEntryCorruptReadChangingGenerationIsCancelled() async {
        let rig = makeRig()
        rig.store.inner.failReads = .corrupted
        let bound = rig.client.sessionGeneration

        let result = await rig.client.recheckRestrictedSession { true }

        XCTAssertEqual(result, .cancelled)
        XCTAssertEqual(rig.store.reads, 1)
        XCTAssertEqual(rig.store.successfulClears, 1, "前提：入口读取发现损坏并执行清理")
        assertNoRefreshSideEffects(rig, bound: bound &+ 1, changes: [.cleared])
        XCTAssertTrue(StubURLProtocol.requests.isEmpty)
    }

    /// 删掉 admitLocked 的 unreadable + isolated → superseded 会红，错误地回到 transient。
    func testIsolatedUnreadableDirectAdmissionIsSuperseded() async {
        let rig = makeRig()
        isolate(rig)
        rig.store.inner.failReads = .readFailed
        let bound = rig.client.sessionGeneration
        let reads = rig.store.reads

        let result = await rig.client.joinRefresh(generation: bound, usedToken: "access-1")

        XCTAssertEqual(result, .superseded)
        XCTAssertEqual(rig.store.reads, reads + 1)
        XCTAssertTrue(rig.client.lock.withLock { rig.client.revokedSession != nil })
        assertNoRefreshSideEffects(rig, bound: bound, changes: [.cleared])
        XCTAssertTrue(StubURLProtocol.requests.isEmpty)
    }

    /// 删掉 unreadable 时的 isolated 分支会红：真实 10002 链会交付 transportFailure 而非本地拒绝。
    func testIsolatedUnreadable10002LocallyRejectsWithoutReplay() async {
        let rig = makeRig()
        isolate(rig)
        rig.store.inner.failReads = .readFailed
        let bound = rig.client.sessionGeneration

        let result = await rig.client.send(ApiCall(operationId: "getConfig", sendsWhenIdentityUnknown: true))

        guard case let .localReject(reason) = result else {
            return XCTFail("隔离中 10002 必须本地结束：\(result)")
        }
        XCTAssertEqual(reason, LocalRejectReason.sessionChanged)
        XCTAssertNil(result.effect)
        XCTAssertTrue(rig.client.lock.withLock { rig.client.revokedSession != nil })
        assertSingleAnonymousRequest()
        assertNoRefreshSideEffects(rig, bound: bound, changes: [.cleared])
    }

    /// 删掉非隔离 unreadable 的 transient 返回、把全部 unreadable 判为 superseded 会红。
    func testNonisolatedUnreadableDirectAdmissionRemainsTransient() async {
        let rig = makeRig()
        rig.store.inner.failReads = .readFailed
        let bound = rig.client.sessionGeneration

        let result = await rig.client.joinRefresh(generation: bound, usedToken: "access-1")

        XCTAssertEqual(result, .transient(LocalRejectReason.sessionUnreadable))
        XCTAssertEqual(rig.store.reads, 1)
        XCTAssertEqual(rig.store.successfulClears, 0)
        assertNoRefreshSideEffects(rig, bound: bound, changes: [])
        XCTAssertTrue(StubURLProtocol.requests.isEmpty)
    }

    /// 删掉 refreshAction 的 transient → 网络错误映射，或把非隔离 unreadable 判为 superseded 会红。
    func testNonisolatedUnreadable10002RemainsTransportFailure() async {
        let rig = makeRig()
        rig.store.inner.failReads = .readFailed
        let bound = rig.client.sessionGeneration

        let result = await rig.client.send(ApiCall(operationId: "getConfig", sendsWhenIdentityUnknown: true))

        guard case let .transportFailure(kind, status, _, _) = result else {
            return XCTFail("非隔离读失败保留网络错误：\(result)")
        }
        XCTAssertEqual(kind, LocalRejectReason.sessionUnreadable)
        XCTAssertNil(status)
        XCTAssertNil(result.effect)
        XCTAssertEqual(rig.store.successfulClears, 0)
        assertSingleAnonymousRequest()
        assertNoRefreshSideEffects(rig, bound: bound, changes: [])
    }

    /// 把 isolated 取值挪到 readSessionLocked 之后会红：本次读取删除成功已解除隔离，仍不得再清一次。
    func testAdmissionDeletingRevokedSessionUsesIsolationBeforeRead() async {
        let rig = makeRig()
        isolate(rig)
        let bound = rig.client.sessionGeneration
        let reads = rig.store.reads
        XCTAssertEqual(rig.store.successfulClears, 0)
        rig.store.allowDeletionDuringNextRead()
        XCTAssertTrue(rig.store.inner.failClears, "入队前删除仍失败，后台重试无法提前解除隔离")
        XCTAssertTrue(rig.client.lock.withLock { rig.client.revokedSession != nil })

        let result = await rig.client.joinRefresh(generation: bound, usedToken: "access-1")

        XCTAssertEqual(result, .superseded)
        XCTAssertEqual(rig.store.reads, reads + 1, "只有入队的这次读取")
        XCTAssertEqual(rig.store.successfulClears, 1, "这次读取内部重试删除成功")
        XCTAssertNil(rig.store.inner.accessToken, "残留条目已删除")
        XCTAssertTrue(rig.client.lock.withLock { rig.client.revokedSession == nil }, "读取确实解除了隔离")
        assertNoRefreshSideEffects(rig, bound: bound, changes: [.cleared])
        XCTAssertTrue(StubURLProtocol.requests.isEmpty)
    }

    private struct Rig {
        let client: ApiClient
        let store: ReadControlledTokens
        let recorder: Recorder
        let changes: SessionChangeLog
    }

    private func makeRig(context: (@Sendable () async -> NetworkContext)? = nil) -> Rig {
        let store = ReadControlledTokens()
        let state = TestState()
        let recorder = Recorder()
        let changes = SessionChangeLog()
        let client = ApiClient(
            identity: ClientIdentity(
                appId: "couli", platform: "ios", appVersion: "1.2.0", build: "120", channel: "app_store"
            ),
            context: context ?? { state.read() },
            device: TestDevice(),
            tokens: store,
            pendingKeys: PendingKeyStore(backend: MemoryPendingKeyBackend(), clock: { 0 }),
            hooks: NetworkHooks(
                onForceUpdate: { recorder.forceUpdate($0) }, onEffect: { recorder.effect($0) }
            ),
            configuration: StubURLProtocol.configuration(),
            clock: { 1_790_661_600_000 },
            sleeper: { _ in },
            nonce: { "b5a8f07b9dda63c3f78ed24c341d25b3" }
        )
        client.observeSessionChanges { changes.append($0, lockHeld: false) }
        StubURLProtocol.install { _ in fail(10002, status: 401) }
        return Rig(client: client, store: store, recorder: recorder, changes: changes)
    }

    private func isolate(_ rig: Rig) {
        rig.store.inner.failClears = true
        rig.client.signOut()
        XCTAssertTrue(rig.client.lock.withLock { rig.client.revokedSession != nil })
        XCTAssertEqual(rig.store.inner.accessToken, "access-1")
        XCTAssertEqual(rig.changes.values, [.cleared])
    }

    private func assertSingleAnonymousRequest(file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(StubURLProtocol.requests.count, 1, "不重放、不发刷新请求", file: file, line: line)
        XCTAssertEqual(StubURLProtocol.requests.first?.path, "/v1/config", file: file, line: line)
        XCTAssertNil(StubURLProtocol.requests.first?.header("Authorization"), file: file, line: line)
    }

    private func assertNoRefreshSideEffects(
        _ rig: Rig,
        bound: UInt64,
        changes: [SessionChange],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(rig.client.sessionGeneration, bound, file: file, line: line)
        XCTAssertEqual(rig.changes.values, changes, file: file, line: line)
        XCTAssertTrue(rig.recorder.effectCalls.isEmpty, file: file, line: line)
        XCTAssertTrue(rig.recorder.forceUpdateCalls.isEmpty, file: file, line: line)
        XCTAssertEqual(rig.client.refreshCalls, 0, file: file, line: line)
        XCTAssertTrue(rig.client.lock.withLock { rig.client.refreshFailures.isEmpty }, file: file, line: line)
    }
}

/// 复用内存存储，记录真实读取；只在被测读取内部放开删除，避免后台重试决定 S3-1 的时序。
private final class ReadControlledTokens: SessionTokens, @unchecked Sendable {
    let inner = MemorySessionTokens(access: "access-1", refresh: "refresh-1", scope: "full", account: "account-A")
    private let lock = NSLock()
    private var readCount = 0
    private var clearCount = 0
    private var allowDeletionOnRead = false

    var reads: Int {
        lock.withLock { readCount }
    }

    var successfulClears: Int {
        lock.withLock { clearCount }
    }

    func allowDeletionDuringNextRead() {
        lock.withLock { allowDeletionOnRead = true }
    }

    func readSession() throws -> SessionSnapshot? {
        let allow = lock.withLock {
            readCount += 1
            defer { allowDeletionOnRead = false }
            return allowDeletionOnRead
        }
        let snapshot = try inner.readSession()
        if allow {
            // ApiClient 的会话锁覆盖 readSessionLocked 的读取和后续删除；后台重试此时进不来。
            inner.failClears = false
        }
        return snapshot
    }

    func save(access: String, refresh: String, scope: String, account: String?, loginEpoch: String?) throws {
        try inner.save(access: access, refresh: refresh, scope: scope, account: account, loginEpoch: loginEpoch)
    }

    func clear() throws {
        try inner.clear()
        lock.withLock { clearCount += 1 }
    }
}
