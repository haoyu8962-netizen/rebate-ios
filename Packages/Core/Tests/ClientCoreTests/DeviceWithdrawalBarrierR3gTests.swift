import ClientCore
import CouliNetwork
import Foundation
import XCTest

/// APP-08 iOS 第七次修复 NEW-05（S0）：撤回期间不读设备凭据（device_id、install_secret，PrivacyWithdrawal.swift:87 的禁读项）。
/// - 组请求：网络锁里的会话准入判断通过后暂停，撤回开始（网络层作废，设备清理器尚未执行）后再恢复，设备凭据零读取、不带设备头；
/// - 设备注册：放行快照取得后暂停，撤回开始后恢复，零读取；
/// - 撤回期间对外的 `deviceId`（埋点用）零读取；
/// 对照：没有撤回时照常读取；撤回清理完成、重新可读之后屏障放下，签名请求照常带设备头。
final class DeviceWithdrawalBarrierR3gTests: XCTestCase {
    /// 组请求时「准入判断通过、读设备凭据之前」的暂停点（不持任何锁）。
    private final class AdmissionGate: @unchecked Sendable {
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

        func waitUntilPaused() async {
            await Task.detached { [paused] in blockOn(paused) }.value
        }
    }

    /// 注册表的状态读取：先取快照、再按需暂停，恢复后交回暂停前的旧快照（模拟放行检查通过之后才发生撤回）。
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

        func waitUntilPaused() async {
            await Task.detached { [paused] in blockOn(paused) }.value
        }
    }

    override func setUp() {
        CoreStubProtocol.install { request in
            if request.path == ClientCoreFixtures.devicesPath {
                return coreOK(ClientCoreFixtures.registered("device-1", "test-only.install.r3g"))
            }
            return coreOK("{\"done\":true}")
        }
    }

    private static let openLink = ApiCall(operationId: "openLink", pathParams: ["link_id": "a"])

    /// 撤回开始：PrivacyGate.withdraw 先改写为基本模式、凭据不可读，再按注册顺序执行清理器；这里只执行第一位的网络层作废，
    /// 设备清理器（DeviceRegistryCleaner）还没执行——设备凭据仍在缓存与安全存储里。
    @MainActor
    private static func startWithdrawal(_ state: CoreTestState, _ client: ApiClient) throws {
        state.set(privacy: PrivacyRaw.basic, readable: false)
        try NetworkInvalidationCleaner(client: client).cleanForEnvironmentSwitch()
    }

    private static func withdraw(_ fixture: DeviceFixture) async throws {
        let (state, client) = (fixture.state, fixture.client)
        try await MainActor.run { try startWithdrawal(state, client) }
    }

    /// NEW-05：准入判断通过后暂停，撤回开始后恢复——设备凭据零读取，请求不带设备头、不签名发出。
    func testAdmissionPassedThenWithdrawalReadsNoDeviceCredentials() async throws {
        let gate = AdmissionGate()
        let fixture = makeDeviceFixture(afterCredentialAdmission: { gate.probe() })
        let registered = await fixture.registry.registerIfNeeded()
        XCTAssertEqual(registered, .registered)
        let baseline = fixture.registry.identityReads
        let sentBefore = CoreStubProtocol.requests.count

        gate.arm()
        let client = fixture.client
        let call = Task { await client.send(Self.openLink) }
        try await completes(within: 5) { await gate.waitUntilPaused() }
        try await Self.withdraw(fixture)
        XCTAssertTrue(fixture.registry.withdrawalBarrierRaised, "撤回开始即在设备锁里竖起设备屏障")
        gate.resume.signal()
        let result = try await completes(within: 5) { await call.value }

        XCTAssertEqual(fixture.registry.identityReads, baseline, "判断通过后撤回开始：设备凭据零读取")
        XCTAssertFalse(result.isSuccessResult)
        let sent = CoreStubProtocol.requests.dropFirst(sentBefore)
        XCTAssertTrue(sent.allSatisfy { $0.header("X-Device-Id") == nil }, "零发送带设备头的请求")
        XCTAssertEqual(sent.count, 0, "撤回后旧请求零发送")
    }

    /// 对照：同样暂停再恢复、期间没有撤回——照常读一次设备凭据，签名请求带设备头。
    func testAdmissionPassedWithoutWithdrawalStillReads() async throws {
        let gate = AdmissionGate()
        let fixture = makeDeviceFixture(afterCredentialAdmission: { gate.probe() })
        _ = await fixture.registry.registerIfNeeded()
        let baseline = fixture.registry.identityReads

        gate.arm()
        let client = fixture.client
        let call = Task { await client.send(Self.openLink) }
        try await completes(within: 5) { await gate.waitUntilPaused() }
        gate.resume.signal()
        let result = try await completes(within: 5) { await call.value }

        XCTAssertTrue(result.isSuccessResult)
        XCTAssertEqual(fixture.registry.identityReads, baseline + 1)
        let open = try XCTUnwrap(CoreStubProtocol.requests.last)
        XCTAssertEqual(open.header("X-Device-Id"), "device-1")
    }

    /// 设备注册路径：放行快照取得后暂停，撤回开始后恢复——零读取，按不放行结束，不注册。
    func testRegistrationAdmittedThenWithdrawalReadsNoDeviceCredentials() async throws {
        let pause = SnapshotThenPause()
        let fixture = makeDeviceFixture(registryContext: { state in await pause.read(state) })
        _ = await fixture.registry.registerIfNeeded()
        let baseline = fixture.registry.identityReads
        let registrations = fixture.registry.registerRequests

        pause.arm()
        let registry = fixture.registry
        let task = Task { await registry.registerIfNeeded() }
        try await completes(within: 5) { await pause.waitUntilPaused() }
        try await Self.withdraw(fixture)
        pause.resume.signal()
        let outcome = try await completes(within: 5) { await task.value }

        XCTAssertEqual(outcome, .notAllowed)
        XCTAssertEqual(fixture.registry.identityReads, baseline, "放行之后撤回开始：设备凭据零读取")
        XCTAssertEqual(fixture.registry.registerRequests, registrations)
    }

    /// 撤回开始、设备清理器还没执行时，对外的 deviceId（埋点）零读取；清理完成、重新同意后屏障放下，签名请求照常带设备头。
    func testBarrierBlocksPublicReadsThenLiftsAfterReadableSnapshot() async throws {
        let fixture = makeDeviceFixture()
        _ = await fixture.registry.registerIfNeeded()
        let baseline = fixture.registry.identityReads
        try await Self.withdraw(fixture)

        XCTAssertNil(fixture.registry.deviceId)
        XCTAssertNil(fixture.registry.credentials)
        XCTAssertEqual(fixture.registry.identityReads, baseline, "屏障竖着：对外读取零读取")
        let blocked = await fixture.client.send(Self.openLink)
        XCTAssertFalse(blocked.isSuccessResult, "基本模式下签名接口不发")
        XCTAssertEqual(fixture.registry.identityReads, baseline)

        // 撤回清理完成后再次同意（作废之后取得的可读快照）：屏障放下，不会永久卡住。
        fixture.state.set(privacy: PrivacyRaw.full, readable: true)
        let again = await fixture.registry.registerIfNeeded()
        XCTAssertEqual(again, .alreadyRegistered)
        XCTAssertFalse(fixture.registry.withdrawalBarrierRaised)
        let result = await fixture.client.send(Self.openLink)
        XCTAssertTrue(result.isSuccessResult)
        XCTAssertEqual(CoreStubProtocol.requests.last?.header("X-Device-Id"), "device-1")
    }

    /// 只经组请求路径也能放下屏障（不依赖设备注册再跑一次）。
    func testBarrierLiftsThroughRequestAdmission() async throws {
        let fixture = makeDeviceFixture()
        _ = await fixture.registry.registerIfNeeded()
        try await Self.withdraw(fixture)
        XCTAssertTrue(fixture.registry.withdrawalBarrierRaised)

        fixture.state.set(privacy: PrivacyRaw.full, readable: true)
        let result = await fixture.client.send(Self.openLink)

        XCTAssertTrue(result.isSuccessResult)
        XCTAssertFalse(fixture.registry.withdrawalBarrierRaised)
        XCTAssertEqual(CoreStubProtocol.requests.last?.header("X-Device-Id"), "device-1")
    }
}

/// 同步等待信号量（放在同步函数里，避免在异步上下文直接调用 noasync 的 wait）。
private func blockOn(_ semaphore: DispatchSemaphore) {
    semaphore.wait()
}
