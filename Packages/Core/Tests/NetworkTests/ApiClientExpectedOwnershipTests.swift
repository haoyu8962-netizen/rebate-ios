import Foundation
@testable import Network
import XCTest

/// APP-08 iOS 第 3 轮后第二次定向复核 RC-01：调用方固定的请求归属（账号、会话世代、作废世代）在首次归属绑定前、组请求后与实际写出前
/// 只比较，不一致零发送、不重新绑定当前会话；不传时其他调用方行为不变。
final class ApiClientExpectedOwnershipTests: XCTestCase {
    private func send(_ harness: Harness, _ expected: RequestOwnership?) async -> ApiResult {
        await harness.client.send(
            ApiCall(operationId: "listOrders", query: "scope=self"),
            isValid: { true }, sendAllowed: { true }, expected: expected
        )
    }

    private func switchToB(_ harness: Harness) throws {
        harness.client.signOut()
        try harness.tokens.save(access: "access-b", refresh: "refresh-b", scope: "full", account: "account-B")
    }

    /// 一致时照常发送，带的是固定账号的凭据。
    func testMatchingOwnershipSends() async {
        let harness = makeHarness()
        StubURLProtocol.install { _ in ok("{\"items\":[]}") }
        let fixed = harness.client.currentOwnership(credentialsReadable: true)
        XCTAssertEqual(fixed.account, "account-A")
        let result = await send(harness, fixed)
        if case .success = result {} else {
            XCTFail("归属一致照常成功：\(result)")
        }
        XCTAssertEqual(StubURLProtocol.requests.count, 1)
        XCTAssertEqual(StubURLProtocol.requests.first?.header("Authorization"), "Bearer access-1")
    }

    /// 固定之后（排队期间）换账号：零发送，按 session_changed 本地结束；不传固定归属的旧行为对照：会绑定 B 发出。
    func testSessionSwapAfterCaptureSendsNothing() async throws {
        let harness = makeHarness()
        StubURLProtocol.install { _ in ok("{\"items\":[]}") }
        let fixed = harness.client.currentOwnership(credentialsReadable: true)
        try switchToB(harness)
        let result = await send(harness, fixed)
        XCTAssertEqual(result, .localReject(reason: LocalRejectReason.sessionChanged))
        XCTAssertTrue(StubURLProtocol.requests.isEmpty, "旧请求零发送")

        // 缺省（nil）：与 send(_:isValid:sendAllowed:) 相同，绑定此刻的会话
        let unchanged = await send(harness, nil)
        if case .success = unchanged {} else {
            XCTFail("不传固定归属的调用行为不变：\(unchanged)")
        }
        XCTAssertEqual(StubURLProtocol.requests.first?.header("Authorization"), "Bearer access-b")
    }

    /// 固定之后切环境（作废世代 +1）：零发送，call_cancelled。
    func testInvalidationAfterCaptureSendsNothing() async {
        let harness = makeHarness()
        StubURLProtocol.install { _ in ok("{\"items\":[]}") }
        let fixed = harness.client.currentOwnership(credentialsReadable: true)
        harness.client.invalidateSessions()
        let result = await send(harness, fixed)
        XCTAssertEqual(result, .localReject(reason: LocalRejectReason.callCancelled))
        XCTAssertTrue(StubURLProtocol.requests.isEmpty)
    }

    /// 首次绑定之后、组请求之前换账号（在发送前闸门里模拟）：组请求后的比较拦下，零发送。
    func testSessionSwapBeforeAdmitSendsNothing() async {
        let harness = makeHarness()
        StubURLProtocol.install { _ in ok("{\"items\":[]}") }
        let fixed = harness.client.currentOwnership(credentialsReadable: true)
        let swapped = Box<Bool>()
        let tokens = harness.tokens
        let client = harness.client
        let result = await client.send(
            ApiCall(operationId: "listOrders", query: "scope=self"),
            isValid: { true },
            sendAllowed: {
                if swapped.value == nil {
                    swapped.value = true
                    client.signOut()
                    try? tokens.save(access: "access-b", refresh: "refresh-b", scope: "full", account: "account-B")
                }
                return true
            },
            expected: fixed
        )
        XCTAssertEqual(swapped.value, true)
        XCTAssertEqual(result, .localReject(reason: LocalRejectReason.sessionChanged))
        XCTAssertTrue(StubURLProtocol.requests.isEmpty)
    }

    /// 同一世代里账号对不上（固定的是别的账号）：带凭据前拦下，account_mismatch，零发送。
    func testAccountMismatchSendsNothing() async {
        let harness = makeHarness()
        StubURLProtocol.install { _ in ok("{\"items\":[]}") }
        let now = harness.client.currentOwnership(credentialsReadable: true)
        let other = RequestOwnership(account: "account-X", generation: now.generation, epoch: now.epoch)
        let result = await send(harness, other)
        XCTAssertEqual(result, .localReject(reason: LocalRejectReason.accountMismatch))
        XCTAssertTrue(StubURLProtocol.requests.isEmpty)
    }
}
