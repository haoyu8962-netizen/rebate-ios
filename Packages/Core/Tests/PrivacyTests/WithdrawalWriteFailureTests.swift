import Config
import Foundation
import XCTest
@testable import Privacy

/// F-ALL-05（APP-02b-harmony R1-01，三端核对）：撤回同意记录写入失败不得被吞掉——内存里立即按基本模式、不放行、
/// 凭据不可读，并持续重试写入；落盘后再清理，清干净才删待清理标记。
/// APP-03a R1-02：UserDefaults 的读回只证明缓存更新了，不证明落盘；以撤回标记（`WithdrawalMarker`）的确认写入为准。
/// 这里的 UserDefaults 照常更新缓存，失败注入在标记上（「缓存已更新、持久化失败」）。
@MainActor
final class WithdrawalWriteFailureTests: XCTestCase {
    private final class ManualScheduler: RetryScheduler {
        var delays: [Int64] = []
        private var jobs: [() -> Void] = []

        func schedule(delayMillis: Int64, action: @escaping () -> Void) {
            delays.append(delayMillis)
            jobs.append(action)
        }

        func runNext() {
            guard !jobs.isEmpty else { return }
            jobs.removeFirst()()
        }

        var pending: Int {
            jobs.count
        }
    }

    private final class CountingCleaner: EnvironmentSwitchCleaning {
        let cleanerName = "counting"
        var calls = 0

        func cleanForEnvironmentSwitch() throws {
            calls += 1
        }
    }

    private var suite = ""
    private var defaults: UserDefaults!
    /// 与 defaults 绑定的撤回标记（同一个 defaults 的各个存储实例共用）。
    private var marker: MemoryWithdrawalMarker!

    override func setUp() {
        suite = "withdraw.write.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
        marker = WithdrawalMarkers.marker(for: defaults) as? MemoryWithdrawalMarker
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
    }

    private struct Fixture {
        let gate: PrivacyGate
        let runner: WithdrawalCleanupRunner
        let scheduler: ManualScheduler
        let cleaner: CountingCleaner
    }

    private func makeGate() -> Fixture {
        let store = UserDefaultsPrivacyStore(defaults: defaults)
        store.commitConsent(version: "1", atMillis: 50)
        let cleaner = CountingCleaner()
        let runner = WithdrawalCleanupRunner(defaults: defaults, registry: .init(cleaners: [cleaner]))
        let gate = PrivacyGate(store: store, clock: { 0 }, bundledPolicyVersion: "1")
        let scheduler = ManualScheduler()
        gate.retryScheduler = scheduler
        gate.withdrawalWriteGuard = runner.writeGuard
        gate.withdrawalCleanup = { _ = runner.run() }
        return Fixture(gate: gate, runner: runner, scheduler: scheduler, cleaner: cleaner)
    }

    /// R1-02：UserDefaults 缓存已更新（读回就是撤回后的记录），但持久化失败 → 不得报告已落盘。
    func testCacheUpdatedButPersistenceFailedIsNotVerified() {
        let store = UserDefaultsPrivacyStore(defaults: defaults)
        store.commitConsent(version: "1", atMillis: 50)
        marker.failWrites = true
        XCTAssertFalse(store.commitWithdrawalVerified())
        let cached = defaults.dictionary(forKey: AppNamespace.privacyRecordKey)
        XCTAssertEqual(cached?["decision"] as? String, "basic_mode", "缓存读回已是撤回后的记录，但这不算落盘")
        XCTAssertEqual(cached?["withdrawal_cleanup_pending"] as? Bool, true)
        XCTAssertNil(marker.read())
        marker.failWrites = false
        XCTAssertTrue(store.commitWithdrawalVerified())
        XCTAssertTrue(store.withdrawalCleanupPending)
        XCTAssertEqual(marker.read(), WithdrawalMarkerState(cleanupPending: true))
    }

    /// R1-02：标记落盘后，进程重启读回旧的 consented 记录（UserDefaults 的异步落盘丢了）也按已撤回、待清理处理。
    func testPersistedMarkerOverridesStaleConsentAfterRelaunch() {
        let store = UserDefaultsPrivacyStore(defaults: defaults)
        store.commitConsent(version: "1", atMillis: 50)
        let stale = defaults.dictionary(forKey: AppNamespace.privacyRecordKey)
        XCTAssertTrue(store.commitWithdrawalVerified())
        // 模拟重启后 UserDefaults 里仍是撤回前的记录。
        defaults.set(stale, forKey: AppNamespace.privacyRecordKey)
        let relaunched = UserDefaultsPrivacyStore(defaults: defaults)
        XCTAssertEqual(relaunched.decisionRaw, "basic_mode")
        XCTAssertTrue(relaunched.basicMode)
        XCTAssertNil(relaunched.consentedVersion)
        XCTAssertNil(relaunched.consentedAtMillis)
        XCTAssertTrue(relaunched.withdrawalCleanupPending)
        let gate = PrivacyGate(store: relaunched, clock: { 0 }, bundledPolicyVersion: "1")
        gate.coldStart(now: 1)
        XCTAssertEqual(gate.state(now: 1).decision, .basicMode)

        // 清理完成只删「待清理」，撤回标记保留；重新同意才删标记。
        relaunched.clearWithdrawalPending()
        XCTAssertFalse(relaunched.withdrawalCleanupPending)
        XCTAssertEqual(relaunched.decisionRaw, "basic_mode")
        relaunched.commitConsent(version: "1", atMillis: 60)
        XCTAssertNil(marker.read())
        XCTAssertEqual(relaunched.decisionRaw, "consented")
    }

    func testWriteFailureActsAsBasicModeAndRetriesUntilPersisted() {
        let fixture = makeGate()
        let (gate, runner, scheduler, cleaner) = (fixture.gate, fixture.runner, fixture.scheduler, fixture.cleaner)
        marker.failWrites = true
        gate.withdraw(now: 1)

        // 内存里立即按基本模式、不放行，凭据不可读。
        XCTAssertEqual(gate.state(now: 1).decision, .basicMode)
        XCTAssertTrue(runner.writeGuard.isUnpersisted)
        XCTAssertFalse(runner.credentialsReadable)
        XCTAssertEqual(cleaner.calls, 1, "凭据照样先清")
        XCTAssertNil(marker.read(), "持久标记确实没写进去")

        // 不放行：同意入口与初始化都被挡住。
        gate.requestFullFunction(now: 2)
        gate.agree(now: 2)
        gate.onConsented(now: 2)
        XCTAssertEqual(gate.state(now: 2).decision, .basicMode)

        // 持续重试，退避 1s、2s、4s…
        scheduler.runNext()
        scheduler.runNext()
        XCTAssertEqual(scheduler.delays, [1000, 2000, 4000])
        XCTAssertTrue(runner.writeGuard.isUnpersisted)

        // 写入恢复：落盘、再清理一次、删标记。
        marker.failWrites = false
        scheduler.runNext()
        XCTAssertFalse(runner.writeGuard.isUnpersisted)
        XCTAssertEqual(scheduler.pending, 0, "落盘后停止重试")
        XCTAssertEqual(cleaner.calls, 2)
        let stored = UserDefaultsPrivacyStore(defaults: defaults)
        XCTAssertEqual(stored.decisionRaw, "basic_mode")
        XCTAssertNil(stored.consentedVersion)
        XCTAssertFalse(stored.withdrawalCleanupPending)
        XCTAssertTrue(runner.credentialsReadable)
        XCTAssertEqual(gate.state(now: 3).decision, .basicMode)
    }

    func testRunnerAloneDoesNotSwallowWriteFailure() {
        let store = UserDefaultsPrivacyStore(defaults: defaults)
        store.commitConsent(version: "1", atMillis: 50)
        let cleaner = CountingCleaner()
        let runner = WithdrawalCleanupRunner(defaults: defaults, registry: .init(cleaners: [cleaner]))
        marker.failWrites = true
        XCTAssertTrue(runner.run().isEmpty)
        XCTAssertFalse(runner.credentialsReadable, "写入失败不能当作没有撤回")
        XCTAssertFalse(runner.retryIfPending())
        XCTAssertFalse(runner.credentialsReadable)
        marker.failWrites = false
        XCTAssertTrue(runner.retryIfPending())
        XCTAssertTrue(runner.credentialsReadable)
        XCTAssertFalse(store.withdrawalCleanupPending)
        XCTAssertEqual(store.decisionRaw, "basic_mode")
    }

    func testAgreeAfterWriteRecoveredGoesThroughNormalFlow() {
        let fixture = makeGate()
        let (gate, runner) = (fixture.gate, fixture.runner)
        marker.failWrites = true
        gate.withdraw(now: 1)
        marker.failWrites = false
        gate.requestFullFunction(now: 2)
        gate.agree(now: 2)
        XCTAssertFalse(runner.writeGuard.isUnpersisted, "同意前先补写撤回记录")
        XCTAssertEqual(gate.state(now: 2).decision, .consented)
        XCTAssertFalse(UserDefaultsPrivacyStore(defaults: defaults).withdrawalCleanupPending)
    }

    func testMemoryStoreWriteFailure() {
        let store = MemoryPrivacyStore()
        store.commitConsent(version: "1", atMillis: 1)
        store.failWithdrawalWrites = true
        let gate = PrivacyGate(store: store, clock: { 0 }, bundledPolicyVersion: "1")
        let scheduler = ManualScheduler()
        gate.retryScheduler = scheduler
        gate.withdraw(now: 1)
        XCTAssertEqual(gate.state(now: 1).decision, .basicMode)
        XCTAssertEqual(scheduler.pending, 1)
    }

    // MARK: - 文件标记（生产）

    private func temporaryURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("withdraw-marker-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("privacy-withdrawal.json")
    }

    func testFileMarkerPersistsAcrossInstances() throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let marker = FileWithdrawalMarker(url: url)
        XCTAssertNil(marker.read())
        try marker.write(WithdrawalMarkerState(cleanupPending: true))
        XCTAssertEqual(FileWithdrawalMarker(url: url).read(), WithdrawalMarkerState(cleanupPending: true))
        try marker.write(WithdrawalMarkerState(cleanupPending: false))
        XCTAssertEqual(FileWithdrawalMarker(url: url).read(), WithdrawalMarkerState(cleanupPending: false))
        try marker.remove()
        XCTAssertNil(FileWithdrawalMarker(url: url).read())
        try marker.remove()
    }

    /// 文件写不进去（目录位置被一个普通文件占着）：抛错，存储报告未落盘。
    func testFileMarkerWriteFailureIsReported() throws {
        let blocker = FileManager.default.temporaryDirectory
            .appendingPathComponent("withdraw-blocker-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: blocker) }
        try Data("x".utf8).write(to: blocker)
        let marker = FileWithdrawalMarker(url: blocker.appendingPathComponent("privacy-withdrawal.json"))
        XCTAssertThrowsError(try marker.write(WithdrawalMarkerState(cleanupPending: true)))
        let store = UserDefaultsPrivacyStore(defaults: defaults, marker: marker)
        store.commitConsent(version: "1", atMillis: 1)
        XCTAssertFalse(store.commitWithdrawalVerified())
    }

    /// 标记内容解不开：按已撤回、待清理（保守）。
    func testCorruptFileMarkerReadsAsPendingWithdrawal() throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: url)
        XCTAssertEqual(FileWithdrawalMarker(url: url).read(), WithdrawalMarkerState(cleanupPending: true))
    }
}
