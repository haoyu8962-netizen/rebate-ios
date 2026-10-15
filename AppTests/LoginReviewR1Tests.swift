import BridgeHost
import Config
@testable import Couli
import CouliNetwork
import Foundation
import Privacy
@testable import Router
import Session
import Update
import XCTest

/// APP-05a iOS 第 1 轮评审（ios-review-r1.md）在 App 真实组合处的回归：R1-01 会话 Effect 经生产网络回调跳登录 / 保持强更页；
/// R1-02 受限会话刷新成 full 后按刷新来源决定是否经启动协调恢复待办；R1-05 桥导航 deferred 不进启动队列、不补执行。
/// 全部经真实 AppNetwork（ApiClient + URLProtocol 本地假服务，基址 .invalid）、AppRouting、AppLogin，不经调试入口。
@MainActor
final class LoginReviewR1Tests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        suiteName = "LoginReviewR1Tests.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        AppStubProtocol.reset()
        UserDefaultsPendingBackend().delete()
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        AppStubProtocol.reset()
        UserDefaultsPendingBackend().delete()
    }

    private struct Device: DeviceCredentials {
        var deviceId: String? = "device-fixture"
        var installSecret: String? = "test-only.install.device-a"
    }

    private struct Fixture {
        let network: AppNetwork
        let routing: AppRouting
        let update: AppUpdate
        let login: AppLogin
    }

    private func makeFixture(tokens: MemorySessionTokens, update: AppUpdate) -> Fixture {
        let withdrawal = EnvironmentSwitchCleanerRegistry(cleaners: [SessionTokensCleaner(tokens: tokens)])
        let environmentSwitch = EnvironmentSwitchCleanerRegistry(cleaners: [SessionTokensCleaner(tokens: tokens)])
        let privacyStore = MemoryPrivacyStore()
        privacyStore.decisionRaw = "consented"
        privacyStore.consentedVersion = "1"
        let runner = WithdrawalCleanupRunner(store: privacyStore, registry: withdrawal)
        let network = AppNetwork(
            tokens: tokens,
            pendingBackend: MemoryPendingKeyBackend(),
            device: Device(),
            withdrawalRegistry: withdrawal,
            environmentRegistry: environmentSwitch,
            credentialsReadable: { runner.credentialsReadable },
            configuration: AppStubProtocol.configuration()
        )
        let environment = EnvironmentStore(defaultEnvironment: .test, defaults: defaults, registry: environmentSwitch)
        let privacy = PrivacyController(
            store: privacyStore, clock: { 1 }, bundledPolicyVersion: "1", withdrawalRunner: runner
        )
        let routing = AppRouting(environment: environment, privacy: privacy, update: update)
        // 与 CouliApp 同序：AppLogin 接上会话状态源与网络回调之后再 attach（attach 会把强更状态推给 ApiClient）。
        let login = AppLogin(network: network, routing: routing, update: update)
        network.attach(environment: environment, privacy: privacy, update: update)
        routing.shellAppeared()
        return Fixture(network: network, routing: routing, update: update, login: login)
    }

    private func waitFor(_ condition: @MainActor () -> Bool) async {
        for _ in 0..<400 where !condition() {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    /// 已登记的 OrderList 待办（游客 / 受限会话点「订单」时守卫登记的那种）。
    private func seedOrderListPending() {
        let pending = PendingActionStore(backend: UserDefaultsPendingBackend())
        XCTAssertTrue(pending.save(
            action: Router.openRouteAction, values: ["route": .string("OrderList")],
            now: pending.now, origin: RouteSource.inApp.rawValue
        ))
    }

    private static func envelope(_ code: Int, data: String = "{}") -> String {
        "{\"code\":\(code),\"msg\":\"\",\"data\":\(data),\"trace_id\":\"t\"}"
    }

    /// 刷新响应（令牌用无意义的短占位串）。
    private static let refreshFull = envelope(
        0, data: "{\"access_token\":\"at-2\",\"refresh_token\":\"rt-2\",\"session_scope\":\"full\"}"
    )

    // MARK: - R1-01

    /// 正常版本、已登录：请求收到 10404 → ApiClient 清会话并经生产回调发出 clear_session_login → 经 Router 打开 Login，
    /// 登录页带会话失效提示（LoginSessionExpired）。
    func testSessionInvalid10404OpensLoginThroughRouter() async {
        let tokens = MemorySessionTokens(access: "at-1", refresh: "rt-1", scope: "full", account: "u1")
        let fixture = makeFixture(tokens: tokens, update: UpdateFixtures.makeUpdate())
        XCTAssertEqual(fixture.update.routerStatus, .finished(.ok))
        AppStubProtocol.install { _ in .json(status: 401, body: Self.envelope(10404)) }

        let result = await fixture.network.client.send(ApiCall(operationId: "getMe"))

        guard case let .failure(code, _, _, _, effect, _) = result else {
            return XCTFail("\(result)")
        }
        XCTAssertEqual(code, 10404)
        XCTAssertEqual(effect.kind, .clearSessionLogin)
        XCTAssertNil(tokens.accessToken, "会话已清")
        XCTAssertEqual(fixture.routing.router.path.map(\.route), [RoutePolicy.login], "经 Router 打开登录页")
        XCTAssertTrue(fixture.login.pageConfig(restricted: false).sessionExpired, "登录页带会话失效提示")
        XCTAssertEqual(fixture.routing.guardState.session, .guest)
    }

    /// 刷新失败（10002 → 刷新被拒）同样经生产回调跳登录，且只开一层登录页。
    func testRefreshFailureOpensLoginOnce() async {
        let tokens = MemorySessionTokens(access: "at-1", refresh: "rt-1", scope: "full", account: "u1")
        let fixture = makeFixture(tokens: tokens, update: UpdateFixtures.makeUpdate())
        AppStubProtocol.install { request in
            request.path == "/v1/auth/refresh"
                ? .json(status: 401, body: Self.envelope(10404))
                : .json(status: 401, body: Self.envelope(10002))
        }

        let result = await fixture.network.client.send(ApiCall(operationId: "getMe"))

        guard case let .sessionCleared(effect) = result else {
            return XCTFail("\(result)")
        }
        XCTAssertEqual(effect.kind, .clearSessionLogin)
        await waitFor { !fixture.routing.router.path.isEmpty }
        XCTAssertEqual(fixture.routing.router.path.map(\.route), [RoutePolicy.login])
        XCTAssertTrue(fixture.login.pageConfig(restricted: false).sessionExpired)
    }

    /// 强更场景（低于最低版本）：收到 10404 清会话后保持强更页，不打开登录页。
    func testSessionInvalidDuringForceUpdateKeepsForceUpdate() async {
        let tokens = MemorySessionTokens(access: "at-1", refresh: "rt-1", scope: "full", account: "u1")
        let record = UpdateRecord(lastResult: UpdateFixtures.force, lastSuccessAt: 1)
        let update = UpdateFixtures.makeUpdate(
            checker: StubUpdateChecker(nil),
            store: MemoryUpdateStore(record: record)
        )
        let fixture = makeFixture(tokens: tokens, update: update)
        XCTAssertEqual(fixture.update.routerStatus, .finished(.belowMin))
        XCTAssertEqual(fixture.routing.router.path.map(\.route), [RoutePolicy.forceUpdate])
        AppStubProtocol.install { _ in .json(status: 401, body: Self.envelope(10404)) }

        _ = await fixture.network.client.send(ApiCall(operationId: "getMe"))

        XCTAssertNil(tokens.accessToken, "会话已清")
        XCTAssertEqual(fixture.routing.router.path.map(\.route), [RoutePolicy.forceUpdate], "保持强更页")
        XCTAssertFalse(fixture.login.pageConfig(restricted: false).sessionExpired, "不留失效提示给以后的登录页")
    }

    // MARK: - R1-02

    /// 冷启动：保存着 deletion_only 会话与未过期的 OrderList 待办；版本检查确认 supported 时守卫因会话受限保留待办 →
    /// 受限会话屏障的异步刷新变为 full → 世代仍有效，通知启动协调器，经 Router 守卫恢复待办。
    func testColdStartBarrierRefreshResumesPending() async {
        let tokens = MemorySessionTokens(
            access: "at-1",
            refresh: "rt-1",
            scope: SessionScope.deletionOnly,
            account: "u1"
        )
        let checker = StubUpdateChecker(nil)
        let update = UpdateFixtures.makeUpdate(checker: checker)
        AppStubProtocol.install { request in
            request.path == "/v1/auth/refresh"
                ? .json(status: 200, body: Self.refreshFull) : .json(status: 200, body: Self.envelope(0))
        }
        seedOrderListPending()
        let fixture = makeFixture(tokens: tokens, update: update)
        XCTAssertEqual(fixture.routing.guardState.session, .restricted)

        // 检查结果到达：同步协调一次（此刻会话仍受限，守卫保留待办），同时 ApiClient 发起受限会话屏障的异步刷新。
        checker.deliver(.success(UpdateFixtures.ok))
        XCTAssertEqual(fixture.update.routerStatus, .finished(.ok))
        XCTAssertNotNil(UserDefaultsPendingBackend().read(), "会话仍受限：守卫保留待办")
        XCTAssertNotEqual(fixture.routing.router.tabRoot.route, "OrderList")

        await waitFor { fixture.routing.router.tabRoot.route == "OrderList" }

        XCTAssertEqual(AppStubProtocol.requests.map(\.path), ["/v1/auth/refresh"])
        XCTAssertEqual(tokens.scope, "full")
        XCTAssertEqual(fixture.routing.router.tabRoot.route, "OrderList", "经启动协调恢复原意图")
        XCTAssertNil(UserDefaultsPendingBackend().read(), "待办执行一次后删除")
    }

    /// 登录尝试那一类的受限复查（ApiClient.recheckRestrictedSession，不是启动 / 版本恢复屏障开的刷新）变为 full：
    /// App 只同步会话状态，不恢复待办（待办只能由仍有效的登录流程交 Router 恢复）。
    func testLoginRecheckRefreshOnlySyncsState() async {
        // 先以 full 会话启动（启动屏障直接通过、不刷新），再换成受限会话：之后的刷新只来自显式复查。
        let tokens = MemorySessionTokens(access: "at-1", refresh: "rt-1", scope: "full", account: "u1")
        AppStubProtocol.install { request in
            request.path == "/v1/auth/refresh"
                ? .json(status: 200, body: Self.refreshFull) : .json(status: 200, body: Self.envelope(0))
        }
        let fixture = makeFixture(tokens: tokens, update: UpdateFixtures.makeUpdate())
        _ = await fixture.network.client.send(ApiCall(operationId: "getMe"))
        try? tokens.save(access: "at-1", refresh: "rt-1", scope: SessionScope.deletionOnly, account: "u1")
        seedOrderListPending()
        fixture.routing.launchConditionsChanged()
        XCTAssertNotNil(UserDefaultsPendingBackend().read(), "受限会话：待办保留")
        let changes = fixture.login.sessionVersion

        let recheck = await fixture.network.client.recheckRestrictedSession(isValid: { true })
        await waitFor { fixture.login.sessionVersion != changes }

        XCTAssertEqual(recheck, .full)
        XCTAssertNotEqual(fixture.login.sessionVersion, changes, "会话状态已同步")
        // APP-05b：会话来自预置令牌、本进程没有查清 phone_bound → 按「已登录未绑手机」（未知不当已绑，共性第 13 条）；本用例关心的是
        // 「会话状态已同步为 full、不借刷新恢复待办」，不是手机号
        XCTAssertEqual(fixture.routing.guardState.session, .loggedIn)
        XCTAssertNotNil(UserDefaultsPendingBackend().read(), "不借刷新通知恢复待办")
        XCTAssertNotEqual(fixture.routing.router.tabRoot.route, "OrderList")
    }

    // MARK: - R1-05

    /// 检查中：桥来源的 nav.open 由守卫判为 deferred → 不进启动队列，桥调用按取消结束（90500）；检查结束后也不补执行。
    func testBridgeNavOpenDeferredIsNotQueued() {
        var state = GuardState(
            privacyState: .consented, updateState: .checking, sessionState: .guest, environmentSettled: true,
            appVersion: AppWeb.appVersion, isDebugBuild: true
        )
        let router = Router(pendingStore: PendingActionStore(backend: MemoryPendingBackend())) { state }

        let outcome = AppBridgeServices.navOpen(
            router: router,
            route: "Search",
            paramsJson: "{}",
            readOnlyPagesOnly: false
        )

        XCTAssertEqual(outcome.code, BridgeCode.nativeError)
        XCTAssertEqual(router.lastDecision?.kind, .deferred)
        XCTAssertFalse(router.hasPendingLaunchIntent, "桥请求不进启动队列")
        state.update = .ok
        router.launchConditionsChanged(
            readiness: LaunchReadiness(environmentSettled: true, privacy: .consented, update: .finished(.ok)),
            shellReady: true, now: 1
        )
        XCTAssertTrue(router.path.isEmpty, "检查结束后不补执行")
    }

    // MARK: - APP-04 共性 66（编排者追加）

    private func guestRouter(checking: Bool = false) -> Router {
        let state = GuardState(
            privacyState: .consented, updateState: checking ? .checking : .ok, sessionState: .guest,
            environmentSettled: true,
            appVersion: AppWeb.appVersion, isDebugBuild: true
        )
        return Router(pendingStore: PendingActionStore(backend: MemoryPendingBackend())) { state }
    }

    /// 只看此刻有没有会话、没有登录提交记录的会话出口（这几条只核对等待与结算时机）。
    private static func plainSession(_ loggedIn: @escaping @MainActor () -> Bool) -> BridgeLoginSession {
        BridgeLoginSession(mark: { 0 }, committedKey: { _ in nil }, loggedIn: loggedIn)
    }

    /// 桥 auth.login：打开登录页后不立即结算；登录完成（会话已保存、登录流程关闭登录页）后回 logged_in=true。
    func testBridgeLoginSettlesAfterLoginCompletes() async {
        let router = guestRouter()
        var loggedIn = false
        var outcome: BridgeOutcome?
        let call = Task { @MainActor in
            outcome = await AppBridgeServices.login(router: router, session: Self.plainSession { loggedIn })
        }
        await waitFor { router.path.last?.route == RoutePolicy.login }
        try? await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertNil(outcome, "登录页还在：不结算")

        loggedIn = true
        router.removeRoute(RoutePolicy.login)
        await call.value
        XCTAssertEqual(outcome?.code, BridgeCode.ok)
        XCTAssertEqual(outcome?.data?["logged_in"] as? Bool, true)
    }

    /// 用户关闭登录页：回 logged_in=false；调用被宿主作废（Task 取消）：立即结束（90500）。
    func testBridgeLoginLeaveAndCancel() async {
        let router = guestRouter()
        var left: BridgeOutcome?
        let leave = Task { @MainActor in
            left = await AppBridgeServices.login(router: router, session: Self.plainSession { false })
        }
        await waitFor { router.path.last?.route == RoutePolicy.login }
        router.path = []
        await leave.value
        XCTAssertEqual(left?.data?["logged_in"] as? Bool, false)

        var cancelled: BridgeOutcome?
        let cancel = Task { @MainActor in
            cancelled = await AppBridgeServices.login(router: router, session: Self.plainSession { true })
        }
        await waitFor { router.path.last?.route == RoutePolicy.login }
        cancel.cancel()
        await cancel.value
        XCTAssertEqual(cancelled?.code, BridgeCode.nativeError)
    }

    /// 守卫没让打开登录页（检查中 → deferred）：按 90500 结束，不进启动队列。
    func testBridgeLoginNotOpenedFails() async {
        let router = guestRouter(checking: true)
        let outcome = await AppBridgeServices.login(router: router, session: Self.plainSession { false })
        XCTAssertEqual(outcome.code, BridgeCode.nativeError)
        XCTAssertTrue(router.path.isEmpty)
        XCTAssertFalse(router.hasPendingLaunchIntent)
    }
}
