import Foundation
@testable import Network
import Session
import XCTest

/// LOCK-ios（编排 D10-1716）补测：读会话遇到损坏条目（`SessionReadError.corrupted`）的几条边角路径。
/// 桩复用 `CorruptibleSessionTokens`、`SessionChangeLog`（见 LockIosCorruptSessionTests.swift）：`corrupt` 时读抛 `.corrupted`；
/// `failClears` 时删除失败、条目留着；删除成功即条目消失；`save` 覆盖条目（不再损坏）。全部对 URLProtocol 本地假服务。
/// 「已按损坏处理」标记（`sessionChanges.corruptEntryHandled`）是否清掉，用可观测行为判定：标记清掉后再出现损坏会再换代、再通知一次。
final class LockIosCorruptSessionGapTests: XCTestCase {
    static let getLink = ApiCall(operationId: "getLink", pathParams: ["link_id": "abc"])
    static let getMe = ApiCall(operationId: "getMe")

    // MARK: - 1. 10002 碰上损坏条目

    /// 1. 请求带 access-1 发出，服务端回 10002（要刷新）；回包前条目变成损坏 → 刷新入队前的读会话（admitLocked）第一次发现损坏：
    /// 换代一次、出锁后只发一次 `.cleared`；本世代已结束，按 superseded → session_changed 结束：不发刷新请求、不重放、
    /// 不再清一次会话，也不交付任何 ErrorEffect（尤其不是跳 Login 的 clearSessionLogin）。
    func testRefresh10002MeetingCorruptEntryEndsSessionChangedOnce() async {
        let rig = makeRig()
        let before = rig.client.sessionGeneration
        let tokens = rig.tokens
        StubURLProtocol.install { request in
            if request.path == "/v1/auth/refresh" {
                return ok(refreshData(access: "access-2"))
            }
            tokens.corrupt = true
            return fail(10002, status: 401)
        }
        let result = await rig.client.send(Self.getMe)

        XCTAssertEqual(result.rejectReason, LocalRejectReason.sessionChanged, "\(result)")
        XCTAssertNil(result.effect, "本地结束，不带会话 Effect")
        XCTAssertEqual(StubURLProtocol.requests(path: "/v1/me").count, 1, "只发出一次、不重放")
        XCTAssertTrue(StubURLProtocol.requests(path: "/v1/auth/refresh").isEmpty, "不发刷新请求")
        XCTAssertEqual(rig.client.refreshCalls, 0, "不开刷新窗口")
        XCTAssertEqual(rig.client.sessionGeneration, before &+ 1, "只换代一次（不再按刷新失败清一次）")
        await rig.changes.settle(atLeast: 1)
        XCTAssertEqual(rig.changes.values, [.cleared], "只通知一次 .cleared")
        XCTAssertEqual(rig.changes.lockHeldDuringCallback, 0, "锁外回调")
        XCTAssertFalse(rig.recorder.effectCalls.contains { $0.route == "Login" }, "\(rig.recorder.effectCalls)")
        XCTAssertTrue(rig.recorder.effectCalls.isEmpty, "不交付任何 Effect：\(rig.recorder.effectCalls)")
    }

    // MARK: - 2. clearSessionLocked 的损坏分支

    /// 2. signOut() 时条目已损坏且删不掉：清会话本身换代一次、通知一次 `.cleared`，并记下「已按损坏处理」→
    /// 之后反复读（请求 + currentIdentity）不再换代、不再通知；删除恢复后再读删掉条目、清掉标记（这一步本身不换代、不通知）→
    /// 再一次损坏：再换代、再通知一次（证明标记确实清了）。
    func testSignOutCorruptUndeletableThenDeleteRecoversResetsMarker() async {
        let rig = makeRig()
        let before = rig.client.sessionGeneration
        rig.tokens.corrupt = true
        rig.tokens.failClears = true
        rig.client.signOut()
        XCTAssertEqual(rig.client.sessionGeneration, before &+ 1, "清会话换代一次")
        await rig.changes.settle(atLeast: 1)
        XCTAssertEqual(rig.changes.values, [.cleared], "清会话通知一次")

        StubURLProtocol.install { _ in ok() }
        for index in 1...2 {
            let result = await rig.client.send(Self.getLink)
            XCTAssertTrue(result.isSuccess, "第 \(index) 次：\(result)")
            XCTAssertNil(rig.client.currentIdentity(credentialsReadable: true).ownership.account)
        }
        XCTAssertTrue(rig.tokens.corrupt, "前提：删不掉，损坏条目还在")
        XCTAssertTrue(StubURLProtocol.requests.allSatisfy { $0.header("Authorization") == nil }, "都匿名")
        XCTAssertEqual(rig.client.sessionGeneration, before &+ 1, "反复读到损坏条目不再换代")
        await rig.changes.settle(atLeast: 2, timeout: 0.2)
        XCTAssertEqual(rig.changes.values, [.cleared], "反复读不再通知")

        rig.tokens.failClears = false
        _ = rig.client.currentIdentity(credentialsReadable: true)
        XCTAssertFalse(rig.tokens.corrupt, "前提：删除恢复，读会话时删掉了损坏条目")
        XCTAssertEqual(rig.client.sessionGeneration, before &+ 1, "删掉本身不换代")
        await rig.changes.settle(atLeast: 2, timeout: 0.2)
        XCTAssertEqual(rig.changes.values, [.cleared], "删掉本身不通知")

        rig.tokens.corrupt = true
        _ = rig.client.currentIdentity(credentialsReadable: true)
        _ = rig.client.currentIdentity(credentialsReadable: true)
        XCTAssertEqual(rig.client.sessionGeneration, before &+ 2, "标记已清：再一次损坏再换代（只一次）")
        await rig.changes.settle(atLeast: 2)
        XCTAssertEqual(rig.changes.values, [.cleared, .cleared], "再通知一次")
        XCTAssertEqual(rig.changes.lockHeldDuringCallback, 0, "锁外回调")
    }

    // MARK: - 3. 刷新保存清标记

    /// 3. 损坏且删不掉（换代、通知一次、标记已置）→ 条目恢复可读（桩直接撤掉损坏，不经保存，标记仍在）：
    /// 对照——此时再损坏不换代、不通知；→ 再恢复，请求回 10002、刷新成功并保存新令牌（覆盖条目）→ 标记清掉：
    /// 再一次损坏重新换代、通知一次。
    func testRefreshSaveResetsCorruptionMarker() async {
        let rig = makeRig()
        let before = rig.client.sessionGeneration
        rig.tokens.failClears = true
        rig.tokens.corrupt = true
        _ = rig.client.currentIdentity(credentialsReadable: true)
        XCTAssertEqual(rig.client.sessionGeneration, before &+ 1, "前提：第一次损坏换代")
        await rig.changes.settle(atLeast: 1)
        XCTAssertEqual(rig.changes.values, [.cleared])

        rig.tokens.corrupt = false
        XCTAssertEqual(rig.client.currentOwnership(credentialsReadable: true).account, "account-A", "前提：条目恢复可读")
        rig.tokens.corrupt = true
        _ = rig.client.currentIdentity(credentialsReadable: true)
        XCTAssertEqual(rig.client.sessionGeneration, before &+ 1, "对照：没有成功写入时标记仍在，不再换代")
        rig.tokens.corrupt = false

        StubURLProtocol.install { request in
            if request.path == "/v1/auth/refresh" {
                return ok(refreshData(access: "access-2"))
            }
            return request.header("Authorization") == "Bearer access-2" ? ok("{\"n\":1}") : fail(10002, status: 401)
        }
        let result = await rig.client.send(Self.getMe)
        XCTAssertTrue(result.isSuccess, "刷新后重放成功：\(result)")
        XCTAssertEqual(StubURLProtocol.requests(path: "/v1/auth/refresh").count, 1, "前提：刷新确实发生并保存")
        XCTAssertEqual(rig.client.sessionGeneration, before &+ 1, "仅令牌刷新不换代")
        await rig.changes.settle(atLeast: 2, timeout: 0.2)
        XCTAssertEqual(rig.changes.values, [.cleared], "仅令牌刷新不通知")

        rig.tokens.corrupt = true
        _ = rig.client.currentIdentity(credentialsReadable: true)
        _ = rig.client.currentIdentity(credentialsReadable: true)
        XCTAssertEqual(rig.client.sessionGeneration, before &+ 2, "刷新保存清了标记：再损坏再换代（只一次）")
        await rig.changes.settle(atLeast: 2)
        XCTAssertEqual(rig.changes.values, [.cleared, .cleared], "再通知一次")
        XCTAssertEqual(rig.changes.lockHeldDuringCallback, 0, "锁外回调")
    }

    // MARK: - 5. S3-1：隔离中读到损坏条目

    /// 5. S3-1：signOut() 时条目可读但删不掉 → 隔离中（revokedSession 非空），清会话本身换代、通知一次；
    /// 之后条目变成损坏、反复读（currentIdentity + 请求）：不再额外换代、不再额外通知 `.cleared`。
    /// 删除恢复后读会话删掉条目、解除隔离并清掉标记 → 再一次损坏按第一次处理：换代、通知一次。
    func testCorruptEntryWhileIsolatedDoesNotBumpOrNotifyAgain() async {
        let rig = makeRig()
        let before = rig.client.sessionGeneration
        rig.tokens.failClears = true
        rig.client.signOut()
        XCTAssertEqual(rig.client.sessionGeneration, before &+ 1, "清会话换代一次")
        XCTAssertTrue(rig.client.lock.withLock { rig.client.revokedSession != nil }, "前提：删不掉，隔离中")

        rig.tokens.corrupt = true
        StubURLProtocol.install { _ in ok() }
        for index in 1...2 {
            let identity = rig.client.currentIdentity(credentialsReadable: true)
            XCTAssertNil(identity.ownership.account, "第 \(index) 次")
            let result = await rig.client.send(Self.getLink)
            XCTAssertTrue(result.isSuccess, "第 \(index) 次：\(result)")
        }
        XCTAssertGreaterThan(rig.tokens.readCount, 2, "前提：确实读到了损坏条目")
        XCTAssertTrue(StubURLProtocol.requests.allSatisfy { $0.header("Authorization") == nil }, "都匿名")
        XCTAssertEqual(rig.client.sessionGeneration, before &+ 1, "隔离中读到损坏不再额外换代")
        await rig.changes.settle(atLeast: 2, timeout: 0.3)
        XCTAssertEqual(rig.changes.values, [.cleared], "只有清会话本身那一次通知")

        rig.tokens.failClears = false
        _ = rig.client.currentIdentity(credentialsReadable: true)
        XCTAssertFalse(rig.tokens.corrupt, "前提：删除恢复，条目已删")
        XCTAssertTrue(rig.client.lock.withLock { rig.client.revokedSession == nil }, "删掉即解除隔离")
        XCTAssertEqual(rig.client.sessionGeneration, before &+ 1, "删掉本身不换代")

        rig.tokens.corrupt = true
        _ = rig.client.currentIdentity(credentialsReadable: true)
        XCTAssertEqual(rig.client.sessionGeneration, before &+ 2, "标记已清、不在隔离：再损坏换代一次")
        await rig.changes.settle(atLeast: 2)
        XCTAssertEqual(rig.changes.values, [.cleared, .cleared])
        XCTAssertEqual(rig.changes.lockHeldDuringCallback, 0, "锁外回调")
    }

    // MARK: - 6. S3-3：recheckAfterRefresh 读到损坏条目

    /// 6. S3-3：刷新完成后的复查读取（recheckAfterRefresh）本身发现损坏条目而换代 → 按已失效返回 .cancelled，
    /// 不能因为读成「没有会话」（scope 为 nil）而落到 .full。对照：同一状态下条目正常时返回 .full。
    func testRecheckAfterRefreshFindingCorruptEntryIsCancelled() async {
        let rig = makeRig()
        let state = await rig.client.readContext()
        XCTAssertEqual(rig.client.recheckAfterRefresh(state, rig.client.currentGeneration), .full, "对照：正常条目")

        let bound = rig.client.currentGeneration
        rig.tokens.failClears = true
        rig.tokens.corrupt = true
        XCTAssertEqual(rig.client.recheckAfterRefresh(state, bound), .cancelled, "读取发现损坏、已换代：按已失效")
        XCTAssertEqual(rig.client.sessionGeneration, bound &+ 1, "换代一次")
        XCTAssertEqual(rig.client.recheckAfterRefresh(state, bound), .cancelled, "旧世代再复查：仍按已失效")
        XCTAssertEqual(rig.client.sessionGeneration, bound &+ 1, "不再换代")
        await rig.changes.settle(atLeast: 1)
        XCTAssertEqual(rig.changes.values, [.cleared], "通知一次")
        XCTAssertEqual(rig.changes.lockHeldDuringCallback, 0, "锁外回调")
    }

    // MARK: - 桩

    private struct Rig {
        let client: ApiClient
        let tokens: CorruptibleSessionTokens
        let changes: SessionChangeLog
        let recorder: Recorder
    }

    private func makeRig() -> Rig {
        let tokens = CorruptibleSessionTokens(snapshot: SessionSnapshot(
            access: "access-1", refresh: "refresh-1", scope: "full", account: "account-A",
            loginEpoch: SessionLoginEpoch.make()
        ))
        let harness = makeHarness(sessionStore: tokens)
        let client = harness.client
        let changes = SessionChangeLog()
        client.observeSessionChanges { [weak client] change in
            // 回调时客户端的锁必须没被持有（NSLock 不可重入，同线程持锁时 try() 返回 false）
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
        return Rig(client: client, tokens: tokens, changes: changes, recorder: harness.recorder)
    }
}
