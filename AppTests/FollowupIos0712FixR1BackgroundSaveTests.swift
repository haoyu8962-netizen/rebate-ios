@testable import Couli
import Foundation
import Router
import XCTest

/// FU-IOS-0712 第 1 轮修复 R1-05：进后台的「保存完成」信号只在恢复内容与后台标记已显式提交并核对之后发；提交失败 / 没完成、读回与刚写的
/// 不一致都不发（UI 测试等不到信号就在上限内失败，不会提前结束进程）。启动参数「挂住提交」让提交永不完成。
@MainActor
final class FollowupIos0712FixR1BackgroundSaveTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        suiteName = "FollowupIos0712FixR1BackgroundSaveTests.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        DebugUITestSignals.poster = Self.realPoster
    }

    private static let realPoster = DebugUITestSignals.poster

    private func router() -> Router {
        let state = GuardState(
            privacyState: .consented, updateState: .ok, sessionState: .guest, environmentSettled: true,
            appVersion: AppWeb.appVersion, isDebugBuild: true
        )
        return Router(pendingStore: PendingActionStore(backend: MemoryPendingBackend())) { state }
    }

    /// 搜索页在栈里、页面状态已交出、启动协调已完成（之后的保存才写盘）。
    private func restoration(_ defaults: UserDefaults) async throws -> SearchRouteRestoration {
        let router = router()
        let restoration = SearchRouteRestoration(router: router, defaults: defaults)
        restoration.replay(Data())
        router.path = [RouteDestination(route: "Search", params: ["q": .string("milk")])]
        for _ in 0..<200 where router.path.isEmpty {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        let id = try XCTUnwrap(router.path.first?.id)
        restoration.save(Data("page-state".utf8), for: id)
        XCTAssertFalse(restoration.encoded.isEmpty, "前提：有要保存的恢复内容")
        return restoration
    }

    private func countingSignals() -> () -> Int {
        var posted: [String] = []
        DebugUITestSignals.poster = { posted.append($0) }
        return { posted.filter { $0 == DebugUITestSignals.backgroundSaved }.count }
    }

    func testSignalOnlyAfterRestorationAndBackgroundFlagAreCommittedAndVerified() async throws {
        let signals = countingSignals()
        let restoration = try await restoration(defaults)
        var commits = 0
        restoration.commit = { defaults in
            commits += 1
            return defaults.synchronize()
        }
        let committed = restoration.sceneEnteredBackground()
        XCTAssertTrue(committed, "提交成功且读回一致")
        XCTAssertEqual(commits, 1, "显式提交了一次")
        XCTAssertTrue(defaults.bool(forKey: SearchRouteRestoration.backgroundKey))
        XCTAssertEqual(defaults.data(forKey: SearchRouteRestoration.dataKey), restoration.encoded)
        DebugUITestSignals.backgroundSaveFinished(committed: committed)
        XCTAssertEqual(signals(), 1, "确认落盘之后才发信号")
    }

    /// 提交没完成（挂住 / 失败）：不发信号。
    func testUncommittedSaveSendsNoSignal() async throws {
        let signals = countingSignals()
        let restoration = try await restoration(defaults)
        restoration.commit = { _ in false }
        let committed = restoration.sceneEnteredBackground()
        XCTAssertFalse(committed)
        DebugUITestSignals.backgroundSaveFinished(committed: committed)
        XCTAssertEqual(signals(), 0, "没提交完不发信号")
    }

    /// 提交返回成功但读回与刚写的不一致（后台标记或恢复内容没写进）：不算保存完成。
    func testReadBackMismatchIsNotCommitted() async throws {
        for dropped in [SearchRouteRestoration.backgroundKey, SearchRouteRestoration.dataKey] {
            let suite = suiteName + "-" + dropped
            let lossy = try XCTUnwrap(DroppingDefaults(suiteName: suite))
            defer { lossy.removePersistentDomain(forName: suite) }
            lossy.dropped = [dropped]
            let restoration = try await restoration(lossy)
            XCTAssertFalse(restoration.sceneEnteredBackground(), "\(dropped) 没写进：不算保存完成")
        }
    }

    /// 启动参数「挂住提交」：提交永不完成，信号不发；没带参数时不改提交。
    func testHoldArgumentMakesTheCommitNeverComplete() async throws {
        let signals = countingSignals()
        let held = try await restoration(defaults)
        DebugUITestSignals.installHold(on: held, arguments: ["Couli", DebugUITestSignals.holdCommitArgument])
        let committed = held.sceneEnteredBackground()
        XCTAssertFalse(committed)
        DebugUITestSignals.backgroundSaveFinished(committed: committed)
        XCTAssertEqual(signals(), 0)
        let normal = try await restoration(defaults)
        DebugUITestSignals.installHold(on: normal, arguments: ["Couli"])
        XCTAssertTrue(normal.sceneEnteredBackground(), "没带参数：照常提交")
    }
}

/// 丢掉指定键写入的 UserDefaults（模拟写入没生效）。
private final class DroppingDefaults: UserDefaults, @unchecked Sendable {
    var dropped: Set<String> = []

    override func set(_ value: Bool, forKey defaultName: String) {
        guard !dropped.contains(defaultName) else { return }
        super.set(value, forKey: defaultName)
    }

    override func set(_ value: Any?, forKey defaultName: String) {
        guard !dropped.contains(defaultName) else { return }
        super.set(value, forKey: defaultName)
    }
}
