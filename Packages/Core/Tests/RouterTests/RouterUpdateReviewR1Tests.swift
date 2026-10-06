import Foundation
import Generated
import XCTest
@testable import Router

/// APP-02c iOS 评审第 1 轮（ios-review-r1.md）的 Router 层回归：
/// R1-01（强更页发起的补同意，同意后继续受限登录、不登记待办）、R1-02（检查期间排队的热推送保留回查器）、
/// R1-03（入队通知启动协调安排 5 秒超时）、F-ALL-06（强更状态下隐私弹窗里的协议链接）。
@MainActor
final class RouterUpdateReviewR1Tests: XCTestCase {
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

    private func readiness(update: UpdateCheckStatus) -> LaunchReadiness {
        LaunchReadiness(environmentSettled: true, privacy: guardState.privacy, update: update)
    }

    // MARK: - R1-01

    func testConsentFromForceUpdatePageContinuesRestrictedLoginWithoutPending() {
        guardState.privacy = .basicMode
        guardState.update = .belowMin
        guardState.session = .guest
        let backend = MemoryPendingBackend()
        let (router, _) = makeRouter(backend: backend)
        router.enterForceUpdate()

        let decision = router.openFromForceUpdatePage(RouteRequest(route: RoutePolicy.login, from: .inApp))
        XCTAssertEqual(decision.kind, .requireConsent, "基本模式：Login 要先补同意")
        XCTAssertTrue(router.consentRequested)
        XCTAssertTrue(router.awaitingConsentResult)
        XCTAssertNil(backend.read(), "强更页发起的请求不登记 pending_action")
        XCTAssertEqual(router.path.map(\.route), [RoutePolicy.forceUpdate], "强更页留着")

        guardState.privacy = .consented
        router.consentResolved(granted: true)
        XCTAssertEqual(router.path.map(\.route), [RoutePolicy.forceUpdate, RoutePolicy.login], "同意后继续受限登录")
        XCTAssertEqual(router.path.last?.fromForceUpdatePage, true)
        XCTAssertFalse(router.consentRequested)
        XCTAssertNil(backend.read())
    }

    func testRefusedConsentFromForceUpdatePageStaysOnForceUpdate() {
        guardState.privacy = .basicMode
        guardState.update = .belowMin
        guardState.session = .guest
        let backend = MemoryPendingBackend()
        let (router, _) = makeRouter(backend: backend)
        router.enterForceUpdate()
        router.openFromForceUpdatePage(RouteRequest(route: RoutePolicy.login, from: .inApp))

        router.consentResolved(granted: false)
        XCTAssertEqual(router.path.map(\.route), [RoutePolicy.forceUpdate], "拒绝：回强更页")
        XCTAssertNil(backend.read())

        // 之后普通同意不再补开被拒的登录。
        guardState.privacy = .consented
        router.consentResolved(granted: true)
        XCTAssertEqual(router.path.map(\.route), [RoutePolicy.forceUpdate])
    }

    func testConsentFromForceUpdatePageDroppedWhenForceUpdateResolved() {
        guardState.privacy = .basicMode
        guardState.update = .belowMin
        guardState.session = .guest
        let (router, _) = makeRouter()
        router.enterForceUpdate()
        router.openFromForceUpdatePage(RouteRequest(route: RoutePolicy.login, from: .inApp))
        guardState.privacy = .consented
        guardState.update = .ok
        router.leaveForceUpdate()
        router.consentResolved(granted: true)
        XCTAssertTrue(router.path.isEmpty, "强更已解除：不按强更来源打开受限登录")
    }

    // MARK: - F-ALL-06

    func testPrivacyDialogAgreementOpensUnderForceUpdate() {
        guardState.update = .belowMin
        for privacy in [PrivacyState.notDecided, .basicMode] {
            guardState.privacy = privacy
            let (router, _) = makeRouter()
            let agreement = RouteRequest(route: "Agreement", values: ["type": .string("privacy")], from: .inApp)
            XCTAssertEqual(router.open(agreement).kind, .forceUpdate, "不带强更来源：被强更拦下（原缺陷）")

            router.path = privacy == .basicMode ? [RouteDestination(route: RoutePolicy.forceUpdate)] : []
            let decision = router.openFromPrivacyDialog(agreement)
            XCTAssertTrue(decision.opensPage, "\(privacy)：弹窗里的协议链接能打开")
            XCTAssertEqual(router.path.last?.route, "Agreement")
            XCTAssertEqual(router.path.last?.params["type"], .string("privacy"))
        }
    }

    func testPrivacyDialogOnlyAgreementGetsForceUpdateSource() {
        guardState.update = .belowMin
        guardState.privacy = .basicMode
        let (router, _) = makeRouter()
        router.enterForceUpdate()
        let decision = router.openFromPrivacyDialog(RouteRequest(route: "PrivacyCenter", from: .inApp))
        XCTAssertEqual(decision.kind, .forceUpdate, "别的路由不借弹窗口子绕过强更")
        XCTAssertEqual(router.path.map(\.route), [RoutePolicy.forceUpdate])

        guardState.update = .ok
        guardState.privacy = .notDecided
        router.path = []
        router.openFromPrivacyDialog(RouteRequest(route: "Agreement", from: .inApp))
        XCTAssertEqual(router.path.last?.fromForceUpdatePage, false, "非强更状态照常 App 内打开")
    }

    // MARK: - R1-02

    func testHotPushQueuedWhileCheckingKeepsItsLanding() async {
        guardState.update = .checking
        let (router, _) = makeRouter()
        let lookups = LookupCounter()
        let landing = PushLanding(timeout: .seconds(5)) { _ in
            await lookups.hit()
            return .found(route: "Search", params: [:])
        }
        XCTAssertNil(router.handlePush(messageId: "m1", using: landing), "检查中：不回查，排队")
        XCTAssertTrue(router.hasPendingLaunchIntent)
        XCTAssertNotNil(router.queuedPushLanding, "排队时保存回查器")

        guardState.update = .ok
        // 调用方不再传回查器（App 只给冷启动推送传过），排队时保存的照样用上。
        let task = router.launchConditionsChanged(
            readiness: readiness(update: .finished(.ok)),
            shellReady: true,
            now: now
        )
        XCTAssertNotNil(task, "检查结束：用保存的回查器回查")
        await task?.value
        let count = await lookups.count
        XCTAssertEqual(count, 1)
        XCTAssertEqual(router.path.count, 1, "回查结果照常执行")
        XCTAssertNil(router.queuedPushLanding, "放行后清掉")
    }

    func testNewIntentClearsQueuedLanding() {
        guardState.update = .checking
        let (router, _) = makeRouter()
        router.handlePush(messageId: "m1", using: PushLanding { _ in .notFound })
        XCTAssertNotNil(router.queuedPushLanding)
        router.open(RouteRequest(route: "Search", from: .deeplink))
        XCTAssertNil(router.queuedPushLanding, "新意图覆盖推送：回查器一起清掉")
        router.enqueueLaunch(.push(messageId: "m2"), pushLanding: PushLanding { _ in .notFound })
        router.discardLaunchIntent()
        XCTAssertNil(router.queuedPushLanding)
    }

    // MARK: - R1-03

    func testEveryEnqueueNotifiesAndSchedulesFromCheckStart() {
        guardState.update = .checking
        let (router, _) = makeRouter()
        var notified = 0
        router.onLaunchQueueChanged = { notified += 1 }
        let checking = readiness(update: .checking(startedAt: now))
        // 闸门已通过、检查已开始，此时没有任何意图：不计时。
        router.launchConditionsChanged(readiness: checking, shellReady: true, now: now)
        XCTAssertNil(router.launchConditionsRetryAt(readiness: checking, now: now + 1000))

        // 检查开始 2 秒后才来的外部请求（深链；桥调用同一条路径）：入队即通知，截止时间按检查起点算（第 5 秒）。
        router.open(RouteRequest(route: "Search", from: .deeplink))
        XCTAssertEqual(notified, 1)
        XCTAssertEqual(router.launchConditionsRetryAt(readiness: checking, now: now + 2000), now + 5000)

        // 第 5 秒协调：按 unknown 只读放行。
        router.launchConditionsChanged(readiness: checking, shellReady: true, now: now + 5000)
        XCTAssertEqual(router.path.map(\.route), ["Search"])
        XCTAssertEqual(router.path.last?.readonly, true)

        router.enqueueLaunch(.push(messageId: "m1"))
        XCTAssertEqual(notified, 2, "冷启动意图入队同样通知")
    }
}

private actor LookupCounter {
    private(set) var count = 0

    func hit() {
        count += 1
    }
}
