import Foundation
@testable import Network
import Session
import XCTest

/// D10-1927：未固定账号的 optional 读也必须在最终准入处拒绝屏障之前启动的旧调用。
final class FuIosTransportCloseRaceBarrierTests: XCTestCase {
    private final class Probe: HttpTransportProbe, @unchecked Sendable {
        private let lock = NSLock()
        private var log: [String] = []

        var events: [String] {
            lock.withLock { log }
        }

        func admitted(_ live: Bool) {
            lock.withLock { log.append("admit:\(live)") }
        }

        func starting(_ live: Bool) {
            lock.withLock { log.append("start:\(live)") }
        }

        func closeRequested() {}
        func invalidated() {}
    }

    /// 复用 sendAllowed 的第一次检查点：已过 attempt 的有效性检查，尚未组请求与进入传输层最终准入。
    private final class AdmissionPause: @unchecked Sendable {
        let reached = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let releasedInTime = Box<Bool>()
        private let lock = NSLock()
        private var armed = true

        func allow() -> Bool {
            let pause = lock.withLock {
                let wasArmed = armed
                armed = false
                return wasArmed
            }
            if pause {
                reached.signal()
                releasedInTime.value = release.wait(timeout: .now() + 5) == .success
            }
            return true
        }
    }

    private static func wait(_ semaphore: DispatchSemaphore, seconds: Double) -> Bool {
        semaphore.wait(timeout: .now() + seconds) == .success
    }

    func testUnpinnedOptionalReadBeforeWithdrawalIsNotSentThenUsesCurrentAuthorization() async throws {
        StubURLProtocol.install { _ in ok("{\"items\":[]}") }
        // 游客没有自动绑定的会话世代，也不传 expected；不能靠账号 / 会话检查掩盖最终作废世代检查缺失。
        let harness = makeHarness(tokens: MemorySessionTokens())
        let client = harness.client
        let probe = Probe()
        let pause = AdmissionPause()
        client.transport.installProbe(probe)
        defer {
            pause.release.signal()
            client.transport.installProbe(nil)
        }
        let call = ApiCall(operationId: "searchProducts", query: "q=barrier")
        let old = Task.detached {
            await client.send(call, isValid: { true }, sendAllowed: { pause.allow() })
        }
        let reached = await Task.detached { Self.wait(pause.reached, seconds: 5) }.value
        XCTAssertTrue(reached, "前提：屏障前已启动 optional 读，并停在最终准入之前")
        XCTAssertTrue(probe.events.isEmpty, "暂停时还没有最终准入与启动事件")
        XCTAssertTrue(StubURLProtocol.requests.isEmpty, "暂停时假服务零到达")

        client.raiseWithdrawalReadBarriers()
        harness.state.set(readable: false)
        XCTAssertTrue(client.withdrawalReadBarrierRaised, "前提：释放暂停之前屏障已竖起")
        pause.release.signal()
        let oldResult = await old.value

        XCTAssertEqual(pause.releasedInTime.value, true, "暂停必须由测试释放，不能靠超时推进")
        XCTAssertEqual(probe.events, ["admit:false", "start:false"], "旧调用必须走到传输层并被最终准入拒绝")
        XCTAssertEqual(oldResult, .localReject(reason: LocalRejectReason.callCancelled))
        XCTAssertFalse(oldResult.isSuccess)
        XCTAssertTrue(StubURLProtocol.requests.isEmpty, "屏障之前的 optional 读不得匿名漏发，假服务零到达")
        XCTAssertTrue(client.withdrawalReadBarrierRaised, "旧快照不得放下屏障")

        // 对照：重新同意、登录取得当前 access；之后的新可读快照放下屏障，同一操作带当前凭据写出。
        try harness.tokens.save(
            access: "access-current",
            refresh: "refresh-current",
            scope: "full",
            account: "account-A"
        )
        harness.state.set(readable: true)
        let fresh = await client.send(call)
        XCTAssertTrue(fresh.isSuccess, "\(fresh)")
        XCTAssertFalse(client.withdrawalReadBarrierRaised, "之后取得的可读快照放下屏障")
        XCTAssertEqual(probe.events, ["admit:false", "start:false", "admit:true", "start:true"])
        let requests = StubURLProtocol.requests
        XCTAssertEqual(requests.count, 1, "同一操作只有解除屏障后的新调用写出一次")
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(request.method, "GET")
        XCTAssertEqual(request.path, "/v1/products/search")
        XCTAssertEqual(request.query, "q=barrier")
        XCTAssertEqual(request.header("Authorization"), "Bearer access-current", "不得匿名发出或复用旧 access")
    }
}
