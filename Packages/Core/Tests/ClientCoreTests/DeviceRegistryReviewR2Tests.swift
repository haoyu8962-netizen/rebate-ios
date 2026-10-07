import ClientCore
import CouliNetwork
import Foundation
import SecureStore
import Session
import XCTest

/// iOS 第 2 轮评审 R2-01、R2-02（APP-03b 共性 24、25）：注册 flight 绑定清理世代；每次有效世代的 10402 都隔离凭据。
final class DeviceRegistryReviewR2Tests: XCTestCase {
    override func setUp() {
        CoreStubProtocol.install { _ in .error(.cannotConnectToHost) }
    }

    private func installRegistrations(
        _ counter: Counter,
        otherwise: @escaping (CoreStubProtocol.Recorded) -> CoreStubProtocol.Reply
    ) {
        CoreStubProtocol.install { request in
            guard request.path == ClientCoreFixtures.devicesPath else {
                return otherwise(request)
            }
            let index = counter.next()
            return coreOK(ClientCoreFixtures.registered("device-\(index)", "test-only.install.n\(index)"))
        }
    }

    // MARK: - R2-01

    /// R2-01：旧环境的注册已把凭据存好、但 flight 还没结算时切换环境（清理）。新环境的注册不得并入旧 flight，
    /// 旧 flight 的成功也不得交给任何人：旧调用按「已取消」结束，新环境真正发出注册并拿到自己的凭据。
    func testCleanupAfterSaveBeforeSettlementDoesNotLeakOldFlight() async throws {
        let secure = MemorySecureStore()
        let pause = SavedCredentialPause(secure)
        let fixture = makeDeviceFixture(secure: secure, registryContext: { state in await pause.read(state) })
        let counter = Counter()
        installRegistrations(counter) { _ in coreOK() }
        let registry = fixture.registry

        let old = Task { await registry.registerIfNeeded() }
        try await completes(within: 5) { await pause.waitUntilPaused() }
        XCTAssertEqual(registry.deviceId, "device-1", "旧环境的凭据已保存，flight 尚未结算")

        try registry.invalidateAndClear()
        XCTAssertNil(registry.deviceId)
        let fresh = try await completes(within: 5) { await registry.registerIfNeeded() }
        pause.resume()
        let stale = try await completes(within: 5) { await old.value }

        XCTAssertEqual(fresh, .registered, "新环境不并入旧 flight，自己注册")
        XCTAssertEqual(stale, .cancelled, "清理后旧 flight 的结果按已取消交付")
        XCTAssertEqual(registry.deviceId, "device-2")
        XCTAssertEqual(CoreStubProtocol.requests(path: ClientCoreFixtures.devicesPath).count, 2)
    }

    /// R2-01：清理时摘掉旧 flight，旧等待者立即按「已取消」结算（不等旧请求结束）；旧请求晚到的成功不落盘。
    func testCleanupSettlesDetachedWaitersAsCancelled() async throws {
        let fixture = makeDeviceFixture()
        CoreStubProtocol.install { _ in .hold }
        let registry = fixture.registry

        let old = Task { await registry.registerIfNeeded() }
        await CoreStubProtocol.waitUntilHeld()
        try registry.invalidateAndClear()
        let outcome = try await completes(within: 5) { await old.value }

        XCTAssertEqual(outcome, .cancelled)
        CoreStubProtocol.release(with: coreOK(ClientCoreFixtures.registered("device-1", "test-only.install.n1")))
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertNil(registry.deviceId, "旧世代晚到的成功不落盘")
    }

    // MARK: - R2-02

    /// R2-02：普通请求首次 10402 → 重新注册得到 device-2 → 重放再次收到 10402。预算用完，原调用结束；device-2 也被
    /// 隔离（凭据不可读，registerIfNeeded 不当作已注册），并只交给退避链一次。
    func testReplayRejectedAgainQuarantinesReplacementCredentials() async throws {
        let fixture = makeDeviceFixture()
        let counter = Counter()
        let notified = Counter()
        fixture.registry.onNeedsRegistration = { _ = notified.next() }
        installRegistrations(counter) { _ in coreFail(10402) }
        let registry = fixture.registry
        let first = await registry.registerIfNeeded()
        XCTAssertEqual(first, .registered)

        let client = fixture.client
        let result = try await completes(within: 5) {
            await client.send(ApiCall(operationId: "openLink", pathParams: ["link_id": "a"]))
        }

        XCTAssertFalse(result.isSuccessResult)
        let replays = CoreStubProtocol.requests.filter { $0.path != ClientCoreFixtures.devicesPath }
        XCTAssertEqual(replays.map { $0.header("X-Device-Id") }, ["device-1", "device-2"], "只重放 1 次")
        XCTAssertNil(registry.credentials, "重放再次被拒的凭据不可读")
        XCTAssertNil(registry.deviceId)
        XCTAssertEqual(notified.next(), 2, "后续恢复只交给退避链一次")
        let recovery = await registry.registerIfNeeded()
        XCTAssertEqual(recovery, .registered, "被拒的凭据不算已注册，退避链重新注册")
        XCTAssertEqual(registry.deviceId, "device-3")
    }

    /// R2-02：刷新使用 device-1 收到 10402 → 重新注册得到 device-2 → 刷新重放仍收到 10402。刷新按暂时失败结束、
    /// 不清会话；device-2 被隔离，并交给退避链。
    func testRefreshReplayRejectedAgainQuarantinesReplacementCredentials() async throws {
        let tokens = MemorySessionTokens(access: "access-1", refresh: "refresh-1", scope: "full", account: "account-A")
        let fixture = makeDeviceFixture(tokens: tokens)
        let counter = Counter()
        let notified = Counter()
        fixture.registry.onNeedsRegistration = { _ = notified.next() }
        installRegistrations(counter) { request in
            request.path == "/v1/auth/refresh" ? coreFail(10402) : coreFail(10002, status: 401)
        }
        let registry = fixture.registry
        let first = await registry.registerIfNeeded()
        XCTAssertEqual(first, .registered)

        let client = fixture.client
        let result = try await completes(within: 5) { await client.send(ApiCall(operationId: "getMe")) }

        XCTAssertFalse(result.isSuccessResult)
        let refreshes = CoreStubProtocol.requests(path: "/v1/auth/refresh")
        XCTAssertEqual(refreshes.map { $0.header("X-Device-Id") }, ["device-1", "device-2"], "刷新只重放 1 次")
        XCTAssertNil(registry.credentials, "刷新重放再次被拒的凭据不可读")
        XCTAssertEqual(notified.next(), 2, "后续恢复只交给退避链一次")
        XCTAssertEqual(tokens.accessToken, "access-1", "设备被拒不是刷新被拒，不清会话")
        let recovery = await registry.registerIfNeeded()
        XCTAssertEqual(recovery, .registered)
        XCTAssertEqual(registry.deviceId, "device-3")
    }
}

/// 凭据已写进安全存储之后的第一次放行检查暂停一次（停在注册 flight 结算之前）。
final class SavedCredentialPause: @unchecked Sendable {
    private let secure: MemorySecureStore
    private let pause = PausingContext()
    private let lock = NSLock()
    private var used = false

    init(_ secure: MemorySecureStore) {
        self.secure = secure
    }

    func read(_ state: CoreTestState) async -> NetworkContext {
        let saved = ((try? secure.data(forAccount: DeviceIdentityStore.account)) ?? nil) != nil
        let arm: Bool = lock.withLock {
            guard saved, !used else {
                return false
            }
            used = true
            return true
        }
        if arm {
            pause.pauseNextRead()
        }
        return await pause.read(state)
    }

    func waitUntilPaused() async {
        await pause.waitUntilPaused()
    }

    func resume() {
        pause.resume()
    }
}
