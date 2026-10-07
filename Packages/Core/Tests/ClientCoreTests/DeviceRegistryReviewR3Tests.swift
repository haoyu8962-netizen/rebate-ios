import ClientCore
import Foundation
import XCTest

/// iOS 第 3 轮评审 R3-01（APP-03b 共性 4、22、25）：退避注册与 10402 窗口共用被拒凭据的恢复状态。
final class DeviceRegistryReviewR3Tests: XCTestCase {
    override func setUp() {
        CoreStubProtocol.install { _ in .error(.cannotConnectToHost) }
    }

    /// R3-01：device-1 被重放再次拒绝（交给退避链）；另一条在途请求的 10402 等待者停在放行检查处。退避注册先拿到
    /// device-2，等待者再恢复：直接复用成功结果，不再发注册请求，也不替换刚恢复的凭据。
    func testBackoffRecoveryIsReusedByPaused10402Waiter() async throws {
        let pause = PausingContext()
        let fixture = makeDeviceFixture(registryContext: { state in await pause.read(state) })
        let counter = Counter()
        let notified = Counter()
        fixture.registry.onNeedsRegistration = { _ = notified.next() }
        CoreStubProtocol.install { request in
            guard request.path == ClientCoreFixtures.devicesPath else {
                return coreOK()
            }
            let index = counter.next()
            return coreOK(ClientCoreFixtures.registered("device-\(index)", "test-only.install.n\(index)"))
        }
        let registry = fixture.registry
        let first = await registry.registerIfNeeded()
        XCTAssertEqual(first, .registered)

        registry.deviceRejected(rejectedDeviceId: "device-1")
        pause.pauseNextRead()
        let waiter = Task { await registry.reRegister(rejectedDeviceId: "device-1") }
        try await completes(within: 5) { await pause.waitUntilPaused() }

        let backoff = try await completes(within: 5) { await registry.registerIfNeeded() }
        XCTAssertEqual(backoff, .registered)
        XCTAssertEqual(registry.deviceId, "device-2")
        pause.resume()
        let resumed = try await completes(within: 5) { await waiter.value }

        XCTAssertTrue(resumed, "退避注册已替换被拒凭据，等待者直接重放")
        XCTAssertEqual(CoreStubProtocol.requests(path: ClientCoreFixtures.devicesPath).count, 2, "初次 + 退避各 1 次")
        XCTAssertEqual(registry.deviceId, "device-2", "不再注册出 device-3")
        XCTAssertEqual(notified.next(), 2, "只交给退避链一次")
        let late = await registry.reRegister(rejectedDeviceId: "device-1")
        XCTAssertTrue(late, "晚到的同一 device_id 的 10402 复用成功结果")
        XCTAssertEqual(CoreStubProtocol.requests(path: ClientCoreFixtures.devicesPath).count, 2)
    }
}
