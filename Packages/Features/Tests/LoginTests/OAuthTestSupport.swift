import CouliNetwork
import Foundation
import Generated
@testable import Login
import Router
import Session
import XCTest

extension Paths {
    static let attempts = "/v1/auth/oauth-attempts"
    static let wechat = "/v1/auth/login/wechat"
    static let apple = "/v1/auth/login/apple"
    static let me = "/v1/me"
    static let bindPhone = "/v1/me/phone"
    static let abandon = "/v1/idempotency-keys/abandon"
}

let attemptData = "{\"attempt_id\":\"att-1\",\"nonce\":\"nonce-for-test-0001\","
    + "\"expire_at\":\"2099-01-01T00:10:00+08:00\"}"

func meData(phoneBound: Bool) -> String {
    "{\"user_id\":\"u1\",\"phone_bound\":\(phoneBound)}"
}

/// 可控的第三方适配器（测试替身只替换 SDK 这一层；执行器、网络层、Router 都是真实的）：`authorize` 挂起，测试 `complete` 给结果。
/// `resumesOnAbort` 为 false 时模拟收不回的 SDK 界面（abort 不回调，迟到的结果之后才到）。
@MainActor
final class FakeAuthorizer: ThirdPartyAuthorizer {
    let provider: String
    var available = true
    var installed: Bool? = true
    var resumesOnAbort = false
    private(set) var nonces: [String] = []
    private(set) var aborts = 0
    private var waiting: CheckedContinuation<OAuthAuthorization, Never>?

    init(_ provider: String) {
        self.provider = provider
    }

    var authorizing: Bool {
        waiting != nil
    }

    func authorize(nonce: String) async -> OAuthAuthorization {
        nonces.append(nonce)
        return await withCheckedContinuation { waiting = $0 }
    }

    func complete(_ result: OAuthAuthorization) {
        let pending = waiting
        waiting = nil
        pending?.resume(returning: result)
    }

    func abort() {
        aborts += 1
        if resumesOnAbort {
            complete(.cancelled)
        }
    }
}

/// 第三方登录与绑手机的组合：真实 ApiClient（URLProtocol 假服务）、真实 Router（内存 pending_action）、生产出口 RouterLoginHost、
/// 生产的 PhoneBindingStore / PhoneBindingSync / OAuthLoginService / BindPhoneService；守卫的会话状态与 App 同一函数
/// （SessionGuardState：full 只有确认 phone_bound=true 才是已绑手机）。
@MainActor
final class OAuthHarness {
    let tokens = MemorySessionTokens()
    let clock = MutableBox<Int64>(1_700_000_000_000)
    let client: ApiClient
    let router: Router
    let pending: PendingActionStore
    let host: RouterLoginHost
    let service: LoginService
    let phone = PhoneBindingStore()
    let sync: PhoneBindingSync
    let oauth: OAuthLoginService
    let bind: BindPhoneService
    let wechat = FakeAuthorizer(OAuthProvider.wechat)
    let apple = FakeAuthorizer(OAuthProvider.apple)
    let pendingBackend = MemoryPendingKeyBackend()
    private(set) var guides: [(UInt64, String)] = []
    private(set) var bound: [BindPhoneOwner] = []

    init() {
        client = ApiClient(
            identity: ClientIdentity(platform: "ios", appVersion: "9.9.9", build: "1", channel: "appstore"),
            context: {
                NetworkContext(
                    privacy: PrivacyRaw.full, environmentSettled: true, credentialsReadable: true,
                    update: UpdateRaw.supported, apiBaseURL: URL(string: "https://api.test.invalid")
                )
            },
            device: StubDevice(),
            tokens: tokens,
            pendingKeys: PendingKeyStore(backend: pendingBackend, clock: { 0 }),
            configuration: LoginStubProtocol.configuration()
        )
        let client = client
        let phone = phone
        let pending = PendingActionStore(backend: MemoryPendingBackend())
        self.pending = pending
        router = Router(pendingStore: pending) {
            GuardState(
                privacyState: .consented, updateState: .ok,
                sessionState: SessionGuardState.of(
                    scope: client.isolatedSessionScope, phoneBound: phone.bound(generation: client.sessionGeneration)
                ),
                environmentSettled: true, appVersion: "9.9.9", isDebugBuild: false
            )
        }
        let routerRef = router
        let clock = clock
        host = RouterLoginHost(router: router, update: { .supported }, markBelow: {}, stateChanged: { resume in
            if resume {
                routerRef.launchConditionsChanged(
                    readiness: LaunchReadiness(environmentSettled: true, privacy: .consented, update: .finished(.ok)),
                    shellReady: true, now: clock.value
                )
            }
        })
        service = LoginService(client: client, host: host, clock: { clock.value })
        service.phoneBinding = phone
        host.watchLoginPage(service)
        sync = PhoneBindingSync(client: client, store: phone)
        oauth = OAuthLoginService(
            login: service, host: host, phone: sync,
            authorizers: [OAuthProvider.wechat: wechat, OAuthProvider.apple: apple]
        )
        bind = BindPhoneService(client: client, sync: sync)
        bind.clock = { clock.value }
        host.onBindGuide = { [unowned self] session, provider in guides.append((session, provider)) }
        bind.onBound = { [unowned self] owner in
            bound.append(owner)
            router.dropPendingHold(session: owner.request.generation)
        }
    }

    var guideSessions: [UInt64] {
        guides.map(\.0)
    }

    var routes: [String?] {
        router.path.map(\.route)
    }

    /// 已登录（第三方账号，phone_bound 未知）。
    func seedSession(account: String = "u1") throws {
        client.signOut()
        try tokens.save(access: "at-0", refresh: "rt-0", scope: Session.SessionScope.full, account: account)
    }

    /// 游客点「订单」（登记 OrderList 待办并推入 Login）。
    func guestOpens(_ route: String) {
        router.open(RouteRequest(route: route, from: .inApp))
    }

    func advance(seconds: Int64) {
        clock.value += seconds * 1000
    }

    /// 等第三方授权界面被拉起（createOauthAttempt 已返回）。
    func waitAuthorizing(_ authorizer: FakeAuthorizer) async {
        await waitUntil { authorizer.authorizing }
    }
}

/// 绑手机页的测试出口：记下导航、播报、出栈。
@MainActor
final class BindHooksLog {
    var opened: [String] = []
    var announced: [String] = []
    var completed: [(UUID, UInt64)] = []
    var alreadyBound: [(UUID, UInt64)] = []
    var backs = 0
    var contacted = 0
    var top = true
    var active = true
    var provider: String?

    func hooks() -> BindPhoneHooks {
        var hooks = BindPhoneHooks()
        hooks.isTop = { [unowned self] _ in top }
        hooks.sceneActive = { [unowned self] in active }
        hooks.open = { [unowned self] in opened.append($0) }
        hooks.completed = { [unowned self] id, gen in completed.append((id, gen)) }
        hooks.alreadyBound = { [unowned self] id, gen in alreadyBound.append((id, gen)) }
        hooks.back = { [unowned self] _ in backs += 1 }
        hooks.contactService = { [unowned self] in contacted += 1 }
        hooks.announce = { [unowned self] in announced.append($0) }
        hooks.providerName = { [unowned self] _ in provider }
        return hooks
    }
}

/// 测试用文案：原样返回键（带变量时附上变量值），便于断言用了哪个键。
@MainActor
struct BindKeyTexts: LoginTexts {
    func text(_ key: String) -> String {
        key
    }

    func format(_ key: String, _ vars: [String: String]) -> String {
        vars.isEmpty ? key : key + "|" + vars.keys.sorted().map { "\($0)=\(vars[$0] ?? "")" }.joined(separator: ",")
    }
}

extension OAuthHarness {
    /// 一个绑手机页执行器（固定身份取自此刻的会话）。
    func bindController(_ log: BindHooksLog, id: UUID = UUID()) -> BindPhoneController {
        BindPhoneController(
            owner: bind.identity(),
            entryId: id,
            service: bind,
            texts: BindKeyTexts(),
            hooks: log.hooks()
        )
    }
}
