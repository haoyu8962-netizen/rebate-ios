import Foundation
import Generated
import XCTest
@testable import Router

/// 三端统一要求：强更等待起算、Agent 记录、pending_action 参数与不登记的动作。
@MainActor
final class RouterUnifiedRequirementTests: XCTestCase {
    private var guardState = GuardState(
        privacyState: .consented,
        updateState: .ok,
        sessionState: .guest,
        environmentSettled: true,
        appVersion: "1.0.0",
        isDebugBuild: false
    )
    private var now: Int64 = 1_000_000

    private func makeRouter(backend: MemoryPendingBackend) -> Router {
        let store = PendingActionStore(backend: backend, clock: { [unowned self] in now })
        return Router(pendingStore: store, state: { [unowned self] in guardState })
    }

    // MARK: 强更 5 秒从闸门通过后起算

    func testUpdateWaitStartsAfterGatesOpen() {
        var queue = LaunchQueue()
        queue.enqueue(.route(RouteRequest(route: "Search", from: .deeplink)))
        let checking = UpdateCheckStatus.checking(startedAt: 0)
        let envPending = LaunchReadiness(environmentSettled: false, privacy: .consented, update: checking)
        XCTAssertNil(queue.release(readiness: envPending, now: 6000), "环境未就绪：即使检查已过 6 秒也不放行")
        XCTAssertNil(queue.nextRetryAt(readiness: envPending), "闸门未就绪：不计时、不空转")
        XCTAssertNil(queue.gatesOpenedAt)

        let privacyPending = LaunchReadiness(environmentSettled: true, privacy: .notDecided, update: checking)
        XCTAssertNil(queue.release(readiness: privacyPending, now: 7000))
        XCTAssertNil(queue.nextRetryAt(readiness: privacyPending))

        let open = LaunchReadiness(environmentSettled: true, privacy: .consented, update: checking)
        XCTAssertNil(queue.release(readiness: open, now: 8000), "闸门 8000 通过，从此起算")
        XCTAssertEqual(queue.gatesOpenedAt, 8000)
        XCTAssertEqual(queue.nextRetryAt(readiness: open), 13000)
        XCTAssertNil(queue.release(readiness: open, now: 12999))
        let released = queue.release(readiness: open, now: 13000)
        XCTAssertEqual(released?.update, .unknown)
        XCTAssertNil(queue.nextRetryAt(readiness: open), "放行后不再计时")
    }

    func testGatesClosingResetsWaitStart() {
        var queue = LaunchQueue()
        queue.enqueue(.push(messageId: "m1"))
        let checking = UpdateCheckStatus.checking(startedAt: 0)
        let open = LaunchReadiness(environmentSettled: true, privacy: .consented, update: checking)
        _ = queue.release(readiness: open, now: 1000)
        _ = queue.release(
            readiness: LaunchReadiness(environmentSettled: false, privacy: .consented, update: checking),
            now: 3000
        )
        XCTAssertNil(queue.release(readiness: open, now: 6000), "闸门重新通过（6000）后重新起算")
        XCTAssertEqual(queue.release(readiness: open, now: 11000)?.update, .unknown)
    }

    func testRouterExposesRetryOnlyWhenGatesOpen() {
        let router = makeRouter(backend: MemoryPendingBackend())
        router.enqueueLaunch(.route(RouteRequest(route: "Search", from: .deeplink)))
        let closed = LaunchReadiness(environmentSettled: true, privacy: .notDecided, update: .checking(startedAt: 0))
        router.drainLaunchQueue(readiness: closed, now: 100)
        XCTAssertNil(router.launchRetryAt(readiness: closed))
        let open = LaunchReadiness(environmentSettled: true, privacy: .consented, update: .checking(startedAt: 0))
        router.drainLaunchQueue(readiness: open, now: 200)
        XCTAssertEqual(router.launchRetryAt(readiness: open), 5200)
        router.drainLaunchQueue(readiness: open, now: 5200)
        XCTAssertEqual(router.path.map(\.route), ["Search"])
    }

    // MARK: Agent 卡片记录遇隐私阻断即删

    private func registerAgentRecord(_ router: Router, _ backend: MemoryPendingBackend) {
        guardState.privacy = .consented
        guardState.session = .guest
        router.open(RouteRequest(route: "Wallet", from: .agentCard))
        XCTAssertNotNil(backend.read())
    }

    func testAgentRecordDeletedWhenPrivacyChanges() {
        for privacy in [PrivacyState.basicMode, .notDecided] {
            let backend = MemoryPendingBackend()
            let router = makeRouter(backend: backend)
            registerAgentRecord(router, backend)
            guardState.privacy = privacy
            router.privacyChanged()
            XCTAssertNil(backend.read(), "\(privacy)：遇隐私阻断即删")
        }
    }

    func testAgentRecordDeletedOnAnyOpenUnderPrivacyBlock() {
        let backend = MemoryPendingBackend()
        let router = makeRouter(backend: backend)
        registerAgentRecord(router, backend)
        guardState.privacy = .basicMode
        router.open(RouteRequest(route: "Search", from: .inApp))
        XCTAssertNil(backend.read())
    }

    func testAgentRecordDeletedOnDrainUnderBasicMode() {
        let backend = MemoryPendingBackend()
        let router = makeRouter(backend: backend)
        registerAgentRecord(router, backend)
        guardState.privacy = .basicMode
        router.enqueueLaunch(.route(RouteRequest(route: "Search", from: .deeplink)))
        router.drainLaunchQueue(
            readiness: LaunchReadiness(environmentSettled: true, privacy: .basicMode, update: .finished(.ok)),
            now: now
        )
        XCTAssertNil(backend.read())
    }

    func testNonAgentRecordSurvivesPrivacyChange() {
        let backend = MemoryPendingBackend()
        let router = makeRouter(backend: backend)
        router.open(RouteRequest(route: "Wallet", from: .inApp))
        XCTAssertNotNil(backend.read())
        guardState.privacy = .basicMode
        router.privacyChanged()
        XCTAssertNotNil(backend.read(), "普通记录不受影响（按 R1-06 同意后恢复）")
    }

    // MARK: pending_action 只存清洗且通过 schema 的参数

    func testOnlySchemaValidSanitizedParamsAreStored() throws {
        let backend = MemoryPendingBackend()
        let router = makeRouter(backend: backend)
        router.open(RouteRequest(route: "OrderDetail", values: ["order_id": .integer(1)], from: .inApp))
        XCTAssertNil(backend.read(), "schema 不符：不登记")
        router.open(RouteRequest(
            route: "OrderDetail",
            values: ["order_id": .string("o1"), "access_token": .string("t")],
            from: .inApp
        ))
        XCTAssertNil(backend.read(), "多余或敏感键：不登记")
        router.open(RouteRequest(route: "OrderDetail", values: ["order_id": .string("o1")], from: .push))
        let text = try XCTUnwrap(backend.read())
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        let params = try XCTUnwrap(object["params"] as? [String: Any])
        XCTAssertEqual(params["route"] as? String, "OrderDetail")
        XCTAssertEqual(params["params"] as? [String: String], ["order_id": "o1"])
    }

    func testAgentCardRecordHasNoParams() throws {
        let backend = MemoryPendingBackend()
        let router = makeRouter(backend: backend)
        router.open(RouteRequest(route: "Wallet", from: .agentCard))
        let text = try XCTUnwrap(backend.read())
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        let params = try XCTUnwrap(object["params"] as? [String: Any])
        XCTAssertNil(params["params"])
    }

    // MARK: 五个敏感动作不登记

    func testSensitiveRoutesNeverRegisterPendingAction() {
        let routes = ["Withdraw", "PayoutAccount", "LaborAgreement", "RealName", "DeleteAccount"]
        let states: [(SessionState, PrivacyState)] = [
            (.guest, .consented), (.restricted, .consented), (.loggedIn, .consented),
            (.phoneBound, .consented), (.guest, .basicMode),
        ]
        for route in routes {
            for (session, privacy) in states {
                for source in [RouteSource.inApp, .push, .bridge, .deeplink, .agentCard] {
                    let backend = MemoryPendingBackend()
                    guardState.session = session
                    guardState.privacy = privacy
                    guardState.realnameVerified = false
                    let router = makeRouter(backend: backend)
                    router.open(RouteRequest(route: route, values: ["amount": .integer(1)], from: source))
                    XCTAssertNil(backend.read(), "\(route) \(session) \(privacy) \(source)")
                }
            }
        }
    }
}
