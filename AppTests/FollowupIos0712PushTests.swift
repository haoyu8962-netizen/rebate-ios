import CouliNetwork
import Foundation
import MeCore
import Push
import XCTest

/// FU-IOS-0712 第 3 项（F-X-08 ②，跨端教训 19；Android FU-AND-0715 R2-01 / 鸿蒙 FU-HM-0719 同场景）：推送上报的 42901 限流计时绑定
/// 「当前会话 + 实际接纳该响应的那一轮」。真实 PushTokenReporter + 可控的异步端口（每条请求由测试放行）+ 注入时钟的闸门 + 可控的补发计时。
@MainActor
final class FollowupIos0712PushTests: XCTestCase {
    private var clock = PushClock()
    private var api = HeldMeApi()
    private var state = PushState()
    private var source = PushSource()
    private var timers = DeferTimers()

    private func make() -> PushTokenReporter {
        let clock = clock
        let timers = timers
        return PushTokenReporter(
            source: source, state: state, api: api, gate: RetryAfterGate(clock: { clock.now }),
            deferSleep: { millis in await timers.sleep(millis) }
        )
    }

    private static func limited(_ millis: Int64) -> ApiResult {
        .failure(
            code: 42901, msg: "", data: nil, traceId: "trace-push-000001",
            effect: ErrorEffect(code: 42901, kind: .disableButton, disableMillis: millis), idempotencyKey: nil
        )
    }

    private static let okResult = ApiResult.success(data: Data("{}".utf8), traceId: nil, idempotencyKey: nil)

    private func waitFor(_ what: String, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(30)
        while !condition() {
            guard Date() < deadline else {
                XCTFail("等待超时（30 秒）：\(what)")
                return
            }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    /// 会话 S1 → S2（App 的会话跟踪按 sessionChanged + loginSucceeded 通知）。
    private func switchToS2(_ reporter: PushTokenReporter) {
        state.session = "S2"
        state.generation = 2
        reporter.sessionChanged()
        reporter.loginSucceeded()
    }

    /// 评审原场景：S2 收 60 秒 42901 且有新令牌待补发之后，S1 迟到的 42901（300 秒）到达：不开始、不延长、不缩短 S2 的计时，S2 的补发任务
    /// 没被取消；S2 到期后按当时的会话与令牌补发一次。
    func testLate42901OfTheOldSessionAfterTheNewSessions42901KeepsTheNewLimit() async {
        let reporter = make()
        reporter.loginSucceeded()
        await waitFor("S1 发出") { api.calls.count == 1 }
        switchToS2(reporter)
        await waitFor("S2 发出") { api.calls.count == 2 }
        api.resolve(1, Self.limited(60000))
        await waitFor("S2 的 42901 结算") { reporter.limited && !reporter.inFlight }
        XCTAssertEqual(reporter.limitRound, 1)
        source.change("t3")
        await waitFor("禁用期内的新触发登记补发") { timers.pending.count == 1 }
        XCTAssertEqual(api.calls.count, 2, "禁用期内不发")

        api.resolve(0, Self.limited(300_000))
        await settle()
        XCTAssertEqual(reporter.limitRound, 1, "旧会话的 42901 不开始新一轮")
        XCTAssertLessThanOrEqual(reporter.gate.remainingMillis, 60000, "不延长")
        XCTAssertGreaterThan(reporter.gate.remainingMillis, 59000, "不缩短、不取消")
        XCTAssertEqual(timers.pending.count, 1, "S2 的补发计时还在")
        XCTAssertEqual(api.calls.count, 2)

        clock.advance(60001)
        timers.fireAll()
        await waitFor("到期补发一次") { api.calls.count == 3 }
        XCTAssertEqual(api.calls[2].token, "t3", "按当时的令牌")
        XCTAssertEqual(api.calls[2].owner?.generation, 2, "按当时的会话")
        await settle()
        XCTAssertEqual(api.calls.count, 3, "只补一次")
    }

    /// S2 的上报在途时 S1 迟到的 42901：不开始任何计时；S2 照常结算。
    func testLate42901OfTheOldSessionWhileTheNewReportIsInFlightStartsNoLimit() async {
        let reporter = make()
        reporter.loginSucceeded()
        await waitFor("S1 发出") { api.calls.count == 1 }
        switchToS2(reporter)
        await waitFor("S2 发出") { api.calls.count == 2 }
        api.resolve(0, Self.limited(60000))
        await settle()
        XCTAssertFalse(reporter.limited, "旧会话的 42901 不限流新会话")
        XCTAssertEqual(reporter.limitRound, 0)
        XCTAssertTrue(reporter.inFlight, "S2 仍在途")
        api.resolve(1, Self.okResult)
        await waitFor("S2 结算") { !reporter.inFlight }
        XCTAssertFalse(reporter.limited)
        XCTAssertTrue(reporter.reportedThisRun)
    }

    /// 会话已经变了、App 的会话跟踪还没来得及通知（旧请求的归属标记仍有效）时 S1 的 42901 到达：发起会话不是当前会话，不接纳、不计时。
    func testLate42901ArrivingBeforeTheSessionNoticeStartsNoLimit() async {
        let reporter = make()
        reporter.loginSucceeded()
        await waitFor("S1 发出") { api.calls.count == 1 }
        state.session = "S2"
        state.generation = 2
        api.resolve(0, Self.limited(60000))
        await settle()
        XCTAssertFalse(reporter.limited, "发起会话不是当前会话：不计时")
        XCTAssertEqual(reporter.limitRound, 0)
    }

    /// 同一会话里较早一轮的补发计时到期，不解除较新一轮的禁用期，也不补发。
    func testAnExpiredTimerOfAnOlderLimitRoundDoesNotLiftTheNewerLimit() async {
        let reporter = make()
        reporter.loginSucceeded()
        await waitFor("发出") { api.calls.count == 1 }
        api.resolve(0, Self.limited(5000))
        await waitFor("第 1 轮") { reporter.limitRound == 1 && !reporter.inFlight }
        source.change("t2")
        await waitFor("第 1 轮的补发计时") { timers.pending.count == 1 }
        // 第 1 轮按时钟到期、补发计时还没回调时，新触发先到：同步消费第 1 轮的补发，直接发出
        clock.advance(5001)
        source.change("t3")
        await waitFor("新触发发出") { api.calls.count == 2 }
        api.resolve(1, Self.limited(60000))
        await waitFor("第 2 轮") { reporter.limitRound == 2 && !reporter.inFlight }
        source.change("t4")
        await waitFor("第 2 轮的补发计时") { timers.pending.count == 2 }
        timers.fire(0)
        await settle()
        XCTAssertTrue(reporter.limited, "第 1 轮的计时不解除第 2 轮")
        XCTAssertEqual(api.calls.count, 2, "也不补发")
        clock.advance(60001)
        timers.fire(1)
        await waitFor("第 2 轮到期补发") { api.calls.count == 3 }
        XCTAssertEqual(api.calls[2].token, "t4")
    }

    /// 第 4 项（F-X-09）：推送上报得非强更的 10405 按普通失败（不交强更分流、失败不重试）；force_update 照旧交强更分流。
    func testNonForced10405IsAnOrdinaryFailureAndForcedGoesToForceUpdate() async {
        let reporter = make()
        reporter.loginSucceeded()
        await waitFor("发出") { api.calls.count == 1 }
        let refreshOnly = ErrorEffect(code: 10405, kind: .refreshOnly)
        api.resolve(
            0,
            .failure(code: 10405, msg: "", data: nil, traceId: nil, effect: refreshOnly, idempotencyKey: nil)
        )
        await waitFor("结算") { !reporter.inFlight }
        await settle()
        XCTAssertEqual(state.forceUpdates, 0, "不进强更")
        XCTAssertEqual(api.calls.count, 1, "失败不自动重试")
        source.change("t2")
        await waitFor("新触发照常上报") { api.calls.count == 2 }
        let forced = ErrorEffect(code: 10405, kind: .forceUpdate)
        api.resolve(1, .failure(code: 10405, msg: "", data: nil, traceId: nil, effect: forced, idempotencyKey: nil))
        await waitFor("强更分流") { state.forceUpdates == 1 }
    }

    private func settle() async {
        for _ in 0..<20 {
            await Task.yield()
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
    }
}

final class PushClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Int64 = 1_790_000_000_000

    var now: Int64 {
        lock.withLock { value }
    }

    func advance(_ millis: Int64) {
        lock.withLock { value += millis }
    }
}

/// 可控的补发计时：记下每次等待，测试放行（被取消的任务放行后由执行器自己丢弃）。
@MainActor
final class DeferTimers {
    private(set) var pending: [UInt64] = []
    private var fired: Set<Int> = []

    func sleep(_ millis: UInt64) async {
        let index = pending.count
        pending.append(millis)
        while !fired.contains(index) {
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
    }

    func fire(_ index: Int) {
        fired.insert(index)
    }

    func fireAll() {
        fired.formUnion(0..<pending.count)
    }
}

@MainActor
final class PushState: PushReportState {
    var session = "S1"
    var generation: UInt64 = 1

    func level() -> String {
        "member"
    }

    func sessionScope() -> String {
        "full"
    }

    func forceUpdate() -> String {
        "supported"
    }

    func sessionKey() -> String {
        session
    }

    func ownership() -> RequestOwnership? {
        RequestOwnership(account: "user-" + session, generation: generation, epoch: 0)
    }

    private(set) var forceUpdates = 0

    func onForceUpdate() {
        forceUpdates += 1
    }
}

@MainActor
final class PushSource: PushTokenSource {
    private var token = "t1"
    private var listeners: [@MainActor () -> Void] = []

    func start() {}

    func stop() {}

    func current() -> String? {
        token
    }

    func subscribe(_ listener: @escaping @MainActor () -> Void) -> () -> Void {
        listeners.append(listener)
        return {}
    }

    func change(_ value: String) {
        token = value
        listeners.forEach { $0() }
    }
}

/// 每条请求挂起，测试按序号放行。
final class HeldMeApi: MeApi, @unchecked Sendable {
    struct Call {
        let token: String?
        let owner: RequestOwnership?
    }

    private let lock = NSLock()
    private var recorded: [Call] = []
    private var waiters: [Int: CheckedContinuation<ApiResult, Never>] = [:]

    var calls: [Call] {
        lock.withLock { recorded }
    }

    func send(
        _ call: ApiCall, isValid _: @escaping @Sendable () -> Bool, sendAllowed _: @escaping @Sendable () -> Bool,
        expected: RequestOwnership?
    ) async -> ApiResult {
        let body = call.body.flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
        return await withCheckedContinuation { continuation in
            lock.withLock {
                waiters[recorded.count] = continuation
                recorded.append(Call(token: body?["token"] as? String, owner: expected))
            }
        }
    }

    func resolve(_ index: Int, _ result: ApiResult) {
        let waiter = lock.withLock { waiters.removeValue(forKey: index) }
        waiter?.resume(returning: result)
    }
}
