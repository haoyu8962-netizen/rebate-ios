import Foundation
@testable import Network
import Session
import XCTest

/// LOCK-ios（编排 D10-1716）：读会话遇到条目内容损坏（`SessionReadError.corrupted`）时与清会话（`clearSessionLocked`）同口径——
/// ① 第一次发现损坏：会话世代 +1、经 `observeSessionChanges` 通知一次（`.cleared`），之后按确认游客处理；固定了旧账号 / 旧世代的在途
///   请求按 session_changed 本地拒、零发送。
/// ② 删除失败时之后每次读都会碰到同一个损坏条目：只有第一次换代、通知；直到下一次成功写入会话（登录 / 刷新保存）才清掉「已按损坏处理」标记。
/// ③ 通知不在持锁时同步回调（观察者里 `client.lock.try()` 必须拿得到锁）。
/// 桩：`CorruptibleSessionTokens`（本文件）——`corrupt = true` 时 `readSession()` 抛 `.corrupted`；`clear()` 成功即删掉条目（损坏一并消失），
/// `failClears = true` 时删除抛错、损坏条目留着；`save` 覆盖条目（不再损坏）。`MemorySessionTokens.failReads` 删掉后仍抛错，模拟不了「删除成功」。
/// 全部对 URLProtocol 本地假服务。
final class LockIosCorruptSessionTests: XCTestCase {
    static let getLink = ApiCall(operationId: "getLink", pathParams: ["link_id": "abc"])

    // MARK: - 1. 运行中会话变成损坏

    /// 1. D10-1716 ①：full 会话可读 → 条目变成损坏 → 下一次读：世代 +1、收到一次 `.cleared`（锁外回调）；之后按确认游客：
    /// 身份已确认、没有账号、不是会员；optional 的 getLink 匿名发出、不带 Authorization，且不再换代、不再通知。
    func testRunningSessionBecomingCorruptBumpsGenerationAndNotifiesOnce() async {
        let rig = makeRig()
        XCTAssertEqual(rig.client.currentOwnership(credentialsReadable: true).account, "account-A", "前提：full 会话可读")
        let before = rig.client.sessionGeneration
        XCTAssertTrue(rig.changes.values.isEmpty)

        rig.tokens.corrupt = true
        let identity = rig.client.currentIdentity(credentialsReadable: true)
        XCTAssertEqual(rig.client.sessionGeneration, before &+ 1, "第一次发现损坏：会话世代 +1（同 clearSessionLocked）")
        await rig.changes.settle(atLeast: 1)
        XCTAssertEqual(rig.changes.values, [.cleared], "通知一次，口径同清会话")
        XCTAssertEqual(rig.changes.lockHeldDuringCallback, 0, "D10-1716 ③：通知不在持锁时同步回调")
        XCTAssertTrue(identity.identityKnown, "按确认游客：身份已确认")
        XCTAssertNil(identity.ownership.account)
        XCTAssertFalse(identity.member)

        StubURLProtocol.install { _ in ok() }
        let result = await rig.client.send(Self.getLink)
        XCTAssertTrue(result.isSuccess, "\(result)")
        XCTAssertEqual(StubURLProtocol.requests.count, 1, "optional 匿名发出")
        XCTAssertNil(StubURLProtocol.requests.first?.header("Authorization"), "不带 Authorization")
        XCTAssertEqual(rig.client.sessionGeneration, before &+ 1, "之后不再换代")
        await rig.changes.settle(atLeast: 1)
        XCTAssertEqual(rig.changes.values, [.cleared], "之后不再通知")
    }

    // MARK: - 2. 固定了旧账号的请求

    /// 2. D10-1716 ①：在损坏前取的固定归属（账号 A、旧世代）在损坏后发送 → session_changed、零发送。
    /// 两种发现顺序都钉：(a) 损坏由这次请求自己的读会话发现；(b) 先由别处的读（currentIdentity）发现、再发请求。
    func testPinnedOldAccountAfterCorruptionIsSessionChanged() async {
        for discoveredFirst in [false, true] {
            let label = discoveredFirst ? "先由别处读发现" : "由请求自己发现"
            let rig = makeRig()
            StubURLProtocol.install { _ in ok() }
            let pinned = rig.client.currentOwnership(credentialsReadable: true)
            XCTAssertEqual(pinned.account, "account-A", label)
            rig.tokens.corrupt = true
            if discoveredFirst {
                _ = rig.client.currentIdentity(credentialsReadable: true)
            }
            let result = await rig.client.send(Self.getLink, isValid: { true }, sendAllowed: { true }, expected: pinned)
            XCTAssertEqual(result.rejectReason, LocalRejectReason.sessionChanged, "\(label)：\(result)")
            XCTAssertTrue(StubURLProtocol.requests.isEmpty, "\(label)：零发送")
            XCTAssertEqual(rig.client.sessionGeneration, pinned.generation &+ 1, "\(label)：只换一代")
        }
    }

    // MARK: - 3. 删除失败、反复读到同一损坏条目

    /// 3. D10-1716 ②：删除失败（条目留着）→ 连续三次请求 + 三次 currentIdentity：世代只 +1 一次、通知只一次；每次都按确认游客。
    func testCorruptEntryThatCannotBeDeletedBumpsAndNotifiesOnlyOnce() async {
        let rig = makeRig()
        let before = rig.client.sessionGeneration
        rig.tokens.failClears = true
        rig.tokens.corrupt = true
        StubURLProtocol.install { _ in ok() }

        for index in 1...3 {
            let result = await rig.client.send(Self.getLink)
            XCTAssertTrue(result.isSuccess, "第 \(index) 次请求：\(result)")
            let identity = rig.client.currentIdentity(credentialsReadable: true)
            XCTAssertTrue(identity.identityKnown, "第 \(index) 次：确认游客")
            XCTAssertNil(identity.ownership.account, "第 \(index) 次")
        }
        XCTAssertTrue(rig.tokens.corrupt, "前提：删除失败，损坏条目还在")
        XCTAssertGreaterThan(rig.tokens.readCount, 3, "前提：确实反复读到了损坏条目")
        XCTAssertEqual(StubURLProtocol.requests.count, 3)
        XCTAssertTrue(StubURLProtocol.requests.allSatisfy { $0.header("Authorization") == nil }, "都匿名")
        XCTAssertEqual(rig.client.sessionGeneration, before &+ 1, "世代只 +1 一次")
        await rig.changes.settle(atLeast: 1)
        XCTAssertEqual(rig.changes.values, [.cleared], "通知只一次")
        XCTAssertEqual(rig.changes.lockHeldDuringCallback, 0, "锁外回调")
    }

    // MARK: - 4. 重新登录清掉标记

    /// 4. D10-1716 ②：删除失败、已按损坏处理过一次 → 重新登录成功（保存新会话，换代、`.saved`）清掉标记 → 再一次损坏：再 +1、再通知一次 `.cleared`。
    func testSuccessfulLoginResetsCorruptionMarker() async {
        let rig = makeRig()
        rig.tokens.failClears = true
        rig.tokens.corrupt = true
        _ = rig.client.currentIdentity(credentialsReadable: true)
        _ = rig.client.currentIdentity(credentialsReadable: true)
        await rig.changes.settle(atLeast: 1)
        XCTAssertEqual(rig.changes.values, [.cleared], "前提：第一次损坏只通知一次")

        StubURLProtocol.install { _ in ok(loginData(access: "access-new", scope: "full", user: "account-B")) }
        let login = await rig.client.send(ApiCall(operationId: "loginBySms", body: "{}"))
        XCTAssertTrue(login.isSuccess, "重新登录：\(login)")
        XCTAssertFalse(rig.tokens.corrupt, "前提：新会话覆盖了损坏条目")
        XCTAssertEqual(rig.client.currentOwnership(credentialsReadable: true).account, "account-B")
        await rig.changes.settle(atLeast: 2)
        XCTAssertEqual(rig.changes.values, [.cleared, .saved])
        let afterLogin = rig.client.sessionGeneration

        rig.tokens.corrupt = true
        _ = rig.client.currentIdentity(credentialsReadable: true)
        _ = rig.client.currentIdentity(credentialsReadable: true)
        XCTAssertEqual(rig.client.sessionGeneration, afterLogin &+ 1, "标记已清：再一次损坏再 +1（只一次）")
        await rig.changes.settle(atLeast: 3)
        XCTAssertEqual(rig.changes.values, [.cleared, .saved, .cleared], "再通知一次")
        XCTAssertEqual(rig.changes.lockHeldDuringCallback, 0, "锁外回调")
    }

    // MARK: - 5. 冷启动就已损坏

    /// 5. D10-1716：客户端创建时条目已损坏（删除也失败）→ 读成没有会话（确认游客，getLink 匿名发出）；是否换代 / 通知按实现约定，
    /// 但反复读也**至多一次**（世代增量 ≤ 1、通知 ≤ 1）。
    func testColdStartCorruptEntryReadsAsNoSessionAtMostOneChange() async {
        let tokens = CorruptibleSessionTokens()
        tokens.corrupt = true
        tokens.failClears = true
        let rig = makeRig(tokens: tokens)
        let before = rig.client.sessionGeneration
        StubURLProtocol.install { _ in ok() }

        for index in 1...3 {
            let identity = rig.client.currentIdentity(credentialsReadable: true)
            XCTAssertTrue(identity.identityKnown, "第 \(index) 次：按没有会话（已确认）")
            XCTAssertNil(identity.ownership.account)
            XCTAssertFalse(identity.member)
            let result = await rig.client.send(Self.getLink)
            XCTAssertTrue(result.isSuccess, "第 \(index) 次：\(result)")
        }
        XCTAssertTrue(StubURLProtocol.requests.allSatisfy { $0.header("Authorization") == nil }, "都匿名")
        XCTAssertLessThanOrEqual(rig.client.sessionGeneration &- before, 1, "世代至多 +1")
        await rig.changes.settle(atLeast: 1, timeout: 0.3)
        XCTAssertLessThanOrEqual(rig.changes.values.count, 1, "通知至多一次：\(rig.changes.values)")
        XCTAssertTrue(rig.changes.values.allSatisfy { $0 == .cleared }, "\(rig.changes.values)")
        XCTAssertEqual(rig.changes.lockHeldDuringCallback, 0, "锁外回调")
    }

    // MARK: - 桩

    private struct Rig {
        let client: ApiClient
        let tokens: CorruptibleSessionTokens
        let changes: SessionChangeLog
    }

    private func makeRig(tokens: CorruptibleSessionTokens = CorruptibleSessionTokens(
        snapshot: SessionSnapshot(
            access: "access-1", refresh: "refresh-1", scope: "full", account: "account-A",
            loginEpoch: SessionLoginEpoch.make()
        )
    )) -> Rig {
        let harness = makeHarness(sessionStore: tokens)
        let client = harness.client
        let changes = SessionChangeLog()
        client.observeSessionChanges { [weak client] change in
            // D10-1716 ③：回调时客户端的锁必须没被持有（NSLock 不可重入，同线程持锁时 try() 返回 false）
            var held = false
            if let client {
                if client.lock.try() {
                    client.lock.unlock()
                } else {
                    held = true
                }
            }
            changes.append(change, lockHeld: held)
        }
        return Rig(client: client, tokens: tokens, changes: changes)
    }
}

/// 会话变化通知的记录（线程安全）。LockIosCorruptSessionGapTests 复用，故不设 private。
final class SessionChangeLog: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [SessionChange] = []
    private var held = 0

    func append(_ change: SessionChange, lockHeld: Bool) {
        lock.withLock {
            stored.append(change)
            if lockHeld {
                held += 1
            }
        }
    }

    var values: [SessionChange] {
        lock.withLock { stored }
    }

    var lockHeldDuringCallback: Int {
        lock.withLock { held }
    }

    /// 通知可能在锁外异步发出：等到至少 `count` 条（或超时），再多等一小会儿，让多发的通知也能被看到。
    func settle(atLeast count: Int, timeout: TimeInterval = 1.0) async {
        let deadline = Date().addingTimeInterval(timeout)
        while values.count < count, Date() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        try? await Task.sleep(nanoseconds: 50_000_000)
    }
}

/// 可造损坏条目的会话存储（单测）：`corrupt` 时读抛 `.corrupted`；删除成功即条目消失（含损坏）；`failClears` 时删除失败、条目留着；
/// 保存覆盖条目（不再损坏）。
final class CorruptibleSessionTokens: SessionTokens, @unchecked Sendable {
    private let lock = NSLock()
    private var current: SessionSnapshot?
    private var corrupted = false
    private var failingClears = false
    private var reads = 0

    init(snapshot: SessionSnapshot? = nil) {
        current = snapshot
    }

    var corrupt: Bool {
        get { lock.withLock { corrupted } }
        set { lock.withLock { corrupted = newValue } }
    }

    var failClears: Bool {
        get { lock.withLock { failingClears } }
        set { lock.withLock { failingClears = newValue } }
    }

    var readCount: Int {
        lock.withLock { reads }
    }

    func readSession() throws -> SessionSnapshot? {
        try lock.withLock {
            reads += 1
            if corrupted {
                throw SessionReadError.corrupted
            }
            return current
        }
    }

    func save(access: String, refresh: String, scope: String, account: String?, loginEpoch: String?) throws {
        lock.withLock {
            corrupted = false
            current = SessionSnapshot(
                access: access,
                refresh: refresh,
                scope: scope,
                account: account,
                loginEpoch: loginEpoch
            )
        }
    }

    struct ClearFailed: Error {}

    func clear() throws {
        try lock.withLock {
            guard !failingClears else {
                throw ClearFailed()
            }
            corrupted = false
            current = nil
        }
    }
}
