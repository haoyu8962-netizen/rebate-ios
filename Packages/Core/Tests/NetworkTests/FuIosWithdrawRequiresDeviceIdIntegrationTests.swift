import Foundation
@testable import Network
import Session
import XCTest

/// FU-IOS-WITHDRAW-REQUIRES-DEVICE-ID（编排 D10-1940 ③）集成层：经真实 ApiClient 组请求（ApiClient+Prepare.swift 38–47：
/// `device.credentials(admittedBy:)` 读不出 → deviceId nil → RequestHeaderPolicy.decide）。隐私撤回记录
/// （recordConsent {type: privacy, accepted: false}）在设备凭据读不出时零发送、本地拒 device_not_ready；读得出照发 1 条、带 X-Device-Id。
/// 桩写法同 LockIosIdentityUnknownTests 7a / 7c：makeHarness（account-A / access-1 的 full 会话）+ StubURLProtocol 本地假服务；
/// 设备替身是 NetworkTestSupport 的 TestDevice（默认 deviceId "device-fixture"）。
final class WithdrawDeviceIdIntegrationTests: XCTestCase {
    static let consentPath = "/v1/consents"
    static let privacyWithdraw =
        "{\"accepted\":false,\"channel\":\"privacy_center\",\"client_at\":\"2026-11-18T09:30:00+08:00\","
            + "\"type\":\"privacy\",\"version\":3}"
    static let privacyAccept =
        "{\"accepted\":true,\"channel\":\"privacy_center\",\"client_at\":\"2026-11-18T09:30:00+08:00\","
            + "\"type\":\"privacy\",\"version\":3}"

    /// 与 AppMe.withdrawConsent 同形的调用：声明 sendsWhenIdentityUnknown（D10-1711）。
    static let withdrawCall = ApiCall(
        operationId: "recordConsent", body: privacyWithdraw, sendsWhenIdentityUnknown: true
    )

    /// 设备凭据读不出的三种替身：没有 device_id、device_id 为空串、没有 install_secret（`credentials` 任一项缺失为 nil，
    /// NetworkTypes.swift 135–140）。
    static let unreadableDevices: [(String, TestDevice)] = [
        ("deviceId nil", TestDevice(deviceId: nil)),
        ("deviceId 空串", TestDevice(deviceId: "")),
        ("installSecret nil", TestDevice(installSecret: nil)),
    ]

    /// 确认后才变得读不出的设备替身（先可读、`makeUnreadable()` 之后读不出）。
    final class SwitchableDevice: DeviceCredentials, @unchecked Sendable {
        private let lock = NSLock()
        private var readable = true

        var deviceId: String? {
            lock.withLock { readable ? "device-fixture" : nil }
        }

        var installSecret: String? {
            lock.withLock { readable ? "test-only.install.device-a" : nil }
        }

        func makeUnreadable() {
            lock.withLock { readable = false }
        }
    }

    // MARK: - 1. 设备凭据读不出 → 零发送、device_not_ready

    /// I1. 设备凭据读不出（三种替身）× 隐私撤回 → 假服务零到达、本地拒 device_not_ready、不为此起刷新。
    func testPrivacyWithdrawWithUnreadableDeviceSendsNothing() async {
        for (label, device) in Self.unreadableDevices {
            let harness = makeHarness(device: device)
            StubURLProtocol.install { _ in ok() }
            let result = await harness.client.send(Self.withdrawCall)
            XCTAssertEqual(result.rejectReason, LocalRejectReason.deviceNotReady, "\(label)：\(result)")
            XCTAssertTrue(StubURLProtocol.requests.isEmpty, "\(label)：零发送（不发不带 X-Device-Id 的撤回记录）")
            XCTAssertEqual(harness.client.refreshCalls, 0, "\(label)：不为此起刷新")
        }
    }

    /// I1'. 同 AppMe.withdrawConsent 的发送方式：确认时固定 sessionOnly 归属，之后设备凭据才变得读不出 → 零发送、device_not_ready。
    func testPrivacyWithdrawPinnedThenDeviceUnreadableSendsNothing() async {
        let device = SwitchableDevice()
        let harness = makeHarness(device: device)
        StubURLProtocol.install { _ in ok() }
        let owner = harness.client.currentOwnership(credentialsReadable: true).sessionOnly
        device.makeUnreadable()
        let result = await harness.client.send(
            Self.withdrawCall, isValid: { true }, sendAllowed: { true }, expected: owner
        )
        XCTAssertEqual(result.rejectReason, LocalRejectReason.deviceNotReady, "\(result)")
        XCTAssertTrue(StubURLProtocol.requests.isEmpty, "零发送")
    }

    /// I1''. 身份未知（会话读不出，D10-1711 声明照发）且设备凭据读不出 → 仍零发送，原因是 device_not_ready（不是匿名发出）。
    func testPrivacyWithdrawIdentityUnknownAndDeviceUnreadableSendsNothing() async {
        let harness = makeHarness(device: TestDevice(deviceId: nil))
        StubURLProtocol.install { _ in ok() }
        harness.tokens.failReads = .readFailed
        let result = await harness.client.send(Self.withdrawCall)
        XCTAssertEqual(result.rejectReason, LocalRejectReason.deviceNotReady, "\(result)")
        XCTAssertTrue(StubURLProtocol.requests.isEmpty, "零发送")
    }

    // MARK: - 2. 设备凭据可读 → 照发 1 条，带 X-Device-Id

    /// I2. 设备凭据可读 × 隐私撤回 → 照发 1 条：带 X-Device-Id、不带签名头（x-signed=false）、Authorization 照现状（有令牌就带）、
    /// 请求体原样。固定 sessionOnly 归属的发送方式同样照发。
    func testPrivacyWithdrawWithReadableDeviceSendsOnceWithDeviceId() async {
        for pinned in [false, true] {
            let harness = makeHarness()
            StubURLProtocol.install { _ in ok() }
            let result: ApiResult
            if pinned {
                let owner = harness.client.currentOwnership(credentialsReadable: true).sessionOnly
                result = await harness.client.send(
                    Self.withdrawCall, isValid: { true }, sendAllowed: { true }, expected: owner
                )
            } else {
                result = await harness.client.send(Self.withdrawCall)
            }
            let label = pinned ? "固定 sessionOnly" : "不固定"
            XCTAssertTrue(result.isSuccess, "\(label)：\(result)")
            XCTAssertEqual(StubURLProtocol.requests.map(\.path), [Self.consentPath], label)
            let sent = StubURLProtocol.requests.first
            XCTAssertEqual(sent?.header(HeaderNames.deviceId), "device-fixture", "\(label)：设备级")
            for name in HeaderNames.signature {
                XCTAssertNil(sent?.header(name), "\(label)：x-signed=false，不带 \(name)")
            }
            XCTAssertEqual(sent?.header(HeaderNames.authorization), "Bearer access-1", "\(label)：现状 optional 有令牌就带")
            XCTAssertEqual(sent?.body, Self.privacyWithdraw, label)
        }
    }

    // MARK: - 3. 对照：其它 recordConsent 不受影响

    /// I3. 对照：设备凭据读不出 × recordConsent {type: privacy, accepted: true} → 与改动前一致照发 1 条、不带 X-Device-Id
    /// （新分支只认隐私撤回体）。
    func testPrivacyAcceptWithUnreadableDeviceStillSends() async {
        let harness = makeHarness(device: TestDevice(deviceId: nil))
        StubURLProtocol.install { _ in ok() }
        let result = await harness.client.send(ApiCall(operationId: "recordConsent", body: Self.privacyAccept))
        XCTAssertTrue(result.isSuccess, "\(result)")
        XCTAssertEqual(StubURLProtocol.requests.map(\.path), [Self.consentPath])
        XCTAssertNil(StubURLProtocol.requests.first?.header(HeaderNames.deviceId))
    }
}
