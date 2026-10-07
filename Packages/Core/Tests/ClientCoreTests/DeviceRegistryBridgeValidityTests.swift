import ClientCore
import CouliNetwork
import Foundation
import Session
import XCTest

/// APP-04 iOS 第 3 轮评审 R3-02（三端共性第 22、46 条）：刷新收到 10402 进入重新注册时，桥调用的有效性一并传进
/// 注册窗口。注册在内部等待（allowed）后、读标识前、实际发送前检查；没有有效调用方就停止这次恢复，不发注册请求。
/// 第 4 轮 R4-02：停下的恢复仍要交给唯一的设备退避链（恰好通知一次），之后的原生请求能恢复。
final class DeviceRegistryBridgeValidityTests: XCTestCase {
    override func setUp() {
        CoreStubProtocol.install { _ in .error(.cannotConnectToHost) }
    }

    /// 撤销发生在 reRegister 入口的放行等待期间。
    func testRevokedDuringReRegisterWaitSendsNoRegistration() async throws {
        try await runRevokedDuringRegistrationWait(pausedReads: 1)
    }

    /// 撤销发生在单飞注册内部的放行等待期间（已进入注册窗口、尚未读标识）。
    func testRevokedDuringRegistrationFlightWaitSendsNoRegistration() async throws {
        try await runRevokedDuringRegistrationWait(pausedReads: 2)
    }

    /// 桥调用 getMe 收到 10002 → 刷新收到 10402 → 重新注册在第 `pausedReads` 次放行检查处暂停；此时桥调用失效
    /// （页面关闭或到期）→ 放行后不读标识、不发注册请求、不重放刷新，调用按 call_cancelled 结束，会话不动。
    private func runRevokedDuringRegistrationWait(pausedReads: Int) async throws {
        let tokens = MemorySessionTokens(access: "access-1", refresh: "refresh-1", scope: "full", account: "account-A")
        let pause = PausingContext()
        let fixture = makeDeviceFixture(tokens: tokens, registryContext: { state in await pause.read(state) })
        let counter = Counter()
        CoreStubProtocol.install { request in
            switch request.path {
            case ClientCoreFixtures.devicesPath:
                let index = counter.next()
                return coreOK(ClientCoreFixtures.registered("device-\(index)", "test-only.install.n\(index)"))
            case "/v1/auth/refresh":
                return coreFail(10402)
            default:
                return coreFail(10002, status: 401)
            }
        }
        let registered = await fixture.registry.registerIfNeeded()
        XCTAssertEqual(registered, .registered)
        let readsBefore = fixture.reader.reads
        let recoveries = RecoveryLog()
        fixture.registry.onNeedsRegistration = { recoveries.record() }

        let valid = ValidityFlag()
        let client = fixture.client
        pause.pauseNextRead()
        let call = Task { await client.send(ApiCall(operationId: "getMe"), isValid: { valid.isValid }) }
        try await completes(within: 5) { await pause.waitUntilPaused() }
        for _ in 1..<pausedReads {
            pause.pauseNextRead()
            pause.resume()
            try await completes(within: 5) { await pause.waitUntilPaused() }
        }
        valid.revoke()
        pause.resume()
        let result = try await completes(within: 5) { await call.value }

        XCTAssertEqual(result.notSentReason, LocalRejectReason.callCancelled, "\(result)")
        XCTAssertEqual(
            CoreStubProtocol.requests(path: ClientCoreFixtures.devicesPath).count, 1, "只有初次注册，撤销后不发注册请求"
        )
        XCTAssertEqual(fixture.reader.reads, readsBefore, "撤销后不读设备标识")
        XCTAssertEqual(CoreStubProtocol.requests(path: "/v1/auth/refresh").count, 1, "不重放刷新")
        XCTAssertEqual(tokens.accessToken, "access-1", "会话不动")
        XCTAssertEqual(tokens.refreshToken, "refresh-1")

        // 设备恢复不能丢（R4-02）：被拒凭据仍被隔离、没有其他恢复窗口 → 唯一的退避链恰好收到一次通知。
        XCTAssertEqual(recoveries.count, 1, "设备恢复通知恰好一次")
        // 退避链重新注册后，之后的原生请求带新凭据恢复。
        let recovered = await fixture.registry.registerIfNeeded()
        XCTAssertEqual(recovered, .registered)
        CoreStubProtocol.install { request in
            request.header("X-Device-Id") == "device-2" ? coreOK() : coreFail(10402)
        }
        let native = await client.send(ApiCall(operationId: "getMe"))
        XCTAssertTrue(native.isSuccessResult, "\(native)")
        XCTAssertEqual(recoveries.count, 1, "恢复后不再重复通知")
    }
}

/// 退避链收到的恢复通知次数（`onNeedsRegistration` 的测试替身）。
private final class RecoveryLog: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    var count: Int {
        lock.withLock { value }
    }

    func record() {
        lock.withLock { value += 1 }
    }
}

/// 线程安全的桥调用有效性（BridgeCallValidity 的测试替身）。
private final class ValidityFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var valid = true

    var isValid: Bool {
        lock.withLock { valid }
    }

    func revoke() {
        lock.withLock { valid = false }
    }
}
