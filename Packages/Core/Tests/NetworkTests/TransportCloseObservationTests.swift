import Foundation
import XCTest

/// 一次原子读取的累计到达记录与中止状态；同一份值供中止与计数断言使用。
struct TransportCloseObservation: Equatable, Sendable {
    let oldCount: Int
    let freshCount: Int
    let oldStopped: Bool

    var oldStopSatisfied: Bool {
        oldCount == 0 || oldStopped
    }
}

enum TransportCloseObservationWindow {
    /// now / sleepUntil 使用同一单调时间轴；read 返回累计历史，窗口内不重置记录。
    /// 未见旧请求也持续观察至截止；只有已到达且已中止可以提前结束。
    static func observe(
        now: @Sendable () -> Duration,
        sleepUntil: @Sendable (Duration) async -> Void,
        read: @Sendable () -> TransportCloseObservation
    ) async -> TransportCloseObservation {
        let deadline = now() + .seconds(2)
        while true {
            let instant = now()
            let observation = read()
            if instant >= deadline || (observation.oldCount > 0 && observation.oldStopped) {
                return observation
            }
            await sleepUntil(min(deadline, instant + .milliseconds(10)))
        }
    }
}

final class TransportCloseObservationTests: XCTestCase {
    private struct Event: Sendable {
        let at: Duration
        let observation: TransportCloseObservation
    }

    /// 只有 sleepUntil 推进虚拟单调时钟，事件按时间确定性出现，不等待真实调度或 URLProtocol。
    private final class Timeline: @unchecked Sendable {
        private let lock = NSLock()
        private let events: [Event]
        private var instant: Duration = .zero
        private var observations: [TransportCloseObservation] = []

        init(_ events: [Event]) {
            self.events = events
        }

        var now: Duration {
            lock.withLock { instant }
        }

        var firstObservation: TransportCloseObservation? {
            lock.withLock { observations.first }
        }

        func advance(to deadline: Duration) {
            lock.withLock { instant = deadline }
        }

        func read() -> TransportCloseObservation {
            lock.withLock {
                let observation = events.last { $0.at <= instant }?.observation
                    ?? TransportCloseObservation(oldCount: 0, freshCount: 0, oldStopped: false)
                observations.append(observation)
                return observation
            }
        }

        func observe() async -> TransportCloseObservation {
            await TransportCloseObservationWindow.observe(
                now: { self.now },
                sleepUntil: { self.advance(to: $0) },
                read: { self.read() }
            )
        }
    }

    func testInitiallyEmptyThenOldArrivesWithoutStopFailsAtDeadline() async {
        let timeline = Timeline([
            .init(at: .milliseconds(10), observation: .init(oldCount: 0, freshCount: 1, oldStopped: false)),
            // 恰在窗口末尾到达：最后一次读取也必须参与中止与计数判定。
            .init(at: .seconds(2), observation: .init(oldCount: 1, freshCount: 1, oldStopped: false)),
        ])
        let final = await timeline.observe()
        XCTAssertEqual(timeline.firstObservation, .init(oldCount: 0, freshCount: 0, oldStopped: false))
        XCTAssertEqual(timeline.now, .seconds(2), "首次未到达不能提前结束观察")
        XCTAssertEqual(final, .init(oldCount: 1, freshCount: 1, oldStopped: false))
        XCTAssertFalse(final.oldStopSatisfied, "首次为空、随后到达且永不中止必须判失败")
    }

    func testInitiallyEmptyThenOldArrivesAndStopsPassesEarly() async {
        let timeline = Timeline([
            .init(at: .milliseconds(10), observation: .init(oldCount: 0, freshCount: 1, oldStopped: false)),
            .init(at: .milliseconds(20), observation: .init(oldCount: 1, freshCount: 1, oldStopped: false)),
            .init(at: .milliseconds(30), observation: .init(oldCount: 1, freshCount: 1, oldStopped: true)),
        ])
        let final = await timeline.observe()
        XCTAssertEqual(timeline.firstObservation, .init(oldCount: 0, freshCount: 0, oldStopped: false))
        XCTAssertEqual(timeline.now, .milliseconds(30), "已到达且已中止才提前结束")
        XCTAssertEqual(final, .init(oldCount: 1, freshCount: 1, oldStopped: true))
        XCTAssertTrue(final.oldStopSatisfied)
    }

    func testOldNeverArrivesPassesOnlyAtDeadline() async {
        let timeline = Timeline([
            .init(at: .milliseconds(10), observation: .init(oldCount: 0, freshCount: 1, oldStopped: false)),
        ])
        let final = await timeline.observe()
        XCTAssertEqual(timeline.firstObservation, .init(oldCount: 0, freshCount: 0, oldStopped: false))
        XCTAssertEqual(timeline.now, .seconds(2), "从未到达也必须等满观察窗口")
        XCTAssertEqual(final, .init(oldCount: 0, freshCount: 1, oldStopped: false))
        XCTAssertTrue(final.oldStopSatisfied, "从未到达无需中止")
    }
}
