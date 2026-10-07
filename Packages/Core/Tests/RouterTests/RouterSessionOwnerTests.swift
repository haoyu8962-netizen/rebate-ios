import Foundation
import Generated
import XCTest
@testable import Router

/// 登出收尾的 Router 清理归属（APP-05a 共性 23、25；ios-review-r2 R2-03）：`sessionEnded(throughSession:)` 只清登记 /
/// 发起时会话标签不大于给定世代的 pending_action 与推送回查，原会话被清之后新建的不动。
@MainActor
final class RouterSessionOwnerTests: XCTestCase {
    private var guardState = GuardState(
        privacyState: .consented, updateState: .ok, sessionState: .guest, environmentSettled: true,
        appVersion: "1.0.0", isDebugBuild: false
    )
    private var tag: UInt64 = 5
    private let ready = LaunchReadiness(environmentSettled: true, privacy: .consented, update: .finished(.ok))

    private func makeRouter(_ backend: MemoryPendingBackend) -> Router {
        let router = Router(pendingStore: PendingActionStore(backend: backend)) { [unowned self] in guardState }
        router.sessionTag = { [unowned self] in tag }
        return router
    }

    /// 原会话（标签 5）期间登记的待办：登出收尾（throughSession 5）删除。
    func testPendingOfEndedSessionIsCleared() {
        let backend = MemoryPendingBackend()
        let router = makeRouter(backend)
        router.open(RouteRequest(route: "OrderList", from: .inApp))
        XCTAssertTrue(router.hasPendingAction)
        router.sessionEnded(throughSession: 5)
        XCTAssertFalse(router.hasPendingAction)
    }

    /// 原会话被清之后（标签 6）新建的待办：旧会话的登出收尾（throughSession 5）保留。
    func testPendingCreatedAfterSessionEndedIsKept() {
        let backend = MemoryPendingBackend()
        let router = makeRouter(backend)
        tag = 6
        router.open(RouteRequest(route: "OrderList", from: .inApp))
        router.sessionEnded(throughSession: 5)
        XCTAssertTrue(router.hasPendingAction, "新待办保留")
        router.sessionEnded(throughSession: 6)
        XCTAssertFalse(router.hasPendingAction)
    }

    /// 归属未知（不是本进程经守卫登记的，例如进程重启前留下的）按旧会话处理：删除。
    func testUntaggedPendingIsCleared() {
        let backend = MemoryPendingBackend()
        let store = PendingActionStore(backend: backend)
        XCTAssertTrue(store.save(action: Router.openRouteAction, values: ["route": .string("OrderList")],
                                 now: store.now))
        let router = makeRouter(backend)
        tag = 9
        router.sessionEnded(throughSession: 5)
        XCTAssertFalse(router.hasPendingAction)
    }

    /// 推送回查：原会话（标签 5）期间发起的结果在登出收尾之后返回 → 丢弃；原会话被清之后（标签 6）、登出收尾之前发起的
    /// → 照常落地（不像整体换代那样一并作废）。
    func testPushLookupOwnership() async throws {
        guardState.session = .phoneBound
        let router = makeRouter(MemoryPendingBackend())
        let oldGate = OwnerLookupGate()
        let newGate = OwnerLookupGate()
        router.enqueueLaunch(.push(messageId: "m1"))
        let old = try XCTUnwrap(router.drainLaunchQueue(
            readiness: ready, now: 1, pushLanding: PushLanding(timeout: .seconds(30)) { _ in await oldGate.wait() }
        ))
        while await !oldGate.started {
            await Task.yield()
        }
        tag = 6
        router.enqueueLaunch(.push(messageId: "m2"))
        let fresh = try XCTUnwrap(router.drainLaunchQueue(
            readiness: ready, now: 2, pushLanding: PushLanding(timeout: .seconds(30)) { _ in await newGate.wait() }
        ))
        while await !newGate.started {
            await Task.yield()
        }

        router.sessionEnded(throughSession: 5)
        await oldGate.open(with: .found(route: "Wallet", params: [:]))
        await old.value
        XCTAssertTrue(router.path.isEmpty, "原会话的回查结果作废")
        await newGate.open(with: .found(route: "Messages", params: [:]))
        await fresh.value
        XCTAssertEqual(router.path.map(\.route), ["Messages"], "原会话结束之后发起的回查照常")
    }
}

/// 可由测试放行的回查门。
private actor OwnerLookupGate {
    private var result: PushLookupResult?
    private var waiters: [CheckedContinuation<PushLookupResult, Never>] = []
    private(set) var started = false

    func wait() async -> PushLookupResult {
        started = true
        if let result {
            return result
        }
        return await withCheckedContinuation { waiters.append($0) }
    }

    func open(with outcome: PushLookupResult) {
        result = outcome
        waiters.forEach { $0.resume(returning: outcome) }
        waiters = []
    }
}
