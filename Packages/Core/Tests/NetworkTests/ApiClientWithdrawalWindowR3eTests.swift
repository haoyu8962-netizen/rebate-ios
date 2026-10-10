import Foundation
@testable import Network
import Session
import XCTest

/// APP-08 iOS 第五次修复 NEW-01（S0）：在途请求取得「凭据可读」的状态快照之后、管线继续之前，主线程完成撤回同意（作废世代推进、
/// 令牌删除失败、清理标记保留 = 不可读）。管线恢复后不得信任这份旧快照：可读性、作废世代 / 会话世代比较与令牌读取在同一把锁里、
/// 先比较再读取，撤回之后令牌存储读取次数为零、零发送。带固定归属（订单 / 购买请求）与不带（普通请求）两条路径都覆盖。
final class ApiClientWithdrawalWindowR3eTests: XCTestCase {
    /// 记读取次数的令牌存储（转给内存实现）。
    private final class CountingTokens: SessionTokens, @unchecked Sendable {
        let inner: MemorySessionTokens
        private let lock = NSLock()
        private var count = 0

        init(_ inner: MemorySessionTokens) {
            self.inner = inner
        }

        var reads: Int {
            lock.withLock { count }
        }

        func readSession() throws -> SessionSnapshot? {
            lock.withLock { count += 1 }
            return try inner.readSession()
        }

        func save(access: String, refresh: String, scope: String, account: String?) throws {
            try inner.save(access: access, refresh: refresh, scope: scope, account: account)
        }

        func clear() throws {
            try inner.clear()
        }
    }

    private struct Rig {
        let client: ApiClient
        let store: CountingTokens
        /// 撤回完成那一刻的读取次数（之后不得再增加）。
        let readsAtWithdrawal: Box<Int>
        let armed: Box<Bool>
    }

    /// `armed` 时：状态源先按「可读」取好快照，返回给管线之前完成一次撤回（推进作废世代、令牌删除失败、之后不可读），
    /// 模拟「快照返回后、管线继续前被撤回」。
    private func makeRig() -> Rig {
        let inner = MemorySessionTokens(access: "access-1", refresh: "refresh-1", scope: "full", account: "account-A")
        let store = CountingTokens(inner)
        let readable = Box<Bool>()
        readable.value = true
        let armed = Box<Bool>()
        let readsAtWithdrawal = Box<Int>()
        let clientBox = Box<ApiClient>()
        let client = ApiClient(
            identity: ClientIdentity(
                appId: "couli", platform: "ios", appVersion: "1.2.0", build: "120", channel: "app_store"
            ),
            context: {
                let snapshot = NetworkContext(
                    privacy: PrivacyRaw.full, environmentSettled: true, credentialsReadable: readable.value ?? false,
                    update: UpdateRaw.supported, apiBaseURL: URL(string: "https://api.test.couli.invalid")
                )
                if armed.value == true {
                    armed.value = false
                    // 撤回：标记先置（不可读）→ 网络层作废（同一把锁推进作废世代）→ 清令牌失败（残留令牌仍在）
                    readable.value = false
                    clientBox.value?.invalidateSessions()
                    inner.failClears = true
                    // 前提：令牌删除失败（残留令牌仍在）；失败时才记下撤回那一刻的读取次数
                    if (try? store.clear()) == nil {
                        readsAtWithdrawal.value = store.reads
                    }
                }
                return snapshot
            },
            device: TestDevice(),
            tokens: store,
            pendingKeys: PendingKeyStore(backend: MemoryPendingKeyBackend(), clock: { 0 }),
            configuration: StubURLProtocol.configuration(),
            clock: { 1_790_661_600_000 },
            sleeper: { _ in },
            nonce: { "b5a8f07b9dda63c3f78ed24c341d25b3" }
        )
        clientBox.value = client
        return Rig(client: client, store: store, readsAtWithdrawal: readsAtWithdrawal, armed: armed)
    }

    private func call() -> ApiCall {
        ApiCall(operationId: "listOrders", query: "scope=self")
    }

    /// 带固定归属：撤回发生在快照返回之后。先比较作废世代再读取 → 零读取、零发送（call_cancelled）。
    func testExpectedCallStaleReadableSnapshotReadsNoTokens() async {
        let rig = makeRig()
        StubURLProtocol.install { _ in ok("{\"items\":[]}") }
        let fixed = rig.client.currentOwnership(credentialsReadable: true)
        rig.armed.value = true
        let result = await rig.client.send(call(), isValid: { true }, sendAllowed: { true }, expected: fixed)
        XCTAssertEqual(result, .localReject(reason: LocalRejectReason.callCancelled))
        XCTAssertNotNil(rig.readsAtWithdrawal.value, "前提：撤回确实发生在快照之后")
        XCTAssertEqual(rig.store.reads, rig.readsAtWithdrawal.value, "撤回之后零令牌读取")
        XCTAssertTrue(StubURLProtocol.requests.isEmpty, "零发送")
    }

    /// 不带固定归属的普通请求：同样不信任旧快照（归属绑定、组请求都先在锁里核作废世代与快照世代），零读取、零发送。
    func testPlainCallStaleReadableSnapshotReadsNoTokens() async {
        let rig = makeRig()
        StubURLProtocol.install { _ in ok("{\"items\":[]}") }
        rig.armed.value = true
        let result = await rig.client.send(call())
        XCTAssertNotNil(rig.readsAtWithdrawal.value)
        XCTAssertEqual(rig.store.reads, rig.readsAtWithdrawal.value, "撤回之后零令牌读取")
        XCTAssertTrue(StubURLProtocol.requests.isEmpty, "零发送：\(result)")
    }

    /// 对照：没有撤回时照常带 A 的凭据发出（同身份正常路径不变）。
    func testWithoutWithdrawalStillSends() async {
        let rig = makeRig()
        StubURLProtocol.install { _ in ok("{\"items\":[]}") }
        let fixed = rig.client.currentOwnership(credentialsReadable: true)
        let result = await rig.client.send(call(), isValid: { true }, sendAllowed: { true }, expected: fixed)
        XCTAssertTrue(result.isSuccess, "\(result)")
        XCTAssertEqual(StubURLProtocol.requests.first?.header("Authorization"), "Bearer access-1")
        let plain = await rig.client.send(call())
        XCTAssertTrue(plain.isSuccess, "\(plain)")
    }
}
