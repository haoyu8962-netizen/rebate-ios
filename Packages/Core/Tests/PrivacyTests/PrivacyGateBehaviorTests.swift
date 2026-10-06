import Config
import Foundation
import XCTest
@testable import Privacy

/// 向量之外的实现约束（APP-02b）：持久化键、切换环境不删隐私决定、撤回后旧重试作废、退避上限、损坏记录的保守处理。
@MainActor
final class PrivacyGateBehaviorTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName = ""

    override func setUp() {
        suiteName = "privacy.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
    }

    private final class ManualScheduler: RetryScheduler {
        var jobs: [(Int64, () -> Void)] = []

        func schedule(delayMillis: Int64, action: @escaping () -> Void) {
            jobs.append((delayMillis, action))
        }

        func runAll() {
            let current = jobs
            jobs = []
            current.forEach { $0.1() }
        }
    }

    func testUserDefaultsStoreRoundTripUsesNamespaceKeys() {
        let store = UserDefaultsPrivacyStore(defaults: defaults)
        XCTAssertEqual(store.decisionRaw, "not_decided")
        let gate = PrivacyGate(store: store, clock: { 0 }, bundledPolicyVersion: "3")
        gate.agree(now: 1234)

        let record = defaults.dictionary(forKey: AppNamespace.privacyRecordKey)
        XCTAssertEqual(record?["decision"] as? String, "consented")
        XCTAssertEqual(record?["consented_version"] as? String, "3")
        XCTAssertEqual((record?["consented_at_ms"] as? NSNumber)?.int64Value, 1234)
        XCTAssertEqual(record?["basic_mode"] as? Bool, false)
        XCTAssertEqual(AppNamespace.privacyDecisionKeys, [AppNamespace.privacyRecordKey], "隐私决定只有一条记录")
        for key in AppNamespace.privacyDecisionKeys {
            XCTAssertTrue(key.hasPrefix(AppNamespace.userDefaultsPrefix), key)
        }

        let reopened = PrivacyGate(store: UserDefaultsPrivacyStore(defaults: defaults), clock: { 0 },
                                   bundledPolicyVersion: "3")
        XCTAssertEqual(reopened.state(now: 0).decision, .consented)
        XCTAssertFalse(reopened.state(now: 0).mustPrompt)
    }

    func testEnvironmentSwitchKeepsPrivacyDecision() throws {
        let store = UserDefaultsPrivacyStore(defaults: defaults)
        store.decisionRaw = "basic_mode"
        store.basicMode = true
        defaults.set("x", forKey: AppNamespace.userDefaultsPrefix + "router.pending_action")
        defaults.set("test", forKey: AppNamespace.appliedEnvironmentKey)

        let registry = EnvironmentSwitchCleanerRegistry(cleaners: [UserDefaultsNamespaceCleaner(defaults: defaults)])
        try EnvironmentApplier(defaults: defaults, registry: registry).apply(environmentID: "staging")

        XCTAssertEqual(store.decisionRaw, "basic_mode")
        XCTAssertTrue(store.basicMode)
        XCTAssertNil(defaults.string(forKey: AppNamespace.userDefaultsPrefix + "router.pending_action"))
    }

    func testEnvironmentSwitchRestoresPrivacyDecisionEvenIfACleanerDeletesIt() throws {
        let store = UserDefaultsPrivacyStore(defaults: defaults)
        store.decisionRaw = "consented"
        store.consentedVersion = "7"
        store.consentedAtMillis = 99
        let greedy = UserDefaultsNamespaceCleaner(defaults: defaults, preservedKeys: [])
        try EnvironmentApplier(defaults: defaults, registry: .init(cleaners: [greedy])).apply(environmentID: "prod")
        XCTAssertEqual(store.decisionRaw, "consented")
        XCTAssertEqual(store.consentedVersion, "7")
        XCTAssertEqual(store.consentedAtMillis, 99)
    }

    func testWithdrawalRegistryHasCredentialPlaceholders() {
        XCTAssertEqual(PrivacyWithdrawalCleanup.registry.registeredNames, ["SessionTokens", "DeviceIdentity"])
        let target = EnvironmentSwitchCleanerRegistry(cleaners: [])
        PrivacyWithdrawalCleanup.registerForEnvironmentSwitch(target)
        PrivacyWithdrawalCleanup.registerForEnvironmentSwitch(target)
        XCTAssertEqual(target.registeredNames, ["SessionTokens", "DeviceIdentity"], "只登记一次")
    }

    func testWithdrawCancelsPendingRetriesAndReconsentRestartsInitialization() {
        let store = MemoryPrivacyStore()
        let scheduler = ManualScheduler()
        let gate = PrivacyGate(store: store, clock: { 0 }, bundledPolicyVersion: "1")
        gate.retryScheduler = scheduler
        // 清理成功：只删待清理标记（R2-01；标记在期间 gate 一律按基本模式、不记同意）。
        gate.withdrawalCleanup = { store.clearWithdrawalPending() }
        var registerCalls = 0
        var pushCalls = 0
        gate.registerInitStep(name: "device_register") {
            registerCalls += 1
            throw NSError(domain: "offline", code: 1)
        }
        gate.registerInitStep(name: "push") { pushCalls += 1 }

        gate.agree(now: 10)
        XCTAssertEqual(registerCalls, 0, "agree 只落同意，不初始化")
        gate.onConsented(now: 10)
        XCTAssertEqual(registerCalls, 1)
        XCTAssertEqual(pushCalls, 1)
        XCTAssertEqual(scheduler.jobs.count, 1)

        gate.withdraw(now: 20)
        scheduler.runAll()
        XCTAssertEqual(registerCalls, 1, "撤回后旧周期的重试作废")
        XCTAssertNil(store.consentedVersion)
        gate.onConsented(now: 21)
        XCTAssertEqual(registerCalls, 1, "基本模式不初始化")

        gate.requestFullFunction(now: 30)
        gate.agree(now: 31)
        gate.onConsented(now: 31)
        XCTAssertEqual(registerCalls, 2, "再同意是新周期，重新注册设备")
        XCTAssertEqual(pushCalls, 2)
    }

    func testRetryDelaysDoubleAndCapAtSixtySeconds() {
        let delays = (1...10).map { PrivacyGate.retryDelayMillis(afterFailure: $0) }
        XCTAssertEqual(delays, [1000, 2000, 4000, 8000, 16000, 32000, 60000, 60000, 60000, 60000])
        XCTAssertEqual(PrivacyGate.retryDelayMillis(afterFailure: 500), 60000)
    }

    func testCorruptRecordsPromptConservatively() {
        let consentedWithoutVersion = MemoryPrivacyStore()
        consentedWithoutVersion.decisionRaw = "consented"
        let gate = PrivacyGate(store: consentedWithoutVersion, clock: { 0 }, bundledPolicyVersion: "2")
        XCTAssertEqual(gate.state(now: 0).promptStage, .first)
        XCTAssertNotEqual(gate.state(now: 0).decision, .consented)

        let badVersion = MemoryPrivacyStore()
        badVersion.decisionRaw = "consented"
        badVersion.consentedVersion = "v2"
        XCTAssertEqual(PrivacyGate(store: badVersion, clock: { 0 }, bundledPolicyVersion: "2")
            .state(now: 0).promptStage, .first)

        let contradictory = MemoryPrivacyStore()
        contradictory.decisionRaw = "consented"
        contradictory.consentedVersion = "2"
        contradictory.basicMode = true
        let state = PrivacyGate(store: contradictory, clock: { 0 }, bundledPolicyVersion: "2").state(now: 0)
        XCTAssertEqual(state.decision, .basicMode, "矛盾时按基本模式：不初始化、不自动弹")
        XCTAssertFalse(state.mustPrompt)

        let unknown = MemoryPrivacyStore()
        unknown.decisionRaw = "garbage"
        XCTAssertEqual(PrivacyGate(store: unknown, clock: { 0 }, bundledPolicyVersion: "2").state(now: 0).decision,
                       .notDecided)
    }

    func testHigherStoredVersionDoesNotPromptAndOperationsOutsideDialogAreIgnored() {
        let store = MemoryPrivacyStore()
        store.decisionRaw = "consented"
        store.consentedVersion = "11"
        store.consentedAtMillis = 5
        let gate = PrivacyGate(store: store, clock: { 0 }, bundledPolicyVersion: "10")
        XCTAssertFalse(gate.state(now: 0).mustPrompt)
        gate.agree(now: 99)
        gate.stillDisagree(now: 99)
        gate.requestFullFunction(now: 99)
        XCTAssertEqual(store.consentedAtMillis, 5, "没有弹窗时不重写同意记录")
        XCTAssertEqual(gate.state(now: 0).decision, .consented)
        XCTAssertFalse(gate.state(now: 0).mustPrompt)
    }
}

/// 撤回同意的本地清理（APP-02b 评审，S0）：失败保留「待清理」标记，下次启动重试直到清干净；期间凭据不可读。
@MainActor
final class WithdrawalCleanupRunnerTests: XCTestCase {
    private final class FlakyCleaner: EnvironmentSwitchCleaning {
        let cleanerName = "flaky"
        var failuresLeft: Int
        var calls = 0

        init(failures: Int) {
            failuresLeft = failures
        }

        func cleanForEnvironmentSwitch() throws {
            calls += 1
            if failuresLeft > 0 {
                failuresLeft -= 1
                throw NSError(domain: "keychain", code: -1)
            }
        }
    }

    func testFailedCleanupKeepsMarkerAndRetriesUntilClean() throws {
        let suite = "withdraw.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let cleaner = FlakyCleaner(failures: 2)
        let runner = WithdrawalCleanupRunner(defaults: defaults, registry: .init(cleaners: [cleaner]))

        XCTAssertTrue(runner.credentialsReadable)
        XCTAssertFalse(runner.run().isEmpty)
        XCTAssertTrue(runner.isPending)
        XCTAssertFalse(runner.credentialsReadable, "清理未完成前不得读取凭据")

        // 下次启动：再失败一次，标记仍在。
        let relaunched = WithdrawalCleanupRunner(defaults: defaults, registry: .init(cleaners: [cleaner]))
        XCTAssertFalse(relaunched.retryIfPending())
        XCTAssertTrue(relaunched.isPending)
        // 再下次：清干净，标记删除。
        XCTAssertTrue(relaunched.retryIfPending())
        XCTAssertFalse(relaunched.isPending)
        XCTAssertTrue(relaunched.credentialsReadable)
        XCTAssertEqual(cleaner.calls, 3)
        // 没有待清理时不重复清理。
        XCTAssertTrue(relaunched.retryIfPending())
        XCTAssertEqual(cleaner.calls, 3)
    }

    func testMarkerSurvivesEnvironmentSwitch() throws {
        let suite = "withdraw.env.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        UserDefaultsPrivacyStore(defaults: defaults).commitWithdrawal()
        try UserDefaultsNamespaceCleaner(defaults: defaults).cleanForEnvironmentSwitch()
        XCTAssertTrue(UserDefaultsPrivacyStore(defaults: defaults).withdrawalCleanupPending)
    }
}

/// 撤回同意对中断安全（第 2 轮评审，三端统一）：基本模式、清除同意记录、待清理标记在同一次持久化写入里完成；
/// 冷启动只要标记在就强制按基本模式处理；清理成功只删标记。各中断点用「重建 store / gate 读回」模拟进程被杀。
@MainActor
final class WithdrawalInterruptionTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName = ""

    override func setUp() {
        suiteName = "withdraw.interrupt.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
    }

    private final class CountingCleaner: EnvironmentSwitchCleaning {
        let cleanerName = "counting"
        var fail = false
        var calls = 0

        func cleanForEnvironmentSwitch() throws {
            calls += 1
            if fail {
                throw NSError(domain: "keychain", code: -1)
            }
        }
    }

    /// 已同意当前版本的记录。
    private func consentedStore() -> UserDefaultsPrivacyStore {
        let store = UserDefaultsPrivacyStore(defaults: defaults)
        store.commitConsent(version: "1", atMillis: 50)
        return store
    }

    /// 模拟进程重启：新 store、新 gate（冷启动）。
    private func relaunch() -> (UserDefaultsPrivacyStore, PrivacyGate) {
        let store = UserDefaultsPrivacyStore(defaults: defaults)
        let gate = PrivacyGate(store: store, clock: { 0 }, bundledPolicyVersion: "1")
        gate.coldStart(now: 0)
        return (store, gate)
    }

    /// 记录每次写入的 UserDefaults。
    private final class CountingDefaults: UserDefaults {
        var writes: [String] = []

        override func set(_ value: Any?, forKey defaultName: String) {
            writes.append(defaultName)
            super.set(value, forKey: defaultName)
        }

        override func removeObject(forKey defaultName: String) {
            writes.append(defaultName)
            super.removeObject(forKey: defaultName)
        }
    }

    func testWithdrawalCommitIsOneWrite() throws {
        let suite = "withdraw.count.\(UUID().uuidString)"
        let counting = try XCTUnwrap(CountingDefaults(suiteName: suite))
        defer { counting.removePersistentDomain(forName: suite) }
        let store = UserDefaultsPrivacyStore(defaults: counting)
        store.commitConsent(version: "1", atMillis: 50)
        counting.writes = []
        store.commitWithdrawal()
        let writes = counting.writes.count
        let record = counting.dictionary(forKey: AppNamespace.privacyRecordKey)
        XCTAssertEqual(writes, 1, "三项在同一次写入里完成")
        XCTAssertEqual(record?["decision"] as? String, "basic_mode")
        XCTAssertEqual(record?["basic_mode"] as? Bool, true)
        XCTAssertNil(record?["consented_version"])
        XCTAssertNil(record?["consented_at_ms"])
        XCTAssertEqual(record?["withdrawal_cleanup_pending"] as? Bool, true)
    }

    /// 中断点 1：撤回记录已落盘、凭据清理还没开始就被杀 → 冷启动是基本模式，启动时重试清理。
    func testInterruptedAfterCommitBeforeCleanup() {
        consentedStore().commitWithdrawal()
        let cleaner = CountingCleaner()
        let runner = WithdrawalCleanupRunner(defaults: defaults, registry: .init(cleaners: [cleaner]))
        XCTAssertFalse(runner.credentialsReadable)
        let (store, gate) = relaunch()
        XCTAssertEqual(gate.state(now: 0).decision, .basicMode)
        XCTAssertFalse(gate.state(now: 0).mustPrompt)
        XCTAssertNil(store.consentedVersion)
        XCTAssertTrue(runner.retryIfPending())
        XCTAssertEqual(cleaner.calls, 1)
        XCTAssertFalse(UserDefaultsPrivacyStore(defaults: defaults).withdrawalCleanupPending)
        XCTAssertEqual(relaunch().1.state(now: 0).decision, .basicMode, "清理成功只删标记，仍是基本模式")
    }

    /// 中断点 2：清理失败（或清完、删标记前被杀）→ 标记仍在，冷启动仍是基本模式，凭据不可读。
    func testInterruptedDuringCleanupKeepsMarker() {
        let store = consentedStore()
        let cleaner = CountingCleaner()
        cleaner.fail = true
        let runner = WithdrawalCleanupRunner(defaults: defaults, registry: .init(cleaners: [cleaner]))
        let gate = PrivacyGate(store: store, clock: { 0 }, bundledPolicyVersion: "1")
        gate.withdrawalCleanup = { _ = runner.run() }
        gate.withdraw(now: 1)
        XCTAssertTrue(runner.isPending)

        let (reread, coldGate) = relaunch()
        XCTAssertEqual(coldGate.state(now: 0).decision, .basicMode)
        XCTAssertTrue(reread.withdrawalCleanupPending)
        XCTAssertFalse(WithdrawalCleanupRunner(defaults: defaults, registry: .init(cleaners: [cleaner]))
            .credentialsReadable)
    }

    /// 标记在、但记录里又出现了同意（如清理失败后用户在本次运行里重新同意）：冷启动仍强制按基本模式处理。
    func testColdStartForcesBasicModeWhileMarkerExists() {
        let store = UserDefaultsPrivacyStore(defaults: defaults)
        store.commitWithdrawal()
        store.commitConsent(version: "1", atMillis: 9)
        XCTAssertTrue(store.withdrawalCleanupPending, "同意不删标记")
        let (reread, gate) = relaunch()
        XCTAssertEqual(gate.state(now: 0).decision, .basicMode)
        XCTAssertNil(reread.consentedVersion)
        XCTAssertEqual(reread.decisionRaw, "basic_mode")
    }

    /// 中断点 1–3 逐一模拟（R2-01）：撤回记录落盘后、清理开始前 / 清理进行中（前一个清理器已清、后一个未清）/
    /// 全部清完、删标记前。每个点都重建 store 与 gate 读回：基本模式、不弹窗、不初始化、不放行完整功能；
    /// 启动重试清理失败时仍是基本模式且不调用任何初始化步骤（设备注册等凭据使用方）；重试成功只删标记、仍是基本模式；
    /// 用户之后重新同意才是新的同意周期。
    func testEveryInterruptionPointRelaunchesInBasicModeWithoutInitialization() {
        enum Point: CaseIterable { case afterCommit, duringCleanup, afterCleanupBeforeMarkerDelete }
        for point in Point.allCases {
            defaults.removePersistentDomain(forName: suiteName)
            let first = CountingCleaner()
            let second = CountingCleaner()
            let registry = EnvironmentSwitchCleanerRegistry(cleaners: [first, second])
            consentedStore().commitWithdrawal()
            switch point {
            case .afterCommit:
                break
            case .duringCleanup:
                second.fail = true
                XCTAssertFalse(registry.cleanAll().isEmpty)
                second.fail = false
            case .afterCleanupBeforeMarkerDelete:
                XCTAssertTrue(registry.cleanAll().isEmpty)
            }
            let label = "\(point)"

            // 冷启动读回。
            var initCalls: [String] = []
            let (store, gate) = relaunch()
            for name in PrivacyInitStep.order {
                gate.registerInitStep(name: name) { initCalls.append(name) }
            }
            XCTAssertTrue(store.withdrawalCleanupPending, label)
            XCTAssertEqual(gate.state(now: 0).decision, .basicMode, label)
            XCTAssertFalse(gate.state(now: 0).mustPrompt, label)
            XCTAssertNil(store.consentedVersion, label)
            gate.onConsented(now: 0)
            XCTAssertEqual(initCalls, [], "不初始化：\(label)")

            // 启动重试清理失败：仍基本模式、凭据不可读、不初始化。
            first.fail = true
            let runner = WithdrawalCleanupRunner(defaults: defaults, registry: registry)
            XCTAssertFalse(runner.retryIfPending(), label)
            XCTAssertFalse(runner.credentialsReadable, label)
            gate.onConsented(now: 0)
            XCTAssertEqual(initCalls, [], label)
            // 此时用户点【开启完整功能】→【同意】：先重试清理，仍失败 → 不记同意、不初始化。
            gate.withdrawalCleanup = { _ = runner.run() }
            gate.requestFullFunction(now: 1)
            gate.agree(now: 1)
            gate.onConsented(now: 1)
            XCTAssertEqual(gate.state(now: 1).decision, .basicMode, label)
            XCTAssertNil(UserDefaultsPrivacyStore(defaults: defaults).consentedVersion, label)
            XCTAssertEqual(initCalls, [], label)

            // 重试成功：只删标记，重建后仍是基本模式。
            first.fail = false
            XCTAssertTrue(runner.retryIfPending(), label)
            let (after, coldGate) = relaunch()
            XCTAssertFalse(after.withdrawalCleanupPending, label)
            XCTAssertEqual(coldGate.state(now: 0).decision, .basicMode, "清理成功不恢复旧同意：\(label)")
            XCTAssertFalse(coldGate.state(now: 0).mustPrompt, label)

            // 重新同意：新的同意周期，才初始化。
            gate.requestFullFunction(now: 2)
            gate.agree(now: 2)
            gate.onConsented(now: 2)
            XCTAssertEqual(gate.state(now: 2).decision, .consented, label)
            XCTAssertEqual(initCalls, PrivacyInitStep.order, label)
        }
    }

    /// 标记在期间（本次运行里清理失败），gate 的生效结论也是基本模式，不只在冷启动时（R2-01）。
    func testPendingMarkerForcesBasicModeInRunningProcess() {
        let store = consentedStore()
        let cleaner = CountingCleaner()
        cleaner.fail = true
        let runner = WithdrawalCleanupRunner(defaults: defaults, registry: .init(cleaners: [cleaner]))
        let gate = PrivacyGate(store: store, clock: { 0 }, bundledPolicyVersion: "1")
        gate.withdrawalCleanup = { _ = runner.run() }
        var initCalls = 0
        gate.registerInitStep(name: PrivacyInitStep.push) { initCalls += 1 }
        gate.withdraw(now: 1)
        XCTAssertEqual(gate.state(now: 1).decision, .basicMode)
        gate.requestFullFunction(now: 2)
        XCTAssertEqual(gate.state(now: 2).promptStage, .first)
        gate.agree(now: 2)
        gate.onConsented(now: 2)
        XCTAssertEqual(gate.state(now: 2).decision, .basicMode, "清理没成功：不记同意")
        XCTAssertEqual(initCalls, 0)
        XCTAssertEqual(cleaner.calls, 2, "同意前重试了一次清理")

        cleaner.fail = false
        gate.requestFullFunction(now: 3)
        gate.agree(now: 3)
        gate.onConsented(now: 3)
        XCTAssertFalse(store.withdrawalCleanupPending)
        XCTAssertEqual(gate.state(now: 3).decision, .consented, "清理成功后的同意照常生效")
        XCTAssertEqual(initCalls, 1)
    }

    /// 中断点 0：撤回记录写入之前被杀 → 什么都没变，仍是已同意（凭据也没动）。
    func testInterruptedBeforeCommitChangesNothing() {
        _ = consentedStore()
        let (_, gate) = relaunch()
        XCTAssertEqual(gate.state(now: 0).decision, .consented)
        XCTAssertTrue(WithdrawalCleanupRunner(defaults: defaults, registry: .init(cleaners: [])).credentialsReadable)
    }
}
