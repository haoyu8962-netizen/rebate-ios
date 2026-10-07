import BridgeHost
import Config
@testable import Couli
@testable import CouliNetwork
import Foundation
import Privacy
import Router
import Session
import Update
import XCTest

/// APP-05a iOS 第 2 轮评审（ios-review-r2.md）在 App 真实组合处的回归：
/// - R2-01（APP-04 共性 66、67、68）：桥 auth.login 走完整 BridgeHost 链路（协议准入 → 分派 → AppBridgeServices.login →
///   Router 打开登录页 → 真实 LoginService 登录 → 结算）：成功回 logged_in=true；取消回 false；同一宿主取消后再次登录成功；
/// - R2-04（共性 26）：会话失效 Effect 的归属由网络层在清理发生时定下，旧 10404 的 Effect 在新登录保存之后才送达也不再打开
///   登录页；没有发生清理的 Effect 不通知。
/// 全部经真实 AppNetwork（ApiClient + URLProtocol 本地假服务，基址 .invalid）、AppRouting、AppLogin。
@MainActor
final class LoginReviewR2Tests: XCTestCase {
    private static let origin = "https://h5.example.test"
    private var suiteName = ""
    private var defaults: UserDefaults!
    /// 宿主只弱引用界面能力（容器持有宿主）：测试里由这里持有。
    private var bridgeUI: LoginBridgeUI?

    override func setUpWithError() throws {
        suiteName = "LoginReviewR2Tests.\(UUID().uuidString)"
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
        var installSecret: String? = "test-only.install.device-b"
    }

    private struct Fixture {
        let network: AppNetwork
        let routing: AppRouting
        let login: AppLogin
    }

    private func makeFixture(tokens: MemorySessionTokens) -> Fixture {
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
        let update = UpdateFixtures.makeUpdate()
        let routing = AppRouting(environment: environment, privacy: privacy, update: update)
        let login = AppLogin(network: network, routing: routing, update: update)
        network.attach(environment: environment, privacy: privacy, update: update)
        routing.shellAppeared()
        return Fixture(network: network, routing: routing, login: login)
    }

    private func waitFor(_ condition: @MainActor () -> Bool) async {
        for _ in 0..<600 where !condition() {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    private static func envelope(_ code: Int, data: String = "{}") -> String {
        "{\"code\":\(code),\"msg\":\"\",\"data\":\(data),\"trace_id\":\"t\"}"
    }

    /// 短信登录响应（令牌用无意义的短占位串）。
    private static let loginOK = envelope(0, data: "{\"user_id\":\"u2\",\"is_new_user\":false,\"tokens\":"
        + "{\"access_token\":\"at-9\",\"refresh_token\":\"rt-9\",\"session_scope\":\"full\"}}")

    private func loginBySms(_ fixture: Fixture) async -> String {
        let outcome = await fixture.login.service.login(
            phone: "13800138000", code: "123456", consentAtMillis: 1, invite: "", restricted: false
        )
        return outcome.stateRaw
    }

    // MARK: - R2-01：完整 BridgeHost 链路

    /// 与 AppWeb 同口径的调用方状态（归属键 = 账号 + 会话世代），接真实的 BridgeHost 与生产的 auth.login 实现。
    private func makeHost(_ fixture: Fixture) -> BridgeHost {
        let client = fixture.network.client
        let caller: @MainActor () -> BridgeCallerState = {
            BridgeCallerState(
                privacy: BridgePrivacy.consented,
                accountKey: AppWeb.accountKey(account: client.isolatedAccount, generation: client.sessionGeneration),
                update: BridgeUpdateState.supported
            )
        }
        let services = LoginBridgeServices(
            router: fixture.routing.router,
            session: BridgeLoginSession.production(login: fixture.login, caller: caller)
        )
        let ui = LoginBridgeUI()
        bridgeUI = ui
        return BridgeHost(
            protocol: { BridgeProtocol(trustedOrigins: [Self.origin], linkPatterns: [:], shareDomains: []) },
            caller: caller,
            services: services,
            ui: ui,
            awaitUpdate: { BridgeUpdateState.supported }
        )
    }

    private func callLogin(_ host: BridgeHost, id: String) -> ReplyBox {
        let box = ReplyBox()
        let raw = #"{"v":1,"id":"\#(id)","method":"auth.login","params":{}}"#
        host.handle(raw: raw, origin: Self.origin, isMainFrame: true, userGesture: true) { box.value = $0 }
        return box
    }

    /// 游客经桥调用 auth.login → 登录页打开、不立即结算 → 短信登录成功（会话保存、登录页关闭，账号由 nil 变为新账号）→
    /// 结算时允许这次登录造成的账号变化：code=0、logged_in=true（不是 90500）。
    func testBridgeLoginSuccessThroughBridgeHost() async {
        AppStubProtocol.install { _ in .json(status: 200, body: Self.loginOK) }
        let fixture = makeFixture(tokens: MemorySessionTokens())
        let host = makeHost(fixture)
        let reply = callLogin(host, id: "l1")
        await waitFor { fixture.routing.router.path.last?.route == RoutePolicy.login }
        XCTAssertEqual(fixture.routing.router.path.map(\.route), [RoutePolicy.login])
        XCTAssertNil(reply.value, "登录页还在：不结算")

        let state = await loginBySms(fixture)
        XCTAssertEqual(state, "logged_in")
        await waitFor { reply.value != nil }
        XCTAssertEqual(reply.code, BridgeCode.ok)
        XCTAssertEqual(reply.data?["logged_in"] as? Bool, true)
        XCTAssertEqual(host.inFlightCount, 0)
    }

    /// 同一宿主：第一次打开登录页后取消（logged_in=false）→ 第二次调用再次打开登录页（同一路由的新页面条目，按本次导航的
    /// 实际结果判断已打开，共性 67）→ 登录成功（logged_in=true）。
    func testBridgeLoginCancelThenSucceedOnSameHost() async {
        AppStubProtocol.install { _ in .json(status: 200, body: Self.loginOK) }
        let fixture = makeFixture(tokens: MemorySessionTokens())
        let router = fixture.routing.router
        let host = makeHost(fixture)

        let first = callLogin(host, id: "c1")
        await waitFor { router.path.last?.route == RoutePolicy.login }
        let firstPage = router.path.last?.id
        router.removeRoute(RoutePolicy.login)
        await waitFor { first.value != nil }
        XCTAssertEqual(first.code, BridgeCode.ok)
        XCTAssertEqual(first.data?["logged_in"] as? Bool, false, "取消：未登录")

        let second = callLogin(host, id: "c2")
        await waitFor { router.path.last?.route == RoutePolicy.login }
        XCTAssertNotEqual(router.path.last?.id, firstPage, "第二次是新推入的登录页")
        XCTAssertNil(second.value)
        let state = await loginBySms(fixture)
        XCTAssertEqual(state, "logged_in")
        await waitFor { second.value != nil }
        XCTAssertEqual(second.code, BridgeCode.ok)
        XCTAssertEqual(second.data?["logged_in"] as? Bool, true)
    }

    /// 守卫仍在：登录成功之后、结算之前会话又被别处换掉（不是这次登录保存的会话）→ 90500。
    func testBridgeLoginBoundToThisLoginSession() async {
        AppStubProtocol.install { _ in .json(status: 200, body: Self.loginOK) }
        let fixture = makeFixture(tokens: MemorySessionTokens())
        let host = makeHost(fixture)
        let reply = callLogin(host, id: "b1")
        await waitFor { fixture.routing.router.path.last?.route == RoutePolicy.login }
        let state = await loginBySms(fixture)
        XCTAssertEqual(state, "logged_in")
        // 轮询发现登录页离开之前，本机会话被清（登出、10404 等）：不再是这次登录保存的会话。
        fixture.login.service.clearLocalSession()
        await waitFor { reply.value != nil }
        XCTAssertEqual(reply.code, BridgeCode.ok)
        XCTAssertEqual(reply.data?["logged_in"] as? Bool, false, "会话已不是这次登录保存的：不报已登录")
    }

    // MARK: - R2-04：会话失效 Effect 的归属

    /// 旧请求收到 10404 并清掉 A 会话 → 用户关掉登录页，另一次登录保存了新会话 → 旧 Effect 这时才送达 App：归属是清理时的
    /// 世代，已不是当前世代，不再打开登录页、不留失效提示。App 不能用回调时的当前世代补作归属。
    func testStaleClearEffectAfterNewLoginIsIgnored() async throws {
        let tokens = MemorySessionTokens(access: "at-1", refresh: "rt-1", scope: "full", account: "u1")
        let fixture = makeFixture(tokens: tokens)
        let router = fixture.routing.router
        AppStubProtocol.install { request in
            request.path == "/v1/auth/login/sms"
                ? .json(status: 200, body: Self.loginOK) : .json(status: 401, body: Self.envelope(10404))
        }
        let before = fixture.network.client.sessionGeneration
        let result = await fixture.network.client.send(ApiCall(operationId: "getMe"))
        guard case let .failure(_, _, _, _, effect, _) = result else { return XCTFail("\(result)") }
        XCTAssertEqual(effect.kind, .clearSessionLogin)
        XCTAssertEqual(effect.sessionGeneration, before &+ 1, "归属 = 清理之后的世代（在清理的同步区里定下）")
        XCTAssertEqual(router.path.map(\.route), [RoutePolicy.login])
        _ = fixture.login.pageConfig(restricted: false)
        router.removeRoute(RoutePolicy.login)

        let state = await loginBySms(fixture)
        XCTAssertEqual(state, "logged_in")
        XCTAssertNotEqual(fixture.network.client.sessionGeneration, effect.sessionGeneration)

        // 旧 Effect 迟到：经生产的网络回调送达。
        await fixture.network.client.hooks.onEffect(effect)
        XCTAssertFalse(router.path.contains { $0.route == RoutePolicy.login }, "新登录之后不再打开登录页")
        XCTAssertFalse(fixture.login.pageConfig(restricted: false).sessionExpired, "不留会话失效提示")
        XCTAssertEqual(fixture.routing.guardState.session, .phoneBound)

        // 世代已变时不清理：清理是否发生与归属在同一把锁里定下，旧世代返回 nil（管线据此不发 Effect）。
        let stale = try XCTUnwrap(effect.sessionGeneration)
        XCTAssertNil(fixture.network.client.clearSession(ifGeneration: stale))
        XCTAssertEqual(tokens.accessToken, "at-9", "新会话保留")
    }

    /// 没有发生清理的会话失效 Effect（不带归属世代）：不通知、不打开登录页。
    func testClearEffectWithoutClearingIsNotDelivered() async {
        let tokens = MemorySessionTokens(access: "at-1", refresh: "rt-1", scope: "full", account: "u1")
        let fixture = makeFixture(tokens: tokens)
        await fixture.network.client.hooks.onEffect(
            ErrorEffect(code: 10404, kind: .clearSessionLogin, route: RoutePolicy.login)
        )
        XCTAssertTrue(fixture.routing.router.path.isEmpty)
        XCTAssertEqual(tokens.accessToken, "at-1")
    }
}

/// 一次桥调用的回复。
@MainActor
private final class ReplyBox {
    var value: String?

    var body: [String: Any]? {
        value.flatMap { AppWeb.object($0) }
    }

    var code: Int? {
        body?["code"] as? Int
    }

    var data: [String: Any]? {
        body?["data"] as? [String: Any]
    }
}

private final class LoginBridgeUI: BridgeUI {
    func toast(text _: String, long _: Bool) {}
    func showLoading(text _: String?) {}
    func hideLoading() {}
    func setNavBar(_: BridgeNavBar) -> Bool {
        true
    }

    func close() {}
}

/// 只接 auth.login（生产实现 `AppBridgeServices.login(router:session:)`），其余能力本测试不用。
@MainActor
private final class LoginBridgeServices: BridgeServices {
    private let router: Router
    private let session: BridgeLoginSession

    init(router: Router, session: BridgeLoginSession) {
        self.router = router
        self.session = session
    }

    func env() -> [String: Any] {
        [:]
    }

    func config(keys _: [String]) -> BridgeOutcome {
        .fail(BridgeCode.notSupported)
    }

    func user(validity _: BridgeCallValidity) async -> BridgeOutcome {
        .fail(BridgeCode.notSupported)
    }

    func h5Token(readOnly _: Bool, validity _: BridgeCallValidity) async -> BridgeOutcome {
        .fail(BridgeCode.notSupported)
    }

    func login() async -> BridgeOutcome {
        await AppBridgeServices.login(router: router, session: session)
    }

    func signedRequest(
        method _: String,
        path _: String,
        bodyJson _: String?,
        validity _: BridgeCallValidity
    ) async -> BridgeOutcome {
        .fail(BridgeCode.notSupported)
    }

    func navOpen(route _: String, paramsJson _: String, readOnlyPagesOnly _: Bool) async -> BridgeOutcome {
        .fail(BridgeCode.notSupported)
    }

    func clipboardWrite(text _: String) -> BridgeOutcome {
        .fail(BridgeCode.notSupported)
    }

    func clipboardRead() async -> BridgeOutcome {
        .fail(BridgeCode.notSupported)
    }

    func setClipboardAutoDetect(enabled _: Bool) -> BridgeOutcome {
        .fail(BridgeCode.notSupported)
    }

    func pushStatus() async -> BridgeOutcome {
        .fail(BridgeCode.notSupported)
    }

    func requestPermission(type _: String, isStillValid _: @escaping @MainActor () -> Bool) async -> BridgeOutcome {
        .fail(BridgeCode.notSupported)
    }

    func track(name _: String) -> BridgeOutcome {
        .fail(BridgeCode.notSupported)
    }

    func reportRejected(method _: String, code _: Int) {}
}
