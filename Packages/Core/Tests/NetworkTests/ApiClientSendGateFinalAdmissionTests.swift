import Foundation
@testable import Network
import XCTest

/// APP-08 iOS 第 1 轮评审 R1-03（共性第 32 条）：发送前闸门在传输层最终准入处再核对一次。
/// 场景：请求 A 已通过 admit 的闸门检查，之后、实际写出前并发请求 B 收到 42901 启动共享禁用期 → A 不得写出，本地结束 send_blocked。
final class ApiClientSendGateFinalAdmissionTests: XCTestCase {
    /// 闸门在 admit 时放行、传输层写出前不放行（模拟 B 在两者之间启动禁用期）：不写出，返回 send_blocked。
    func testGateClosedBetweenAdmitAndWriteBlocksAtTransport() async {
        let harness = makeHarness()
        StubURLProtocol.install { _ in ok("{\"items\":[]}") }
        let checks = Box<Int>()
        let result = await harness.client.send(
            ApiCall(operationId: "listOrders", query: "scope=self"),
            isValid: { true },
            sendAllowed: {
                checks.value = (checks.value ?? 0) + 1
                // 第 1 次（admit）放行；第 2 次（传输层最终准入）已在禁用期
                return checks.value == 1
            }
        )
        XCTAssertEqual(result, .localReject(reason: LocalRejectReason.sendBlocked))
        XCTAssertTrue(StubURLProtocol.requests.isEmpty, "禁用期内一个包都不写出")
        XCTAssertEqual(checks.value, 2, "admit 与传输层最终准入各核对一次")
    }

    /// 归属先于闸门：最终准入时归属已失效，仍按 call_cancelled（不把限流混进归属，也不把作废报成限流）。
    func testOwnershipLostAtTransportStaysCallCancelled() async {
        let harness = makeHarness()
        StubURLProtocol.install { _ in ok("{\"items\":[]}") }
        let allowChecks = Box<Int>()
        let ownership = Box<Bool>()
        ownership.value = true
        let result = await harness.client.send(
            ApiCall(operationId: "listOrders", query: "scope=self"),
            isValid: { ownership.value ?? false },
            sendAllowed: {
                allowChecks.value = (allowChecks.value ?? 0) + 1
                // admit 放行后归属失效、闸门也关：传输层先看归属
                ownership.value = false
                return allowChecks.value == 1
            }
        )
        XCTAssertEqual(result, .localReject(reason: LocalRejectReason.callCancelled))
        XCTAssertTrue(StubURLProtocol.requests.isEmpty)
    }

    /// 非订单请求（不带闸门）行为不变：照常写出、照常收结果。
    func testCallsWithoutGateUnchanged() async {
        let harness = makeHarness()
        StubURLProtocol.install { _ in ok("{\"items\":[]}") }
        let result = await harness.client.send(ApiCall(operationId: "listOrders", query: "scope=self"))
        if case .success = result {} else {
            XCTFail("不带闸门的调用照常成功：\(result)")
        }
        let withValid = await harness.client.send(
            ApiCall(operationId: "listOrders", query: "scope=self"), isValid: { true }
        )
        if case .success = withValid {} else {
            XCTFail("只带归属的调用照常成功：\(withValid)")
        }
        XCTAssertEqual(StubURLProtocol.requests.count, 2)
    }
}
