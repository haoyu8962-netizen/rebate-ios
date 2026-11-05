import Config
@testable import Couli
import Foundation
import Generated
import XCTest

/// App target 的调试源码集（Debug / Staging 编译）。测试动作用 Debug。
@MainActor
final class DebugCapabilitiesTests: XCTestCase {
    func testProdKeepsOnlySwitchServer() {
        let capabilities = DebugCapabilities(environment: .prod)
        XCTAssertTrue(capabilities.isAvailable(.switchServer))
        for capability in DebugCapability.allCases where capability != .switchServer {
            XCTAssertFalse(capabilities.isAvailable(capability), "\(capability) must be off on prod")
        }
    }

    func testNonProdEnvironmentsKeepAllCapabilities() {
        for environment in AppEnvironment.selectable where environment != .prod {
            let capabilities = DebugCapabilities(environment: environment)
            for capability in DebugCapability.allCases {
                XCTAssertTrue(capabilities.isAvailable(capability), "\(capability) on \(environment.id)")
            }
        }
    }

    func testEveryEnvironmentUsesInvalidPlaceholderHosts() {
        XCTAssertEqual(AppEnvironment.selectable.map(\.id), ["local", "test", "staging", "prod"])
        for environment in AppEnvironment.selectable {
            for url in [environment.endpoints.apiBaseURL, environment.endpoints.h5BaseURL] {
                XCTAssertEqual(url.scheme, "https")
                // #24 test-change（FU-X-STAGING-HOSTS-ios）：staging 改连真实主机，只换这一行的期望；local / test / prod 原样
                if environment.id == "staging" {
                    XCTAssertTrue(["api-stg.couliapp.cn", "h5-stg.couliapp.cn"].contains(url.host ?? ""), "\(url)")
                } else {
                    XCTAssertTrue(url.host?.hasSuffix(".\(environment.id).couli.invalid") ?? false, "\(url)")
                }
            }
        }
    }

    /// App 侧 debug_only 表与包内（Debug 下）登记的 debug_only 路由一致。
    func testDebugOnlyRoutesMatchGeneratedTable() {
        XCTAssertEqual(DebugOnlyRoutes.all, Routes.all.filter(\.value.debugOnly))
        XCTAssertFalse(DebugOnlyRoutes.all.isEmpty)
        XCTAssertGreaterThan(DebugOnlyRoutes.tableMarker.utf8.count, 15)
    }
}

@MainActor
final class EnvironmentStoreTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() async throws {
        suiteName = "EnvironmentStoreTests.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
    }

    private func defaultCleaners(_ extra: [any EnvironmentSwitchCleaning] = []) -> EnvironmentSwitchCleanerRegistry {
        EnvironmentSwitchCleanerRegistry(cleaners: [UserDefaultsNamespaceCleaner(defaults: defaults)] + extra)
    }

    func testDefaultEnvironmentIsUsedWithoutStoredSelection() {
        let store = EnvironmentStore(defaultEnvironment: .staging, defaults: defaults, registry: .init())
        XCTAssertEqual(store.current, .staging)
        XCTAssertEqual(store.launchOutcome, .firstRecord)
    }

    func testSwitchRunsCleanersThenPersistsSelection() throws {
        let spy = SpyCleaner(name: "spy")
        defaults.set("token", forKey: AppNamespace.userDefaultsPrefix + "session.token")
        let store = EnvironmentStore(defaultEnvironment: .test, defaults: defaults, registry: defaultCleaners([spy]))
        XCTAssertEqual(spy.calls, 0, "first launch only records")

        try store.switchTo(.prod)

        XCTAssertEqual(spy.calls, 1)
        XCTAssertEqual(store.current, .prod)
        XCTAssertNil(defaults.object(forKey: AppNamespace.userDefaultsPrefix + "session.token"))
        XCTAssertFalse(store.debugCapabilities.isAvailable(.diagnostics))
        let reopened = EnvironmentStore(defaultEnvironment: .test, defaults: defaults, registry: defaultCleaners([spy]))
        XCTAssertEqual(reopened.current, .prod, "selection survives relaunch")
        XCTAssertEqual(reopened.launchOutcome, .unchanged)
        XCTAssertEqual(spy.calls, 1)
    }

    func testSwitchToSameEnvironmentDoesNotClean() throws {
        let spy = SpyCleaner(name: "spy")
        let store = EnvironmentStore(defaultEnvironment: .test, defaults: defaults, registry: .init(cleaners: [spy]))
        try store.switchTo(.test)
        XCTAssertEqual(spy.calls, 0)
    }

    // R1-08：已有选择 prod + 默认清理器 + 后续清理器失败 → 不切换；重建 store 仍是 prod。
    func testFailedCleanupKeepsStoredSelectionAcrossRelaunch() throws {
        let first = EnvironmentStore(defaultEnvironment: .test, defaults: defaults, registry: defaultCleaners())
        try first.switchTo(.prod)
        XCTAssertEqual(defaults.string(forKey: AppNamespace.environmentSelectionKey), "prod")

        let failing = SpyCleaner(name: "failing", fails: true)
        let store = EnvironmentStore(
            defaultEnvironment: .test,
            defaults: defaults,
            registry: defaultCleaners([failing])
        )
        XCTAssertEqual(store.current, .prod)
        XCTAssertThrowsError(try store.switchTo(.staging)) { error in
            XCTAssertEqual((error as? EnvironmentCleanupFailure)?.cleanerName, "failing")
        }
        XCTAssertEqual(store.current, .prod)

        let relaunched = EnvironmentStore(defaultEnvironment: .test, defaults: defaults, registry: defaultCleaners())
        XCTAssertEqual(relaunched.current, .prod, "selection must survive a failed cleanup")
        XCTAssertEqual(relaunched.launchOutcome, .unchanged)
        XCTAssertEqual(defaults.string(forKey: AppNamespace.appliedEnvironmentKey), "prod")
    }

    // X-01：Debug（默认 test，从未手动切换）被 Staging（默认 staging）覆盖安装 → 启动时先清理旧环境数据。
    func testOverInstallWithAnotherDefaultCleansBeforeRecording() {
        let debugBuild = EnvironmentStore(defaultEnvironment: .test, defaults: defaults, registry: defaultCleaners())
        XCTAssertEqual(debugBuild.launchOutcome, .firstRecord)
        XCTAssertNil(defaults.string(forKey: AppNamespace.environmentSelectionKey))
        defaults.set("token", forKey: AppNamespace.userDefaultsPrefix + "session.token")

        let spy = SpyCleaner(name: "spy")
        let stagingBuild = EnvironmentStore(
            defaultEnvironment: .staging,
            defaults: defaults,
            registry: defaultCleaners([spy])
        )

        XCTAssertEqual(stagingBuild.current, .staging)
        XCTAssertEqual(stagingBuild.launchOutcome, .cleaned(previous: "test"))
        XCTAssertEqual(spy.calls, 1)
        XCTAssertNil(defaults.object(forKey: AppNamespace.userDefaultsPrefix + "session.token"))
        XCTAssertEqual(defaults.string(forKey: AppNamespace.appliedEnvironmentKey), "staging")
    }

    // X-01 / R2-01：覆盖安装后清理失败一次 → 自动重试一次成功 → settled。
    func testLaunchCleanupFailingOnceIsRetriedAutomatically() {
        _ = EnvironmentStore(defaultEnvironment: .test, defaults: defaults, registry: defaultCleaners())
        let flaky = SpyCleaner(name: "flaky", failTimes: 1)

        let store = EnvironmentStore(
            defaultEnvironment: .staging,
            defaults: defaults,
            registry: defaultCleaners([flaky])
        )

        XCTAssertEqual(flaky.calls, 2)
        XCTAssertEqual(store.gate, .settled)
        XCTAssertEqual(store.launchOutcome, .cleaned(previous: "test"))
        XCTAssertEqual(defaults.string(forKey: AppNamespace.appliedEnvironmentKey), "staging")
    }

    // X-01 / R2-01：自动重试仍失败 → blocked，记录不变；阻断页重试失败仍 blocked、记录不变；重试成功 → settled 且记录更新。
    func testLaunchCleanupFailureBlocksUntilRetrySucceeds() {
        _ = EnvironmentStore(defaultEnvironment: .test, defaults: defaults, registry: defaultCleaners())
        let flaky = SpyCleaner(name: "flaky", failTimes: 3)

        let store = EnvironmentStore(
            defaultEnvironment: .staging,
            defaults: defaults,
            registry: defaultCleaners([flaky])
        )
        XCTAssertEqual(flaky.calls, 2, "one automatic retry")
        XCTAssertEqual(store.gate, .blocked)
        guard case .cleanupFailed(previous: "test", failures: _) = store.launchOutcome else {
            return XCTFail("expected cleanupFailed, got \(store.launchOutcome)")
        }
        XCTAssertEqual(defaults.string(forKey: AppNamespace.appliedEnvironmentKey), "test", "blocked keeps record")
        XCTAssertThrowsError(try store.switchTo(.prod)) { _ in }
        XCTAssertEqual(store.current, .staging)

        store.retryLaunchCleanup() // 第 3 次失败，自动再试第 4 次成功
        XCTAssertEqual(flaky.calls, 4)
        XCTAssertEqual(store.gate, .settled)
        XCTAssertEqual(defaults.string(forKey: AppNamespace.appliedEnvironmentKey), "staging")
    }

    func testRetryWhileStillFailingStaysBlockedWithRecordUnchanged() {
        _ = EnvironmentStore(defaultEnvironment: .test, defaults: defaults, registry: defaultCleaners())
        let broken = SpyCleaner(name: "broken", fails: true)
        let store = EnvironmentStore(
            defaultEnvironment: .staging,
            defaults: defaults,
            registry: defaultCleaners([broken])
        )
        store.retryLaunchCleanup()
        XCTAssertEqual(store.gate, .blocked)
        XCTAssertEqual(defaults.string(forKey: AppNamespace.appliedEnvironmentKey), "test")
    }
}

@MainActor
private final class SpyCleaner: EnvironmentSwitchCleaning {
    struct Failure: Error {}

    let cleanerName: String
    let fails: Bool
    /// 前若干次失败，之后成功。
    private var failTimes: Int
    private(set) var calls = 0

    init(name: String, fails: Bool = false, failTimes: Int = 0) {
        cleanerName = name
        self.fails = fails
        self.failTimes = failTimes
    }

    func cleanForEnvironmentSwitch() throws {
        calls += 1
        if fails {
            throw Failure()
        }
        if failTimes > 0 {
            failTimes -= 1
            throw Failure()
        }
    }
}
