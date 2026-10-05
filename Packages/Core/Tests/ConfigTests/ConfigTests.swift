@testable import Config
import Foundation
import Security
import XCTest

@MainActor
final class EnvironmentCleaningTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() async throws {
        suiteName = "ConfigTests.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
    }

    func testUserDefaultsCleanerRemovesOnlyAppNamespaceAndKeepsEnvironmentRecords() throws {
        defaults.set("token", forKey: AppNamespace.userDefaultsPrefix + "session.token")
        defaults.set(1, forKey: AppNamespace.userDefaultsPrefix + "lkg.version")
        defaults.set("keep", forKey: "other.namespace.key")
        defaults.set("prod", forKey: AppNamespace.environmentSelectionKey)
        defaults.set("prod", forKey: AppNamespace.appliedEnvironmentKey)

        try UserDefaultsNamespaceCleaner(defaults: defaults).cleanForEnvironmentSwitch()

        XCTAssertNil(defaults.object(forKey: AppNamespace.userDefaultsPrefix + "session.token"))
        XCTAssertNil(defaults.object(forKey: AppNamespace.userDefaultsPrefix + "lkg.version"))
        XCTAssertEqual(defaults.string(forKey: "other.namespace.key"), "keep")
        XCTAssertEqual(defaults.string(forKey: AppNamespace.environmentSelectionKey), "prod")
        XCTAssertEqual(defaults.string(forKey: AppNamespace.appliedEnvironmentKey), "prod")
    }

    func testRegistryRunsEveryCleanerAndReportsFailures() {
        let failing = SpyCleaner(name: "failing", fails: true)
        let other = SpyCleaner(name: "other")
        let registry = EnvironmentSwitchCleanerRegistry(cleaners: [failing])
        registry.register(other)
        XCTAssertEqual(registry.registeredNames, ["failing", "other"])

        let failures = registry.cleanAll()

        XCTAssertEqual(failures.map(\.cleanerName), ["failing"])
        XCTAssertEqual(other.calls, 1, "other cleaners still run")
    }

    // X-01：首次安装只记录、不清理。
    func testFirstLaunchRecordsWithoutCleaning() {
        let spy = SpyCleaner(name: "spy")
        let applier = EnvironmentApplier(defaults: defaults, registry: .init(cleaners: [spy]))

        XCTAssertEqual(applier.reconcileAtLaunch(environmentID: "test"), .firstRecord)
        XCTAssertEqual(spy.calls, 0)
        XCTAssertEqual(applier.appliedEnvironmentID, "test")

        XCTAssertEqual(applier.reconcileAtLaunch(environmentID: "test"), .unchanged)
        XCTAssertEqual(spy.calls, 0)
    }

    // X-01：覆盖安装后要用的环境与记录不同 → 先清理，全部成功才记录。
    func testLaunchWithDifferentEnvironmentCleansThenRecords() {
        defaults.set("test", forKey: AppNamespace.appliedEnvironmentKey)
        defaults.set("token", forKey: AppNamespace.userDefaultsPrefix + "session.token")
        let spy = SpyCleaner(name: "spy")
        let registry = EnvironmentSwitchCleanerRegistry(cleaners: [
            UserDefaultsNamespaceCleaner(defaults: defaults),
            spy,
        ])

        let outcome = EnvironmentApplier(defaults: defaults, registry: registry)
            .reconcileAtLaunch(environmentID: "staging")

        XCTAssertEqual(outcome, .cleaned(previous: "test"))
        XCTAssertEqual(spy.calls, 1)
        XCTAssertNil(defaults.object(forKey: AppNamespace.userDefaultsPrefix + "session.token"))
        XCTAssertEqual(defaults.string(forKey: AppNamespace.appliedEnvironmentKey), "staging")
    }

    // X-01：清理失败不记录，下次启动重试。
    func testLaunchCleanupFailureIsRetriedOnNextLaunch() {
        defaults.set("test", forKey: AppNamespace.appliedEnvironmentKey)
        let flaky = SpyCleaner(name: "flaky", fails: true)
        let registry = EnvironmentSwitchCleanerRegistry(cleaners: [
            UserDefaultsNamespaceCleaner(defaults: defaults),
            flaky,
        ])

        let first = EnvironmentApplier(defaults: defaults, registry: registry)
            .reconcileAtLaunch(environmentID: "staging")
        guard case let .cleanupFailed(previous, failures) = first else {
            return XCTFail("expected cleanupFailed, got \(first)")
        }
        XCTAssertEqual(previous, "test")
        XCTAssertEqual(failures.map(\.cleanerName), ["flaky"])
        XCTAssertEqual(defaults.string(forKey: AppNamespace.appliedEnvironmentKey), "test", "not recorded")

        flaky.fails = false
        let second = EnvironmentApplier(defaults: defaults, registry: registry)
            .reconcileAtLaunch(environmentID: "staging")
        XCTAssertEqual(second, .cleaned(previous: "test"))
        XCTAssertEqual(flaky.calls, 2)
        XCTAssertEqual(defaults.string(forKey: AppNamespace.appliedEnvironmentKey), "staging")
    }

    // R2-01：启动对账清理失败自动重试一次，仍失败 → blocked，记录不变。
    func testSettleAtLaunchRetriesOnceThenBlocks() {
        defaults.set("test", forKey: AppNamespace.appliedEnvironmentKey)
        let broken = SpyCleaner(name: "broken", fails: true)
        let applier = EnvironmentApplier(defaults: defaults, registry: .init(cleaners: [broken]))

        let (outcome, gate) = applier.settleAtLaunch(environmentID: "staging")

        XCTAssertEqual(gate, .blocked)
        XCTAssertEqual(broken.calls, 2)
        guard case .cleanupFailed = outcome else {
            return XCTFail("expected cleanupFailed, got \(outcome)")
        }
        XCTAssertEqual(defaults.string(forKey: AppNamespace.appliedEnvironmentKey), "test")
    }

    // R1-08：清理期间任何清理器误删环境记录键，也会恢复。
    func testApplyRestoresRecordKeysEvenIfACleanerDeletesThem() {
        defaults.set("prod", forKey: AppNamespace.environmentSelectionKey)
        defaults.set("prod", forKey: AppNamespace.appliedEnvironmentKey)
        let greedy = UserDefaultsNamespaceCleaner(defaults: defaults, preservedKeys: [])
        let failing = SpyCleaner(name: "failing", fails: true)
        let applier = EnvironmentApplier(defaults: defaults, registry: .init(cleaners: [greedy, failing]))

        XCTAssertThrowsError(try applier.apply(environmentID: "staging")) { error in
            XCTAssertEqual((error as? EnvironmentCleanupFailure)?.cleanerName, "failing")
        }
        XCTAssertEqual(defaults.string(forKey: AppNamespace.environmentSelectionKey), "prod")
        XCTAssertEqual(defaults.string(forKey: AppNamespace.appliedEnvironmentKey), "prod")
    }

    func testEndpointsParseLiterals() {
        let endpoints = EnvironmentEndpoints(api: "https://api.example.invalid", h5: "https://h5.example.invalid")
        XCTAssertEqual(endpoints.apiBaseURL.host, "api.example.invalid")
        XCTAssertEqual(endpoints.h5BaseURL.host, "h5.example.invalid")
    }

    func testKeychainCleanerDeletesItemsUnderService() throws {
        let service = "com.couli.app.tests.\(UUID().uuidString)"
        let add: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "account",
            kSecValueData as String: Data("secret".utf8),
        ]
        let addStatus = SecItemAdd(add as CFDictionary, nil)
        if addStatus == errSecMissingEntitlement {
            throw XCTSkip("Keychain unavailable in this test host（App 宿主的 BuildConfigurationTests 另测）")
        }
        XCTAssertEqual(addStatus, errSecSuccess)

        try KeychainServiceCleaner(service: service).cleanForEnvironmentSwitch()

        let lookup: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ]
        XCTAssertEqual(SecItemCopyMatching(lookup as CFDictionary, nil), errSecItemNotFound)
        // 再清一次（没有条目）也算成功。
        XCTAssertNoThrow(try KeychainServiceCleaner(service: service).cleanForEnvironmentSwitch())
    }
}

@MainActor
final class SpyCleaner: EnvironmentSwitchCleaning {
    struct Failure: Error {}

    let cleanerName: String
    var fails: Bool
    private(set) var calls = 0

    init(name: String, fails: Bool = false) {
        cleanerName = name
        self.fails = fails
    }

    func cleanForEnvironmentSwitch() throws {
        calls += 1
        if fails {
            throw Failure()
        }
    }
}
