import ClientCore
import Config
import CouliNetwork
import Foundation
import Privacy
import Session
import XCTest

/// APP-08 iOS 第八次修复 NEW-05（S0）：禁读屏障先于撤回待清理标记生效。
///
/// 时序（修复后）：撤回入口 → 同步竖起网络 readBarrier、推进网络作废世代、竖起设备 withdrawalBarrier → 发布待清理标记
/// （磁盘标记 / 未落盘内存标记）→ 依次执行清理器（第一位仍是网络层作废 `invalidateSessions`）。
///
/// 场景：持有旧可读快照的请求暂停；撤回入口写下待清理标记、网络清理器尚未执行时（隐私存储的写入探针里）恢复它，
/// 会话令牌零读取、设备凭据零读取、零发送。入口覆盖 `PrivacyGate.withdraw`、`WithdrawalCleanupRunner.run`（独立调用）、
/// `retryIfPending`（补写未落盘记录）、闸门的补写重试与冷启动补写。
/// 对照：撤回清理完成、重新同意后，正常请求与设备注册都能放下屏障。
@MainActor
final class WithdrawalBarrierOrderR3hTests: XCTestCase {
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

    /// 隐私存储：每次写撤回记录（发布待清理标记）之后立即调 `onMarker`——此刻标记已生效、清理器尚未执行。
    private final class MarkerProbeStore: PrivacyStore {
        let inner = MemoryPrivacyStore()
        var onMarker: (() -> Void)?

        var decisionRaw: String {
            get { inner.decisionRaw }
            set { inner.decisionRaw = newValue }
        }

        var consentedVersion: String? {
            get { inner.consentedVersion }
            set { inner.consentedVersion = newValue }
        }

        var consentedAtMillis: Int64? {
            get { inner.consentedAtMillis }
            set { inner.consentedAtMillis = newValue }
        }

        var basicMode: Bool {
            get { inner.basicMode }
            set { inner.basicMode = newValue }
        }

        var withdrawalCleanupPending: Bool {
            inner.withdrawalCleanupPending
        }

        func commitConsent(version: String, atMillis: Int64) {
            inner.commitConsent(version: version, atMillis: atMillis)
        }

        func commitBasicMode() {
            inner.commitBasicMode()
        }

        func commitWithdrawal() {
            inner.commitWithdrawal()
            onMarker?()
        }

        func clearWithdrawalPending() {
            inner.clearWithdrawalPending()
        }

        func commitWithdrawalVerified() -> Bool {
            let written = inner.commitWithdrawalVerified()
            onMarker?()
            return written
        }
    }

    /// 组请求的状态读取：先取快照，再按需暂停，恢复后交回暂停前的旧快照（旧请求持有撤回之前的可读快照）。
    private final class SnapshotThenPause: @unchecked Sendable {
        private let lock = NSLock()
        private var armed = false
        let paused = DispatchSemaphore(value: 0)
        let resume = DispatchSemaphore(value: 0)

        func arm() {
            lock.withLock { armed = true }
        }

        func read(_ state: CoreTestState) async -> NetworkContext {
            let snapshot = state.context
            let stop: Bool = lock.withLock {
                let value = armed
                armed = false
                return value
            }
            if stop {
                paused.signal()
                await Task.detached { [resume] in blockOn(resume) }.value
            }
            return snapshot
        }

        /// 等到暂停点（最多 5 秒）；没等到返回 false。
        func waitUntilPaused() async -> Bool {
            await Task.detached { [paused] in waitOn(paused, seconds: 5) }.value
        }
    }

    /// 组请求「会话准入通过、读设备凭据之前」的暂停点。
    private final class AdmissionPause: @unchecked Sendable {
        private let lock = NSLock()
        private var armed = false
        let paused = DispatchSemaphore(value: 0)
        let resume = DispatchSemaphore(value: 0)

        func arm() {
            lock.withLock { armed = true }
        }

        func probe() {
            let stop: Bool = lock.withLock {
                let value = armed
                armed = false
                return value
            }
            guard stop else {
                return
            }
            paused.signal()
            resume.wait()
        }

        /// 等到暂停点（最多 5 秒）；没等到返回 false。
        func waitUntilPaused() async -> Bool {
            await Task.detached { [paused] in waitOn(paused, seconds: 5) }.value
        }
    }

    /// 标记生效那一刻的观察。
    private final class MarkerSeen {
        var networkBarrier: [Bool] = []
        var deviceBarrier: [Bool] = []
        var tokenReadsDelta: [Int] = []
        var deviceReadsDelta: [Int] = []
        var resumedFinished: [Bool] = []
    }

    private struct Rig {
        let fixture: DeviceFixture
        let tokens: CountingTokens
        let store: MarkerProbeStore
        let runner: WithdrawalCleanupRunner
        let gate: PrivacyGate
        let scheduler: CapturingScheduler
    }

    private final class CapturingScheduler: RetryScheduler {
        var actions: [() -> Void] = []

        func schedule(delayMillis _: Int64, action: @escaping () -> Void) {
            actions.append(action)
        }

        func runAll() {
            let pending = actions
            actions = []
            pending.forEach { $0() }
        }
    }

    private static let openLink = ApiCall(operationId: "openLink", pathParams: ["link_id": "a"])

    override func setUp() {
        CoreStubProtocol.install { request in
            if request.path == ClientCoreFixtures.devicesPath {
                return coreOK(ClientCoreFixtures.registered("device-1", "test-only.install.r3h"))
            }
            return coreOK("{\"done\":true}")
        }
    }

    /// 与 App 的 PrivacyController 相同的接线：闸门的清理入口接执行器，屏障入口接执行器的 `raiseReadBarriers`；
    /// 撤回注册表第一位是网络层作废，其后是设备凭据清理器。
    private func makeRig(
        clientContext: (@Sendable (CoreTestState) async -> NetworkContext)? = nil,
        afterCredentialAdmission: @escaping @Sendable () -> Void = {}
    ) -> Rig {
        let tokens = CountingTokens(
            MemorySessionTokens(access: "access-1", refresh: "refresh-1", scope: "full", account: "account-A")
        )
        let fixture = makeDeviceFixture(
            tokens: tokens, afterCredentialAdmission: afterCredentialAdmission, clientContext: clientContext
        )
        let registry = EnvironmentSwitchCleanerRegistry(cleaners: [
            NetworkInvalidationCleaner(client: fixture.client),
            DeviceRegistryCleaner(registry: fixture.registry),
        ])
        let store = MarkerProbeStore()
        store.commitConsent(version: "1", atMillis: 0)
        let runner = WithdrawalCleanupRunner(store: store, registry: registry)
        let gate = PrivacyGate(store: store, clock: { 0 }, bundledPolicyVersion: "1")
        let scheduler = CapturingScheduler()
        gate.retryScheduler = scheduler
        gate.withdrawalWriteGuard = runner.writeGuard
        gate.withdrawalCleanup = {
            MainActor.assumeIsolated { _ = runner.run() }
        }
        gate.raiseWithdrawalReadBarriers = {
            MainActor.assumeIsolated { runner.raiseReadBarriers() }
        }
        return Rig(fixture: fixture, tokens: tokens, store: store, runner: runner, gate: gate, scheduler: scheduler)
    }

    /// 标记生效、清理器尚未执行时：快照改为基本模式不可读（新快照），记下两道屏障，恢复旧请求并等它结束（最多 5 秒）。
    private func probeAtMarker(
        _ rig: Rig, seen: MarkerSeen, resume: DispatchSemaphore?, finished: DispatchSemaphore?
    ) {
        let tokenBase = rig.tokens.reads
        let deviceBase = rig.fixture.registry.identityReads
        rig.store.onMarker = { [weak seen] in
            guard let seen else { return }
            rig.fixture.state.set(privacy: PrivacyRaw.basic, readable: false)
            seen.networkBarrier.append(rig.fixture.client.withdrawalReadBarrierRaised)
            seen.deviceBarrier.append(rig.fixture.registry.withdrawalBarrierRaised)
            if let resume, let finished {
                resume.signal()
                seen.resumedFinished.append(finished.wait(timeout: .now() + 5) == .success)
            }
            seen.tokenReadsDelta.append(rig.tokens.reads - tokenBase)
            seen.deviceReadsDelta.append(rig.fixture.registry.identityReads - deviceBase)
            rig.store.onMarker = nil
        }
    }

    // MARK: - 标记已生效、网络清理器尚未执行：旧请求零读取

    /// PrivacyGate.withdraw：持有旧可读快照、尚未读会话的请求在标记生效后恢复——会话令牌零读取（设备凭据同样零读取）、零发送。
    func testWithdrawMarkerBeforeCleanerOldRequestReadsNoSessionTokens() async {
        let pause = SnapshotThenPause()
        let rig = makeRig(clientContext: { state in await pause.read(state) })
        let first = await rig.fixture.registry.registerIfNeeded()
        XCTAssertEqual(first, .registered)
        let sentBefore = CoreStubProtocol.requests.count

        pause.arm()
        let finished = DispatchSemaphore(value: 0)
        let client = rig.fixture.client
        let call = Task.detached { () -> Bool in
            let result = await client.send(Self.openLink)
            finished.signal()
            return result.isSuccessResult
        }
        let reachedPause = await pause.waitUntilPaused()
        XCTAssertTrue(reachedPause, "前提：旧请求停在暂停点")
        let seen = MarkerSeen()
        probeAtMarker(rig, seen: seen, resume: pause.resume, finished: finished)

        rig.gate.withdraw(now: 1)
        let succeeded = await call.value

        XCTAssertEqual(seen.resumedFinished, [true], "前提：旧请求在标记生效、清理器执行之前已恢复并结束")
        XCTAssertEqual(seen.networkBarrier, [true], "标记发布之前已竖起网络禁读屏障")
        XCTAssertEqual(seen.deviceBarrier, [true], "标记发布之前已竖起设备屏障")
        XCTAssertEqual(seen.tokenReadsDelta, [0], "标记已生效、网络清理器未执行：会话令牌零读取")
        XCTAssertEqual(seen.deviceReadsDelta, [0], "标记已生效、网络清理器未执行：设备凭据零读取")
        XCTAssertFalse(succeeded)
        XCTAssertEqual(CoreStubProtocol.requests.count, sentBefore, "旧请求零发送")
    }

    /// PrivacyGate.withdraw：会话准入已通过、读设备凭据之前暂停的请求在标记生效后恢复——设备凭据零读取、零发送。
    func testWithdrawMarkerBeforeCleanerAdmittedRequestReadsNoDeviceCredentials() async {
        let pause = AdmissionPause()
        let rig = makeRig(afterCredentialAdmission: { pause.probe() })
        let first = await rig.fixture.registry.registerIfNeeded()
        XCTAssertEqual(first, .registered)
        let sentBefore = CoreStubProtocol.requests.count

        pause.arm()
        let finished = DispatchSemaphore(value: 0)
        let client = rig.fixture.client
        let call = Task.detached { () -> Bool in
            let result = await client.send(Self.openLink)
            finished.signal()
            return result.isSuccessResult
        }
        let reachedPause = await pause.waitUntilPaused()
        XCTAssertTrue(reachedPause, "前提：旧请求停在暂停点")
        let seen = MarkerSeen()
        probeAtMarker(rig, seen: seen, resume: pause.resume, finished: finished)

        rig.gate.withdraw(now: 1)
        let succeeded = await call.value

        XCTAssertEqual(seen.resumedFinished, [true], "前提：旧请求在标记生效、清理器执行之前已恢复并结束")
        XCTAssertEqual(seen.deviceBarrier, [true], "标记发布之前已竖起设备屏障")
        XCTAssertEqual(seen.deviceReadsDelta, [0], "标记已生效、网络清理器未执行：设备凭据零读取")
        XCTAssertFalse(succeeded)
        let sent = CoreStubProtocol.requests.dropFirst(sentBefore)
        XCTAssertTrue(sent.allSatisfy { $0.header("X-Device-Id") == nil })
        XCTAssertEqual(sent.count, 0, "旧请求零发送")
    }

    /// 独立清理入口 WithdrawalCleanupRunner.run（标记还不在时由它写）：同样先竖屏障，旧请求会话令牌、设备凭据都零读取。
    func testStandaloneRunnerMarkerBeforeCleanerOldRequestReadsNothing() async {
        let pause = SnapshotThenPause()
        let rig = makeRig(clientContext: { state in await pause.read(state) })
        let first = await rig.fixture.registry.registerIfNeeded()
        XCTAssertEqual(first, .registered)
        let sentBefore = CoreStubProtocol.requests.count

        pause.arm()
        let finished = DispatchSemaphore(value: 0)
        let client = rig.fixture.client
        let call = Task.detached { () -> Bool in
            let result = await client.send(Self.openLink)
            finished.signal()
            return result.isSuccessResult
        }
        let reachedPause = await pause.waitUntilPaused()
        XCTAssertTrue(reachedPause, "前提：旧请求停在暂停点")
        let seen = MarkerSeen()
        probeAtMarker(rig, seen: seen, resume: pause.resume, finished: finished)

        XCTAssertEqual(rig.runner.run(), [])
        let succeeded = await call.value

        XCTAssertEqual(seen.resumedFinished, [true])
        XCTAssertEqual(seen.networkBarrier, [true], "独立入口：标记之前已竖起网络屏障")
        XCTAssertEqual(seen.deviceBarrier, [true], "独立入口：标记之前已竖起设备屏障")
        XCTAssertEqual(seen.tokenReadsDelta, [0], "独立入口：会话令牌零读取")
        XCTAssertEqual(seen.deviceReadsDelta, [0], "独立入口：设备凭据零读取")
        XCTAssertFalse(succeeded)
        XCTAssertEqual(CoreStubProtocol.requests.count, sentBefore)
    }

    // MARK: - 每个写标记的入口：标记发布时两道屏障都已竖起

    /// 先放下两道屏障（作废之后的可读快照经组请求放下），再走入口，标记写入那一刻记下屏障状态。
    private func lowerBarriers(_ rig: Rig) async {
        rig.fixture.state.set(privacy: PrivacyRaw.full, readable: true)
        _ = await rig.fixture.client.send(Self.openLink)
        XCTAssertFalse(rig.fixture.client.withdrawalReadBarrierRaised, "前提：网络屏障已放下")
        XCTAssertFalse(rig.fixture.registry.withdrawalBarrierRaised, "前提：设备屏障已放下")
    }

    func testEveryMarkerWriterRaisesBarriersFirst() async {
        let rig = makeRig()
        let first = await rig.fixture.registry.registerIfNeeded()
        XCTAssertEqual(first, .registered)
        var entries: [String] = []
        let seen = MarkerSeen()

        // 1. 闸门撤回、记录写不进去（未落盘内存标记）。
        rig.store.inner.failWithdrawalWrites = true
        probeAtMarker(rig, seen: seen, resume: nil, finished: nil)
        rig.gate.withdraw(now: 1)
        entries.append("PrivacyGate.withdraw（写入失败）")
        XCTAssertTrue(rig.runner.writeGuard.isUnpersisted, "前提：未落盘标记已置")

        // 2. 闸门的补写重试（persistWithdrawal）。
        await lowerBarriers(rig)
        rig.store.inner.failWithdrawalWrites = false
        probeAtMarker(rig, seen: seen, resume: nil, finished: nil)
        rig.scheduler.runAll()
        entries.append("PrivacyGate 补写重试")
        XCTAssertFalse(rig.runner.writeGuard.isUnpersisted)

        // 3. 启动补清（retryIfPending）：记录未落盘时先补写。
        rig.store.inner.failWithdrawalWrites = true
        await lowerBarriers(rig)
        rig.store.inner.clearWithdrawalPending()
        probeAtMarker(rig, seen: seen, resume: nil, finished: nil)
        _ = rig.runner.run()
        entries.append("WithdrawalCleanupRunner.run（独立，写入失败）")
        XCTAssertTrue(rig.runner.writeGuard.isUnpersisted)
        await lowerBarriers(rig)
        rig.store.inner.failWithdrawalWrites = false
        probeAtMarker(rig, seen: seen, resume: nil, finished: nil)
        XCTAssertTrue(rig.runner.retryIfPending())
        entries.append("WithdrawalCleanupRunner.retryIfPending（补写）")

        // 4. 冷启动补写（待清理标记在：forceBasicModeIfCleanupPending 重写撤回记录）。
        await lowerBarriers(rig)
        rig.store.inner.commitWithdrawal()
        probeAtMarker(rig, seen: seen, resume: nil, finished: nil)
        rig.gate.coldStart(now: 2)
        entries.append("PrivacyGate.coldStart（标记在）")

        XCTAssertEqual(seen.networkBarrier.count, entries.count, "前提：每个入口都写了标记 \(entries)")
        for (index, entry) in entries.enumerated() where index < seen.networkBarrier.count {
            XCTAssertTrue(seen.networkBarrier[index], "\(entry)：标记发布之前已竖起网络屏障")
            XCTAssertTrue(seen.deviceBarrier[index], "\(entry)：标记发布之前已竖起设备屏障")
        }
    }

    // MARK: - 对照：重新同意后屏障能放下

    /// 撤回清理完成、重新同意后：正常请求放下网络与设备屏障；设备重新注册后签名请求照常带设备头。
    func testReconsentRequestLowersBarriersAndRegistrationWorks() async {
        let rig = makeRig()
        let first = await rig.fixture.registry.registerIfNeeded()
        XCTAssertEqual(first, .registered)
        rig.fixture.state.set(privacy: PrivacyRaw.basic, readable: false)
        rig.gate.withdraw(now: 1)
        XCTAssertFalse(rig.store.withdrawalCleanupPending, "前提：撤回清理已完成")
        XCTAssertTrue(rig.fixture.client.withdrawalReadBarrierRaised)
        XCTAssertTrue(rig.fixture.registry.withdrawalBarrierRaised)

        rig.store.commitConsent(version: "1", atMillis: 3)
        rig.fixture.state.set(privacy: PrivacyRaw.full, readable: true)
        _ = await rig.fixture.client.send(Self.openLink)
        XCTAssertFalse(rig.fixture.client.withdrawalReadBarrierRaised, "重新同意后的正常请求放下网络屏障")
        XCTAssertFalse(rig.fixture.registry.withdrawalBarrierRaised, "重新同意后的正常请求放下设备屏障")

        let again = await rig.fixture.registry.registerIfNeeded()
        XCTAssertEqual(again, .registered, "设备凭据已清，重新注册")
        let result = await rig.fixture.client.send(Self.openLink)
        XCTAssertTrue(result.isSuccessResult)
        XCTAssertEqual(CoreStubProtocol.requests.last?.header("X-Device-Id"), "device-1")
    }

    /// 撤回清理完成、重新同意后：设备注册单独也能放下设备屏障（不依赖先发组请求），之后请求照常。
    func testReconsentRegistrationLowersDeviceBarrier() async {
        let rig = makeRig()
        let first = await rig.fixture.registry.registerIfNeeded()
        XCTAssertEqual(first, .registered)
        rig.fixture.state.set(privacy: PrivacyRaw.basic, readable: false)
        rig.gate.withdraw(now: 1)
        XCTAssertTrue(rig.fixture.registry.withdrawalBarrierRaised)

        rig.store.commitConsent(version: "1", atMillis: 3)
        rig.fixture.state.set(privacy: PrivacyRaw.full, readable: true)
        let again = await rig.fixture.registry.registerIfNeeded()
        XCTAssertEqual(again, .registered)
        XCTAssertFalse(rig.fixture.registry.withdrawalBarrierRaised, "重新同意后的设备注册放下设备屏障")

        let result = await rig.fixture.client.send(Self.openLink)
        XCTAssertTrue(result.isSuccessResult)
        XCTAssertFalse(rig.fixture.client.withdrawalReadBarrierRaised)
        XCTAssertEqual(CoreStubProtocol.requests.last?.header("X-Device-Id"), "device-1")
    }
}

/// 同步等待信号量（放在同步函数里，避免在异步上下文直接调用 noasync 的 wait）。
private func blockOn(_ semaphore: DispatchSemaphore) {
    semaphore.wait()
}

/// 限时等待信号量（同步函数里调用）。
private func waitOn(_ semaphore: DispatchSemaphore, seconds: Double) -> Bool {
    semaphore.wait(timeout: .now() + seconds) == .success
}
