import Foundation
import Generated
import XCTest
@testable import Router

/// 评审第 1 轮（ios-review-r1.md R1-01…R1-06）的回归测试。

/// 可由测试放行的回查门：回查函数挂在 `wait()` 上，直到测试调 `open(with:)`。
private actor LookupGate {
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

@MainActor
final class RouterPushGuardReviewFixTests: XCTestCase {
    private var guardState = GuardState(
        privacyState: .consented,
        updateState: .ok,
        sessionState: .loggedIn,
        environmentSettled: true,
        appVersion: "1.0.0",
        isDebugBuild: false
    )
    private var now: Int64 = 1_000_000
    private let ready = LaunchReadiness(environmentSettled: true, privacy: .consented, update: .finished(.ok))

    private func makeRouter(backend: MemoryPendingBackend = MemoryPendingBackend()) -> Router {
        let store = PendingActionStore(backend: backend, clock: { [unowned self] in now })
        return Router(pendingStore: store, state: { [unowned self] in guardState })
    }

    private func stored(_ backend: MemoryPendingBackend) throws -> [String: Any] {
        let text = try XCTUnwrap(backend.read())
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }

    /// 让推送回查挂起，期间执行 `during`，然后放行回查并等任务结束。
    private func pushWithSuspendedLookup(
        _ router: Router,
        outcome: PushLookupResult,
        during: () -> Void
    ) async throws {
        let gate = LookupGate()
        let landing = PushLanding(timeout: .seconds(30)) { _ in await gate.wait() }
        router.enqueueLaunch(.push(messageId: "m1"))
        let task = try XCTUnwrap(router.drainLaunchQueue(readiness: ready, now: now, pushLanding: landing))
        while await !gate.started {
            await Task.yield()
        }
        during()
        await gate.open(with: outcome)
        await task.value
    }

    // R1-01
    func testLogoutDuringPushLookupDoesNotOpenWithdrawRecords() async throws {
        let backend = MemoryPendingBackend()
        let router = makeRouter(backend: backend)
        try await pushWithSuspendedLookup(
            router,
            outcome: .found(route: "WithdrawRecords", params: ["withdrawal_id": .string("w1")])
        ) {
            guardState.session = .guest
            router.sessionEnded()
        }
        XCTAssertTrue(router.path.isEmpty, "退出登录后旧回查结果作废")
        XCTAssertNil(backend.read(), "不为新会话登记旧账号的 WithdrawRecords")
    }

    func testControlLookupWithoutStateChangeOpensWithdrawRecords() async throws {
        let router = makeRouter()
        try await pushWithSuspendedLookup(
            router,
            outcome: .found(route: "WithdrawRecords", params: ["withdrawal_id": .string("w1")])
        ) {}
        XCTAssertEqual(router.path.map(\.route), ["WithdrawRecords"])
        XCTAssertEqual(router.path.first?.params, ["withdrawal_id": .string("w1")])
    }

    func testForceUpdateDuringPushLookupWins() async throws {
        let router = makeRouter()
        try await pushWithSuspendedLookup(
            router,
            outcome: .found(route: "WithdrawRecords", params: [:])
        ) {
            guardState.update = .belowMin
        }
        XCTAssertEqual(router.path.map(\.route), ["ForceUpdate"])
    }

    func testEnvironmentChangeDuringPushLookupDiscardsResult() async throws {
        let router = makeRouter()
        try await pushWithSuspendedLookup(router, outcome: .found(route: "Wallet", params: [:])) {
            router.environmentChanged()
        }
        XCTAssertTrue(router.path.isEmpty)
    }

    func testEnvironmentUnsettledDuringPushLookupRequeuesPush() async throws {
        let router = makeRouter()
        try await pushWithSuspendedLookup(router, outcome: .found(route: "Wallet", params: [:])) {
            guardState.environmentSettled = false
        }
        XCTAssertTrue(router.path.isEmpty)
        XCTAssertTrue(router.hasPendingLaunchIntent, "环境未就绪：推送重新排队，条件满足后再回查")
    }

    func testApplyPushRedecidesWithCurrentState() {
        let router = makeRouter()
        let stale = PushLandingResult(
            decision: GuardDecision(kind: .open, route: "WithdrawRecords", reason: GuardReason.allowed),
            request: RouteRequest(route: "WithdrawRecords", values: ["withdrawal_id": .string("w1")], from: .push),
            afterLogin: nil
        )
        guardState.update = .belowMin
        router.applyPush(stale, issuedAt: router.currentGeneration)
        XCTAssertEqual(router.path.map(\.route), ["ForceUpdate"])
    }

    // R1-02
    func testExternalPageAndWebPageRequireAllowlist() {
        let external = RouteRequest(
            route: "ExternalPage",
            values: ["url": .string("https://evil.example/x")],
            from: .deeplink
        )
        let web = RouteRequest(route: "WebPage", values: ["url": .string("https://evil.example/x")], from: .bridge)
        for request in [external, web] {
            let decision = EntryGuard.decide(request: request, state: guardState)
            XCTAssertEqual(decision, GuardDecision(kind: .reject, route: nil, reason: GuardReason.targetNotAllowed))
        }

        var allowed = guardState
        allowed.targets = RouteTargetAllowlist(
            externalHosts: ["shop.example.com"],
            bridgeOrigins: ["https://h5.example.com"]
        )
        let cases: [TargetCase] = [
            TargetCase(route: "ExternalPage", url: "https://shop.example.com/a?b=1", opens: true),
            TargetCase(route: "ExternalPage", url: "https://SHOP.example.com/a", opens: true),
            TargetCase(route: "ExternalPage", url: "https://evil.shop.example.com/a", opens: false),
            TargetCase(route: "ExternalPage", url: "https://shop.example.com.evil.example/a", opens: false),
            TargetCase(route: "ExternalPage", url: "https://user@shop.example.com/a", opens: false),
            TargetCase(route: "ExternalPage", url: "https://shop.example.com:8443/a", opens: false),
            TargetCase(route: "WebPage", url: "https://h5.example.com/page", opens: true),
            TargetCase(route: "WebPage", url: "https://h5.example.com:443/page", opens: true),
            TargetCase(route: "WebPage", url: "https://h5.example.com:8443/page", opens: false),
            TargetCase(route: "WebPage", url: "https://other.example.com/page", opens: false),
            TargetCase(route: "WebPage", url: "https://shop.example.com/page", opens: false),
        ]
        for item in cases {
            let decision = EntryGuard.decide(
                request: RouteRequest(route: item.route, values: ["url": .string(item.url)], from: .inApp),
                state: allowed
            )
            XCTAssertEqual(decision.kind == .open, item.opens, "\(item.route) \(item.url) → \(decision)")
        }
    }

    // R1-03
    func testParamsSchemaIsCheckedForEverySource() {
        let invalid: [(String, [String: JSONValue])] = [
            ("Search", ["q": .integer(123)]),
            ("Search", ["q": .string(String(repeating: "a", count: 101))]),
            ("Search", ["platform": .string("nope")]),
            ("Search", ["extra": .string("x")]),
            ("OrderDetail", [:]),
            ("OrderDetail", ["order_id": .string("")]),
            ("ExternalPage", ["url": .string("http://shop.example.com")]),
        ]
        for source in [RouteSource.inApp, .bridge, .push, .pendingAction] {
            for (route, params) in invalid {
                let decision = EntryGuard.decide(
                    request: RouteRequest(route: route, values: params, from: source),
                    state: guardState
                )
                XCTAssertEqual(
                    decision,
                    GuardDecision(kind: .reject, route: nil, reason: GuardReason.paramsInvalid),
                    "\(source) \(route) \(params)"
                )
            }
        }
        let valid = EntryGuard.decide(
            request: RouteRequest(route: "OrderDetail", values: ["order_id": .string("o1")], from: .bridge),
            state: guardState
        )
        XCTAssertEqual(valid.kind, .open)
    }

    func testRouterDoesNotPushInvalidParams() {
        let router = makeRouter()
        router.open(RouteRequest(route: "Search", values: ["q": .integer(123)], from: .bridge))
        XCTAssertTrue(router.path.isEmpty)
        XCTAssertEqual(router.lastDecision?.reason, GuardReason.paramsInvalid)
    }

    func testSensitivePagesDropParamsBeforeSchemaCheck() {
        guardState.session = .phoneBound
        guardState.realnameVerified = true
        let decision = EntryGuard.decide(
            request: RouteRequest(route: "Withdraw", values: ["amount": .integer(100)], from: .inApp),
            state: guardState
        )
        XCTAssertEqual(decision, GuardDecision(kind: .open, route: "Withdraw", reason: GuardReason.paramsDropped))
    }
}

private struct TargetCase {
    let route: String
    let url: String
    let opens: Bool
}
