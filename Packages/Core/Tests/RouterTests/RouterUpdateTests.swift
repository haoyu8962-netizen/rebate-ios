import Foundation
import Generated
import XCTest
@testable import Router

/// APP-02c：强更检查进行中的等待（F-ALL-03）、同意回调交给启动协调恢复（F-IOS-09）、below_min 时守卫删除待办
/// （F-AND-07 在 iOS 的对应）、强更页的进出与次要入口。
@MainActor
final class RouterUpdateTests: XCTestCase {
    private var guardState = GuardState(
        privacyState: .consented,
        updateState: .ok,
        sessionState: .loggedIn,
        environmentSettled: true,
        appVersion: "1.0.0",
        isDebugBuild: false
    )
    private var now: Int64 = 1_000_000

    private func makeRouter(backend: MemoryPendingBackend = MemoryPendingBackend()) -> (Router, PendingActionStore) {
        let store = PendingActionStore(backend: backend, clock: { [unowned self] in now })
        let router = Router(pendingStore: store, state: { [unowned self] in guardState })
        return (router, store)
    }

    private func savePending(_ store: PendingActionStore, route: String, origin: RouteSource = .inApp) {
        XCTAssertTrue(store.save(
            action: Router.openRouteAction,
            values: ["route": .string(route)],
            now: now,
            origin: origin.rawValue
        ))
    }

    private func readiness(update: UpdateCheckStatus, privacy: PrivacyState = .consented) -> LaunchReadiness {
        LaunchReadiness(environmentSettled: true, privacy: privacy, update: update)
    }

    // MARK: - F-ALL-03：检查中外部来源与 pending 恢复等待，App 内不等

    func testCheckingDefersExternalSourcesWithUpdateCheckingReason() {
        guardState.update = .checking
        for source in [RouteSource.deeplink, .bridge, .agentCard, .push, .pendingAction] {
            let decision = EntryGuard.decide(request: RouteRequest(route: "Search", from: source), state: guardState)
            XCTAssertEqual(decision.kind, .deferred, source.rawValue)
            XCTAssertEqual(decision.reason, GuardReason.updateChecking, source.rawValue)
            XCTAssertNil(decision.route, source.rawValue)
        }
        XCTAssertEqual(GuardReason.updateChecking, "update_checking", "三端同名原因码")
    }

    func testCheckingDoesNotBlockInAppActions() {
        guardState.update = .checking
        let decision = EntryGuard.decide(request: RouteRequest(route: "Wallet", from: .inApp), state: guardState)
        XCTAssertEqual(decision.kind, .open, "App 内用户自己的操作不等待，也不按只读降级")
        XCTAssertEqual(decision.reason, GuardReason.allowed)
    }

    func testCheckingStillHonoursBelowMinAndPrivacyFirst() {
        guardState.update = .checking
        guardState.privacy = .basicMode
        let basic = EntryGuard.decide(request: RouteRequest(route: "Wallet", from: .deeplink), state: guardState)
        XCTAssertEqual(basic.reason, GuardReason.basicModeBlocked, "隐私闸门先于强更等待")
    }

    func testRouterQueuesExternalRequestWhileChecking() {
        guardState.update = .checking
        let (router, _) = makeRouter()
        let decision = router.open(RouteRequest(route: "Search", from: .deeplink))
        XCTAssertEqual(decision.reason, GuardReason.updateChecking)
        XCTAssertTrue(router.hasPendingLaunchIntent, "排进启动队列，等结果或 5 秒")
        XCTAssertTrue(router.path.isEmpty)

        router.open(RouteRequest(route: "Search", from: .inApp))
        XCTAssertEqual(router.path.map(\.route), ["Search"], "App 内操作照常打开")
    }

    func testPushWhileCheckingIsNotTreatedAsMessagesFallback() {
        guardState.update = .checking
        let result = EntryGuard.decideWithTarget(
            request: RouteRequest(route: "AuthManage", from: .push),
            state: guardState,
            routes: Routes.all
        )
        XCTAssertEqual(result.decision.reason, GuardReason.updateChecking)
        XCTAssertEqual(result.target.route, "AuthManage", "等待时不改落 Messages")
    }

    func testPendingResumeWhileCheckingKeepsRecord() {
        guardState.update = .checking
        let backend = MemoryPendingBackend()
        let (router, store) = makeRouter(backend: backend)
        savePending(store, route: "OrderList")
        router.resumePending()
        XCTAssertNotNil(backend.read(), "检查中恢复：保留待办，等结果")
        XCTAssertEqual(router.lastDecision?.reason, nil, "等待类保留时不执行")
        XCTAssertTrue(router.path.isEmpty)
    }

    // MARK: - F-IOS-09：同意回调交给启动协调

    func testRecordedPrerequisiteWaitsForUpdateResultAndShell() {
        guardState.session = .guest
        guardState.update = .checking
        let backend = MemoryPendingBackend()
        let (router, store) = makeRouter(backend: backend)
        savePending(store, route: "OrderList")
        router.awaitingConsentResult = true
        router.consentRequested = true

        router.consentResolved(granted: true)
        XCTAssertFalse(router.awaitingConsentResult)
        XCTAssertFalse(router.consentRequested)
        XCTAssertTrue(router.path.isEmpty, "同意回调不直接恢复")

        let checking = readiness(update: .checking(startedAt: now))
        router.launchConditionsChanged(readiness: checking, shellReady: false, now: now)
        XCTAssertTrue(router.path.isEmpty, "外壳未就绪：不恢复")
        router.launchConditionsChanged(readiness: checking, shellReady: true, now: now + 1000)
        XCTAssertTrue(router.path.isEmpty, "强更还在检查、没等满 5 秒：不恢复")
        XCTAssertNotNil(backend.read())

        guardState.update = .ok
        router.launchConditionsChanged(readiness: readiness(update: .finished(.ok)), shellReady: true, now: now + 2000)
        XCTAssertEqual(router.path.map(\.route), [RoutePolicy.login], "有结果后按「完成前置」继续：游客去登录")
        XCTAssertNotNil(backend.read(), "登录前保留待办")
    }

    func testRecordedPrerequisiteResumesAfterFiveSecondTimeoutAsUnknown() {
        guardState.update = .checking
        let backend = MemoryPendingBackend()
        let (router, store) = makeRouter(backend: backend)
        savePending(store, route: "OrderList")
        router.recordPrerequisiteCompleted()
        let checking = readiness(update: .checking(startedAt: now))
        router.launchConditionsChanged(readiness: checking, shellReady: true, now: now)
        XCTAssertTrue(router.path.isEmpty)
        router.launchConditionsChanged(readiness: checking, shellReady: true, now: now + LaunchQueue.updateWaitMillis)
        // OrderList 是 Tab 根路由：切 Tab（只读，强更未知）。
        XCTAssertEqual(router.tabRoot.route, "OrderList")
        XCTAssertTrue(router.tabRoot.readonly, "等满 5 秒按 unknown：只读打开")
        XCTAssertNil(backend.read())
    }

    func testRecordPrerequisiteWithoutPendingDoesNothing() {
        let (router, _) = makeRouter()
        router.recordPrerequisiteCompleted()
        XCTAssertFalse(router.resumeAfterPrerequisite, "没有待办时不留标记（之后新登记的待办不会被当成刚完成前置）")
    }

    func testConsentRefusedClearsPendingAndFlags() {
        let backend = MemoryPendingBackend()
        let (router, store) = makeRouter(backend: backend)
        savePending(store, route: "OrderList")
        router.awaitingConsentResult = true
        router.consentRequested = true
        router.consentResolved(granted: false)
        XCTAssertFalse(router.awaitingConsentResult)
        XCTAssertFalse(router.consentRequested)
        XCTAssertNil(backend.read())
    }

    // MARK: - below_min：守卫删除待办、进入强更页（F-AND-07 对应）

    func testBelowMinCoordinationDeletesPendingAndShowsForceUpdate() {
        let backend = MemoryPendingBackend()
        let (router, store) = makeRouter(backend: backend)
        savePending(store, route: "Search")
        guardState.update = .belowMin
        router.launchConditionsChanged(readiness: readiness(update: .finished(.belowMin)), shellReady: true, now: now)
        XCTAssertNil(backend.read(), "below_min：丢弃待办")
        XCTAssertEqual(router.path.map(\.route), [RoutePolicy.forceUpdate])
    }

    func testBelowMinDropsLaunchIntentAndKeepsForceUpdateStack() {
        let (router, _) = makeRouter()
        guardState.update = .belowMin
        router.enterForceUpdate()
        router.openFromForceUpdatePage(RouteRequest(route: "PrivacyCenter", from: .inApp))
        router.enqueueLaunch(.route(RouteRequest(route: "Search", from: .deeplink)))
        router.launchConditionsChanged(readiness: readiness(update: .finished(.belowMin)), shellReady: true, now: now)
        XCTAssertFalse(router.hasPendingLaunchIntent)
        XCTAssertEqual(router.path.map(\.route), [RoutePolicy.forceUpdate, "PrivacyCenter"],
                       "停在强更页（及其次要入口）时丢弃外部请求，不打断用户")
    }

    // MARK: - 强更页

    func testEnterAndLeaveForceUpdate() {
        let (router, _) = makeRouter()
        router.open(RouteRequest(route: "Search", from: .inApp))
        router.enterForceUpdate()
        XCTAssertEqual(router.path.map(\.route), [RoutePolicy.forceUpdate], "任何页面都进入强更页")
        XCTAssertTrue(router.isOnForceUpdate)
        router.enterForceUpdate()
        XCTAssertEqual(router.path.count, 1)
        router.leaveForceUpdate()
        XCTAssertTrue(router.path.isEmpty)
        router.open(RouteRequest(route: "Search", from: .inApp))
        router.leaveForceUpdate()
        XCTAssertEqual(router.path.map(\.route), ["Search"], "不在强更页时不动")
    }

    func testSecondaryEntriesFromForceUpdatePage() {
        guardState.update = .belowMin
        guardState.session = .guest
        let (router, store) = makeRouter()
        router.enterForceUpdate()

        router.openFromForceUpdatePage(RouteRequest(route: "PrivacyCenter", from: .inApp))
        XCTAssertEqual(router.lastDecision?.reason, GuardReason.forceUpdateException)
        XCTAssertEqual(router.path.last?.route, "PrivacyCenter")
        XCTAssertEqual(router.path.last?.fromForceUpdatePage, true)

        router.path.removeLast()
        router.openFromForceUpdatePage(RouteRequest(route: RoutePolicy.login, from: .inApp))
        XCTAssertEqual(router.path.last?.route, RoutePolicy.login)
        XCTAssertEqual(router.path.last?.fromForceUpdatePage, true, "登录页按受限登录显示")

        router.path.removeLast()
        router.openFromForceUpdatePage(RouteRequest(route: "Search", from: .inApp))
        XCTAssertEqual(router.path.map(\.route), [RoutePolicy.forceUpdate], "其余路由不打开")
        XCTAssertNil(store.load(now: now), "强更状态下不登记 pending_action")

        // 不是从强更页进入的同一路由：拦下。
        router.open(RouteRequest(route: "PrivacyCenter", from: .inApp))
        XCTAssertEqual(router.path.map(\.route), [RoutePolicy.forceUpdate])
    }

    /// 编排者裁定：进入基本模式（仍不同意、撤回同意）清栈时不清掉强更页，强更页留在最上层；其上的次要入口页面清掉。
    func testEnteringBasicModeKeepsForceUpdatePage() {
        guardState.update = .belowMin
        let (router, _) = makeRouter()
        router.enterForceUpdate()
        router.openFromForceUpdatePage(RouteRequest(route: "PrivacyCenter", from: .inApp))
        XCTAssertEqual(router.path.map(\.route), [RoutePolicy.forceUpdate, "PrivacyCenter"])
        guardState.privacy = .basicMode
        router.enteredBasicMode()
        XCTAssertEqual(router.path.map(\.route), [RoutePolicy.forceUpdate], "强更页不被清掉")

        guardState.update = .ok
        guardState.privacy = .consented
        router.leaveForceUpdate()
        router.open(RouteRequest(route: "Search", from: .inApp))
        XCTAssertEqual(router.path.map(\.route), ["Search"])
        router.enteredBasicMode()
        XCTAssertTrue(router.path.isEmpty, "不在强更页时照常清空")
    }
}
