import ClientCore
import Config
@testable import Couli
import CouliNetwork
import Foundation
import Privacy
import SecureStore
import Session
import XCTest

/// iOS 第 1 轮评审 R1-03（APP-03b 共性 23）：埋点队列的清理器在启动环境对账之前登记，覆盖安装换了环境时旧队列被清掉。
@MainActor
final class AppLaunchCleanupTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!
    private var directory: URL!

    override func setUpWithError() throws {
        suiteName = "AppLaunchCleanupTests.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(suiteName)
        AppStubProtocol.reset()
        AppStubProtocol.install { _ in
            .json(status: 200, body: "{\"code\":0,\"msg\":\"\",\"data\":{},\"trace_id\":\"t\"}")
        }
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: directory)
        AppStubProtocol.reset()
    }

    private final class IdleTicker: RepeatingTicker {
        func start(intervalMillis _: Int64, tick _: @escaping () -> Void) {}
        func stop() {}
    }

    private struct NoIdentifier: DeviceIdentifierReading {
        @MainActor
        func readIdentifier() -> String? {
            nil
        }
    }

    /// Staging 留下的埋点队列（含原子写的临时文件）。
    private func writeStagingQueue(_ file: ClientFile) throws {
        let event = try JSONSerialization.data(withJSONObject: [
            "name": "app_launch", "device_id": "device-staging", "user_id": "user-staging",
        ])
        let queue = try JSONSerialization.data(withJSONObject: [
            "v": 1, "events": [String(bytes: event, encoding: .utf8) ?? ""],
        ])
        try file.write(String(bytes: queue, encoding: .utf8) ?? "")
        try Data("partial".utf8).write(to: file.temporaryURL)
    }

    /// 冷启动：Staging 留有埋点队列 → 覆盖安装 Release（prod）→ 启动对账清掉旧队列（正式文件与临时文件）；
    /// 保留的同意状态下随后创建的 Tracker 不加载、不上报旧环境的事件。
    /// 已同意（隐私决定在切换环境时保留）的组件，与生产冷启动同样的形状，只换成本地注册表与假服务。
    private struct Parts {
        let withdrawal: EnvironmentSwitchCleanerRegistry
        let environmentSwitch: EnvironmentSwitchCleanerRegistry
        let privacyStore: MemoryPrivacyStore
        let runner: WithdrawalCleanupRunner
        let network: AppNetwork
    }

    private func makeParts() -> Parts {
        let tokens = MemorySessionTokens()
        let withdrawal = EnvironmentSwitchCleanerRegistry(cleaners: [SessionTokensCleaner(tokens: tokens)])
        let environmentSwitch = EnvironmentSwitchCleanerRegistry(cleaners: [SessionTokensCleaner(tokens: tokens)])
        let privacyStore = MemoryPrivacyStore()
        privacyStore.decisionRaw = "consented"
        privacyStore.consentedVersion = "1"
        let runner = WithdrawalCleanupRunner(store: privacyStore, registry: withdrawal)
        let network = AppNetwork(
            tokens: tokens,
            pendingBackend: MemoryPendingKeyBackend(),
            deviceStore: DeviceIdentityStore(store: MemorySecureStore()),
            identifierReader: NoIdentifier(),
            withdrawalRegistry: withdrawal,
            environmentRegistry: environmentSwitch,
            credentialsReadable: { runner.credentialsReadable },
            configuration: AppStubProtocol.configuration()
        )
        return Parts(
            withdrawal: withdrawal, environmentSwitch: environmentSwitch, privacyStore: privacyStore,
            runner: runner, network: network
        )
    }

    func testColdStartFromStagingToReleaseClearsOldTrackerQueue() throws {
        let parts = makeParts()
        let (withdrawal, environmentSwitch, runner) = (parts.withdrawal, parts.environmentSwitch, parts.runner)
        let file = ClientFile(name: AppTracker.fileName, baseDirectory: directory)
        try writeStagingQueue(file)
        defaults.set(AppEnvironment.staging.id, forKey: AppNamespace.appliedEnvironmentKey)

        let launch = AppLaunchCleanup.reconcile(
            trackerFile: file,
            withdrawalRegistry: withdrawal,
            environmentRegistry: environmentSwitch,
            retryWithdrawal: { runner.retryIfPending() },
            makeEnvironment: {
                EnvironmentStore(defaultEnvironment: .prod, defaults: defaults, registry: environmentSwitch)
            }
        )

        XCTAssertEqual(launch.environment.launchOutcome, .cleaned(previous: "staging"))
        XCTAssertEqual(launch.environment.gate, .settled)
        XCTAssertNil(try file.read(), "启动对账删掉旧环境的队列文件")
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.temporaryURL.path), "临时文件一并删掉")

        let privacy = PrivacyController(
            store: parts.privacyStore, clock: { 1 }, bundledPolicyVersion: "1", withdrawalRunner: runner,
            deviceRegistration: { done in done(true) }
        )
        let update = UpdateFixtures.makeUpdate(clock: { 1 })
        parts.network.attach(environment: launch.environment, privacy: privacy, update: update) {}
        var uploaded: [String] = []
        let tracker = AppTracker(
            privacy: privacy, update: update, network: parts.network, cleaner: launch.trackerCleaner,
            environmentReady: { launch.environment.gate == .settled }, credentialsReadable: { true },
            sink: { batch, _ in
                uploaded += batch
                return true
            },
            ticker: IdleTicker()
        )
        tracker.startIfReady()

        XCTAssertEqual(tracker.queue?.queueSize, 0, "不加载旧环境的队列")
        XCTAssertTrue(uploaded.isEmpty, "旧环境的事件不上报")
        XCTAssertTrue(environmentSwitch.registeredNames.contains(TrackerQueueCleaner.name))
        XCTAssertTrue(withdrawal.registeredNames.contains(TrackerQueueCleaner.name))
    }
}
