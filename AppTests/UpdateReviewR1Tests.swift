import Config
@testable import Couli
import Foundation
import Privacy
import Router
import Update
import XCTest

/// APP-02c iOS 评审第 1 轮（ios-review-r1.md）的接线回归：
/// R1-01 基本模式下强更页上的补同意弹窗与受限登录；R1-02 检查期间排队的热推送；R1-03 入队后的 5 秒超时；
/// R1-04 强更页重试不无限重试；R1-05 更高 latest 再提示；F-ALL-06 强更下隐私弹窗里的协议链接；
/// 以及回前台复查进行中按 checking（不拿旧 ok 放行外部入口）。
@MainActor
final class UpdateReviewR1Tests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        suiteName = "UpdateReviewR1Tests.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        UserDefaultsPendingBackend().delete()
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        UserDefaultsPendingBackend().delete()
    }

    private func consentedStore(version: String = "1") -> MemoryPrivacyStore {
        let store = MemoryPrivacyStore()
        store.decisionRaw = "consented"
        store.consentedVersion = version
        return store
    }

    private func basicStore() -> MemoryPrivacyStore {
        let store = MemoryPrivacyStore()
        store.decisionRaw = "basic_mode"
        store.basicMode = true
        return store
    }

    private func forceStore() -> MemoryUpdateStore {
        MemoryUpdateStore(record: UpdateRecord(lastResult: UpdateFixtures.force, lastSuccessAt: 1))
    }

    private func makeRouting(_ privacyStore: MemoryPrivacyStore, update: AppUpdate) -> AppRouting {
        let environment = EnvironmentStore(defaultEnvironment: .test, defaults: defaults, registry: .init(cleaners: []))
        let privacy = PrivacyController(store: privacyStore, clock: { 1 }, bundledPolicyVersion: "1")
        return AppRouting(environment: environment, privacy: privacy, update: update)
    }

    private func recommend(latest: String) -> UpdateCheckResult {
        UpdateCheckResult(
            minSupported: nil, recommended: "99.0.0", latest: latest, defaultStore: "huawei",
            stores: [UpdateStoreListing(store: "huawei", version: latest)]
        )
    }

    // MARK: - R1-01

    /// 本机记着 below_min、基本模式、游客 → 强更页点「注销账号」（游客先登录）→ 补同意弹窗叠在强更页上 →
    /// 同意后进受限登录；全程不登记 pending_action。
    func testBasicModeConsentFromForceUpdatePageContinuesToRestrictedLogin() {
        let routing = makeRouting(basicStore(), update: UpdateFixtures.makeUpdate(
            checker: StubUpdateChecker(nil), store: forceStore()
        ))
        XCTAssertEqual(routing.router.path.map(\.route), [RoutePolicy.forceUpdate])
        XCTAssertFalse(routing.showsPrivacyDialog)

        routing.router.openFromForceUpdatePage(RouteRequest(route: RoutePolicy.login, from: .inApp))
        XCTAssertTrue(routing.privacy.isPrompting, "需要同意：弹补同意")
        XCTAssertTrue(routing.showsPrivacyDialog, "弹窗显示在强更页之上（导航栈不为空也显示）")
        XCTAssertEqual(routing.router.path.map(\.route), [RoutePolicy.forceUpdate])
        XCTAssertNil(UserDefaultsPendingBackend().read(), "不登记普通业务待办")

        routing.privacy.agree()
        XCTAssertEqual(routing.router.path.map(\.route), [RoutePolicy.forceUpdate, RoutePolicy.login], "同意后进受限登录")
        XCTAssertEqual(routing.router.path.last?.fromForceUpdatePage, true)
        XCTAssertFalse(routing.showsPrivacyDialog)
        XCTAssertNil(UserDefaultsPendingBackend().read())
    }

    func testBasicModeRefusalOnForceUpdateStaysOnForceUpdate() {
        let routing = makeRouting(basicStore(), update: UpdateFixtures.makeUpdate(
            checker: StubUpdateChecker(nil), store: forceStore()
        ))
        routing.router.openFromForceUpdatePage(RouteRequest(route: RoutePolicy.login, from: .inApp))
        XCTAssertTrue(routing.showsPrivacyDialog)
        for _ in 0..<2 where routing.privacy.isPrompting {
            if routing.privacy.state.promptStage == .second {
                routing.privacy.stillDisagree()
            } else {
                routing.privacy.disagree()
            }
        }
        XCTAssertEqual(routing.router.path.map(\.route), [RoutePolicy.forceUpdate], "拒绝：回强更页")
        XCTAssertFalse(routing.router.consentRequested)
        XCTAssertNil(UserDefaultsPendingBackend().read())
    }

    // MARK: - F-ALL-06

    /// 补同意弹窗叠在强更页上：弹窗里的协议链接带强更来源打开 Agreement；读完返回，弹窗回来。
    func testAgreementLinkInDialogOverForceUpdateOpens() {
        let routing = makeRouting(basicStore(), update: UpdateFixtures.makeUpdate(
            checker: StubUpdateChecker(nil), store: forceStore()
        ))
        routing.router.openFromForceUpdatePage(RouteRequest(route: RoutePolicy.login, from: .inApp))
        XCTAssertTrue(routing.showsPrivacyDialog)

        routing.openAgreementFromPrivacyDialog(type: "privacy")
        XCTAssertEqual(routing.router.path.map(\.route), [RoutePolicy.forceUpdate, "Agreement"])
        XCTAssertEqual(routing.router.path.last?.params["type"], .string("privacy"))
        XCTAssertFalse(routing.showsPrivacyDialog, "读协议时弹窗让出")

        routing.router.path.removeLast()
        XCTAssertTrue(routing.showsPrivacyDialog, "返回后弹窗回来，强更页仍在")
        XCTAssertEqual(routing.router.path.map(\.route), [RoutePolicy.forceUpdate])
    }

    /// 隐私政策升级要重新同意、本机记着 below_min：首启弹窗里的协议链接同样能打开（不被强更拦下、不把弹窗挤掉）。
    func testAgreementLinkInReconsentDialogWithKnownForceUpdate() {
        let routing = makeRouting(consentedStore(version: "0"), update: UpdateFixtures.makeUpdate(
            checker: StubUpdateChecker(nil), store: forceStore()
        ))
        XCTAssertTrue(routing.privacy.isPrompting)
        XCTAssertTrue(routing.showsPrivacyDialog)

        routing.openAgreementFromPrivacyDialog(type: "agreement")
        XCTAssertEqual(routing.router.path.map(\.route), ["Agreement"], "协议页打开，没有被转去强更页")
        XCTAssertFalse(routing.showsPrivacyDialog)
        routing.router.path.removeLast()
        XCTAssertTrue(routing.showsPrivacyDialog)

        routing.privacy.agree()
        XCTAssertEqual(routing.router.path.map(\.route), [RoutePolicy.forceUpdate], "有结论后进入强更页")
    }

    // MARK: - R1-02

    func testHotPushQueuedDuringCheckingIsLookedUpAfterCheck() async throws {
        let checker = StubUpdateChecker(nil)
        let routing = makeRouting(consentedStore(), update: UpdateFixtures.makeUpdate(checker: checker))
        routing.placeholders.session = .loggedIn
        routing.shellAppeared()

        let looked = expectation(description: "回查")
        let landing = PushLanding(timeout: .seconds(5)) { _ in
            looked.fulfill()
            return .found(route: "Search", params: [:])
        }
        XCTAssertNil(routing.handlePush(messageId: "m1", coldStart: false, using: landing))
        XCTAssertTrue(routing.router.hasPendingLaunchIntent, "检查中：排队")

        checker.deliver(.success(UpdateFixtures.ok))
        await fulfillment(of: [looked], timeout: 3)
        for _ in 0..<100 where routing.router.path.isEmpty {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(routing.router.path.map(\.route), ["Search"], "检查结束后照常回查并执行")
    }

    // MARK: - R1-03

    /// 检查开始后才进来的外部请求（此前没有任何意图或待办）：入队即安排超时，第 5 秒按 unknown 只读放行。
    func testRequestQueuedAfterCheckStartedTimesOutAtFiveSeconds() async throws {
        let checker = StubUpdateChecker(nil)
        let update = UpdateFixtures.makeUpdate(checker: checker)
        let routing = makeRouting(consentedStore(), update: update)
        routing.shellAppeared()
        XCTAssertNil(routing.scheduledLaunchRetryAt, "无事可做：不计时")
        let started = try XCTUnwrap(update.checkStartedAt)

        let decision = routing.router.open(RouteRequest(route: "Search", from: .deeplink))
        XCTAssertEqual(decision.reason, GuardReason.updateChecking)
        let retryAt = try XCTUnwrap(routing.scheduledLaunchRetryAt, "入队即安排超时协调")
        XCTAssertEqual(
            retryAt,
            max(started, routing.router.launchGatesOpenedAt ?? started) + LaunchQueue.updateWaitMillis
        )

        for _ in 0..<80 where routing.router.path.isEmpty {
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertEqual(checker.calls, 1, "检查一直没有回调")
        XCTAssertEqual(routing.router.path.map(\.route), ["Search"], "第 5 秒按 unknown 放行")
        XCTAssertEqual(routing.router.path.last?.readonly, true, "unknown：只读")
    }

    // MARK: - 回前台复查进行中

    func testForegroundRecheckInFlightDefersExternalAndPending() {
        let clock = TestClock(PendingActionStore.wallClockMillis())
        let checker = StubUpdateChecker(.success(UpdateFixtures.ok))
        let update = UpdateFixtures.makeUpdate(checker: checker, clock: { clock.now })
        let routing = makeRouting(consentedStore(), update: update)
        routing.shellAppeared()
        XCTAssertEqual(routing.readiness.update, .finished(.ok))

        checker.outcome = nil
        clock.now += Int64(UpdateGate.defaultRecheckIntervalSec + 1) * 1000
        routing.sceneEnteredBackground()
        routing.sceneBecameActive()
        XCTAssertEqual(checker.calls, 2, "超过间隔：回前台复查")
        XCTAssertEqual(routing.readiness.update, .checking(startedAt: clock.now), "复查进行中：按检查中，不用旧 ok")
        XCTAssertEqual(update.ui.status, .ok, "界面投影可保留已知结论（G12）")
        XCTAssertEqual(routing.guardState.update, .checking)

        let pending = PendingActionStore(backend: UserDefaultsPendingBackend())
        XCTAssertTrue(pending.save(
            action: Router.openRouteAction, values: ["route": .string("Search")],
            now: pending.now, origin: RouteSource.inApp.rawValue
        ))
        routing.launchConditionsChanged()
        XCTAssertNotNil(UserDefaultsPendingBackend().read(), "待办恢复等结果（update_checking）")
        XCTAssertTrue(routing.router.path.isEmpty)

        let external = routing.router.open(RouteRequest(route: "Search", from: .deeplink))
        XCTAssertEqual(external.kind, .deferred)
        XCTAssertEqual(external.reason, GuardReason.updateChecking)

        checker.deliver(.success(UpdateFixtures.ok))
        XCTAssertEqual(routing.readiness.update, .finished(.ok))
        XCTAssertNil(UserDefaultsPendingBackend().read(), "有结果后恢复待办")
        XCTAssertEqual(routing.router.path.map(\.route), ["Search", "Search"], "待办与排队的深链各执行一次")
    }

    // MARK: - R1-04

    func testForceGoStoreWithoutResultChecksOnceThenWaitsForRetry() {
        let checker = StubUpdateChecker(.failure)
        let update = UpdateFixtures.makeUpdate(checker: checker)
        _ = makeRouting(consentedStore(), update: update)
        update.on10405(minSupported: "9.0.0")
        XCTAssertEqual(update.ui.status, .belowMin)
        let before = checker.calls

        update.forceGoStore()
        XCTAssertEqual(checker.calls, before + 1, "从未成功检查：【去更新】只发一次检查")
        XCTAssertTrue(update.ui.forceUnavailable, "失败后停在暂时无法更新")
        XCTAssertFalse(update.ui.working)

        update.retry()
        XCTAssertEqual(checker.calls, before + 2, "用户再点【重试】才再查一次")
        XCTAssertTrue(update.ui.forceUnavailable)
    }

    /// Release 的占位检查器同步失败：不递归（原来会无限重试直至栈溢出）。
    func testSynchronousFailingCheckerDoesNotRecurse() {
        let gate = UpdateGate(
            store: MemoryUpdateStore(), clock: PendingActionStore.wallClockMillis, appVersion: "1.0.0",
            platform: "ios", channel: "appstore", installSource: nil
        )
        let update = AppUpdate(
            gate: gate, checker: FailingUpdateChecker(), stores: StubStoreAccess(),
            clock: PendingActionStore.wallClockMillis
        )
        _ = makeRouting(consentedStore(), update: update)
        update.on10405(minSupported: "9.0.0")
        update.forceGoStore()
        XCTAssertTrue(update.ui.forceUnavailable)
        update.retry()
        XCTAssertTrue(update.ui.forceUnavailable)
    }

    // MARK: - R1-05

    func testHigherLatestPromptsAgainInSameProcess() {
        let clock = TestClock(1_000_000)
        let checker = StubUpdateChecker(.success(recommend(latest: "99.1.0")))
        let update = UpdateFixtures.makeUpdate(checker: checker, clock: { clock.now })
        _ = makeRouting(consentedStore(), update: update)
        XCTAssertTrue(update.showsPrompt)

        update.dismissPrompt()
        XCTAssertFalse(update.showsPrompt, "暂不更新：同一 latest 不再提示")

        func recheck(latest: String) {
            checker.outcome = .success(recommend(latest: latest))
            clock.now += Int64(UpdateGate.defaultRecheckIntervalSec + 1) * 1000
            update.enteredForeground()
        }
        recheck(latest: "99.1.0")
        XCTAssertFalse(update.showsPrompt, "同一版本仍不提示")
        recheck(latest: "99.2.0")
        XCTAssertTrue(update.showsPrompt, "同一进程内更高 latest：再提示")

        update.promptGoStore()
        XCTAssertFalse(update.showsPrompt, "去更新后同一版本本次运行不再弹")
        recheck(latest: "99.2.0")
        XCTAssertFalse(update.showsPrompt)
        recheck(latest: "99.3.0")
        XCTAssertTrue(update.showsPrompt, "去更新之后出现更高 latest：再提示")
    }
}

/// 可拨动的测试时钟。
private final class TestClock {
    var now: Int64

    init(_ now: Int64) {
        self.now = now
    }
}
