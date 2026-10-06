import Foundation
import Generated
import XCTest
@testable import Router

/// 评审第 1 轮 R1-04…R1-06 的回归测试：实名前置、Agent 来源的 pending_action、需同意时登记与恢复。
@MainActor
final class RouterPendingReviewFixTests: XCTestCase {
    private var guardState = GuardState(
        privacyState: .consented,
        updateState: .ok,
        sessionState: .loggedIn,
        environmentSettled: true,
        appVersion: "1.0.0",
        isDebugBuild: false
    )
    private var now: Int64 = 1_000_000

    private func makeRouter(backend: MemoryPendingBackend = MemoryPendingBackend()) -> Router {
        let store = PendingActionStore(backend: backend, clock: { [unowned self] in now })
        return Router(pendingStore: store, state: { [unowned self] in guardState })
    }

    private func stored(_ backend: MemoryPendingBackend) throws -> [String: Any] {
        let text = try XCTUnwrap(backend.read())
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }

    // R1-04
    func testRealnameRoutesRequireVerifiedRealname() {
        let backend = MemoryPendingBackend()
        guardState.session = .phoneBound
        let router = makeRouter(backend: backend)
        for route in ["Withdraw", "PayoutAccount", "LaborAgreement"] {
            let decision = EntryGuard.decide(request: RouteRequest(route: route, from: .inApp), state: guardState)
            XCTAssertEqual(
                decision,
                GuardDecision(kind: .requireRealname, route: "RealName", reason: GuardReason.realnameRequired),
                route
            )
        }
        router.open(RouteRequest(route: "Withdraw", from: .inApp))
        XCTAssertEqual(router.path.map(\.route), ["RealName"])
        XCTAssertNil(backend.read(), "Withdraw 不登记 pending_action")

        // 实名完成后不自动打开 Withdraw：回到发起页，由用户重新点击。
        guardState.realnameVerified = true
        router.path = []
        router.prerequisiteCompleted()
        XCTAssertTrue(router.path.isEmpty)
        router.open(RouteRequest(route: "Withdraw", from: .inApp))
        XCTAssertEqual(router.path.map(\.route), ["Withdraw"])
    }

    /// BR-ID-10 细则「不适用的动作」：四个需二次验证的操作及其前置步骤缺前置时只进前置页，不登记。
    func testSensitiveRoutesNeverRegisterPendingAction() {
        let cases: [PrerequisiteCase] = [
            PrerequisiteCase(route: "Withdraw", session: .guest, prerequisite: "Login"),
            PrerequisiteCase(route: "PayoutAccount", session: .loggedIn, prerequisite: "BindPhone"),
            PrerequisiteCase(route: "LaborAgreement", session: .phoneBound, prerequisite: "RealName"),
            PrerequisiteCase(route: "RealName", session: .loggedIn, prerequisite: "BindPhone"),
        ]
        for item in cases {
            let backend = MemoryPendingBackend()
            guardState.session = item.session
            let router = makeRouter(backend: backend)
            router.open(RouteRequest(route: item.route, from: .inApp))
            XCTAssertEqual(router.path.map(\.route), [item.prerequisite], item.route)
            XCTAssertNil(backend.read(), item.route)
        }
        // 基本模式下点这些页面要求同意，同样不登记。
        let backend = MemoryPendingBackend()
        guardState.privacy = .basicMode
        let router = makeRouter(backend: backend)
        router.open(RouteRequest(route: "Withdraw", from: .inApp))
        XCTAssertTrue(router.consentRequested)
        XCTAssertNil(backend.read())
        // 其余路由照旧登记。
        router.open(RouteRequest(route: "Wallet", from: .inApp))
        XCTAssertNotNil(backend.read())
    }

    func testRealnameRouteStillRequiresLoginAndPhoneFirst() {
        guardState.realnameVerified = true
        guardState.session = .loggedIn
        XCTAssertEqual(
            EntryGuard.decide(request: RouteRequest(route: "Withdraw", from: .inApp), state: guardState).kind,
            .requireBindPhone
        )
        guardState.session = .guest
        XCTAssertEqual(
            EntryGuard.decide(request: RouteRequest(route: "Withdraw", from: .inApp), state: guardState).kind,
            .requireLogin
        )
    }

    func testPushLookupOfRealnameRouteRequiresRealname() async {
        guardState.session = .phoneBound
        let landing = PushLanding { _ in .found(route: "PayoutAccount", params: [:]) }
        let result = await landing.land(messageId: "m1", state: guardState)
        XCTAssertEqual(result.decision.kind, .requireRealname)
    }

    // R1-05
    func testAgentPendingActionIsDeletedOnPrivacyBlockNotReplayed() throws {
        let backend = MemoryPendingBackend()
        guardState.session = .guest
        let router = makeRouter(backend: backend)
        router.open(RouteRequest(route: "Wallet", from: .agentCard))
        XCTAssertEqual(router.path.map(\.route), ["Login"])
        XCTAssertEqual(try stored(backend)["origin"] as? String, "agent_card")

        // 登录后隐私需要重新同意：恢复时遇隐私阻断，直接删除。
        guardState.session = .loggedIn
        guardState.privacy = .notDecided
        router.path = []
        router.prerequisiteCompleted()
        XCTAssertNil(backend.read(), "Agent 动作遇隐私阻断即删除")
        XCTAssertTrue(router.path.isEmpty)

        // 同意后也不自动打开 Wallet。
        guardState.privacy = .consented
        router.consentHandled()
        router.prerequisiteCompleted()
        XCTAssertTrue(router.path.isEmpty)
    }

    func testConsentHandledDeletesAgentPendingAction() {
        let backend = MemoryPendingBackend()
        guardState.session = .guest
        let router = makeRouter(backend: backend)
        router.open(RouteRequest(route: "Wallet", from: .agentCard))
        XCTAssertNotNil(backend.read())
        guardState.session = .loggedIn
        router.path = []
        router.consentHandled()
        XCTAssertNil(backend.read())
        XCTAssertTrue(router.path.isEmpty)
    }

    func testNonAgentPendingActionSurvivesPrivacyDefer() {
        let backend = MemoryPendingBackend()
        guardState.session = .guest
        let router = makeRouter(backend: backend)
        router.open(RouteRequest(route: "Wallet", from: .inApp))
        guardState.session = .loggedIn
        guardState.privacy = .notDecided
        router.path = []
        router.prerequisiteCompleted()
        XCTAssertNotNil(backend.read(), "普通动作等隐私结论，保留")
        guardState.privacy = .consented
        router.prerequisiteCompleted()
        XCTAssertEqual(router.path.map(\.route), ["Wallet"])
    }

    // R1-06
    func testConsentRequiredRemembersAndResumesAfterConsent() throws {
        let backend = MemoryPendingBackend()
        guardState.privacy = .basicMode
        guardState.session = .guest
        let router = makeRouter(backend: backend)
        router.open(RouteRequest(route: "InviteShare", from: .inApp))
        XCTAssertTrue(router.consentRequested)
        XCTAssertEqual(try stored(backend)["origin"] as? String, "in_app")

        // 同意后按前置继续：还是游客 → 登录。
        guardState.privacy = .consented
        router.consentHandled(granted: true)
        XCTAssertFalse(router.consentRequested)
        XCTAssertEqual(router.path.map(\.route), ["Login"])
        XCTAssertNotNil(backend.read())

        guardState.session = .phoneBound
        router.path = []
        router.prerequisiteCompleted()
        XCTAssertEqual(router.path.map(\.route), ["InviteShare"])
        XCTAssertNil(backend.read())
    }

    func testConsentGrantedOpensOriginalRouteWithParams() {
        guardState.privacy = .basicMode
        let router = makeRouter()
        router.open(RouteRequest(route: "OrderDetail", values: ["order_id": .string("o1")], from: .inApp))
        guardState.privacy = .consented
        router.consentHandled(granted: true)
        XCTAssertEqual(router.path.map(\.route), ["OrderDetail"])
        XCTAssertEqual(router.path.first?.params, ["order_id": .string("o1")])
    }

    func testConsentDeclinedDropsPendingAction() {
        let backend = MemoryPendingBackend()
        guardState.privacy = .basicMode
        let router = makeRouter(backend: backend)
        router.open(RouteRequest(route: "Wallet", from: .inApp))
        XCTAssertNotNil(backend.read())
        router.consentHandled(granted: false)
        XCTAssertNil(backend.read())
        XCTAssertTrue(router.path.isEmpty)
    }

    func testConsentRequiredDoesNotRememberInvalidParams() {
        let backend = MemoryPendingBackend()
        guardState.privacy = .basicMode
        let router = makeRouter(backend: backend)
        router.open(RouteRequest(route: "OrderDetail", values: ["order_id": .integer(1)], from: .inApp))
        XCTAssertTrue(router.consentRequested)
        XCTAssertNil(backend.read(), "不登记不合 schema 的参数")
    }

    func testOriginSurvivesMarkStepDone() throws {
        let backend = MemoryPendingBackend()
        let store = PendingActionStore(backend: backend, clock: { 0 })
        XCTAssertTrue(store.save(
            action: "open_route",
            values: ["route": .string("Wallet")],
            now: 0,
            origin: "agent_card"
        ))
        store.markStepDone(now: 1000)
        let pending = try XCTUnwrap(store.load(now: 1000))
        XCTAssertEqual(pending.origin, "agent_card")
        XCTAssertEqual(pending.timerStartedAt, 1000)
    }
}

private struct PrerequisiteCase {
    let route: String
    let session: SessionState
    let prerequisite: String
}
