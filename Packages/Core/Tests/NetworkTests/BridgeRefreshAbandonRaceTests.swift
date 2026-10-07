import Foundation
@testable import Network
import Session
import XCTest

/// APP-04 iOS 第 4 轮评审 R4-01：作废刷新窗口与调用方入队是原子的。判空之后、作废之前有调用方入队就重新判断；
/// 已作废的窗口不再接收有效调用方，它们等作废窗口结算后重新入队（不会两个窗口同时拿旧 refresh_token 刷新）。
final class BridgeRefreshAbandonRaceTests: XCTestCase {
    private static let skewedDate = ["Date": "Tue, 29 Sep 2026 07:00:00 GMT"]

    /// 桥调用到期：BridgeHost 先撤销有效性、再取消执行它的 Task。
    private func expire(_ valid: Box<Bool>, _ call: Task<ApiResult, Never>) {
        valid.value = false
        call.cancel()
    }

    /// 在同步回调里（判空之后、作废之前）让 B 发起 getMe：B 收到 10002 后并入当前刷新窗口，回调阻塞到 B 已登记为止。
    private static func enqueueCallerSynchronously(
        _ client: ApiClient, isValid: @escaping @Sendable () -> Bool
    ) -> Task<ApiResult, Never> {
        let before = client.lock.withLock { client.refreshWindows.values.first?.callers.count ?? 0 }
        let task = Task.detached { await client.send(ApiCall(operationId: "getMe"), isValid: isValid) }
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            let count = client.lock.withLock { client.refreshWindows.values.first?.callers.count ?? 0 }
            if count > before {
                break
            }
            usleep(2000)
        }
        return task
    }

    /// 原场景：窗口里 A（桥调用）与 C（已失效、尚未结束）。A 到期 → 判定时读到 C 失效、窗口里已没有有效调用方；
    /// 就在判空之后、作废之前，B（有效）收到 10002 并入同一窗口 → 不得作废窗口、不得取消在途刷新；B 拿到新令牌重放成功。
    func testCallerJoiningAfterEmptyCheckKeepsRefresh() async {
        let harness = makeHarness()
        StubURLProtocol.install { request in
            switch request.path {
            case "/v1/auth/refresh":
                return .hold("race-refresh")
            default:
                if request.header("Authorization") == "Bearer access-2" {
                    return ok()
                }
                return fail(10002, status: 401)
            }
        }
        let client = harness.client
        let validA = Box<Bool>()
        validA.value = true
        let validC = Box<Bool>()
        validC.value = true
        let probe = Box<Bool>()
        probe.value = false
        let joined = Box<Task<ApiResult, Never>>()
        let first = Task { await client.send(ApiCall(operationId: "getMe"), isValid: { validA.value ?? false }) }
        await StubURLProtocol.waitUntilHeld("race-refresh")
        let third = Task {
            await client.send(ApiCall(operationId: "getMe"), isValid: {
                // C 的有效性在锁外求值：第一次被问到时（A 到期后的判空）让 B 入队，再报告 C 已失效。
                if probe.value == true {
                    probe.value = false
                    joined.value = Self.enqueueCallerSynchronously(client) { true }
                }
                return validC.value ?? false
            })
        }
        for _ in 0..<200 where client.lock.withLock({ client.refreshWindows.values.first?.callers.count ?? 0 }) < 2 {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        validC.value = false
        probe.value = true
        expire(validA, first)
        XCTAssertNotNil(joined.value, "交错已发生：判空时 B 入队")
        try? await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertFalse(StubURLProtocol.wasStopped("race-refresh"), "B 仍有效：刷新不取消")
        StubURLProtocol.release("race-refresh", with: ok(refreshData(access: "access-2")))
        let resultA = await first.value
        let resultB = await joined.value?.value
        let resultC = await third.value
        XCTAssertEqual(resultA.rejectReason, LocalRejectReason.callCancelled)
        XCTAssertEqual(resultC.rejectReason, LocalRejectReason.callCancelled)
        XCTAssertTrue(resultB?.isSuccess ?? false, "B 照常重放：\(String(describing: resultB))")
        XCTAssertEqual(StubURLProtocol.requests(path: "/v1/auth/refresh").count, 1, "只刷新一次")
        XCTAssertEqual(harness.tokens.accessToken, "access-2")
    }

    /// 窗口已作废（唯一调用方 A 失效，刷新响应 10401 不再校时重签）、尚未结算时 B 收到 10002：B 不拿作废窗口的
    /// call_cancelled，等它结算后另开窗口刷新并重放成功；两个窗口先后进行，不同时拿旧 refresh_token 刷新。
    func testCallerJoiningAbandonedWindowRefreshesAfterItSettles() async {
        let harness = makeHarness()
        let refreshes = Box<Int>()
        refreshes.value = 0
        let inFlight = Box<Int>()
        inFlight.value = 0
        StubURLProtocol.install { request in
            switch request.path {
            case "/v1/auth/refresh":
                refreshes.value = (refreshes.value ?? 0) + 1
                if refreshes.value == 1 {
                    return .hold("abandoned-refresh")
                }
                return ok(refreshData(access: "access-2"))
            default:
                return request.header("Authorization") == "Bearer access-2" ? ok() : fail(10002, status: 401)
            }
        }
        let client = harness.client
        let validA = Box<Bool>()
        validA.value = true
        let joined = Box<Task<ApiResult, Never>>()
        let first = Task { await client.send(ApiCall(operationId: "getMe"), isValid: { validA.value ?? false }) }
        await StubURLProtocol.waitUntilHeld("abandoned-refresh")
        // 作废窗口结算前要再读一次状态：在这一步让 B 入队（窗口此时已作废、仍未摘下）。
        harness.state.onRead = { index in
            guard index == 1 else {
                return
            }
            inFlight.value = client.refreshing ? 1 : 0
            joined.value = Self.enqueueCallerSynchronously(client) { true }
        }
        validA.value = false
        StubURLProtocol.release("abandoned-refresh", with: fail(10401, status: 401, headers: Self.skewedDate))
        let resultA = await first.value
        for _ in 0..<200 where joined.value == nil {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        let resultB = await joined.value?.value
        harness.state.onRead = nil
        XCTAssertEqual(resultA.rejectReason, LocalRejectReason.callCancelled)
        XCTAssertEqual(inFlight.value, 1, "B 入队时作废窗口仍在")
        XCTAssertTrue(resultB?.isSuccess ?? false, "B 另开窗口刷新后重放：\(String(describing: resultB))")
        XCTAssertEqual(StubURLProtocol.requests(path: "/v1/auth/refresh").count, 2, "作废窗口 1 次 + B 的新窗口 1 次")
        XCTAssertEqual(client.refreshCalls, 2)
        XCTAssertEqual(client.clockOffsetMillis, 0, "作废窗口不校时")
        XCTAssertEqual(harness.tokens.accessToken, "access-2")
    }
}
