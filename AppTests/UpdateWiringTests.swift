import Config
@testable import Couli
import Foundation
import Privacy
import Router
import Update
import XCTest

/// APP-02c：强更检查接线（AppUpdate → Router 状态源、强更页进出、可关闭提示、选店），
/// 以及 F-IOS-09（同意回调的恢复等强更与 Tab 就绪）、F-IOS-10（同意没生效时复位补同意标记）。
@MainActor
final class UpdateWiringTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        suiteName = "UpdateWiringTests.\(UUID().uuidString)"
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

    private func basicStore() -> MemoryPrivacyStore {
        let store = MemoryPrivacyStore()
        store.decisionRaw = "basic_mode"
        store.basicMode = true
        return store
    }

    private func makeRouting(_ privacyStore: MemoryPrivacyStore, update: AppUpdate) -> AppRouting {
        let environment = EnvironmentStore(defaultEnvironment: .test, defaults: defaults, registry: .init(cleaners: []))
        let privacy = PrivacyController(store: privacyStore, clock: { 1 }, bundledPolicyVersion: "1")
        return AppRouting(environment: environment, privacy: privacy, update: update)
    }

    // MARK: - 检查时机与 Router 状态源

    func testColdStartCheckOnlyAfterConsent() {
        let checker = StubUpdateChecker(.success(UpdateFixtures.ok))
        let update = UpdateFixtures.makeUpdate(checker: checker)
        let routing = makeRouting(MemoryPrivacyStore(), update: update)
        XCTAssertEqual(checker.calls, 0, "隐私未决：同意前不发 check（BR-ID-11）")
        if case .checking = routing.readiness.update {} else {
            XCTFail("冷启动检查还没发出：按检查中")
        }
        routing.privacy.agree()
        XCTAssertEqual(checker.calls, 1, "同意后补发冷启动检查")
        XCTAssertEqual(routing.readiness.update, .finished(.ok))
    }

    func testBasicModeDoesNotCheckAndIsUnknown() {
        let checker = StubUpdateChecker(.success(UpdateFixtures.ok))
        let routing = makeRouting(basicStore(), update: UpdateFixtures.makeUpdate(checker: checker))
        XCTAssertEqual(checker.calls, 0, "基本模式不发 check")
        XCTAssertEqual(routing.readiness.update, .finished(.unknown), "基本模式：未知、不等待")
    }

    func testBasicModeKeepsPersistedForceUpdate() {
        let store = MemoryUpdateStore(record: UpdateRecord(lastResult: UpdateFixtures.force, lastSuccessAt: 1))
        let routing = makeRouting(basicStore(), update: UpdateFixtures.makeUpdate(store: store))
        XCTAssertEqual(routing.readiness.update, .finished(.belowMin))
        XCTAssertEqual(routing.router.path.map(\.route), [RoutePolicy.forceUpdate], "本机记着低于：基本模式照样强更")
    }

    func testCheckingExternalDeferredInAppNot() {
        let checker = StubUpdateChecker(nil)
        let routing = makeRouting(consentedStore(), update: UpdateFixtures.makeUpdate(checker: checker))
        XCTAssertEqual(checker.calls, 1)
        XCTAssertEqual(routing.guardState.update, .checking, "没等满 5 秒：checking（F-ALL-03）")
        let external = routing.router.open(RouteRequest(route: "Search", from: .bridge))
        XCTAssertEqual(external.reason, GuardReason.updateChecking)
        XCTAssertTrue(routing.router.hasPendingLaunchIntent)
        let inApp = routing.router.open(RouteRequest(route: "Search", from: .inApp))
        XCTAssertEqual(inApp.kind, .open, "App 内操作不等")
    }

    func testForceUpdateEntersFromAnyPageAndLeavesWhenResolved() {
        let checker = StubUpdateChecker(nil)
        let update = UpdateFixtures.makeUpdate(checker: checker)
        let routing = makeRouting(consentedStore(), update: update)
        routing.shellAppeared()
        routing.router.open(RouteRequest(route: "Search", from: .inApp))
        checker.deliver(.success(UpdateFixtures.force))
        XCTAssertEqual(routing.router.path.map(\.route), [RoutePolicy.forceUpdate], "无论在哪个页面都进入强更页")

        routing.router.openFromForceUpdatePage(RouteRequest(route: RoutePolicy.login, from: .inApp))
        XCTAssertEqual(routing.router.path.map(\.route), [RoutePolicy.forceUpdate, RoutePolicy.login])
        XCTAssertEqual(routing.router.path.last?.fromForceUpdatePage, true)

        update.debugRecheck()
        checker.deliver(.success(UpdateFixtures.ok))
        XCTAssertTrue(routing.router.path.isEmpty, "解除后离开强更页")
    }

    func test10405EntersForceUpdateAndRechecksWhenNoResult() {
        let checker = StubUpdateChecker(.failure)
        let update = UpdateFixtures.makeUpdate(checker: checker)
        let routing = makeRouting(consentedStore(), update: update)
        XCTAssertEqual(routing.readiness.update, .finished(.unknown))
        routing.on10405(minSupported: "9.0.0")
        XCTAssertEqual(routing.router.path.map(\.route), [RoutePolicy.forceUpdate])
        XCTAssertEqual(checker.calls, 2, "没有检查结果：立即再查一次（页面内容）")
        routing.on10405(minSupported: nil)
        XCTAssertEqual(update.ui.status, .belowMin)
    }

    // MARK: - 选店

    func testForceGoStoreUnavailableWhenTableIsNull() {
        let stores = StubStoreAccess()
        let update = UpdateFixtures.makeUpdate(
            checker: StubUpdateChecker(.success(UpdateFixtures.force)),
            stores: stores
        )
        _ = makeRouting(consentedStore(), update: update)
        XCTAssertFalse(update.ui.forceUnavailable, "版本够：先给【去更新】")
        update.forceGoStore()
        XCTAssertTrue(update.ui.forceUnavailable, "打不开（对照表为 null）→ 暂时无法更新与【重试】")
        XCTAssertEqual(stores.opened, [], "打不开时不调用打开")
    }

    func testForceGoStoreOpensFirstQualifiedStore() {
        let stores = StubStoreAccess(openable: ["huawei"])
        let update = UpdateFixtures.makeUpdate(
            checker: StubUpdateChecker(.success(UpdateFixtures.force)),
            stores: stores
        )
        _ = makeRouting(consentedStore(), update: update)
        update.forceGoStore()
        XCTAssertEqual(stores.opened, ["huawei"])
        XCTAssertFalse(update.ui.forceUnavailable)
        stores.openSucceeds = false
        update.forceGoStore()
        XCTAssertTrue(update.ui.forceUnavailable, "打开失败：显示暂时无法更新")
    }

    func testNoStoreVersionShowsUnavailableUpFrontAndRetryRechecks() {
        let checker = StubUpdateChecker(.success(UpdateFixtures.forceNoStore))
        let update = UpdateFixtures.makeUpdate(checker: checker)
        _ = makeRouting(consentedStore(), update: update)
        XCTAssertTrue(update.ui.forceUnavailable, "一家已上架版本都不够：直接显示暂时无法更新")
        checker.outcome = .success(UpdateFixtures.ok)
        update.retry()
        XCTAssertEqual(checker.calls, 2, "【重试】重新调 check")
        XCTAssertEqual(update.ui.status, .ok)
    }

    func testAppStoreAccessTreatsNullTableAsUnopenable() {
        let access = AppStoreAccess()
        XCTAssertNil(access.installSource, "对照表里 App Store 的商店键还是 null（N-17）")
        XCTAssertFalse(access.canOpen("huawei"))
        XCTAssertFalse(access.canOpen("appstore"))
        var opened: Bool?
        access.open("huawei") { opened = $0 }
        XCTAssertEqual(opened, false, "对照表为 null：不调用 UIApplication.open")
        XCTAssertEqual(AppStoreAccess.platform, "ios")
    }

    // MARK: - 可关闭提示

    func testPromptDismissedForSameLatest() {
        let store = MemoryUpdateStore()
        let update = UpdateFixtures.makeUpdate(
            checker: StubUpdateChecker(.success(UpdateFixtures.recommend)),
            store: store
        )
        _ = makeRouting(consentedStore(), update: update)
        XCTAssertTrue(update.showsPrompt)
        update.dismissPrompt()
        XCTAssertFalse(update.showsPrompt)
        XCTAssertEqual(store.record.dismissedLatest, "99.1.0", "按提示时的 latest 记录")

        let again = UpdateFixtures.makeUpdate(
            checker: StubUpdateChecker(.success(UpdateFixtures.recommend)),
            store: store
        )
        _ = makeRouting(consentedStore(), update: again)
        XCTAssertFalse(again.showsPrompt, "同一版本不再提示")
    }

    func testPromptGoStoreUnavailableShowsToastAndDoesNotSwitchStore() {
        let stores = StubStoreAccess()
        let update = UpdateFixtures.makeUpdate(
            checker: StubUpdateChecker(.success(UpdateFixtures.recommend)), stores: stores
        )
        _ = makeRouting(consentedStore(), update: update)
        update.promptGoStore()
        XCTAssertFalse(update.showsPrompt)
        XCTAssertEqual(update.toast?.text, "暂时无法更新，应用商店里还没有可以安装的新版本，请稍后再试")
        XCTAssertEqual(stores.opened, [])
    }

    // MARK: - F-IOS-09

    /// R3-01 场景：冷启动有未过期的 OrderList 待办，隐私版本升级要重新同意；强更检查进行中、外壳未就绪 → 用户同意 →
    /// 不立即进登录；外壳就绪、检查仍在进行也不进；检查有结果后才按前置继续。
    func testConsentDuringCheckingWaitsForResultAndShell() {
        let pending = PendingActionStore(backend: UserDefaultsPendingBackend())
        XCTAssertTrue(pending.save(
            action: Router.openRouteAction,
            values: ["route": .string("OrderList")],
            now: pending.now,
            origin: RouteSource.inApp.rawValue
        ))
        let store = MemoryPrivacyStore()
        store.decisionRaw = "consented"
        store.consentedVersion = "0"
        let checker = StubUpdateChecker(nil)
        let routing = makeRouting(store, update: UpdateFixtures.makeUpdate(checker: checker))
        XCTAssertTrue(routing.privacy.isPrompting, "旧版本同意不作数，先弹首启弹窗")

        routing.privacy.agree()
        XCTAssertEqual(checker.calls, 1)
        XCTAssertTrue(routing.router.path.isEmpty, "检查中、外壳未就绪：不恢复")
        routing.shellAppeared()
        XCTAssertTrue(routing.router.path.isEmpty, "外壳就绪但检查还没结果：不恢复")
        XCTAssertNotNil(UserDefaultsPendingBackend().read())

        checker.deliver(.success(UpdateFixtures.ok))
        XCTAssertEqual(routing.router.path.map(\.route), [RoutePolicy.login], "有结果后：游客继续去登录")
    }

    // MARK: - F-IOS-10

    /// 撤回清理失败 → 基本模式点受限 Tab（补同意）→ 同意时清理重试仍失败、弹窗关闭 → 复位两个标记并丢弃待办，
    /// 再点受限 Tab 还能弹隐私提示。
    func testConsentNotTakingEffectResetsConsentFlags() {
        // 撤回清理一直失败：隐私记录与清理执行器用同一个测试 UserDefaults，清理器总是抛错。
        let store = UserDefaultsPrivacyStore(defaults: defaults)
        store.commitWithdrawal()
        XCTAssertTrue(store.withdrawalCleanupPending)
        let runner = WithdrawalCleanupRunner(
            defaults: defaults,
            registry: EnvironmentSwitchCleanerRegistry(cleaners: [FailingCleaner()])
        )
        let environment = EnvironmentStore(defaultEnvironment: .test, defaults: defaults, registry: .init(cleaners: []))
        let privacy = PrivacyController(store: store, clock: { 1 }, bundledPolicyVersion: "1", withdrawalRunner: runner)
        let routing = AppRouting(environment: environment, privacy: privacy, update: UpdateFixtures.makeUpdate())
        routing.shellAppeared()

        XCTAssertNil(routing.selectTab(.orders))
        XCTAssertTrue(routing.router.consentRequested)
        XCTAssertTrue(routing.privacy.isPrompting)
        routing.privacy.agree()
        XCTAssertEqual(routing.privacy.routerPrivacy, .basicMode, "清理仍失败：同意没生效")
        XCTAssertFalse(routing.privacy.isPrompting, "弹窗已关闭")
        XCTAssertFalse(routing.router.consentRequested, "复位补同意请求")
        XCTAssertFalse(routing.router.awaitingConsentResult)
        XCTAssertNil(UserDefaultsPendingBackend().read(), "结束这次补同意：丢弃待办")

        XCTAssertNil(routing.selectTab(.me))
        XCTAssertTrue(routing.privacy.isPrompting, "再点受限 Tab 仍会弹隐私提示")
    }
}

/// 总是失败的清理器（模拟撤回清理失败）。
@MainActor
private final class FailingCleaner: EnvironmentSwitchCleaning {
    let cleanerName = "UpdateWiringTests.Failing"

    func cleanForEnvironmentSwitch() throws {
        throw CocoaError(.fileWriteUnknown)
    }
}
