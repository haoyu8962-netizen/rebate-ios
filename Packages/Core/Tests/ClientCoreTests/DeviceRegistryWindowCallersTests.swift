import ClientCore
import Foundation
import XCTest

/// APP-04 共性第 61 条（H-05a-R4-01）在 iOS 的核对：并入「进行中」重新注册窗口的调用方也登记为窗口的调用方；
/// 只有窗口里的调用方全部失效才停止底层注册。同一被拒凭据两个调用方，第一个取消后第二个仍能拿到新凭据。
final class DeviceRegistryWindowCallersTests: XCTestCase {
    override func setUp() {
        CoreStubProtocol.install { _ in .error(.cannotConnectToHost) }
    }

    func testJoinedCallerKeepsWindowAliveAfterFirstCancels() async throws {
        let fixture = makeDeviceFixture()
        let counter = Counter()
        CoreStubProtocol.install { request in
            guard request.path == ClientCoreFixtures.devicesPath else {
                return coreOK()
            }
            return counter.next() == 1 ? coreOK(ClientCoreFixtures.registered("device-1", "test-only.install.n1"))
                : .hold
        }
        let registry = fixture.registry
        let first = await registry.registerIfNeeded()
        XCTAssertEqual(first, .registered)

        let validA = Flag(true)
        let validB = Flag(true)
        let waiterA = Task { await registry.reRegister(rejectedDeviceId: "device-1", isValid: { validA.value }) }
        await CoreStubProtocol.waitUntilHeld()
        let waiterB = Task { await registry.reRegister(rejectedDeviceId: "device-1", isValid: { validB.value }) }
        try? await Task.sleep(nanoseconds: 100_000_000)
        // 第一个调用方失效并取消：窗口里还有有效的 B，底层注册不停。
        validA.value = false
        waiterA.cancel()
        try? await Task.sleep(nanoseconds: 50_000_000)
        CoreStubProtocol.release(with: coreOK(ClientCoreFixtures.registered("device-2", "test-only.install.n2")))
        let resultB = try await completes(within: 5) { await waiterB.value }
        _ = try await completes(within: 5) { await waiterA.value }

        XCTAssertTrue(resultB, "并入进行中窗口的调用方仍拿到新凭据")
        XCTAssertEqual(registry.deviceId, "device-2")
        XCTAssertEqual(CoreStubProtocol.requests(path: ClientCoreFixtures.devicesPath).count, 2, "初次 + 窗口 1 次")
    }
}

private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Bool

    init(_ value: Bool) {
        stored = value
    }

    var value: Bool {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}
