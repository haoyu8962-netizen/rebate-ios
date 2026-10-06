import Combine
import Config
@testable import Couli
import Foundation
import Privacy
import Router
import Update
import XCTest

/// APP-02c 编排者裁定：进入基本模式时强更页留在最上层；调试假结果不写进 Release 读取的强更记录。
/// （G15 跨版本升级的持久化 below_min 重比在 Core 的 UpdateGateBehaviorTests。）
@MainActor
final class UpdateRulingTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        suiteName = "UpdateRulingTests.\(UUID().uuidString)"
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

    /// 编排者裁定：进入基本模式（撤回同意）清栈时不清掉强更页；below_min 时强更页始终在最上层，其上的次要入口页面清掉。
    func testEnteringBasicModeKeepsForceUpdateOnTop() {
        let runner = WithdrawalCleanupRunner(
            defaults: defaults,
            registry: EnvironmentSwitchCleanerRegistry(cleaners: [])
        )
        let environment = EnvironmentStore(defaultEnvironment: .test, defaults: defaults, registry: .init(cleaners: []))
        let privacy = PrivacyController(
            store: consentedStore(), clock: { 1 }, bundledPolicyVersion: "1", withdrawalRunner: runner
        )
        let update = UpdateFixtures.makeUpdate(checker: StubUpdateChecker(.success(UpdateFixtures.force)))
        let routing = AppRouting(environment: environment, privacy: privacy, update: update)
        routing.shellAppeared()
        XCTAssertEqual(routing.router.path.map(\.route), [RoutePolicy.forceUpdate])
        routing.router.openFromForceUpdatePage(RouteRequest(route: "PrivacyCenter", from: .inApp))
        XCTAssertEqual(routing.router.path.last?.fromForceUpdatePage, true, "隐私政策占位页带强更来源标记")

        var sawPathWithoutForceUpdate = false
        let observation = routing.router.$path.sink { path in
            if path.first?.route != RoutePolicy.forceUpdate {
                sawPathWithoutForceUpdate = true
            }
        }
        privacy.withdraw()
        observation.cancel()
        XCTAssertEqual(privacy.routerPrivacy, .basicMode)
        XCTAssertEqual(routing.router.path.map(\.route), [RoutePolicy.forceUpdate], "强更页留在最上层")
        XCTAssertFalse(sawPathWithoutForceUpdate, "清栈过程中强更页一刻也没被清掉")
        XCTAssertEqual(routing.readiness.update, .finished(.belowMin), "基本模式不检查，已知强更照旧")
    }

    /// 编排者裁定：调试假结果不写进 Release 读取的强更记录。
    func testDebugFakeResultsDoNotWriteReleaseRecord() {
        #if DEBUG
        XCTAssertNotEqual(AppUpdate.recordKey, AppNamespace.updateRecordKey, "Debug / Staging 用另一把键")
        XCTAssertTrue(AppUpdate.makeChecker() is DebugUpdateChecker)
        #else
        XCTAssertEqual(AppUpdate.recordKey, AppNamespace.updateRecordKey)
        #endif
        let update = AppUpdate.makeForBuild(defaults: defaults)
        update.gate.apply(result: UpdateFixtures.force, now: 1)
        XCTAssertNotNil(defaults.data(forKey: AppUpdate.recordKey))
        #if DEBUG
        XCTAssertNil(defaults.data(forKey: AppNamespace.updateRecordKey), "Release 读取的键里没有调试假结果")
        #endif
    }
}
