import Config
import Foundation
import XCTest
@testable import Update

/// UpdateGate 向量之外的实现约定（APP-02c）：10405 的例外、非法版本、复查期间保留已知结论、持久化、选店的边界。
final class UpdateGateBehaviorTests: XCTestCase {
    private func gate(
        store: MemoryUpdateStore = MemoryUpdateStore(),
        appVersion: String = "1.0.0",
        installSource: String? = nil
    ) -> UpdateGate {
        UpdateGate(store: store, clock: { 0 }, appVersion: appVersion, platform: "ios", channel: "appstore",
                   installSource: installSource)
    }

    private let ok = UpdateCheckResult(
        minSupported: "1.0.0", recommended: "1.0.0", latest: "1.2.0", defaultStore: "a",
        stores: [UpdateStoreListing(store: "a", version: "1.2.0")]
    )

    func test10405WithoutMinimumOrNotLowerIsIgnored() {
        let subject = gate()
        subject.apply(result: ok, now: 1)
        subject.on10405(minSupported: nil, now: 2)
        XCTAssertEqual(subject.state(now: 2).status, .ok, "空 min：旧受限令牌，先刷新，不进强更（rule-gaps G07）")
        subject.on10405(minSupported: "1.0.0", now: 3)
        XCTAssertEqual(subject.state(now: 3).status, .ok, "本机不低于 min：不进强更")
        subject.on10405(minSupported: "x.y", now: 4)
        XCTAssertEqual(subject.state(now: 4).status, .ok, "解析不了：不进强更")
        subject.on10405(minSupported: "1.1.0", now: 5)
        XCTAssertEqual(subject.state(now: 5), UpdateState(status: .belowMin, targetVersion: "1.1.0"))
    }

    func test10405IsPersistedUntilNextSuccessfulCheck() {
        let store = MemoryUpdateStore()
        gate(store: store).on10405(minSupported: "2.0.0", now: 1)
        let rebuilt = gate(store: store)
        XCTAssertEqual(rebuilt.state(now: 2).status, .belowMin, "重建后仍直接强更")
        rebuilt.onColdStart(now: 3)
        XCTAssertEqual(rebuilt.state(now: 3).status, .belowMin, "冷启动检查期间仍是强更")
        rebuilt.apply(result: ok, now: 4)
        XCTAssertEqual(rebuilt.state(now: 4).status, .ok, "成功检查覆盖 10405")
    }

    func testInvalidVersionsAreUnknown() {
        let badApp = gate(appVersion: "1.0.0-beta")
        badApp.apply(result: ok, now: 1)
        XCTAssertEqual(badApp.state(now: 1).status, .unknown)

        let badResult = gate()
        badResult.apply(
            result: UpdateCheckResult(minSupported: "v2", recommended: nil, latest: nil, defaultStore: nil, stores: []),
            now: 1
        )
        XCTAssertEqual(badResult.state(now: 1).status, .unknown)
        XCTAssertNil(UpdateGate.compareVersions(a: "1..0", b: "1.0"))
        XCTAssertNil(UpdateGate.compareVersions(a: "", b: "1.0"))
        XCTAssertNil(UpdateGate.compareVersions(a: "1.0", b: "1.٣"), "只认 ASCII 数字")
    }

    func testForegroundRecheckKeepsKnownConclusion() {
        let subject = gate()
        subject.apply(result: ok, now: 0)
        XCTAssertTrue(subject.onForeground(now: 1_800_001))
        XCTAssertTrue(subject.isChecking)
        XCTAssertEqual(subject.state(now: 1_800_001).status, .ok, "回前台复查期间保留已知结论，不拦用户")
        subject.applyFailure(now: 1_800_002)
        XCTAssertFalse(subject.isChecking)
        XCTAssertEqual(subject.state(now: 1_800_002).status, .ok)
        XCTAssertTrue(subject.onForeground(now: 1_800_003), "失败不重置计时：下次回前台再试")
    }

    func testRecheckIntervalComesFromResult() {
        let subject = gate()
        let short = UpdateCheckResult(minSupported: nil, recommended: nil, latest: nil, defaultStore: nil, stores: [],
                                      recheckIntervalSec: 60)
        subject.apply(result: short, now: 0)
        XCTAssertFalse(subject.onForeground(now: 60000))
        XCTAssertTrue(subject.onForeground(now: 60001))
    }

    func testPromptRequiresDefaultStoreListingWhenSourceUnknown() {
        let subject = gate()
        subject.apply(
            result: UpdateCheckResult(
                minSupported: nil, recommended: "1.1.0", latest: "1.2.0", defaultStore: "a",
                stores: [UpdateStoreListing(store: "b", version: "1.2.0")]
            ),
            now: 0
        )
        let state = subject.state(now: 0)
        XCTAssertEqual(state.status, .belowRecommended)
        XCTAssertFalse(state.showPrompt, "默认商店没有已知上架版本：不弹")
    }

    func testPickStoreWhenNotNeeded() {
        let subject = gate()
        subject.apply(result: ok, now: 0)
        var asked = false
        let choice = subject.pickStore(result: ok, now: 0) { _ in
            asked = true
            return true
        }
        XCTAssertEqual(choice, StoreChoice(storeKey: nil, unavailable: true))
        XCTAssertFalse(asked, "不需要更新时不查能力")
    }

    func testPickStoreChecksVersionBeforeCapability() {
        let subject = gate()
        let result = UpdateCheckResult(
            minSupported: "1.1.0", recommended: nil, latest: "1.1.0", defaultStore: "a",
            stores: [UpdateStoreListing(store: "a", version: "1.0.5"), UpdateStoreListing(store: "b", version: "1.1.0")]
        )
        subject.apply(result: result, now: 0)
        var asked: [String] = []
        let choice = subject.pickStore(result: result, now: 0) { key in
            asked.append(key)
            return false
        }
        XCTAssertEqual(asked, ["b"], "版本不够的不问能力")
        XCTAssertTrue(choice.unavailable)
    }

    func testDismissInBelowMinIsIgnoredAndRecordedOtherwise() {
        let store = MemoryUpdateStore()
        let subject = gate(store: store)
        subject.apply(
            result: UpdateCheckResult(
                minSupported: nil, recommended: "1.1.0", latest: "1.2.0", defaultStore: "a",
                stores: [UpdateStoreListing(store: "a", version: "1.2.0")]
            ),
            now: 0
        )
        subject.dismissPrompt(now: 1)
        XCTAssertEqual(store.record.dismissedLatest, "1.2.0")
    }

    func testUserDefaultsStoreRoundTripAndCorruptData() throws {
        let suite = "UpdateGateBehaviorTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = UserDefaultsUpdateStore(defaults: defaults)
        XCTAssertEqual(store.load(), UpdateRecord())
        let record = UpdateRecord(lastResult: ok, lastSuccessAt: 5, dismissedLatest: "1.2.0", forcedMinimum: "1.1.0")
        store.save(record)
        XCTAssertEqual(UserDefaultsUpdateStore(defaults: defaults).load(), record)
        XCTAssertTrue(AppNamespace.updateRecordKey.hasPrefix(AppNamespace.userDefaultsPrefix), "切换环境随命名空间清理")

        defaults.set(Data("not json".utf8), forKey: AppNamespace.updateRecordKey)
        XCTAssertEqual(store.load(), UpdateRecord(), "解码失败按空记录（未知），不当作不低于")
    }

    // MARK: - 编排者裁定 G15：持久化 below_min 跨本机版本升级

    private let forceResult = UpdateCheckResult(
        minSupported: "1.1.0", recommended: "1.1.0", latest: "1.2.0", defaultStore: "a",
        stores: [UpdateStoreListing(store: "a", version: "1.2.0")]
    )

    func testPersistedBelowMinIsRecomparedAfterUpgradeToMinimum() {
        let store = MemoryUpdateStore()
        gate(store: store, appVersion: "1.0.0").apply(result: forceResult, now: 1)
        XCTAssertEqual(gate(store: store, appVersion: "1.0.0").state(now: 2).status, .belowMin, "同版本仍强更")

        let upgraded = gate(store: store, appVersion: "1.1.0")
        XCTAssertEqual(upgraded.state(now: 3).status, .unknown, "升级到等于缓存 min：不再强更，结论未知")
        XCTAssertTrue(upgraded.onColdStart(now: 3))
        XCTAssertEqual(upgraded.state(now: 3).status, .checking, "冷启动检查中，不是强更")
        upgraded.applyFailure(now: 4)
        XCTAssertEqual(upgraded.state(now: 4), UpdateState(status: .unknown), "本次失败按 unknown，不恢复旧强更也不当 ok")
    }

    func testPersistedBelowMinAfterUpgradeAboveMinimumIsUnknown() {
        let store = MemoryUpdateStore()
        gate(store: store, appVersion: "1.0.0").apply(result: forceResult, now: 1)
        let upgraded = gate(store: store, appVersion: "1.3.0")
        upgraded.onColdStart(now: 2)
        upgraded.applyFailure(now: 3)
        XCTAssertEqual(upgraded.state(now: 3).status, .unknown)
    }

    func testPersistedBelowMinAfterUpgradeStillLowerStaysBelowMin() {
        let store = MemoryUpdateStore()
        gate(store: store, appVersion: "1.0.0").apply(result: forceResult, now: 1)
        let upgraded = gate(store: store, appVersion: "1.0.5")
        upgraded.onColdStart(now: 2)
        XCTAssertEqual(upgraded.state(now: 2), UpdateState(status: .belowMin, targetVersion: "1.1.0"))
        upgraded.applyFailure(now: 3)
        XCTAssertEqual(upgraded.state(now: 3), UpdateState(status: .belowMin, targetVersion: "1.1.0"), "升级后仍低于：照旧强更")
    }

    func testPersisted10405IsRecomparedAfterUpgrade() {
        let store = MemoryUpdateStore()
        gate(store: store, appVersion: "1.0.0").on10405(minSupported: "1.1.0", now: 1)
        XCTAssertEqual(gate(store: store, appVersion: "1.0.0").state(now: 2).status, .belowMin, "同版本 10405 仍强更")

        let stillLow = gate(store: store, appVersion: "1.0.9")
        stillLow.onColdStart(now: 3)
        stillLow.applyFailure(now: 4)
        XCTAssertEqual(stillLow.state(now: 4), UpdateState(status: .belowMin, targetVersion: "1.1.0"))

        for version in ["1.1.0", "2.0.0"] {
            let upgraded = gate(store: store, appVersion: version)
            upgraded.onColdStart(now: 5)
            XCTAssertEqual(upgraded.state(now: 5).status, .checking, "\(version)：10405 的 min 已不高于本机")
            upgraded.applyFailure(now: 6)
            XCTAssertEqual(upgraded.state(now: 6).status, .unknown, "\(version)：失败按 unknown")
        }
    }

    func testColdStartFailureKeepsDismissalButNotCachedConclusion() {
        let store = MemoryUpdateStore()
        let first = gate(store: store, installSource: "a")
        first.apply(
            result: UpdateCheckResult(
                minSupported: nil, recommended: "1.1.0", latest: "1.2.0", defaultStore: "a",
                stores: [UpdateStoreListing(store: "a", version: "1.2.0")]
            ),
            now: 0
        )
        first.dismissPrompt(now: 1)
        let rebuilt = gate(store: store, installSource: "a")
        rebuilt.onColdStart(now: 2)
        rebuilt.applyFailure(now: 3)
        XCTAssertEqual(rebuilt.state(now: 3), UpdateState(status: .unknown))
        XCTAssertEqual(store.record.dismissedLatest, "1.2.0", "「暂不更新」记录不失效")
        XCTAssertTrue(rebuilt.onForeground(now: 4), "失败后下次回前台再试，不论间隔")
    }

    func testFailingCheckerAlwaysFails() async {
        let outcome = await MainActor.run { () -> UpdateCheckOutcome? in
            var received: UpdateCheckOutcome?
            FailingUpdateChecker().check { received = $0 }
            return received
        }
        XCTAssertEqual(outcome, .failure)
    }
}
