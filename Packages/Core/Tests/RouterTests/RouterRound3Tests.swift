import Foundation
import Generated
import XCTest
@testable import Router

/// 评审第 2 轮（ios-review-r2.md R2-01、R2-02）与三端统一要求自查的回归测试。

/// 挂起的回查：`wait()` 一直不返回，直到测试 `release(with:)`；不响应任务取消。
private actor HeldLookup {
    private var waiters: [CheckedContinuation<PushLookupResult, Never>] = []
    private(set) var started = false
    private(set) var calls = 0

    func wait() async -> PushLookupResult {
        started = true
        calls += 1
        return await withCheckedContinuation { waiters.append($0) }
    }

    func release(with outcome: PushLookupResult) {
        waiters.forEach { $0.resume(returning: outcome) }
        waiters = []
    }
}

/// 回查次数计数。
private actor CallCounter {
    private(set) var value = 0

    func increment() {
        value += 1
    }
}

/// 只在 `delay` 之后靠 DispatchQueue 回调返回、完全不理会取消的回查。
private final class LateFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    var isDone: Bool {
        lock.lock()
        defer { lock.unlock() }
        return done
    }

    func markDone() {
        lock.lock()
        done = true
        lock.unlock()
    }
}

private func lateLookup(after delay: TimeInterval, flag: LateFlag,
                        outcome: PushLookupResult) async -> PushLookupResult {
    await withCheckedContinuation { continuation in
        DispatchQueue.global().asyncAfter(deadline: .now() + delay) {
            flag.markDone()
            continuation.resume(returning: outcome)
        }
    }
}

private func seconds(_ duration: Duration) -> Double {
    let parts = duration.components
    return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
}

@MainActor
final class RouterPushGenerationTests: XCTestCase {
    private var guardState = GuardState(
        privacyState: .consented,
        updateState: .ok,
        sessionState: .loggedIn,
        environmentSettled: true,
        appVersion: "1.0.0",
        isDebugBuild: false
    )
    private var now: Int64 = 1_000_000
    private let withdrawalOfA = PushLookupResult.found(
        route: "WithdrawRecords",
        params: ["withdrawal_id": .string("wA")]
    )

    private func makeRouter(backend: MemoryPendingBackend = MemoryPendingBackend()) -> Router {
        let store = PendingActionStore(backend: backend, clock: { [unowned self] in now })
        return Router(pendingStore: store, state: { [unowned self] in guardState })
    }

    /// 运行中点击推送（公开入口 handlePush）：回查挂起期间执行 `during`，再放行回查并等任务结束。
    private func hotPush(_ router: Router, outcome: PushLookupResult, during: () -> Void) async throws {
        let held = HeldLookup()
        let landing = PushLanding(timeout: .seconds(30)) { _ in await held.wait() }
        let task = try XCTUnwrap(router.handlePush(messageId: "m1", using: landing))
        while await !held.started {
            await Task.yield()
        }
        during()
        await held.release(with: outcome)
        await task.value
    }

    func testHotPushControlOpensLookedUpRoute() async throws {
        let router = makeRouter()
        try await hotPush(router, outcome: withdrawalOfA) {}
        XCTAssertEqual(router.path.map(\.route), ["WithdrawRecords"])
        XCTAssertEqual(router.path.first?.params, ["withdrawal_id": .string("wA")])
    }

    /// A 登录 → 回查挂起 → 退出 → B 登录 → 旧结果不打开、不带 A 的参数。
    func testHotPushAccountSwitchDiscardsStaleResult() async throws {
        let backend = MemoryPendingBackend()
        let router = makeRouter(backend: backend)
        try await hotPush(router, outcome: withdrawalOfA) {
            guardState.session = .guest
            router.sessionEnded()
            guardState.session = .loggedIn // 账号 B
        }
        XCTAssertTrue(router.path.isEmpty, "旧账号的回查结果不打开")
        XCTAssertNil(router.lastDecision, "旧结果不产生任何结论")
        XCTAssertNil(backend.read(), "不为 B 登记带 A 参数的动作")
    }

    func testHotPushEnvironmentSwitchDiscardsStaleResult() async throws {
        let backend = MemoryPendingBackend()
        let router = makeRouter(backend: backend)
        try await hotPush(router, outcome: withdrawalOfA) {
            router.environmentChanged()
        }
        XCTAssertTrue(router.path.isEmpty)
        XCTAssertNil(backend.read())
        XCTAssertFalse(router.hasPendingLaunchIntent)
    }

    /// 直接用公开的 PushLanding.land 取结果，再交给 Router：必须带发起时的代次，代次不符丢弃。
    func testLandThenApplyWithStaleGenerationIsDropped() async {
        let router = makeRouter()
        let issued = router.currentGeneration
        let outcome = withdrawalOfA
        let landing = PushLanding { _ in outcome }
        let result = await landing.land(messageId: "m1", state: guardState)
        guardState.session = .guest
        router.sessionEnded()
        guardState.session = .loggedIn // 账号 B
        router.applyPush(result, issuedAt: issued)
        XCTAssertTrue(router.path.isEmpty)

        let envIssued = router.currentGeneration
        router.environmentChanged()
        router.applyPush(result, issuedAt: envIssued)
        XCTAssertTrue(router.path.isEmpty)

        router.applyPush(result, issuedAt: router.currentGeneration)
        XCTAssertEqual(router.path.map(\.route), ["WithdrawRecords"], "代次相符时照常执行")
    }

    /// 冷启动队列里的推送：A 的回查挂起时切到 B，旧结果同样丢弃。
    func testColdPushAccountSwitchDiscardsStaleResult() async throws {
        let router = makeRouter()
        let held = HeldLookup()
        let landing = PushLanding(timeout: .seconds(30)) { _ in await held.wait() }
        router.enqueueLaunch(.push(messageId: "m1"))
        let ready = LaunchReadiness(environmentSettled: true, privacy: .consented, update: .finished(.ok))
        let task = try XCTUnwrap(router.drainLaunchQueue(readiness: ready, now: now, pushLanding: landing))
        while await !held.started {
            await Task.yield()
        }
        router.sessionEnded()
        await held.release(with: withdrawalOfA)
        await task.value
        XCTAssertTrue(router.path.isEmpty)
    }

    // MARK: - 回查前置条件

    func testNoLookupBeforeGuardPrerequisites() async {
        let cases: [(String, (inout GuardState) -> Void)] = [
            ("环境未就绪", { $0.environmentSettled = false }),
            ("隐私未决", { $0.privacy = .notDecided }),
            ("基本模式", { $0.privacy = .basicMode }),
            ("低于最低版本", { $0.update = .belowMin }),
            ("受限会话", { $0.session = .restricted }),
            ("游客", { $0.session = .guest }),
        ]
        for (name, mutate) in cases {
            guardState = GuardState(
                privacyState: .consented,
                updateState: .ok,
                sessionState: .loggedIn,
                environmentSettled: true,
                appVersion: "1.0.0",
                isDebugBuild: false
            )
            mutate(&guardState)
            let counter = CallCounter()
            let landing = PushLanding { _ in
                await counter.increment()
                return .found(route: "Wallet", params: [:])
            }
            let router = makeRouter()
            let task = router.handlePush(messageId: "m1", using: landing)
            XCTAssertNil(task, "\(name)：不发回查")
            await task?.value
            let calls = await counter.value
            XCTAssertEqual(calls, 0, name)
            // land 本身也先过前置条件。
            _ = await landing.land(messageId: "m1", state: guardState)
            let after = await counter.value
            XCTAssertEqual(after, 0, "\(name)：land 也不回查")
        }
    }

    func testHotPushWhileEnvironmentUnsettledIsQueuedThenLookedUp() async throws {
        guardState.environmentSettled = false
        let router = makeRouter()
        let landing = PushLanding { _ in .found(route: "Wallet", params: [:]) }
        XCTAssertNil(router.handlePush(messageId: "m1", using: landing))
        XCTAssertTrue(router.hasPendingLaunchIntent, "等待：排进启动队列")
        guardState.environmentSettled = true
        let ready = LaunchReadiness(environmentSettled: true, privacy: .consented, update: .finished(.ok))
        let task = try XCTUnwrap(router.drainLaunchQueue(readiness: ready, now: now, pushLanding: landing))
        await task.value
        XCTAssertEqual(router.path.map(\.route), ["Wallet"])
    }

    func testRestrictedSessionGoesToLoginAndRemembersMessagesOnly() {
        guardState.session = .restricted
        let backend = MemoryPendingBackend()
        let router = makeRouter(backend: backend)
        let landing = PushLanding { _ in .found(route: "Wallet", params: [:]) }
        XCTAssertNil(router.handlePush(messageId: "m1", using: landing))
        XCTAssertEqual(router.path.map(\.route), ["Login"])
        XCTAssertNotNil(backend.read())
        XCTAssertFalse(backend.read()?.contains("m1") ?? true, "不带消息编号")
    }

    // MARK: - Messages 兜底也经守卫

    func testMessagesFallbackIsGuarded() {
        var routes = Routes.all
        routes.removeValue(forKey: RoutePolicy.messages)
        let fallback = GuardDecision(kind: .open, route: RoutePolicy.messages, reason: GuardReason.pushEntryFallback)
        let blocked = PushLanding.guardedFallback(
            fallback,
            for: RouteRequest(route: "Login", from: .push),
            state: guardState,
            routes: routes
        )
        XCTAssertEqual(blocked.kind, .upgrade, "Messages 本身过不了守卫就不打开")

        var guest = guardState
        guest.session = .guest
        let login = PushLanding.guardedFallback(
            fallback,
            for: RouteRequest(route: "Login", from: .push),
            state: guest,
            routes: Routes.all
        )
        XCTAssertEqual(login.kind, .requireLogin)

        let ok = PushLanding.guardedFallback(
            fallback,
            for: RouteRequest(route: "Login", from: .push),
            state: guardState,
            routes: Routes.all
        )
        XCTAssertEqual(ok, fallback)
    }

    func testTimeoutFallbackOpensMessagesThroughGuardWithoutParams() async {
        let landing = PushLanding(timeout: .milliseconds(50)) { _ in
            await withCheckedContinuation { (_: CheckedContinuation<PushLookupResult, Never>) in }
        }
        let result = await landing.land(messageId: "m1", state: guardState)
        XCTAssertEqual(result.request?.route, RoutePolicy.messages)
        XCTAssertEqual(result.request?.paramValues, [:])
        XCTAssertEqual(
            result.decision,
            GuardDecision(kind: .open, route: RoutePolicy.messages, reason: GuardReason.allowed)
        )
    }
}

/// R2-02：回查不响应取消时，5 秒到点立即落到 Messages。
@MainActor
final class PushLookupTimeoutTests: XCTestCase {
    private var guardState = GuardState(
        privacyState: .consented,
        updateState: .ok,
        sessionState: .loggedIn,
        environmentSettled: true,
        appVersion: "1.0.0",
        isDebugBuild: false
    )

    func testDefaultTimeoutIsFiveSeconds() {
        XCTAssertEqual(PushLanding.lookupTimeout, .seconds(5))
    }

    /// 回查永不返回（也不理会取消）：默认 5 秒时返回 Messages。
    func testNeverReturningLookupFallsBackAtFiveSeconds() async {
        let held = HeldLookup()
        let landing = PushLanding { _ in await held.wait() }
        let clock = ContinuousClock()
        let start = clock.now
        let result = await landing.land(messageId: "m1", state: guardState)
        let elapsed = seconds(clock.now - start)
        XCTAssertEqual(result.decision.route, RoutePolicy.messages)
        XCTAssertGreaterThanOrEqual(elapsed, 4.9)
        XCTAssertLessThan(elapsed, 6.5, "到 5 秒立即兜底，不等回查")
        await held.release(with: .failed) // 收尾，避免泄漏
    }

    /// 回查 10 秒后才返回（不理会取消）：5 秒时经 Router 打开 Messages；10 秒后的迟到结果丢弃。
    func testLateLookupResultIsDiscarded() async throws {
        let flag = LateFlag()
        let landing = PushLanding { _ in
            await lateLookup(after: 10, flag: flag, outcome: .found(route: "Wallet", params: [:]))
        }
        let router = Router(
            pendingStore: PendingActionStore(backend: MemoryPendingBackend()),
            state: { [unowned self] in guardState }
        )
        let clock = ContinuousClock()
        let start = clock.now
        let task = try XCTUnwrap(router.handlePush(messageId: "m1", using: landing))
        await task.value
        let elapsed = seconds(clock.now - start)
        XCTAssertLessThan(elapsed, 6.5)
        XCTAssertEqual(router.path.map(\.route), [RoutePolicy.messages])
        XCTAssertFalse(flag.isDone)

        while !flag.isDone {
            try await Task.sleep(for: .milliseconds(100))
        }
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(router.path.map(\.route), [RoutePolicy.messages], "迟到的 Wallet 不打开")
    }

    /// 缩短的超时同样不等不响应取消的回查。
    func testShortTimeoutDoesNotWaitForUncancellableLookup() async {
        let held = HeldLookup()
        let landing = PushLanding(timeout: .milliseconds(100)) { _ in await held.wait() }
        let clock = ContinuousClock()
        let start = clock.now
        let result = await landing.land(messageId: "m1", state: guardState)
        XCTAssertLessThan(seconds(clock.now - start), 2)
        XCTAssertEqual(result.decision.route, RoutePolicy.messages)
        await held.release(with: .found(route: "Wallet", params: [:]))
    }

    func testFastLookupWinsOverTimer() async {
        let landing = PushLanding { _ in .found(route: "Wallet", params: [:]) }
        let result = await landing.land(messageId: "m1", state: guardState)
        XCTAssertEqual(result.decision.route, "Wallet")
    }
}
