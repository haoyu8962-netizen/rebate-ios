import Foundation
@testable import Network
import XCTest

/// FU-IOS-0711 R1-01：传输层「最终准入通过 → 切换推进作废世代 → 旧任务 resume」的交错。
///
/// 用 `HttpTransportProbe` 在准入判定与 `task.resume` 之间停住旧请求，此时从另一线程调用 `invalidateSessions`
/// （切换环境 / 撤回同意的关闭步骤：`closeAll` 推进作废世代并取消在途任务）。暂停点等 `closeAll` 发起后，再最多等 1 秒看作废是否插进来：
/// - 修复后准入与 resume 同在传输锁里，`closeAll` 拿不到锁，作废只能排在启动之后，随后取消这个已启动的任务；
/// - 若 resume 在锁外（变异 M2b），作废会插在准入与启动之间，事件序列出现「作废之后才启动一个已准入的请求」。
final class TransportAdmissionCloseRaceTests: XCTestCase {
    /// 记录事件顺序；第一次「准入通过」时暂停（arm 之后一次）。
    private final class Probe: HttpTransportProbe, @unchecked Sendable {
        private let lock = NSLock()
        private var log: [String] = []
        private var armed = true
        private var pausing = false
        private var closeSeenWhilePaused = false
        private var invalidatedWhilePaused = false
        let admittedLive = DispatchSemaphore(value: 0)
        private let closeRequestedSignal = DispatchSemaphore(value: 0)
        private let invalidatedSignal = DispatchSemaphore(value: 0)

        var events: [String] {
            lock.withLock { log }
        }

        /// 暂停期间：`closeAll` 已发起 / 作废已执行（插进了准入与启动之间）。
        var pauseObservation: (closeRequested: Bool, invalidated: Bool) {
            lock.withLock { (closeSeenWhilePaused, invalidatedWhilePaused) }
        }

        func admitted(_ live: Bool) {
            let stop: Bool = lock.withLock {
                log.append("admit:\(live)")
                guard live, armed else {
                    return false
                }
                armed = false
                pausing = true
                return true
            }
            guard stop else {
                return
            }
            admittedLive.signal()
            let requested = closeRequestedSignal.wait(timeout: .now() + 5) == .success
            // 修复后作废拿不到传输锁、这里必然超时；锁外 resume 时作废立即执行。
            let invalidated = requested && invalidatedSignal.wait(timeout: .now() + 1) == .success
            lock.withLock {
                pausing = false
                closeSeenWhilePaused = requested
                invalidatedWhilePaused = invalidated
            }
        }

        func starting(_ live: Bool) {
            lock.withLock { log.append("start:\(live)") }
        }

        func closeRequested() {
            let signal: Bool = lock.withLock {
                log.append("closeRequested")
                return pausing
            }
            if signal {
                closeRequestedSignal.signal()
            }
        }

        func invalidated() {
            let signal: Bool = lock.withLock {
                log.append("invalidated")
                return pausing
            }
            if signal {
                invalidatedSignal.signal()
            }
        }
    }

    private static func wait(_ semaphore: DispatchSemaphore, seconds: Double) -> Bool {
        semaphore.wait(timeout: .now() + seconds) == .success
    }

    /// 准入通过后被抢占、切换的关闭步骤同时发起：启动与作废有严格先后（已准入的请求在作废之前启动），旧任务被取消；
    /// 作废之后的准入一律不通过；之后的新请求正常完成。
    func testAdmittedRequestStartsBeforeInvalidationAndIsCancelledNewRequestCompletes() async {
        let holdOld = Box<Bool>()
        holdOld.value = true
        StubURLProtocol.install { _ in
            (holdOld.value ?? false) ? .hold("old") : ok()
        }
        let harness = makeHarness()
        let client = harness.client
        let probe = Probe()
        client.transport.installProbe(probe)

        let old = Task.detached { await client.send(ApiCall(operationId: "getMe")) }
        let paused = await Task.detached { Self.wait(probe.admittedLive, seconds: 5) }.value
        XCTAssertTrue(paused, "前提：旧请求已通过最终准入、停在启动之前 \(probe.events)")
        let closing = Task.detached { client.invalidateSessions() }
        await closing.value
        let oldResult = await old.value
        holdOld.value = false

        let observed = probe.pauseObservation
        XCTAssertTrue(observed.closeRequested, "前提：关闭步骤在旧请求准入之后、启动之前发起 \(probe.events)")
        let events = probe.events
        let invalidatedAt = events.firstIndex(of: "invalidated")
        let startAt = events.firstIndex(of: "start:true")
        XCTAssertNotNil(invalidatedAt, "\(events)")
        XCTAssertNotNil(startAt, "\(events)")
        if let invalidatedAt, let startAt {
            XCTAssertLessThan(startAt, invalidatedAt, "已准入的旧请求先启动、后作废，不得在作废之后才启动 \(events)")
            let afterInvalidation = events[(invalidatedAt + 1)...]
            XCTAssertFalse(afterInvalidation.contains("admit:true"), "作废之后的准入一律不通过 \(events)")
            XCTAssertFalse(afterInvalidation.contains("start:true"), "作废之后不启动任何已准入请求 \(events)")
        }
        XCTAssertFalse(observed.invalidated, "作废不能插进准入与启动之间 \(events)")

        // 旧任务被取消：没有拿到响应，按传输取消（已写出、结果未知）或本地 call_cancelled 结束。
        let oldCancelled: Bool = {
            if case let .transportFailure(kind, _, _, _) = oldResult {
                return kind == HttpTransport.kindCancelled
            }
            return oldResult.notSentReason == LocalRejectReason.callCancelled
        }()
        XCTAssertTrue(oldCancelled, "旧任务被取消 \(oldResult)")
        XCTAssertFalse(oldResult.isSuccess, "\(oldResult)")
        let oldReachedServer = StubURLProtocol.requests.count
        XCTAssertTrue(oldReachedServer == 0 || StubURLProtocol.wasStopped("old"), "到达假服务的旧请求也被中止")

        // 新请求：作废之后取得的可读快照放下屏障，正常完成。
        let fresh = await client.send(ApiCall(operationId: "getMe"))
        XCTAssertTrue(fresh.isSuccess, "\(fresh)")
        XCTAssertEqual(StubURLProtocol.requests.count, oldReachedServer + 1, "新请求写出一次")
        client.transport.installProbe(nil)
    }
}
