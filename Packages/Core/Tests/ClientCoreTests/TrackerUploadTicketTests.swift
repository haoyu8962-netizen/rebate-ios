import ClientCore
import Foundation
import Generated
import XCTest

/// iOS 第 1 轮评审 R1-05（S2，F-AND-12）：批次带发送票据交给 sink；交接之后撤回同意、切换环境时票据作废、
/// sink 登记的发送任务被取消。
final class TrackerUploadTicketTests: XCTestCase {
    /// 只登记交接、稍后发送的 sink。
    private final class DeferredSink {
        var tickets: [TrackerUploadTicket] = []
        let cancelled = Counter()

        func accept(_: [String], _ ticket: TrackerUploadTicket) -> Bool {
            tickets.append(ticket)
            let cancelled = cancelled
            ticket.onCancel { _ = cancelled.next() }
            return true
        }
    }

    private func makeQueue(_ file: MemoryFile, _ sink: DeferredSink) -> TrackerQueue {
        TrackerQueue(
            readFile: file.read, writeFile: file.write, sink: { _ in false }, privacy: TrackerQueue.consented,
            userId: { nil }, currentDeviceId: { "device-t" }, platform: "ios", appVersion: "1.2.0",
            channel: "appstore", sessionId: "session-t", clock: { 1_790_661_600_000 }, canUpload: { true },
            ticketedSink: sink.accept, clientTicket: { 7 }
        )
    }

    func testWithdrawalCancelsHandedOffBatch() {
        let sink = DeferredSink()
        let queue = makeQueue(MemoryFile(), sink)
        XCTAssertTrue(queue.track(event: ClientEvents.appLaunch(page: "Home")))
        queue.flush()
        let ticket = try? XCTUnwrap(sink.tickets.first)
        XCTAssertEqual(ticket?.isValid, true)
        XCTAssertEqual(ticket?.clientTicket, 7, "带上交接时的 ApiClient 票据")

        queue.onPrivacyChanged(state: "basic_mode")

        XCTAssertEqual(ticket?.isValid, false, "撤回同意后已交接的批次不得再发送")
        XCTAssertEqual(sink.cancelled.next(), 2, "sink 登记的发送任务被取消一次")
    }

    func testEnvironmentCleanupCancelsHandedOffBatch() throws {
        let sink = DeferredSink()
        let queue = makeQueue(MemoryFile(), sink)
        XCTAssertTrue(queue.track(event: ClientEvents.appLaunch(page: "Home")))
        queue.flush()
        let ticket = try XCTUnwrap(sink.tickets.first)

        try queue.clearForCleanup()

        XCTAssertFalse(ticket.isValid)
        let late = Counter()
        ticket.onCancel { _ = late.next() }
        XCTAssertEqual(late.next(), 2, "作废后登记的取消动作立即执行")
    }

    func testFinishedTicketIsNotCancelledLater() throws {
        let sink = DeferredSink()
        let queue = makeQueue(MemoryFile(), sink)
        XCTAssertTrue(queue.track(event: ClientEvents.appLaunch(page: "Home")))
        queue.flush()
        let ticket = try XCTUnwrap(sink.tickets.first)
        ticket.finish()

        try queue.clearForCleanup()

        XCTAssertEqual(sink.cancelled.next(), 1, "已结束的发送不再取消")
    }

    /// R2-03：sink 同步拒收（不结束票据）时，队列立即结束并移除票据；定时重试连续失败多次，票据数不增长。
    func testRepeatedSynchronousFailuresDoNotAccumulateTickets() {
        var handed: [TrackerUploadTicket] = []
        let queue = TrackerQueue(
            readFile: MemoryFile().read, writeFile: MemoryFile().write, sink: { _ in false },
            privacy: TrackerQueue.consented, userId: { nil }, currentDeviceId: { "device-t" }, platform: "ios",
            appVersion: "1.2.0", channel: "appstore", sessionId: "session-t", clock: { 1_790_661_600_000 },
            canUpload: { true },
            ticketedSink: { _, ticket in
                handed.append(ticket)
                return false
            }
        )
        XCTAssertTrue(queue.track(event: ClientEvents.appLaunch(page: "Home")))

        for _ in 0..<6 {
            queue.flush()
        }

        XCTAssertEqual(handed.count, 6, "每次触发都交给 sink 一次")
        XCTAssertEqual(queue.outstandingTickets, 0, "同步拒收的批次票据立即结束并移除")
        XCTAssertEqual(queue.queueSize, 1, "失败的事件留在队列里")
    }

    /// R2-03：sink 同步完成（已结束票据）后不再保留票据；仍在发送中的票据保留到结束或作废。
    func testOnlyInFlightTicketsAreRetained() {
        let deferred = DeferredSink()
        var finishNow = true
        let queue = TrackerQueue(
            readFile: MemoryFile().read, writeFile: MemoryFile().write, sink: { _ in false },
            privacy: TrackerQueue.consented, userId: { nil }, currentDeviceId: { "device-t" }, platform: "ios",
            appVersion: "1.2.0", channel: "appstore", sessionId: "session-t", clock: { 1_790_661_600_000 },
            canUpload: { true },
            ticketedSink: { batch, ticket in
                if finishNow {
                    ticket.finish()
                    return false
                }
                return deferred.accept(batch, ticket)
            }
        )
        XCTAssertTrue(queue.track(event: ClientEvents.appLaunch(page: "Home")))
        queue.flush()
        queue.flush()
        XCTAssertEqual(queue.outstandingTickets, 0)

        finishNow = false
        queue.flush()
        XCTAssertEqual(queue.outstandingTickets, 1, "交接后仍在发送中的批次保留票据")
    }
}
