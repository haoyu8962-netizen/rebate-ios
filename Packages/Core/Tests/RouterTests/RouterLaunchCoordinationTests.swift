import Foundation
import Generated
import XCTest
@testable import Router

/// APP-02b 顺带的后续项：F-IOS-07（EntryGuard 对 Messages 兜底再判定）与
/// F-IOS-08（冷启动与条件变化后恢复 pending_action；强更 5 秒等待从闸门通过起算，不因外壳未就绪推迟）。
@MainActor
final class RouterLaunchCoordinationTests: XCTestCase {
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

    private func readiness(
        privacy: PrivacyState = .consented,
        update: UpdateCheckStatus = .finished(.ok),
        environment: Bool = true
    ) -> LaunchReadiness {
        LaunchReadiness(environmentSettled: environment, privacy: privacy, update: update)
    }

    // MARK: - F-IOS-07

    func testGuardItselfRedecidesMessagesFallbackForGuest() {
        var state = guardState
        state.session = .guest
        // Login 只声明 in_app：推送命中时兜底 Messages；Messages 要登录，游客不能直接打开。
        let decision = EntryGuard.decide(request: RouteRequest(route: "Login", from: .push), state: state)
        XCTAssertEqual(decision.kind, .requireLogin)
        XCTAssertEqual(decision.route, RoutePolicy.login)
    }

    func testGuardMessagesFallbackStillOpensForLoggedIn() {
        let decision = EntryGuard.decide(request: RouteRequest(route: "Login", from: .push), state: guardState)
        XCTAssertEqual(decision.kind, .open)
        XCTAssertEqual(decision.route, RoutePolicy.messages)
        XCTAssertEqual(decision.reason, GuardReason.pushEntryFallback)
    }

    func testUnknownUpdateFallbackForGuestNeedsLogin() {
        var state = guardState
        state.session = .guest
        state.update = .unknown
        let decision = EntryGuard.decide(request: RouteRequest(route: "AuthManage", from: .push), state: state)
        XCTAssertEqual(decision.kind, .requireLogin)
    }

    func testDirectRouterOpenFromPushDoesNotOpenMessagesForGuest() {
        guardState.session = .guest
        let (router, _) = makeRouter()
        router.open(RouteRequest(route: "BindPhone", from: .push))
        XCTAssertFalse(router.path.contains { $0.route == RoutePolicy.messages })
        XCTAssertEqual(router.path.last?.route, RoutePolicy.login)
    }

    // MARK: - F-IOS-08 pending_action

    func testColdStartResumesValidPendingOnceAndDeletes() {
        let backend = MemoryPendingBackend()
        let (router, store) = makeRouter(backend: backend)
        savePending(store, route: "Search")
        now += 1000
        router.launchConditionsChanged(readiness: readiness(), shellReady: true, now: now)
        XCTAssertEqual(router.path.map(\.route), ["Search"])
        XCTAssertNil(store.load(now: now))
        router.launchConditionsChanged(readiness: readiness(), shellReady: true, now: now)
        XCTAssertEqual(router.path.count, 1, "只执行一次")
    }

    func testExpiredPendingIsDeletedWithoutExecuting() {
        let (router, store) = makeRouter()
        savePending(store, route: "Search")
        now += PendingActionStore.ttlMillis + 1
        router.launchConditionsChanged(readiness: readiness(), shellReady: true, now: now)
        XCTAssertTrue(router.path.isEmpty)
        XCTAssertNil(store.load(now: now))
    }

    func testPendingWithUnmetPrerequisiteIsKeptWithoutOpeningLogin() {
        guardState.session = .guest
        let (router, store) = makeRouter()
        savePending(store, route: "Wallet")
        router.launchConditionsChanged(readiness: readiness(), shellReady: true, now: now)
        XCTAssertTrue(router.path.isEmpty, "冷启动不自动拉登录页")
        XCTAssertNotNil(store.load(now: now))
        // 前置满足（登录）后条件变化再调：执行一次并删除。
        guardState.session = .loggedIn
        router.launchConditionsChanged(readiness: readiness(), shellReady: true, now: now)
        XCTAssertEqual(router.path.map(\.route), ["Wallet"])
        XCTAssertNil(store.load(now: now))
    }

    /// F-ALL-04：自动恢复时守卫 reject（基本模式丢弃）→ 删除、不补执行，也不弹隐私弹窗。
    func testPendingRejectedInBasicModeIsDeletedAndAgentPendingPurged() {
        guardState.privacy = .basicMode
        let (router, store) = makeRouter()
        savePending(store, route: "Wallet")
        router.launchConditionsChanged(readiness: readiness(privacy: .basicMode), shellReady: true, now: now)
        XCTAssertTrue(router.path.isEmpty)
        XCTAssertFalse(router.consentRequested, "冷启动不因 pending_action 自动弹隐私弹窗")
        XCTAssertEqual(router.lastDecision?.reason, GuardReason.basicModeBlocked)
        XCTAssertNil(store.load(now: now))

        store.clear()
        savePending(store, route: "Messages", origin: .agentCard)
        router.launchConditionsChanged(readiness: readiness(privacy: .basicMode), shellReady: true, now: now)
        XCTAssertNil(store.load(now: now), "Agent 卡片记录遇隐私阻断即删")
    }

    /// F-ALL-04：参数不合法、入口不允许的记录在自动恢复时删除、不补执行。
    func testPendingRejectedForInvalidParamsOrEntryIsDeleted() {
        let (router, store) = makeRouter()
        XCTAssertTrue(store.save(
            action: Router.openRouteAction,
            values: ["route": .string("Agreement"), "params": .object(["type": .string("bogus")])],
            now: now,
            origin: RouteSource.inApp.rawValue
        ))
        router.resumePending(state: guardState, entersPrerequisite: false)
        XCTAssertEqual(router.lastDecision?.kind, .reject)
        XCTAssertNil(store.load(now: now))
        XCTAssertTrue(router.path.isEmpty)

        // 外部网页目标不在白名单：target_not_allowed（reject）→ 删除。
        XCTAssertTrue(store.save(
            action: Router.openRouteAction,
            values: ["route": .string("ExternalPage"), "params": .object(["url": .string("https://evil.example/")])],
            now: now,
            origin: RouteSource.inApp.rawValue
        ))
        router.resumePending(state: guardState, entersPrerequisite: false)
        XCTAssertEqual(router.lastDecision?.kind, .reject)
        XCTAssertNil(store.load(now: now))
    }

    /// 等待类（环境未就绪等 defer）保留。
    func testDeferredPendingIsKept() {
        let (router, store) = makeRouter()
        savePending(store, route: "Search")
        var waiting = guardState
        waiting.environmentSettled = false
        router.resumePending(state: waiting, entersPrerequisite: false)
        XCTAssertEqual(router.lastDecision?.kind ?? .deferred, .deferred)
        XCTAssertNotNil(store.load(now: now))
    }

    func testNothingRunsBeforeShellOrPrivacyOrEnvironmentReady() {
        let (router, store) = makeRouter()
        savePending(store, route: "Search")
        router.launchConditionsChanged(readiness: readiness(), shellReady: false, now: now)
        router.launchConditionsChanged(readiness: readiness(privacy: .notDecided), shellReady: true, now: now)
        router.launchConditionsChanged(readiness: readiness(environment: false), shellReady: true, now: now)
        XCTAssertTrue(router.path.isEmpty)
        XCTAssertNotNil(store.load(now: now))
    }

    // MARK: - F-IOS-08 强更 5 秒

    func testUpdateWaitStartsAtGatesNotAtShellReady() {
        let (router, _) = makeRouter()
        router.enqueueLaunch(.route(RouteRequest(route: "Search", from: .deeplink)))
        let checking = UpdateCheckStatus.checking(startedAt: now)
        // 闸门在 now 通过，外壳还没就绪。
        router.launchConditionsChanged(readiness: readiness(update: checking), shellReady: false, now: now)
        XCTAssertEqual(router.launchGatesOpenedAt, now)
        XCTAssertEqual(router.launchConditionsRetryAt(readiness: readiness(update: checking), now: now), now + 5000)
        // 外壳 6 秒后才就绪：已超时，直接按 unknown 交出（Search 在只读清单里，只读打开）。
        router.launchConditionsChanged(readiness: readiness(update: checking), shellReady: true, now: now + 6000)
        XCTAssertEqual(router.path.map(\.route), ["Search"])
        XCTAssertEqual(router.path.first?.readonly, true)
        XCTAssertFalse(router.hasPendingLaunchIntent)
    }

    func testUpdateStillCheckingWithinWaitKeepsIntent() {
        let (router, _) = makeRouter()
        router.enqueueLaunch(.route(RouteRequest(route: "Search", from: .deeplink)))
        let checking = UpdateCheckStatus.checking(startedAt: now)
        router.launchConditionsChanged(readiness: readiness(update: checking), shellReady: true, now: now + 4999)
        XCTAssertTrue(router.path.isEmpty)
        XCTAssertTrue(router.hasPendingLaunchIntent)
        router.launchConditionsChanged(readiness: readiness(update: .finished(.ok)), shellReady: true, now: now + 5001)
        XCTAssertEqual(router.path.first?.readonly, false)
    }

    func testRetryAtIsNilWithoutWork() {
        let (router, _) = makeRouter()
        let checking = UpdateCheckStatus.checking(startedAt: now)
        router.launchConditionsChanged(readiness: readiness(update: checking), shellReady: false, now: now)
        XCTAssertNil(router.launchConditionsRetryAt(readiness: readiness(update: checking), now: now))
    }

    func testDiscardLaunchIntent() {
        let (router, _) = makeRouter()
        router.enqueueLaunch(.route(RouteRequest(route: "Search", from: .deeplink)))
        router.discardLaunchIntent()
        XCTAssertFalse(router.hasPendingLaunchIntent)
    }
}

/// APP-02b：首启弹窗里的协议链接经 Router 打开 Agreement（同意前只允许协议文本）。
final class PreConsentAgreementTests: XCTestCase {
    private func state(_ privacy: PrivacyState) -> GuardState {
        GuardState(privacyState: privacy, updateState: .ok, sessionState: .guest, environmentSettled: true,
                   appVersion: "1.0.0", isDebugBuild: false)
    }

    func testInAppAgreementOpensReadonlyBeforeConsent() {
        let request = RouteRequest(route: "Agreement", values: ["type": .string("privacy")], from: .inApp)
        let decision = EntryGuard.decide(request: request, state: state(.notDecided))
        XCTAssertEqual(decision.kind, .openReadonly)
        XCTAssertEqual(decision.route, "Agreement")
        XCTAssertEqual(decision.reason, GuardReason.privacyUndecidedReadonly)
    }

    func testOtherRoutesAndExternalAgreementStillWaitBeforeConsent() {
        XCTAssertEqual(EntryGuard.decide(request: RouteRequest(route: "Settings", from: .inApp),
                                         state: state(.notDecided)).kind, .deferred)
        for source in [RouteSource.deeplink, .push, .pendingAction] {
            XCTAssertEqual(EntryGuard.decide(request: RouteRequest(route: "Agreement", from: source),
                                             state: state(.notDecided)).kind, .deferred, source.rawValue)
        }
        XCTAssertEqual(RoutePolicy.privacyUndecidedReadableRoutes, ["Agreement"])
    }

    func testInvalidAgreementParamsRejected() {
        let request = RouteRequest(route: "Agreement", values: ["type": .string("other")], from: .inApp)
        XCTAssertEqual(EntryGuard.decide(request: request, state: state(.notDecided)).kind, .reject)
    }
}

/// APP-02b 评审（三端统一）：Tab 点击过守卫、保留只读标记；进入基本模式清空导航栈；拒绝补同意丢弃待办。
@MainActor
final class RouterTabAndBasicModeTests: XCTestCase {
    private var guardState = GuardState(
        privacyState: .consented,
        updateState: .ok,
        sessionState: .guest,
        environmentSettled: true,
        appVersion: "1.0.0",
        isDebugBuild: false
    )
    private let now: Int64 = 5_000_000

    private func makeRouter() -> (Router, PendingActionStore) {
        let store = PendingActionStore(backend: MemoryPendingBackend(), clock: { [unowned self] in now })
        return (Router(pendingStore: store, state: { [unowned self] in guardState }), store)
    }

    func testGuestTappingOrdersTabGoesToLoginAndRemembers() {
        let (router, store) = makeRouter()
        let result = router.selectTab(route: "OrderList")
        XCTAssertFalse(result.allowsSwitch)
        XCTAssertEqual(result.decision.kind, .requireLogin)
        XCTAssertEqual(router.path.map(\.route), [RoutePolicy.login])
        XCTAssertEqual(store.load(now: now)?.paramValues["route"]?.stringValue, "OrderList")
    }

    func testOpenTabsSwitchWithoutPushing() {
        let (router, _) = makeRouter()
        for route in ["Home", "AgentChat", "Me"] {
            let result = router.selectTab(route: route)
            XCTAssertTrue(result.allowsSwitch, route)
            XCTAssertEqual(result.decision.kind, .open, route)
        }
        XCTAssertTrue(router.path.isEmpty)
    }

    func testBasicModeTabKeepsReadonlyOrRequestsConsent() {
        guardState.privacy = .basicMode
        let (router, store) = makeRouter()
        let home = router.selectTab(route: "Home")
        XCTAssertTrue(home.allowsSwitch)
        XCTAssertEqual(home.decision.kind, .openReadonly, "只读标记交给调用方")

        let me = router.selectTab(route: "Me")
        XCTAssertFalse(me.allowsSwitch)
        XCTAssertTrue(router.consentRequested)
        XCTAssertNotNil(store.load(now: now))

        // 再次不同意 / 仍不同意：丢弃待办，之后同意也不自动打开。
        router.consentHandled(granted: false)
        XCTAssertNil(store.load(now: now))
        XCTAssertFalse(router.consentRequested)
        guardState.privacy = .consented
        router.prerequisiteCompleted()
        XCTAssertTrue(router.path.isEmpty)
    }

    func testAgreeAsPrerequisiteContinuesToLogin() {
        guardState.privacy = .basicMode
        let (router, store) = makeRouter()
        _ = router.selectTab(route: "OrderList")
        XCTAssertTrue(router.consentRequested)
        guardState.privacy = .consented
        router.consentHandled(granted: true)
        XCTAssertEqual(router.path.map(\.route), [RoutePolicy.login], "同意后按前置继续：游客去登录")
        XCTAssertNotNil(store.load(now: now), "登录前保留待办")
    }

    func testEnteredBasicModeClearsNavigationStack() {
        let (router, _) = makeRouter()
        router.open(RouteRequest(route: "Search", from: .inApp))
        XCTAssertFalse(router.path.isEmpty)
        guardState.privacy = .basicMode
        router.enteredBasicMode()
        XCTAssertTrue(router.path.isEmpty)
    }
}
