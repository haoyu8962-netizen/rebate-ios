import Config
import Foundation
import Generated
import XCTest
@testable import Router

/// 向量文件之外的行为：推送回查（假回查函数）、启动意图排队、Router 执行层、pending_action 的 UserDefaults 后端。
final class PushLandingTests: XCTestCase {
    private func state(
        session: SessionState = .loggedIn,
        update: UpdateState = .ok,
        privacy: PrivacyState = .consented
    ) -> GuardState {
        GuardState(
            privacyState: privacy,
            updateState: update,
            sessionState: session,
            environmentSettled: true,
            appVersion: "1.0.0",
            isDebugBuild: false
        )
    }

    func testLoggedInOpensLookedUpRouteWithPushEntry() async {
        let landing = PushLanding { id in
            id == "m1" ? .found(route: "OrderDetail", params: ["order_id": .string("o1")]) : .notFound
        }
        let result = await landing.land(messageId: "m1", state: state())
        XCTAssertEqual(result.decision, GuardDecision(kind: .open, route: "OrderDetail", reason: GuardReason.allowed))
        XCTAssertEqual(result.request?.sourceKind, .push)
    }

    func testLookedUpRouteWithoutPushEntryFallsBackToMessages() async {
        let landing = PushLanding { _ in .found(route: "Login", params: [:]) }
        let result = await landing.land(messageId: "m1", state: state())
        XCTAssertEqual(result.decision.route, RoutePolicy.messages)
        XCTAssertEqual(result.decision.reason, GuardReason.pushEntryFallback)
    }

    func testNotFoundEmptyRouteAndFailureOpenMessages() async {
        for outcome in [
            PushLookupResult.notFound,
            .failed,
            .found(route: nil, params: [:]),
            .found(route: "", params: [:]),
        ] {
            let landing = PushLanding { _ in outcome }
            let result = await landing.land(messageId: "m1", state: state())
            XCTAssertEqual(
                result.decision,
                GuardDecision(kind: .open, route: RoutePolicy.messages, reason: GuardReason.allowed),
                "\(outcome)"
            )
        }
    }

    func testLookupTimeoutOpensMessages() async {
        let landing = PushLanding(timeout: .milliseconds(50)) { _ in
            try? await Task.sleep(for: .seconds(30))
            return .found(route: "Wallet", params: [:])
        }
        let result = await landing.land(messageId: "m1", state: state())
        XCTAssertEqual(result.decision.route, RoutePolicy.messages)
    }

    func testGuestGoesToLoginThenMessagesWithoutLookup() async {
        let counter = LookupCounter()
        let landing = PushLanding { _ in
            await counter.increment()
            return .found(route: "Wallet", params: [:])
        }
        let result = await landing.land(messageId: "m1", state: state(session: .guest))
        XCTAssertEqual(result.decision.kind, .requireLogin)
        XCTAssertEqual(result.decision.route, RoutePolicy.login)
        XCTAssertEqual(result.afterLogin?.route, RoutePolicy.messages)
        let calls = await counter.value
        XCTAssertEqual(calls, 0, "未登录不回查")
    }

    func testUnknownUpdateKeepsReadonlyList() async {
        let landing = PushLanding { _ in .found(route: "AuthManage", params: [:]) }
        let result = await landing.land(messageId: "m1", state: state(update: .unknown))
        XCTAssertEqual(
            result.decision,
            GuardDecision(
                kind: .openReadonly,
                route: RoutePolicy.messages,
                reason: GuardReason.updateUnknownPushFallback
            )
        )
    }

    func testBelowMinimumAndBasicModeDoNotLookUp() async {
        let landing = PushLanding { _ in .found(route: "Wallet", params: [:]) }
        let forced = await landing.land(messageId: "m1", state: state(update: .belowMin))
        XCTAssertEqual(forced.decision.kind, .forceUpdate)
        XCTAssertNil(forced.request)
        let basic = await landing.land(messageId: "m1", state: state(session: .guest, privacy: .basicMode))
        XCTAssertEqual(basic.decision.kind, .reject)
        XCTAssertNil(basic.request)
    }
}

private actor LookupCounter {
    var value = 0

    func increment() {
        value += 1
    }
}

final class LaunchQueueTests: XCTestCase {
    private let request = RouteRequest(route: "Search", values: ["q": .string("x")], from: .deeplink)

    func testWaitsForEnvironmentPrivacyAndUpdate() {
        var queue = LaunchQueue()
        queue.enqueue(.route(request))
        let blocked = [
            LaunchReadiness(environmentSettled: false, privacy: .consented, update: .finished(.ok)),
            LaunchReadiness(environmentSettled: true, privacy: .notDecided, update: .finished(.ok)),
            LaunchReadiness(environmentSettled: true, privacy: .consented, update: .checking(startedAt: 1000)),
        ]
        for readiness in blocked {
            XCTAssertNil(queue.release(readiness: readiness, now: 1000), "\(readiness)")
        }
        let ready = LaunchReadiness(environmentSettled: true, privacy: .basicMode, update: .finished(.ok))
        let released = queue.release(readiness: ready, now: 1000)
        XCTAssertEqual(released?.intent, .route(request))
        XCTAssertEqual(released?.update, .ok)
        XCTAssertNil(queue.pending, "放行后清空")
    }

    func testUpdateCheckTimesOutAfterFiveSecondsAsUnknown() {
        var queue = LaunchQueue()
        queue.enqueue(.push(messageId: "m1"))
        let readiness = LaunchReadiness(
            environmentSettled: true,
            privacy: .consented,
            update: .checking(startedAt: 1000)
        )
        XCTAssertNil(queue.release(readiness: readiness, now: 1000), "闸门在 1000 通过，从这一刻起算 5 秒")
        XCTAssertNil(queue.release(readiness: readiness, now: 5999))
        let released = queue.release(readiness: readiness, now: 6000)
        XCTAssertEqual(released?.intent, .push(messageId: "m1"))
        XCTAssertEqual(released?.update, .unknown)
    }

    func testOnlyLatestIntentIsKept() {
        var queue = LaunchQueue()
        queue.enqueue(.push(messageId: "old"))
        queue.enqueue(.route(request))
        XCTAssertEqual(queue.pending, .route(request))
        queue.discard()
        XCTAssertNil(queue.pending)
    }
}

@MainActor
final class RouterExecutionTests: XCTestCase {
    private var guardState = GuardState(
        privacyState: .consented,
        updateState: .ok,
        sessionState: .guest,
        environmentSettled: true,
        appVersion: "1.0.0",
        isDebugBuild: false
    )
    private var now: Int64 = 1_000_000

    private func makeRouter(backend: MemoryPendingBackend = MemoryPendingBackend()) -> Router {
        let store = PendingActionStore(backend: backend, clock: { [unowned self] in now })
        return Router(pendingStore: store, state: { [unowned self] in guardState })
    }

    func testOpenPushesPlaceholderAndHomeIsRoot() {
        let router = makeRouter()
        router.open(RouteRequest(route: "Search", values: ["q": .string("a")], from: .deeplink))
        XCTAssertEqual(router.path.map(\.route), ["Search"])
        XCTAssertEqual(router.path.first?.params, ["q": .string("a")])
        router.open(RouteRequest(route: "Home", from: .inApp))
        XCTAssertTrue(router.path.isEmpty)
    }

    func testRejectedDeepLinkStaysOnCurrentPage() {
        let router = makeRouter()
        router.open(RouteRequest(route: "Wallet", from: .deeplink))
        XCTAssertTrue(router.path.isEmpty)
        XCTAssertEqual(router.lastDecision?.reason, GuardReason.entryNotAllowed)
    }

    func testUnknownRouteShowsUpgradePrompt() {
        let router = makeRouter()
        router.open(RouteRequest(route: "NoSuchRoute", from: .deeplink))
        XCTAssertEqual(router.path.count, 1)
        XCTAssertTrue(router.path[0].isUpgradePrompt)
    }

    func testLoginRequiredRemembersActionAndResumesAfterLogin() {
        let backend = MemoryPendingBackend()
        let router = makeRouter(backend: backend)
        router.open(RouteRequest(route: "InviteShare", from: .inApp))
        XCTAssertEqual(router.path.map(\.route), ["Login"])
        XCTAssertNotNil(backend.read())

        guardState.session = .loggedIn
        now += 60000
        router.path = []
        router.prerequisiteCompleted()
        XCTAssertEqual(router.path.map(\.route), ["BindPhone"], "还缺绑手机：保留记录，进前置页")
        XCTAssertNotNil(backend.read())

        guardState.session = .phoneBound
        now += 540_000
        router.path = []
        router.prerequisiteCompleted()
        XCTAssertEqual(router.path.map(\.route), ["InviteShare"])
        XCTAssertNil(backend.read(), "执行 1 次后删除")
    }

    func testExpiredActionIsDiscarded() {
        let backend = MemoryPendingBackend()
        let router = makeRouter(backend: backend)
        router.open(RouteRequest(route: "Wallet", from: .inApp))
        guardState.session = .loggedIn
        now += 600_001
        router.path = []
        router.prerequisiteCompleted()
        XCTAssertTrue(router.path.isEmpty)
        XCTAssertNil(backend.read())
    }

    func testFundPagesDropParamsAndAreNotRemembered() {
        let backend = MemoryPendingBackend()
        let router = makeRouter(backend: backend)
        router.open(RouteRequest(route: "RealName", values: ["name": .string("x")], from: .push))
        XCTAssertEqual(router.path.map(\.route), ["Login"])
        XCTAssertNil(backend.read(), "实名页面不登记 pending_action（BR-ID-10 不适用的动作）")
        guardState.session = .phoneBound
        router.path = []
        router.open(RouteRequest(route: "RealName", values: ["name": .string("x")], from: .push))
        XCTAssertEqual(router.path.first?.route, "RealName")
        XCTAssertEqual(router.path.first?.params, [:])
    }

    func testDeferredExternalRequestIsQueuedAndReleased() {
        guardState.environmentSettled = false
        let router = makeRouter()
        router.open(RouteRequest(route: "Search", from: .deeplink))
        XCTAssertTrue(router.hasPendingLaunchIntent)
        router.drainLaunchQueue(
            readiness: LaunchReadiness(environmentSettled: true, privacy: .consented, update: .finished(.ok)),
            now: now
        )
        XCTAssertEqual(router.path.map(\.route), ["Search"])
        XCTAssertFalse(router.hasPendingLaunchIntent)
    }

    func testBelowMinimumReplacesStackWithForceUpdate() {
        guardState.update = .belowMin
        let router = makeRouter()
        router.path = [RouteDestination(route: "Search")]
        router.open(RouteRequest(route: "Search", from: .inApp))
        XCTAssertEqual(router.path.map(\.route), ["ForceUpdate"])
    }

    func testSessionEndedClearsPendingAction() {
        let backend = MemoryPendingBackend()
        let router = makeRouter(backend: backend)
        router.open(RouteRequest(route: "Wallet", from: .inApp))
        XCTAssertNotNil(backend.read())
        router.sessionEnded()
        XCTAssertNil(backend.read())
    }
}

@MainActor
final class PendingBackendTests: XCTestCase {
    func testUserDefaultsKeyIsInAppNamespaceAndCleanedOnEnvironmentSwitch() throws {
        let suite = "RouterTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertTrue(UserDefaultsPendingBackend.key.hasPrefix(AppNamespace.userDefaultsPrefix))
        let store = PendingActionStore(backend: UserDefaultsPendingBackend(defaults: defaults), clock: { 0 })
        XCTAssertTrue(store.save(action: "open_route", params: ["route": "Wallet"], now: 0))
        XCTAssertNotNil(store.load(now: 0))

        try UserDefaultsNamespaceCleaner(defaults: defaults).cleanForEnvironmentSwitch()
        XCTAssertNil(store.load(now: 0))
    }

    func testCorruptRecordIsDeleted() {
        let backend = MemoryPendingBackend()
        backend.write("not json")
        XCTAssertNil(PendingActionStore(backend: backend).load(now: 0))
        XCTAssertNil(backend.read())
    }
}

final class DeepLinkSchemaTests: XCTestCase {
    private let config = DeepLinkConfig(schemes: ["couli-test"], hosts: ["l.example.invalid"])

    func testUnknownRouteNameParsesForUpgradePrompt() {
        let request = DeepLinkParser.parse(url: "couli-test://r/FutureRoute?x=1", config: config)
        XCTAssertEqual(request?.route, "FutureRoute")
        XCTAssertEqual(request?.paramValues, ["x": .string("1")])
    }

    func testRejectsExtraParamDuplicateKeyFragmentAndPort() {
        for url in [
            "couli-test://r/Home?x=1",
            "couli-test://r/Search?q=a&q=b",
            "https://l.example.invalid/r/Home#top",
            "https://l.example.invalid:8443/r/Home",
            "couli-test://r/Search?q",
        ] {
            XCTAssertNil(DeepLinkParser.parse(url: url, config: config), url)
        }
    }

    func testEmptyConfigUsesNoBuiltInEntries() {
        XCTAssertNil(DeepLinkParser.parse(url: "https://l.example.invalid/r/Home", config: .empty))
    }
}
