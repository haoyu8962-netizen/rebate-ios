import ClientCore
import CouliNetwork
import Foundation
import XCTest

/// iOS 第 1 轮评审 R1-01、R1-02（APP-03b 共性 21、22）：10402 的凭据隔离、注册请求不递归、重新注册窗口的原子结算。
final class DeviceRegistryReviewR1Tests: XCTestCase {
    override func setUp() {
        CoreStubProtocol.install { _ in .error(.cannotConnectToHost) }
    }

    /// R1-01：服务端按 BR-ID-09 拒收带失效 X-Device-Id 的注册请求。被拒凭据立即隔离，重新注册的 registerDevice
    /// 不带旧设备头，原请求不挂起、重放 1 次成功。
    func testReRegistrationOmitsRejectedDeviceHeader() async throws {
        let fixture = makeDeviceFixture()
        let counter = Counter()
        CoreStubProtocol.install { request in
            if request.path == ClientCoreFixtures.devicesPath {
                if request.header("X-Device-Id") != nil {
                    return coreFail(10402)
                }
                let index = counter.next()
                return coreOK(ClientCoreFixtures.registered("device-\(index)", "test-only.install.n\(index)"))
            }
            return request.header("X-Device-Id") == "device-1" ? coreFail(10402) : coreOK("{\"done\":true}")
        }
        let first = await fixture.registry.registerIfNeeded()
        XCTAssertEqual(first, .registered)

        let client = fixture.client
        let result = try await completes(within: 5) {
            await client.send(ApiCall(operationId: "openLink", pathParams: ["link_id": "a"]))
        }

        XCTAssertTrue(result.isSuccessResult, "\(result)")
        let registrations = CoreStubProtocol.requests(path: ClientCoreFixtures.devicesPath)
        XCTAssertEqual(registrations.count, 2)
        XCTAssertEqual(registrations.compactMap { $0.header("X-Device-Id") }, [], "registerDevice 不带被拒的设备头")
        XCTAssertEqual(fixture.registry.deviceId, "device-2")
    }

    /// R1-01：收到 10402 后、新凭据到手前，被拒的设备凭据不可读（隔离）。
    func testRejectedCredentialsAreQuarantinedImmediately() async {
        let fixture = makeDeviceFixture()
        CoreStubProtocol.install { _ in coreOK(ClientCoreFixtures.registered("device-1", "test-only.install.n1")) }
        let first = await fixture.registry.registerIfNeeded()
        XCTAssertEqual(first, .registered)
        CoreStubProtocol.install { _ in .hold }

        let registry = fixture.registry
        let pending = Task { await registry.reRegister(rejectedDeviceId: "device-1") }
        await CoreStubProtocol.waitUntilHeld()

        XCTAssertNil(registry.credentials, "被拒凭据在重新注册进行中就已隔离")
        XCTAssertNil(CoreStubProtocol.requests.first?.header("X-Device-Id"))
        CoreStubProtocol.release(with: coreOK(ClientCoreFixtures.registered("device-2", "test-only.install.n2")))
        let replaced = await pending.value
        XCTAssertTrue(replaced)
        XCTAssertEqual(registry.deviceId, "device-2")
    }

    /// R1-01：注册请求自身遇到 10402 时不递归进入它正在执行的注册窗口（否则等待自己，永久挂起）。
    func testRegistrationOwn10402DoesNotRecurseIntoItsFlight() async throws {
        let fixture = makeDeviceFixture()
        CoreStubProtocol.install { _ in coreFail(10402) }

        let registry = fixture.registry
        let outcome = try await completes(within: 5) { await registry.registerIfNeeded() }

        XCTAssertEqual(outcome, .requestFailed)
        XCTAssertEqual(CoreStubProtocol.requests(path: ClientCoreFixtures.devicesPath).count, 1, "不递归、不重放注册")
        XCTAssertNil(registry.deviceId)
    }

    /// R1-02：等待者 B 通过结果检查后暂停，首个窗口 A 完成（失败）后 B 才恢复——B 在锁内复用 A 的结果，
    /// 不启动第二次注册；失败只通知退避一次。
    func testWaiterPausedAfterCheckReusesSettledWindow() async throws {
        let pause = PausingContext()
        let fixture = makeDeviceFixture(registryContext: { state in await pause.read(state) })
        let counter = Counter()
        let notified = Counter()
        fixture.registry.onNeedsRegistration = { _ = notified.next() }
        CoreStubProtocol.install { request in
            guard request.path == ClientCoreFixtures.devicesPath else {
                return coreOK()
            }
            return counter.next() == 1
                ? coreOK(ClientCoreFixtures.registered("device-1", "test-only.install.n1"))
                : coreFail(50001, status: 500)
        }
        let first = await fixture.registry.registerIfNeeded()
        XCTAssertEqual(first, .registered)

        let registry = fixture.registry
        pause.pauseNextRead()
        let waiterB = Task { await registry.reRegister(rejectedDeviceId: "device-1") }
        await pause.waitUntilPaused()

        let resultA = await registry.reRegister(rejectedDeviceId: "device-1")
        XCTAssertFalse(resultA)
        pause.resume()
        let resultB = try await completes(within: 5) { await waiterB.value }

        XCTAssertFalse(resultB, "失败结果也复用")
        XCTAssertEqual(CoreStubProtocol.requests(path: ClientCoreFixtures.devicesPath).count, 2, "初次 + 窗口的 1 次")
        XCTAssertEqual(notified.next(), 2, "同一窗口只通知退避一次")
    }

    /// R1-02：多个 10402 同时并入同一窗口，只注册一次、只通知一次。
    func testConcurrentWaitersShareOneWindow() async throws {
        let fixture = makeDeviceFixture()
        let counter = Counter()
        let notified = Counter()
        fixture.registry.onNeedsRegistration = { _ = notified.next() }
        CoreStubProtocol.install { _ in
            guard counter.next() == 1 else {
                return .hold
            }
            return coreOK(ClientCoreFixtures.registered("device-1", "test-only.install.n1"))
        }
        let first = await fixture.registry.registerIfNeeded()
        XCTAssertEqual(first, .registered)

        let registry = fixture.registry
        let waiters = (0..<4).map { _ in Task { await registry.reRegister(rejectedDeviceId: "device-1") } }
        await CoreStubProtocol.waitUntilHeld()
        try? await Task.sleep(nanoseconds: 50_000_000)
        CoreStubProtocol.release(with: coreFail(50001, status: 500))
        var results: [Bool] = []
        for waiter in waiters {
            try await results.append(completes(within: 5) { await waiter.value })
        }

        XCTAssertEqual(results, [false, false, false, false])
        XCTAssertEqual(CoreStubProtocol.requests(path: ClientCoreFixtures.devicesPath).count, 2)
        XCTAssertEqual(notified.next(), 2, "只通知一次")
    }
}

/// 在限定时间内完成，否则判失败（被测流程挂起时测试不跟着挂起）。
private final class Completion<T: Sendable>: @unchecked Sendable {
    var value: T?
}

extension XCTestCase {
    func completes<T: Sendable>(
        within seconds: TimeInterval,
        _ operation: @escaping @Sendable () async -> T
    ) async throws -> T {
        let box = Completion<T>()
        let done = expectation(description: "completes")
        Task {
            box.value = await operation()
            done.fulfill()
        }
        await fulfillment(of: [done], timeout: seconds)
        return try XCTUnwrap(box.value, "流程没有在 \(seconds) 秒内结束（挂起）")
    }
}

/// 注册表的网络状态读取：可让下一次读取暂停，直到测试放行（模拟等待者在检查之后、入队之前被挂起）。
final class PausingContext: @unchecked Sendable {
    private let lock = NSLock()
    private var pauseArmed = false
    private var paused: CheckedContinuation<Void, Never>?
    private var pausedWaiters: [CheckedContinuation<Void, Never>] = []

    func pauseNextRead() {
        lock.withLock { pauseArmed = true }
    }

    func read(_ state: CoreTestState) async -> NetworkContext {
        let shouldPause: Bool = lock.withLock {
            let armed = pauseArmed
            pauseArmed = false
            return armed
        }
        if shouldPause {
            await withCheckedContinuation { continuation in
                let waiters: [CheckedContinuation<Void, Never>] = lock.withLock {
                    paused = continuation
                    let all = pausedWaiters
                    pausedWaiters = []
                    return all
                }
                waiters.forEach { $0.resume() }
            }
        }
        return state.context
    }

    func waitUntilPaused() async {
        await withCheckedContinuation { continuation in
            let ready: Bool = lock.withLock {
                if paused != nil {
                    return true
                }
                pausedWaiters.append(continuation)
                return false
            }
            if ready {
                continuation.resume()
            }
        }
    }

    func resume() {
        let continuation: CheckedContinuation<Void, Never>? = lock.withLock {
            let current = paused
            paused = nil
            return current
        }
        continuation?.resume()
    }
}
