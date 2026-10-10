import Foundation
@testable import Network
import Session
import XCTest

/// APP-08 iOS 第六次修复 NEW-01（S0）：网络层没有状态快照的令牌读取也过同一道撤回禁读屏障。
/// - 后台删除重试：登出时令牌删除失败、重试已排队，随后撤回同意（作废世代推进、清理仍失败）。重试醒来只删除、不读取，零令牌读取；
/// - 刷新完成后的读取（Restricted 复查）：刷新窗口结算、保存新令牌之后、复查读取作用域之前撤回同意。同一把锁里先比较再读取，零读取、
///   按已失效结束；
/// - 撤回期间的登出、对外的隔离账号 / 作用域 / 请求归属：屏障竖着时零读取。
/// 对照：没有撤回时同身份的复查、重试删除照常完成。
final class ApiClientReadBarrierR3fTests: XCTestCase {
    /// 记读取、删除次数的令牌存储（转给内存实现）；`onSave` 在保存成功后（ApiClient 持锁中）调用，只能记录、不能回调 ApiClient。
    private final class CountingTokens: SessionTokens, @unchecked Sendable {
        let inner: MemorySessionTokens
        private let lock = NSLock()
        private var readCount = 0
        private var clearCount = 0
        var onSave: (@Sendable () -> Void)?

        init(_ inner: MemorySessionTokens) {
            self.inner = inner
        }

        var reads: Int {
            lock.withLock { readCount }
        }

        var clears: Int {
            lock.withLock { clearCount }
        }

        func readSession() throws -> SessionSnapshot? {
            lock.withLock { readCount += 1 }
            return try inner.readSession()
        }

        func save(access: String, refresh: String, scope: String, account: String?) throws {
            try inner.save(access: access, refresh: refresh, scope: scope, account: account)
            onSave?()
        }

        func clear() throws {
            lock.withLock { clearCount += 1 }
            try inner.clear()
        }
    }

    private struct Rig {
        let client: ApiClient
        let store: CountingTokens
        let readable: Box<Bool>
    }

    private func makeRig(scope: String = "full", retryDelays: [Int64] = [1000]) -> Rig {
        let inner = MemorySessionTokens(access: "access-1", refresh: "refresh-1", scope: scope, account: "account-A")
        let store = CountingTokens(inner)
        let readable = Box<Bool>()
        readable.value = true
        let client = ApiClient(
            identity: ClientIdentity(
                appId: "couli", platform: "ios", appVersion: "1.2.0", build: "120", channel: "app_store"
            ),
            context: {
                NetworkContext(
                    privacy: PrivacyRaw.full, environmentSettled: true, credentialsReadable: readable.value ?? false,
                    update: UpdateRaw.supported, apiBaseURL: URL(string: "https://api.test.couli.invalid")
                )
            },
            device: TestDevice(),
            tokens: store,
            pendingKeys: PendingKeyStore(backend: MemoryPendingKeyBackend(), clock: { 0 }),
            configuration: StubURLProtocol.configuration(),
            clock: { 1_790_661_600_000 },
            sleeper: { _ in },
            nonce: { "b5a8f07b9dda63c3f78ed24c341d25b3" },
            revokedRetryDelays: retryDelays
        )
        return Rig(client: client, store: store, readable: readable)
    }

    /// 撤回同意：标记先置（不可读）→ 网络层作废（同一把锁推进作废世代、竖起禁读屏障）→ 清令牌失败（残留令牌仍在）。
    private static func withdraw(_ rig: Rig) -> Bool {
        rig.readable.value = false
        rig.client.invalidateSessions()
        rig.store.inner.failClears = true
        return (try? rig.store.clear()) == nil
    }

    private func withdraw(_ rig: Rig) {
        XCTAssertTrue(Self.withdraw(rig), "前提：撤回清理删除失败，残留令牌仍在")
    }

    private func wait(until condition: () -> Bool, timeout: TimeInterval = 3) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    // MARK: - 后台删除重试

    /// 删除重试排队后撤回：重试醒来只删除、不读取，零令牌读取。之后删除恢复成功，隔离照常解除（仍零读取）。
    func testRevokedRetryQueuedThenWithdrawalReadsNoTokens() async {
        let rig = makeRig(retryDelays: [30])
        rig.store.inner.failClears = true
        rig.client.signOut()
        let clearsAtSignOut = rig.store.clears
        withdraw(rig)
        let readsAtWithdrawal = rig.store.reads
        let clearsAtWithdrawal = rig.store.clears
        // 等重试醒来至少两次（每次都删一次、仍失败）
        await wait { rig.store.clears >= clearsAtWithdrawal + 2 }
        XCTAssertGreaterThan(clearsAtWithdrawal, clearsAtSignOut, "前提：撤回清理也试过删除")
        XCTAssertGreaterThanOrEqual(rig.store.clears, clearsAtWithdrawal + 2, "前提：后台重试确实醒来并重试删除")
        XCTAssertEqual(rig.store.reads, readsAtWithdrawal, "撤回之后后台删除重试零令牌读取")
        // 删除恢复：下一次重试删掉残留，隔离解除，仍然零读取
        rig.store.inner.failClears = false
        await wait { (try? rig.store.inner.readSession()) == nil }
        XCTAssertNil(try? rig.store.inner.readSession(), "残留令牌被后台重试删掉")
        XCTAssertEqual(rig.store.reads, readsAtWithdrawal, "删除成功的那次重试同样零读取")
    }

    /// 撤回期间的登出（世代已变）与对外的隔离账号 / 作用域 / 请求归属：屏障竖着，零令牌读取。
    func testBarrierBlocksSnapshotFreeReadsDuringWithdrawal() {
        let rig = makeRig()
        let generation = rig.client.sessionGeneration
        withdraw(rig)
        let readsAtWithdrawal = rig.store.reads
        XCTAssertEqual(rig.client.signOut(expectedGeneration: generation), .alreadyCleared)
        XCTAssertNil(rig.client.isolatedAccount)
        XCTAssertNil(rig.client.isolatedSessionScope)
        XCTAssertNil(rig.client.currentOwnership(credentialsReadable: true).account)
        rig.client.signOut()
        XCTAssertEqual(rig.store.reads, readsAtWithdrawal, "撤回期间零令牌读取")
    }

    /// 对照：撤回清理完成、之后的状态快照可读时屏障放下，同身份读取照常。
    func testBarrierLiftsAfterReadableSnapshot() async {
        let rig = makeRig()
        withdraw(rig)
        rig.store.inner.failClears = false
        rig.readable.value = true
        try? rig.store.inner.save(access: "access-2", refresh: "refresh-2", scope: "full", account: "account-B")
        XCTAssertNil(rig.client.isolatedAccount, "屏障放下之前不读")
        StubURLProtocol.install { _ in ok("{\"items\":[]}") }
        _ = await rig.client.send(ApiCall(operationId: "listOrders", query: "scope=self"))
        XCTAssertEqual(rig.client.isolatedAccount, "account-B", "可读快照之后照常读取")
    }

    // MARK: - 刷新完成后的读取

    /// 受限会话复查：刷新窗口结算、新令牌保存之后，复查读取作用域之前撤回同意 → 零读取，按已失效结束。
    func testRestrictedRecheckWithdrawalAfterRefreshReadsNoTokens() async {
        let rig = makeRig(scope: "deletion_only")
        StubURLProtocol.install { request in
            request.path == "/v1/auth/refresh" ? ok(refreshData(access: "access-2", scope: "full")) : ok()
        }
        let saved = Box<Bool>()
        rig.store.onSave = { saved.value = true }
        let fired = Box<Bool>()
        let readsAtWithdrawal = Box<Int>()
        let outcome = await rig.client.recheckRestrictedSession { [rig] in
            // 新令牌已保存（刷新完成）后的第一次有效性核对：在复查读取之前撤回
            if saved.value == true, fired.value != true {
                fired.value = Self.withdraw(rig)
                readsAtWithdrawal.value = rig.store.reads
            }
            return true
        }
        XCTAssertEqual(fired.value, true, "前提：撤回发生在刷新完成之后")
        XCTAssertEqual(StubURLProtocol.requests(path: "/v1/auth/refresh").count, 1, "前提：刷新确实发出并完成")
        XCTAssertEqual(outcome, .cancelled, "刷新完成后撤回：按已失效结束")
        XCTAssertEqual(rig.store.reads, readsAtWithdrawal.value, "刷新完成后撤回：零令牌读取")
    }

    /// 对照：没有撤回时复查照常读取作用域，刷新拿到 full。
    func testRestrictedRecheckWithoutWithdrawalStillReads() async {
        let rig = makeRig(scope: "deletion_only")
        StubURLProtocol.install { request in
            request.path == "/v1/auth/refresh" ? ok(refreshData(access: "access-2", scope: "full")) : ok()
        }
        let outcome = await rig.client.recheckRestrictedSession { true }
        XCTAssertEqual(outcome, .full)
    }
}
