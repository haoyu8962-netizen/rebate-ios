import Combine
import Foundation
import Generated
import XCTest
@testable import Router

/// APP-02b iOS 评审第 1 轮（ios-review-r1.md）R1-01…R1-06 在 Router 层的回归测试。
@MainActor
final class RouterReviewR1FixTests: XCTestCase {
    private var guardState = GuardState(
        privacyState: .consented,
        updateState: .ok,
        sessionState: .guest,
        environmentSettled: true,
        appVersion: "1.0.0",
        isDebugBuild: false
    )
    private let now: Int64 = 7_000_000

    private func makeRouter(_ backend: MemoryPendingBackend = MemoryPendingBackend())
        -> (Router, PendingActionStore) {
        let store = PendingActionStore(backend: backend, clock: { [unowned self] in now })
        return (Router(pendingStore: store, state: { [unowned self] in guardState }), store)
    }

    private func readiness(_ privacy: PrivacyState, update: UpdateCheckStatus = .finished(.ok)) -> LaunchReadiness {
        LaunchReadiness(environmentSettled: true, privacy: privacy, update: update)
    }

    // MARK: - R1-01 弹窗期间的自动恢复不删用户刚登记的待办

    func testLaunchCoordinationKeepsPendingAwaitingConsent() {
        guardState.privacy = .basicMode
        let (router, store) = makeRouter()
        // 订阅 consentRequested 的一方（App 里是弹出弹窗 → 启动协调）在 willSet 时被通知：此刻也必须已保护待办。
        var coordinatedDuringPublish = false
        let sink = router.$consentRequested.filter(\.self).sink { [unowned router] _ in
            MainActor.assumeIsolated {
                router.launchConditionsChanged(readiness: self.readiness(.basicMode), shellReady: true, now: self.now)
                coordinatedDuringPublish = true
            }
        }
        _ = router.selectTab(route: "OrderList")
        XCTAssertTrue(coordinatedDuringPublish)
        XCTAssertTrue(router.awaitingConsentResult)
        router.launchConditionsChanged(readiness: readiness(.basicMode), shellReady: true, now: now)
        XCTAssertEqual(store.load(now: now)?.paramValues["route"]?.stringValue, "OrderList", "弹窗期间不按 reject 删除")

        guardState.privacy = .consented
        router.launchConditionsChanged(readiness: readiness(.consented), shellReady: true, now: now)
        router.consentHandled(granted: true)
        XCTAssertFalse(router.awaitingConsentResult)
        XCTAssertEqual(router.path.map(\.route), [RoutePolicy.login], "同意 = 前置完成：游客继续去登录")
        XCTAssertNotNil(store.load(now: now))
        sink.cancel()
    }

    func testAfterRestartPendingIsRejectedInBasicMode() {
        guardState.privacy = .basicMode
        let backend = MemoryPendingBackend()
        let (first, _) = makeRouter(backend)
        _ = first.selectTab(route: "OrderList")
        // 进程重启：内存标记不在，照常按 reject（basic_mode_blocked）删除。
        let (second, store) = makeRouter(backend)
        XCTAssertNotNil(store.load(now: now))
        second.launchConditionsChanged(readiness: readiness(.basicMode), shellReady: true, now: now)
        XCTAssertNil(store.load(now: now))
    }

    // MARK: - R1-02 Messages 兜底需要登录时登记 Messages

    func testPushFallbackRequiringLoginRemembersMessages() {
        let (router, store) = makeRouter()
        let decision = router.open(RouteRequest(route: "BindPhone", values: [:], from: .push))
        XCTAssertEqual(decision.kind, .requireLogin)
        XCTAssertEqual(router.path.map(\.route), [RoutePolicy.login])
        let pending = store.load(now: now)
        XCTAssertEqual(pending?.paramValues["route"]?.stringValue, RoutePolicy.messages)
        XCTAssertNil(pending?.paramValues["params"])

        // 登录完成：打开 Messages，而不是被入口限制拒绝的 BindPhone。
        router.path = []
        guardState.session = .loggedIn
        router.prerequisiteCompleted()
        XCTAssertEqual(router.path.map(\.route), [RoutePolicy.messages])
        XCTAssertNil(store.load(now: now))
    }

    /// 第 2 轮评审 R2-02（BR-ID-10 推送兜底与登录后落点）：原目标是敏感动作（不适用 pending_action）时，
    /// 敏感原目标本身不登记，但兜底的 Messages 要登记，登录后打开 Messages。
    func testPushFallbackForSensitiveRouteRemembersMessages() {
        let (router, store) = makeRouter()
        let decision = router.open(RouteRequest(route: "LaborAgreement", from: .push))
        XCTAssertEqual(decision.kind, .requireLogin)
        XCTAssertEqual(router.path.map(\.route), [RoutePolicy.login])
        let pending = store.load(now: now)
        XCTAssertEqual(pending?.paramValues["route"]?.stringValue, RoutePolicy.messages, "登记兜底 Messages")
        XCTAssertNil(pending?.paramValues["params"])

        router.path = []
        guardState.session = .loggedIn
        router.prerequisiteCompleted()
        XCTAssertEqual(router.path.map(\.route), [RoutePolicy.messages], "登录后落到 Messages，不重放敏感原目标")
        XCTAssertNil(store.load(now: now))
    }

    /// 敏感动作不是推送兜底时（App 内发起、缺登录）仍不登记（BR-ID-10「不适用的动作」）。
    func testSensitiveRouteWithoutFallbackRegistersNothing() {
        let (router, store) = makeRouter()
        let decision = router.open(RouteRequest(route: "LaborAgreement", from: .inApp))
        XCTAssertEqual(decision.kind, .requireLogin)
        XCTAssertNil(store.load(now: now))
    }

    func testDecideWithTargetKeepsOriginalWhenNoFallback() {
        let request = RouteRequest(route: "Search", from: .deeplink)
        let result = EntryGuard.decideWithTarget(request: request, state: guardState, routes: Routes.all)
        XCTAssertEqual(result.target, request)
        XCTAssertEqual(result.decision, EntryGuard.decide(request: request, state: guardState))
    }

    // MARK: - R1-03 丢弃新输入不删冷启动原意图

    func testDiscardIsNotUsedForNewInputs() {
        let (router, _) = makeRouter()
        let original = RouteRequest(route: "Search", from: .deeplink)
        router.enqueueLaunch(.route(original))
        // 新输入由调用方直接忽略；原意图仍在。
        XCTAssertTrue(router.hasPendingLaunchIntent)
        guardState.privacy = .consented
        router.launchConditionsChanged(readiness: readiness(.consented), shellReady: true, now: now)
        XCTAssertEqual(router.path.map(\.route), ["Search"])
    }

    // MARK: - R1-04 热推送在首启弹窗期间丢弃

    func testHotPushWhilePrivacyUndecidedIsDropped() {
        guardState.privacy = .notDecided
        guardState.session = .loggedIn
        let (router, _) = makeRouter()
        let landing = PushLanding { _ in .found(route: "Wallet", params: [:]) }
        XCTAssertNil(router.handlePush(messageId: "m1", using: landing))
        XCTAssertFalse(router.hasPendingLaunchIntent, "热推送不入队")
        guardState.privacy = .consented
        XCTAssertNil(router.drainLaunchQueue(readiness: readiness(.consented), now: now, pushLanding: landing))
        XCTAssertTrue(router.path.isEmpty, "同意后不补执行")
    }

    func testColdPushStillWaitsForPrivacy() async throws {
        guardState.privacy = .notDecided
        guardState.session = .loggedIn
        let (router, _) = makeRouter()
        let landing = PushLanding { _ in .found(route: "Wallet", params: [:]) }
        router.enqueueLaunch(.push(messageId: "m1"))
        XCTAssertNil(router.drainLaunchQueue(readiness: readiness(.notDecided), now: now, pushLanding: landing))
        XCTAssertTrue(router.hasPendingLaunchIntent, "冷启动推送等隐私结论")
        guardState.privacy = .consented
        let task = try XCTUnwrap(router.drainLaunchQueue(readiness: readiness(.consented), now: now,
                                                         pushLanding: landing))
        await task.value
        XCTAssertEqual(router.path.map(\.route), ["Wallet"])
    }

    // MARK: - R1-05 Tab 根路由由 Router 切 Tab

    func testDeepLinkToTabRootSwitchesTabAndKeepsReadonly() {
        guardState.session = .loggedIn
        let (router, _) = makeRouter()
        XCTAssertTrue(router.selectTab(route: "AgentChat").allowsSwitch)
        XCTAssertEqual(router.tabRoot.route, "AgentChat")

        router.open(RouteRequest(route: "Search", from: .inApp))
        router.open(RouteRequest(route: "Home", from: .deeplink))
        XCTAssertTrue(router.path.isEmpty)
        XCTAssertEqual(router.tabRoot.route, "Home", "Home 深链切回首页 Tab")
        XCTAssertFalse(router.tabRoot.readonly)

        guardState.update = .unknown
        router.open(RouteRequest(route: "Home", from: .deeplink))
        XCTAssertEqual(router.tabRoot.route, "Home")
        XCTAssertTrue(router.tabRoot.readonly, "openReadonly(Home) 保留只读")

        router.open(RouteRequest(route: "OrderList", from: .push))
        XCTAssertTrue(router.path.isEmpty, "Tab 根不入栈")
        XCTAssertEqual(router.tabRoot.route, "OrderList")
        XCTAssertTrue(router.tabRoot.readonly)
    }

    func testResumedTabRootPendingSwitchesTab() {
        let (router, store) = makeRouter()
        _ = router.selectTab(route: "OrderList")
        XCTAssertEqual(router.path.map(\.route), [RoutePolicy.login])
        XCTAssertEqual(router.tabRoot.route, "Home", "未登录不切 Tab")
        guardState.session = .loggedIn
        router.prerequisiteCompleted()
        XCTAssertTrue(router.path.isEmpty)
        XCTAssertEqual(router.tabRoot.route, "OrderList")
        XCTAssertNil(store.load(now: now))
    }

    func testEnteringBasicModeResetsTabRoot() {
        guardState.session = .loggedIn
        let (router, _) = makeRouter()
        _ = router.selectTab(route: "OrderList")
        guardState.privacy = .basicMode
        router.enteredBasicMode()
        XCTAssertEqual(router.tabRoot.route, "Home")
        XCTAssertFalse(router.tabRoot.readonly)
    }

    /// 第 2 轮补充（三端统一）：外壳重建（重新出现、条件变化后的协调）不重新判定、不覆盖已保存的 Tab 只读标记；
    /// 只有用户重新点击 Tab 才重新判定。
    func testShellRebuildKeepsSavedTabReadonly() {
        guardState.session = .loggedIn
        guardState.update = .unknown
        let (router, _) = makeRouter()
        // in_app 点 Tab 不受强更未知影响；用推送打开只读的 OrderList。
        router.open(RouteRequest(route: "OrderList", from: .push))
        XCTAssertEqual(router.tabRoot.route, "OrderList")
        XCTAssertTrue(router.tabRoot.readonly)
        let saved = router.tabRoot

        guardState.update = .ok
        router.launchConditionsChanged(readiness: readiness(.consented), shellReady: true, now: now)
        router.privacyChanged()
        XCTAssertEqual(router.tabRoot, saved, "重建 / 协调不改写 Tab 根与只读标记")

        XCTAssertTrue(router.selectTab(route: "OrderList").allowsSwitch)
        XCTAssertFalse(router.tabRoot.readonly, "用户重新点击 Tab 才重新判定")
    }

    // MARK: - R1-06 超时后不再安排重试

    func testRetryAtIsNilAfterDeadlineWhilePendingRetained() {
        let (router, store) = makeRouter()
        XCTAssertTrue(store.save(action: Router.openRouteAction, values: ["route": .string("OrderList")],
                                 now: now, origin: RouteSource.inApp.rawValue))
        let checking = UpdateCheckStatus.checking(startedAt: now)
        router.launchConditionsChanged(readiness: readiness(.consented, update: checking), shellReady: true, now: now)
        XCTAssertEqual(router.launchConditionsRetryAt(readiness: readiness(.consented, update: checking), now: now),
                       now + LaunchQueue.updateWaitMillis)
        let late = now + LaunchQueue.updateWaitMillis
        router.launchConditionsChanged(readiness: readiness(.consented, update: checking), shellReady: true, now: late)
        XCTAssertNotNil(store.load(now: late), "游客的 OrderList 要登录：保留")
        XCTAssertNil(router.launchConditionsRetryAt(readiness: readiness(.consented, update: checking), now: late),
                     "截止时间已处理：不再安排计时")
        XCTAssertNil(router.launchConditionsRetryAt(readiness: readiness(.consented, update: checking),
                                                    now: late + 10))
    }
}
