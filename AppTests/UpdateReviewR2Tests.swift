import Config
@testable import Couli
import Foundation
import Privacy
import Router
import Update
import XCTest

/// APP-02c iOS 评审第 2 轮（ios-review-r2.md）的接线回归：
/// R2-01 本次运行成功过、之后复查失败：界面可保留旧结论，交给 Router 的按 unknown，直到下一次成功检查（编排者裁定）；
/// R2-02 同一次检查在途时再回前台：不重置检查起点与 5 秒等待、不另发请求。
@MainActor
final class UpdateReviewR2Tests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        suiteName = "UpdateReviewR2Tests.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        UserDefaultsPendingBackend().delete()
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        UserDefaultsPendingBackend().delete()
    }

    private func consentedStore() -> MemoryPrivacyStore {
        let store = MemoryPrivacyStore()
        store.decisionRaw = "consented"
        store.consentedVersion = "1"
        return store
    }

    private func makeRouting(update: AppUpdate) -> AppRouting {
        let environment = EnvironmentStore(defaultEnvironment: .test, defaults: defaults, registry: .init(cleaners: []))
        let privacy = PrivacyController(store: consentedStore(), clock: { 1 }, bundledPolicyVersion: "1")
        return AppRouting(environment: environment, privacy: privacy, update: update)
    }

    private func savePending(route: String) {
        let pending = PendingActionStore(backend: UserDefaultsPendingBackend())
        XCTAssertTrue(pending.save(
            action: Router.openRouteAction, values: ["route": .string(route)],
            now: pending.now, origin: RouteSource.inApp.rawValue
        ))
    }

    // MARK: - R2-01

    /// 评审场景：本次运行成功检查为 ok → 超过间隔回前台复查 → 复查期间 bridge 来源的 Login 排队 → 复查失败。
    /// 界面投影保留 ok，但 Router 按 unknown：排队的 Login 不在只读清单，不得打开；之后的外部入口只读、
    /// 待办恢复同样受限；下一次成功检查后才恢复正常。
    func testFailedRecheckAfterSuccessRoutesAsUnknownUntilNextSuccess() {
        let clock = TestClock(PendingActionStore.wallClockMillis())
        let checker = StubUpdateChecker(.success(UpdateFixtures.ok))
        let update = UpdateFixtures.makeUpdate(checker: checker, clock: { clock.now })
        let routing = makeRouting(update: update)
        routing.shellAppeared()
        XCTAssertEqual(routing.readiness.update, .finished(.ok))

        checker.outcome = nil
        clock.now += Int64(UpdateGate.defaultRecheckIntervalSec + 1) * 1000
        routing.sceneEnteredBackground()
        routing.sceneBecameActive()
        XCTAssertEqual(checker.calls, 2, "超过间隔：回前台复查")

        let queued = routing.router.open(RouteRequest(route: RoutePolicy.login, from: .bridge))
        XCTAssertEqual(queued.kind, .deferred, "复查中：bridge 来源排队")
        XCTAssertEqual(queued.reason, GuardReason.updateChecking)

        checker.deliver(.failure)
        XCTAssertEqual(update.ui.status, .ok, "界面投影保留旧结论（向量 G14）")
        XCTAssertTrue(update.gate.lastCheckFailed)
        XCTAssertEqual(routing.readiness.update, .finished(.unknown), "交给 Router 的按 unknown，不沿用旧 ok")
        XCTAssertEqual(routing.guardState.update, .unknown)
        XCTAssertFalse(routing.router.path.map(\.route).contains(RoutePolicy.login), "排队的 Login 不在只读清单：不打开")

        let bridgeLogin = routing.router.open(RouteRequest(route: RoutePolicy.login, from: .bridge))
        XCTAssertNotEqual(bridgeLogin.kind, .open, "失败后新的 bridge Login 也不按正常放行")
        XCTAssertFalse(routing.router.path.map(\.route).contains(RoutePolicy.login))

        let deeplink = routing.router.open(RouteRequest(route: "Search", from: .deeplink))
        XCTAssertEqual(deeplink.kind, .openReadonly, "外部入口：只读")
        XCTAssertEqual(routing.router.path.last?.readonly, true)

        savePending(route: "Settings")
        routing.launchConditionsChanged()
        XCTAssertFalse(routing.router.path.map(\.route).contains("Settings"), "unknown：待办只恢复只读清单页")

        let inApp = routing.router.open(RouteRequest(route: RoutePolicy.login, from: .inApp))
        XCTAssertEqual(inApp.kind, .open, "用户在原生页面上自己的操作不受影响（03 §4.1）")

        // 失败后下次回前台不论间隔再查；成功后恢复正常。
        routing.router.path.removeAll()
        UserDefaultsPendingBackend().delete()
        checker.outcome = .success(UpdateFixtures.ok)
        clock.now += 1000
        routing.sceneEnteredBackground()
        routing.sceneBecameActive()
        XCTAssertEqual(checker.calls, 3)
        XCTAssertFalse(update.gate.lastCheckFailed)
        XCTAssertEqual(routing.readiness.update, .finished(.ok), "下一次成功检查后恢复正常")
        let after = routing.router.open(RouteRequest(route: RoutePolicy.login, from: .bridge))
        XCTAssertEqual(after.kind, .open, "对照：ok 时同一 bridge Login 正常打开")
        let search = routing.router.open(RouteRequest(route: "Search", from: .deeplink))
        XCTAssertEqual(search.kind, .open)
    }

    /// 已知 below_min 不受「失败按 unknown」影响：10405 进强更后复查失败仍是 below_min。
    func testKnownBelowMinSurvivesFailedRecheck() {
        let checker = StubUpdateChecker(.success(UpdateFixtures.ok))
        let update = UpdateFixtures.makeUpdate(checker: checker)
        let routing = makeRouting(update: update)
        routing.shellAppeared()
        update.on10405(minSupported: "9.0.0")
        checker.outcome = .failure
        update.retry()
        XCTAssertTrue(update.gate.lastCheckFailed)
        XCTAssertEqual(routing.readiness.update, .finished(.belowMin))
        XCTAssertEqual(routing.router.path.map(\.route), [RoutePolicy.forceUpdate])
    }

    // MARK: - R2-02

    /// 冷启动检查一直不回调：第 4 秒回前台、之后反复切换，都不重置检查起点、不另发请求，截止时间不变。
    func testForegroundWhileCheckInFlightKeepsStartAndDeadline() throws {
        let clock = TestClock(1_000_000)
        let checker = StubUpdateChecker(nil)
        let update = UpdateFixtures.makeUpdate(checker: checker, clock: { clock.now })
        let routing = makeRouting(update: update)
        routing.shellAppeared()
        let started = try XCTUnwrap(update.checkStartedAt)
        XCTAssertEqual(routing.readiness.update, .checking(startedAt: started))

        for _ in 0..<4 {
            clock.now += 1000
            routing.sceneEnteredBackground()
            routing.sceneBecameActive()
            XCTAssertEqual(update.checkStartedAt, started, "在途：不重置检查起点")
            XCTAssertEqual(routing.readiness.update, .checking(startedAt: started))
            XCTAssertEqual(checker.calls, 1, "在途：不另发请求")
        }

        // 回前台复查同样：在途时再回前台不改起点。
        checker.deliver(.success(UpdateFixtures.ok))
        clock.now += Int64(UpdateGate.defaultRecheckIntervalSec + 1) * 1000
        routing.sceneEnteredBackground()
        routing.sceneBecameActive()
        XCTAssertEqual(checker.calls, 2)
        let recheckStarted = try XCTUnwrap(update.checkStartedAt)
        clock.now += 4000
        routing.sceneEnteredBackground()
        routing.sceneBecameActive()
        XCTAssertEqual(update.checkStartedAt, recheckStarted)
        XCTAssertEqual(routing.readiness.update, .checking(startedAt: recheckStarted))
        XCTAssertEqual(checker.calls, 2)
    }

    /// 评审场景（真实时间）：已同意、外壳就绪，检查一直不回调，Search 深链已排队；第 2 秒回前台。
    /// 恢复仍在原定第 5 秒按 unknown 只读放行（修复前会推迟到第 7 秒），请求只发一次。
    func testForegroundWhileCheckInFlightDoesNotDelayFiveSecondRelease() async throws {
        let checker = StubUpdateChecker(nil)
        let update = UpdateFixtures.makeUpdate(checker: checker)
        let routing = makeRouting(update: update)
        routing.shellAppeared()
        let started = try XCTUnwrap(update.checkStartedAt)

        let decision = routing.router.open(RouteRequest(route: "Search", from: .deeplink))
        XCTAssertEqual(decision.reason, GuardReason.updateChecking)
        let deadline = try XCTUnwrap(routing.scheduledLaunchRetryAt)

        try await Task.sleep(for: .seconds(2))
        routing.sceneEnteredBackground()
        routing.sceneBecameActive()
        XCTAssertEqual(update.checkStartedAt, started)
        XCTAssertEqual(routing.scheduledLaunchRetryAt, deadline, "截止时间不变")

        for _ in 0..<80 where routing.router.path.isEmpty {
            try await Task.sleep(for: .milliseconds(50))
        }
        let openedAt = PendingActionStore.wallClockMillis()
        XCTAssertEqual(routing.router.path.map(\.route), ["Search"])
        XCTAssertEqual(routing.router.path.last?.readonly, true, "unknown：只读")
        XCTAssertLessThan(openedAt, started + LaunchQueue.updateWaitMillis + 1500, "没有被推迟到第 7 秒")
        XCTAssertEqual(checker.calls, 1, "请求只发一次")
    }
}

/// 可拨动的测试时钟。
private final class TestClock {
    var now: Int64

    init(_ now: Int64) {
        self.now = now
    }
}
