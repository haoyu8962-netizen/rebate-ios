import Config
@testable import Couli
import CouliNetwork
import Foundation
import Privacy
import Router
import Session
import Update
import XCTest

/// APP-03a iOS 第 1 轮评审 R1-01、R1-06：网络核心在 App 真实组合处的接线（AppNetwork）。
/// 只用真实入口驱动：撤回同意走 PrivacyController.withdraw，强更状态变化走 AppUpdate 的检查结果；不直接调
/// ApiClient 的通知方法。全部对本地 URLProtocol 假服务，基址是 .invalid。
@MainActor
final class AppNetworkWiringTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        suiteName = "AppNetworkWiringTests.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        AppStubProtocol.reset()
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        AppStubProtocol.reset()
    }

    private struct Device: DeviceCredentials {
        var deviceId: String? = "device-fixture"
        var installSecret: String? = "test-only.install.device-a"
    }

    private struct Fixture {
        let network: AppNetwork
        let privacy: PrivacyController
        let update: AppUpdate
        let routing: AppRouting
        let withdrawal: EnvironmentSwitchCleanerRegistry
        let environmentSwitch: EnvironmentSwitchCleanerRegistry
    }

    private func consentedStore() -> MemoryPrivacyStore {
        let store = MemoryPrivacyStore()
        store.decisionRaw = "consented"
        store.consentedVersion = "1"
        return store
    }

    private func makeFixture(tokens: MemorySessionTokens, update: AppUpdate) -> Fixture {
        let withdrawal = EnvironmentSwitchCleanerRegistry(cleaners: [SessionTokensCleaner(tokens: tokens)])
        let environmentSwitch = EnvironmentSwitchCleanerRegistry(cleaners: [SessionTokensCleaner(tokens: tokens)])
        let privacyStore = consentedStore()
        let runner = WithdrawalCleanupRunner(store: privacyStore, registry: withdrawal)
        let network = AppNetwork(
            tokens: tokens,
            pendingBackend: MemoryPendingKeyBackend(),
            device: Device(),
            withdrawalRegistry: withdrawal,
            environmentRegistry: environmentSwitch,
            credentialsReadable: { runner.credentialsReadable },
            configuration: AppStubProtocol.configuration()
        )
        let environment = EnvironmentStore(defaultEnvironment: .test, defaults: defaults, registry: environmentSwitch)
        let privacy = PrivacyController(
            store: privacyStore,
            clock: { 1 },
            bundledPolicyVersion: "1",
            withdrawalRunner: runner
        )
        network.attach(environment: environment, privacy: privacy, update: update)
        let routing = AppRouting(environment: environment, privacy: privacy, update: update)
        return Fixture(
            network: network, privacy: privacy, update: update, routing: routing,
            withdrawal: withdrawal, environmentSwitch: environmentSwitch
        )
    }

    // MARK: - R1-01

    /// 创建时就登记在两个真实注册表的第一位（先于清令牌）。
    func testInvalidationCleanerIsFirstInBothRegistries() {
        let tokens = MemorySessionTokens(access: "access-1", refresh: "refresh-1", scope: "full", account: "account-A")
        let fixture = makeFixture(tokens: tokens, update: UpdateFixtures.makeUpdate())
        // APP-03b：设备凭据的清理项（DeviceRegistryCleaner）追加在后面。
        let expected = [NetworkInvalidationCleaner.name, SessionTokensCleaner.name, "DeviceIdentity"]
        XCTAssertEqual(fixture.withdrawal.registeredNames, expected)
        XCTAssertEqual(fixture.environmentSwitch.registeredNames, expected)
    }

    /// 生产组合：CouliApp 用的共享注册表里同样排在第一位（宿主 App 启动时已创建过 AppNetwork）。
    func testProductionRegistriesHaveInvalidationCleanerFirst() {
        XCTAssertEqual(PrivacyWithdrawalCleanup.registry.registeredNames.first, NetworkInvalidationCleaner.name)
        XCTAssertEqual(EnvironmentSwitchCleanerRegistry.shared.registeredNames.first, NetworkInvalidationCleaner.name)
    }

    /// 请求已带上 Authorization、还在等连接 → 用户经 PrivacyController 撤回同意 → 在途任务被取消，旧凭据不再写出，
    /// 也不重试。
    func testWithdrawThroughPrivacyControllerCancelsRequestWaitingForConnection() async {
        let tokens = MemorySessionTokens(access: "access-1", refresh: "refresh-1", scope: "full", account: "account-A")
        let fixture = makeFixture(tokens: tokens, update: UpdateFixtures.makeUpdate())
        AppStubProtocol.install { _ in .hold }
        let client = fixture.network.client
        let call = Task { await client.send(ApiCall(operationId: "getMe")) }
        await AppStubProtocol.waitUntilHeld()
        XCTAssertEqual(AppStubProtocol.requests.first?.header("Authorization"), "Bearer access-1")

        fixture.privacy.withdraw()

        let result = await call.value
        // URLSession 取消任务后会异步调用协议的 stopLoading。
        for _ in 0..<200 where !AppStubProtocol.wasCancelled {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertTrue(AppStubProtocol.wasCancelled, "等连接的请求被取消")
        if case .success = result {
            XCTFail("撤回同意后的在途请求不得成功")
        }
        if case let .transportFailure(kind, _, _, _) = result {
            XCTAssertEqual(kind, "cancelled")
        } else {
            XCTAssertEqual(result.notSentReason, LocalRejectReason.callCancelled, "\(result)")
        }
        XCTAssertEqual(AppStubProtocol.requests.count, 1, "不重试")
        XCTAssertNil(tokens.accessToken, "随后清了令牌")
        XCTAssertEqual(fixture.privacy.routerPrivacy, .basicMode)

        // 之后的请求按基本模式：不带凭据，非白名单本地拒绝。
        let after = await client.send(ApiCall(operationId: "getMe"))
        XCTAssertEqual(after.notSentReason, LocalRejectReason.basicModeDenied)
    }

    // MARK: - R1-06

    /// AppUpdate 从 below_min 经真实检查结果恢复为 ok → ApiClient 收到状态变化，存储的 deletion_only 会话立即刷新
    /// （不依附任何请求）。
    func testAppUpdateRecoveryTriggersRestrictedRefresh() async {
        let tokens = MemorySessionTokens(
            access: "access-1", refresh: "refresh-1", scope: SessionScope.deletionOnly, account: "account-A"
        )
        let checker = StubUpdateChecker(nil)
        let record = UpdateRecord(lastResult: UpdateFixtures.force, lastSuccessAt: 1)
        let update = UpdateFixtures.makeUpdate(checker: checker, store: MemoryUpdateStore(record: record))
        let refreshed = expectation(description: "refresh")
        let refreshBody = Self.refreshEnvelope
        AppStubProtocol.install { request in
            if request.path == "/v1/auth/refresh" {
                refreshed.fulfill()
                return .json(status: 200, body: refreshBody)
            }
            return .json(status: 200, body: "{\"code\":0,\"msg\":\"\",\"data\":{},\"trace_id\":\"t\"}")
        }
        let fixture = makeFixture(tokens: tokens, update: update)
        XCTAssertEqual(fixture.update.routerStatus, .finished(.belowMin))
        XCTAssertEqual(checker.calls, 1, "冷启动检查已发出")
        // 等一会儿：强更期间不刷新。
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertTrue(AppStubProtocol.requests.isEmpty)

        checker.deliver(.success(UpdateFixtures.ok))
        XCTAssertEqual(fixture.update.routerStatus, .finished(.ok))
        await fulfillment(of: [refreshed], timeout: 5)
        XCTAssertEqual(AppStubProtocol.requests.map(\.path), ["/v1/auth/refresh"], "不依附任何请求")
        for _ in 0..<200 where tokens.accessToken != "access-2" {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertEqual(tokens.accessToken, "access-2")
        XCTAssertEqual(tokens.scope, "full")
    }

    /// 确需强更的 10405 → NetworkHooks.onForceUpdate → AppUpdate.on10405：进入 below_min、强更页。
    func testForceUpdate10405ReachesAppUpdate() async {
        let tokens = MemorySessionTokens(access: "access-1", refresh: "refresh-1", scope: "full", account: "account-A")
        let fixture = makeFixture(tokens: tokens, update: UpdateFixtures.makeUpdate())
        XCTAssertEqual(fixture.update.routerStatus, .finished(.ok))
        AppStubProtocol.install { _ in
            .json(
                status: 403,
                body: "{\"code\":10405,\"msg\":\"\",\"data\":{\"min_supported_version\":\"99.0.0\"},\"trace_id\":\"t\"}"
            )
        }
        let result = await fixture.network.client.send(ApiCall(operationId: "getMe"))
        guard case let .failure(code, _, _, _, effect, _) = result else {
            return XCTFail("\(result)")
        }
        XCTAssertEqual(code, 10405)
        XCTAssertEqual(effect.kind, ErrorEffectKind.forceUpdate)
        XCTAssertEqual(fixture.update.routerStatus, .finished(.belowMin))
        XCTAssertEqual(fixture.routing.router.path.map(\.route), [RoutePolicy.forceUpdate])
    }

    private static let refreshEnvelope = "{\"code\":0,\"msg\":\"\",\"data\":{\"access_token\":\"access-2\","
        + "\"access_expires_at\":\"2026-10-02T13:30:00+08:00\",\"refresh_token\":\"refresh-2\","
        + "\"refresh_expires_at\":\"2026-11-01T11:30:00+08:00\",\"session_scope\":\"full\"},\"trace_id\":\"t\"}"
}

/// App 测试用的本地假服务：按处理函数回应；`.hold` 的请求一直不回（模拟还在等连接 / TLS），被取消时记下。
final class AppStubProtocol: URLProtocol, @unchecked Sendable {
    enum Reply {
        case json(status: Int, body: String)
        /// 带响应头（如 Date）的回应。
        case jsonHeaders(status: Int, headers: [String: String], body: String)
        case hold
    }

    struct Recorded {
        let path: String
        let headers: [String: String]

        func header(_ name: String) -> String? {
            headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
        }
    }

    private static let lock = NSLock()
    private nonisolated(unsafe) static var handler: ((Recorded) -> Reply)?
    private nonisolated(unsafe) static var recorded: [Recorded] = []
    private nonisolated(unsafe) static var heldCount = 0
    private nonisolated(unsafe) static var cancelled = false
    private nonisolated(unsafe) static var heldWaiters: [CheckedContinuation<Void, Never>] = []
    private var isHeld = false

    static func configuration() -> URLSessionConfiguration {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [AppStubProtocol.self]
        return config
    }

    static func reset() {
        lock.withLock {
            handler = nil
            recorded = []
            heldCount = 0
            cancelled = false
            heldWaiters = []
        }
    }

    static func install(_ handler: @escaping (Recorded) -> Reply) {
        lock.withLock { self.handler = handler }
    }

    static var requests: [Recorded] {
        lock.withLock { recorded }
    }

    static var wasCancelled: Bool {
        lock.withLock { cancelled }
    }

    static func waitUntilHeld() async {
        await withCheckedContinuation { continuation in
            let ready: Bool = lock.withLock {
                if heldCount > 0 {
                    return true
                }
                heldWaiters.append(continuation)
                return false
            }
            if ready {
                continuation.resume()
            }
        }
    }

    override static func canInit(with _: URLRequest) -> Bool {
        true
    }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let url = request.url ?? URL(fileURLWithPath: "/")
        let entry = Recorded(path: url.path(percentEncoded: true), headers: request.allHTTPHeaderFields ?? [:])
        let reply: Reply = Self.lock.withLock {
            Self.recorded.append(entry)
            return Self.handler?(entry) ?? .json(status: 502, body: "")
        }
        switch reply {
        case .hold:
            isHeld = true
            let waiters: [CheckedContinuation<Void, Never>] = Self.lock.withLock {
                Self.heldCount += 1
                defer { Self.heldWaiters = [] }
                return Self.heldWaiters
            }
            waiters.forEach { $0.resume() }
        case let .json(status, body):
            deliver(url, status: status, headers: [:], body: body)
        case let .jsonHeaders(status, headers, body):
            deliver(url, status: status, headers: headers, body: body)
        }
    }

    private func deliver(_ url: URL, status: Int, headers: [String: String], body: String) {
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)
        client?.urlProtocol(self, didReceive: response ?? URLResponse(), cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {
        if isHeld {
            Self.lock.withLock { Self.cancelled = true }
        }
    }
}
