import ClientCore
import Config
@testable import Couli
import CouliNetwork
import Foundation
import Privacy
import Router
import SecureStore
import Session
import XCTest

/// APP-03b 的 App 接线：设备注册接进 PrivacyGate.onConsented 的第一步、撤回同意清掉设备凭据与埋点队列、
/// 三类清理项登记在真实注册表里。只用真实入口驱动（PrivacyController.agree / withdraw），全部对本地假服务。
@MainActor
final class AppClientCoreWiringTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!
    private var directory: URL!

    override func setUpWithError() throws {
        suiteName = "AppClientCoreWiringTests.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(suiteName)
        AppStubProtocol.reset()
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: directory)
        AppStubProtocol.reset()
    }

    private struct FixedReader: DeviceIdentifierReading {
        @MainActor
        func readIdentifier() -> String? {
            "E621E1F8-C36C-495A-93FC-0C247A3E6E5F"
        }
    }

    private final class IdleTicker: RepeatingTicker {
        func start(intervalMillis _: Int64, tick _: @escaping () -> Void) {}
        func stop() {}
    }

    private struct Fixture {
        let network: AppNetwork
        let privacy: PrivacyController
        let secure: MemorySecureStore
        let tracker: AppTracker
        let environment: EnvironmentStore
        let environmentChanges: EnvironmentChangeCounter
        let environmentRegistry: EnvironmentSwitchCleanerRegistry
        /// 网络状态源只弱引用 AppUpdate：测试组合要持有它（生产里由 CouliApp 的 @StateObject 持有）。
        let update: AppUpdate
    }

    final class EnvironmentChangeCounter {
        var count = 0
    }

    private func makeFixture(consented: Bool) -> Fixture {
        let tokens = MemorySessionTokens()
        let withdrawal = EnvironmentSwitchCleanerRegistry(cleaners: [SessionTokensCleaner(tokens: tokens)])
        let environmentSwitch = EnvironmentSwitchCleanerRegistry(cleaners: [SessionTokensCleaner(tokens: tokens)])
        let privacyStore = MemoryPrivacyStore()
        if consented {
            privacyStore.decisionRaw = "consented"
            privacyStore.consentedVersion = "1"
        }
        let runner = WithdrawalCleanupRunner(store: privacyStore, registry: withdrawal)
        let secure = MemorySecureStore()
        let network = AppNetwork(
            tokens: tokens,
            pendingBackend: MemoryPendingKeyBackend(),
            deviceStore: DeviceIdentityStore(store: secure),
            identifierReader: FixedReader(),
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
            withdrawalRunner: runner,
            deviceRegistration: { done in network.registerDevice(done: done) }
        )
        let update = UpdateFixtures.makeUpdate()
        let changes = EnvironmentChangeCounter()
        network.attach(environment: environment, privacy: privacy, update: update) {
            changes.count += 1
        }
        let tracker = makeTracker(
            privacy: privacy, update: update, network: network, environment: environment,
            readable: { runner.credentialsReadable }, registries: (withdrawal, environmentSwitch)
        )
        tracker.startIfReady()
        return Fixture(
            network: network, privacy: privacy, secure: secure, tracker: tracker,
            environment: environment, environmentChanges: changes, environmentRegistry: environmentSwitch,
            update: update
        )
    }

    // swiftlint:disable:next function_parameter_count
    private func makeTracker(
        privacy: PrivacyController,
        update: AppUpdate,
        network: AppNetwork,
        environment: EnvironmentStore,
        readable: @escaping @MainActor () -> Bool,
        registries: (withdrawal: EnvironmentSwitchCleanerRegistry, environmentSwitch: EnvironmentSwitchCleanerRegistry)
    ) -> AppTracker {
        AppTracker(
            privacy: privacy,
            update: update,
            network: network,
            environmentReady: { [weak environment] in
                environment.map { $0.gate == .settled && !$0.switching } ?? false
            },
            credentialsReadable: readable,
            file: ClientFile(name: AppTracker.fileName, baseDirectory: directory),
            withdrawalRegistry: registries.withdrawal,
            environmentRegistry: registries.environmentSwitch,
            sink: { _, _ in false },
            ticker: IdleTicker()
        )
    }

    private func installDeviceServer() {
        AppStubProtocol.install { request in
            guard request.path == "/v1/devices" else {
                return .json(status: 200, body: "{\"code\":0,\"msg\":\"\",\"data\":{},\"trace_id\":\"t\"}")
            }
            return .json(
                status: 200,
                body: "{\"code\":0,\"msg\":\"\",\"data\":{\"device_id\":\"device-app-1\","
                    + "\"install_secret\":\"test-only.install.app-1\"},\"trace_id\":\"t\"}"
            )
        }
    }

    private func waitForDevice(_ network: AppNetwork) async {
        for _ in 0..<400 where network.registry.deviceId == nil {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    /// 同意 → PrivacyGate.onConsented 第一步注册设备；撤回同意 → 设备凭据清掉（安全存储里也没有）。
    func testConsentRegistersDeviceAndWithdrawClearsCredentials() async throws {
        installDeviceServer()
        let fixture = makeFixture(consented: false)
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertTrue(AppStubProtocol.requests.filter { $0.path == "/v1/devices" }.isEmpty, "同意前不注册设备")

        fixture.privacy.agree()
        await waitForDevice(fixture.network)

        XCTAssertEqual(fixture.network.registry.deviceId, "device-app-1")
        XCTAssertEqual(AppStubProtocol.requests.filter { $0.path == "/v1/devices" }.count, 1)
        XCTAssertNotNil(try fixture.secure.data(forAccount: DeviceIdentityStore.account))

        fixture.privacy.withdraw()

        XCTAssertNil(fixture.network.registry.deviceId)
        XCTAssertNil(try fixture.secure.data(forAccount: DeviceIdentityStore.account))
    }

    /// 共性 5：切换环境提交完成后在新环境重新注册设备、重新拉配置（清理阶段删掉旧凭据）。
    func testEnvironmentSwitchReRegistersDeviceAfterCommit() async throws {
        installDeviceServer()
        let fixture = makeFixture(consented: true)
        await waitForDevice(fixture.network)
        XCTAssertEqual(AppStubProtocol.requests.filter { $0.path == "/v1/devices" }.count, 1)

        try fixture.environment.switchTo(.staging)
        XCTAssertNil(fixture.network.registry.deviceId, "清理阶段删掉旧环境的设备凭据")
        await waitForDevice(fixture.network)

        XCTAssertEqual(fixture.network.registry.deviceId, "device-app-1")
        XCTAssertEqual(AppStubProtocol.requests.filter { $0.path == "/v1/devices" }.count, 2, "新环境重新注册")
        XCTAssertEqual(fixture.environmentChanges.count, 1, "新环境提交后通知重新拉配置")
        XCTAssertEqual(fixture.environment.current.id, "staging")
    }

    /// 共性 10：切换环境一开始就关闭环境闸门；清理与提交期间网络状态源是「未就绪」，注册与请求都发不出；
    /// 切换前发出、之后才回来的注册结果不落盘（注册绑定清理世代）。
    func testEnvironmentGateClosedDuringSwitchAndLateRegistrationDropped() async throws {
        let fixture = makeFixture(consented: false)
        let probe = GateProbe(source: fixture.network.source, client: fixture.network.client)
        fixture.environmentRegistry.register(probe)
        AppStubProtocol.install { _ in .hold }
        fixture.privacy.agree()
        await AppStubProtocol.waitUntilHeld()

        let ticket = fixture.network.client.invalidationTicket
        try fixture.environment.switchTo(.staging)
        XCTAssertEqual(probe.settledDuringClean, false, "清理期间环境闸门已关闭")
        XCTAssertEqual(probe.ticketDuringClean.map { $0 > ticket }, true, "清理一开始（任何 await 之前）就作废了网络世代（共性 17）")
        XCTAssertTrue(fixture.network.source.snapshot().environmentSettled, "提交后重新放行")
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertNil(fixture.network.registry.deviceId, "旧环境的注册结果不带进新环境")
    }

    /// 共性 14：切换环境失败（清理器已删掉设备凭据，仍留在旧环境）后恢复设备注册与配置拉取。
    func testFailedEnvironmentSwitchRestoresRegistration() async throws {
        installDeviceServer()
        let fixture = makeFixture(consented: true)
        await waitForDevice(fixture.network)
        fixture.environmentRegistry.register(FailingCleaner())

        XCTAssertThrowsError(try fixture.environment.switchTo(.staging))
        XCTAssertNil(fixture.network.registry.deviceId, "设备凭据已在清理阶段删掉")
        await waitForDevice(fixture.network)

        XCTAssertEqual(fixture.environment.current.id, "test", "仍在旧环境")
        XCTAssertEqual(fixture.network.registry.deviceId, "device-app-1", "恢复设备注册")
        XCTAssertEqual(fixture.environmentChanges.count, 1, "恢复配置拉取")
    }

    /// 共性 15：埋点在冷启动流程里显式启动；环境未就绪前不读旧队列，启动后立即提交旧队列。
    func testTrackerStartsExplicitlyAndSubmitsOldQueue() throws {
        let file = ClientFile(name: AppTracker.fileName, baseDirectory: directory)
        let event = try JSONSerialization.data(withJSONObject: ["name": "app_launch", "device_id": "d"])
        let old = try JSONSerialization.data(withJSONObject: [
            "v": 1,
            "events": [String(bytes: event, encoding: .utf8) ?? ""],
        ])
        try file.write(String(bytes: old, encoding: .utf8) ?? "")
        let base = makeFixture(consented: true)
        var ready = false
        var uploaded: [String] = []
        let tracker = AppTracker(
            privacy: base.privacy, update: UpdateFixtures.makeUpdate(clock: { 1 }), network: base.network,
            environmentReady: { ready }, credentialsReadable: { true }, file: file,
            withdrawalRegistry: EnvironmentSwitchCleanerRegistry(),
            environmentRegistry: EnvironmentSwitchCleanerRegistry(),
            sink: { batch, _ in
                uploaded += batch
                return true
            },
            ticker: IdleTicker()
        )
        tracker.startIfReady()
        XCTAssertNil(tracker.queue, "环境未就绪：不创建队列、不读旧文件")
        ready = true
        tracker.startIfReady()
        XCTAssertNotNil(tracker.queue)
        XCTAssertEqual((tracker.queue?.queueSize ?? 0) + uploaded.count, 1, "旧队列被读回（能上报时立即提交）")
    }

    /// 验收：撤回同意后埋点队列被清空，且不再采集。
    func testWithdrawThroughPrivacyControllerClearsTrackerQueue() {
        let fixture = makeFixture(consented: true)
        XCTAssertTrue(fixture.tracker.track(ClientEvents.appLaunch(page: "Home")))
        XCTAssertEqual(fixture.tracker.queue?.queueSize, 1)

        fixture.privacy.withdraw()

        XCTAssertEqual(fixture.tracker.queue?.queueSize, 0)
        XCTAssertFalse(fixture.tracker.track(ClientEvents.appLaunch(page: "Home")), "基本模式不采集")
        let file = ClientFile(name: AppTracker.fileName, baseDirectory: directory)
        XCTAssertNil(try file.read(), "持久化的队列一并清掉")
    }

    /// 生产组合（宿主 App 启动时已创建）：设备、埋点、LKG 的清理项登记在真实注册表里；撤回同意不清 LKG。
    func testProductionRegistriesCarryClientCoreCleaners() {
        let withdrawal = PrivacyWithdrawalCleanup.registry.registeredNames
        let environmentSwitch = EnvironmentSwitchCleanerRegistry.shared.registeredNames
        XCTAssertTrue(withdrawal.contains("DeviceIdentity"))
        XCTAssertTrue(withdrawal.contains(TrackerQueueCleaner.name))
        XCTAssertFalse(withdrawal.contains(ConfigLKGCleaner.name), "撤回同意不清配置")
        XCTAssertTrue(environmentSwitch.contains("DeviceIdentity"))
        XCTAssertTrue(environmentSwitch.contains(TrackerQueueCleaner.name))
        XCTAssertTrue(environmentSwitch.contains(ConfigLKGCleaner.name), "切换环境清 LKG（03 §3.6）")
        XCTAssertEqual(withdrawal.filter { $0 == "DeviceIdentity" }.count, 1, "替换同名占位，不重复登记")
    }

    func testTrackerUploadsOnlyWithKnownUpdateResult() {
        XCTAssertFalse(AppTracker.updateKnown(.checking(startedAt: 0)))
        XCTAssertFalse(AppTracker.updateKnown(.finished(.unknown)))
        XCTAssertTrue(AppTracker.updateKnown(.finished(.ok)))
        XCTAssertTrue(AppTracker.updateKnown(.finished(.belowMin)))
    }
}

/// 在切换环境的清理阶段记录网络状态源是否放行。
@MainActor
private final class GateProbe: EnvironmentSwitchCleaning {
    let cleanerName = "GateProbe"
    private let source: NetworkContextSource
    private let client: ApiClient
    private(set) var settledDuringClean: Bool?
    private(set) var ticketDuringClean: UInt64?

    init(source: NetworkContextSource, client: ApiClient) {
        self.source = source
        self.client = client
    }

    func cleanForEnvironmentSwitch() throws {
        settledDuringClean = source.snapshot().environmentSettled
        ticketDuringClean = client.invalidationTicket
    }
}

/// 清理失败的清理项（模拟切换环境失败）。
@MainActor
private final class FailingCleaner: EnvironmentSwitchCleaning {
    struct Failure: Error {}

    let cleanerName = "Failing"

    func cleanForEnvironmentSwitch() throws {
        throw Failure()
    }
}

/// R2-03：生产空实现 sink（TODO(N-20)）明确结束票据，定时重试多次失败后票据数不增长。
final class AppTrackerProductionSinkTests: XCTestCase {
    func testProductionSinkFinishesTicketsOnRepeatedFailures() {
        var text: String?
        let queue = TrackerQueue(
            readFile: { text }, writeFile: { text = $0 }, sink: { _ in false }, privacy: TrackerQueue.consented,
            userId: { nil }, currentDeviceId: { "device-t" }, platform: "ios", appVersion: "1.2.0",
            channel: "appstore", sessionId: "session-t", clock: { 1_790_661_600_000 }, canUpload: { true },
            ticketedSink: AppTracker.productionSink
        )
        XCTAssertTrue(queue.track(event: ClientEvents.appLaunch(page: "Home")))

        for _ in 0..<5 {
            queue.flush()
        }

        XCTAssertEqual(queue.outstandingTickets, 0)
        XCTAssertEqual(queue.queueSize, 1, "空实现不冒充已上报")
    }
}
