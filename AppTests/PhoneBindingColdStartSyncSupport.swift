import Combine
@testable import Couli
import CouliNetwork
import Foundation
import Login
import Router
import Session
import XCTest

/// FU-IOS-PHONE-BINDING-COLDSTART 的公共搭法：真 AppNetwork + AppRouting + AppLogin + AppMe（`MeAppFixture`，本地
/// WalletStubProtocol 假服务）。
/// 冷启动态 = `make(phoneKnown: false)`：PhoneBindingStore 对当前会话没有记录（只在内存，进程重启后即如此）；夹具在 make 里照生产顺序
/// 先建 AppLogin 再 `routing.shellAppeared()`（启动协调 → beforeLaunchCoordination）。之后的触发一律走 AppRouting 的真实入口
/// （`launchConditionsChanged` / `sessionStateChanged`），不直接调 AppLogin 的同步函数。
///
/// 计数：`phoneSync.queries` 是 PhoneBindingSync 实际发起的查询次数（逻辑次数；GET 断连时 ApiClient 会自动重发 1 次 HTTP，所以断连用例
/// 只比逻辑次数与「之后 HTTP 次数不再变」）；`meHttp` 是假服务收到的 GET /v1/me 次数。
@MainActor
class PhoneBindingColdStartSyncTestCase: MeTestCase {
    static let boundTrue = WalletStubProtocol.Reply.envelope(
        code: 0,
        data: MeSamples.me(phoneBound: true),
        headers: [:]
    )
    static let boundFalse = WalletStubProtocol.Reply.envelope(
        code: 0, data: MeSamples.me(phoneBound: false), headers: [:]
    )
    static let serverError = WalletStubProtocol.Reply.envelope(code: 50001, data: "null", headers: [:])

    override func setUpWithError() throws {
        try super.setUpWithError()
        // Router 的 pending_action 存在标准 UserDefaults（各用例共用）：别的用例留下的手机号级待办会让现状的 ensurePhoneBindingKnown 也去查
        UserDefaultsPendingBackend().delete()
    }

    override func tearDown() {
        UserDefaultsPendingBackend().delete()
        super.tearDown()
    }

    /// 冷启动：GET /v1/me 按 `reply` 回答（nil = MeTestCase 缺省的 phone_bound:true），存储未知，夹具内已跑过一次启动协调。
    func coldStart(_ reply: WalletStubProtocol.Reply? = nil, account: String? = "user-a", scope: String = "full",
                   decision: String = "consented") -> MeAppFixture {
        if let reply {
            script.on("GET /v1/me", reply)
        }
        return make(account: account, scope: scope, decision: decision, phoneKnown: false)
    }

    func phoneBound(_ fixture: MeAppFixture) -> Bool? {
        fixture.login.phone.bound(generation: fixture.client.sessionGeneration)
    }

    func queries(_ fixture: MeAppFixture) -> Int {
        fixture.login.phoneSync.queries
    }

    var meHttp: Int {
        requests("GET", "/v1/me").count
    }

    /// 假服务此刻挂起的 GET /v1/me 编号。
    var heldMe: [Int] {
        let held = Set(WalletStubProtocol.heldIds)
        return requests("GET", "/v1/me").map(\.id).filter { held.contains($0) }
    }

    /// 等 PhoneBindingSync 恰好发起过 `count` 次且当前会话没有在途查询（结论已落定）。
    func waitQueriesSettled(_ fixture: MeAppFixture, _ count: Int, _ message: String,
                            file: StaticString = #filePath, line: UInt = #line) async {
        await waitUntil(message + "。" + describe(fixture), file: file, line: line) {
            queries(fixture) == count
                && !fixture.login.phoneSync.querying(generation: fixture.client.sessionGeneration)
        }
    }

    /// 强更检查已有结论（不再是 checking）：之后不会有强更结论触发的启动协调，也不安排 5 秒超时协调。
    func updateSettled(_ fixture: MeAppFixture) -> Bool {
        switch fixture.update.routerStatus {
        case .checking, .finished(.checking):
            false
        case .finished:
            true
        }
    }

    /// 本机留下一条手机号级待办（与 Router 登记的同一份存储，同 OAuthBindPhoneWiringTests 的写法）。
    func savePendingRoute(_ route: String, file: StaticString = #filePath, line: UInt = #line) {
        let pending = PendingActionStore(backend: UserDefaultsPendingBackend())
        XCTAssertTrue(pending.save(
            action: Router.openRouteAction, values: ["route": .string(route)], now: pending.now,
            origin: RouteSource.inApp.rawValue
        ), "前提：待办写入", file: file, line: line)
    }

    /// 已登录（full）的新会话：先登出再保存 `account` 的令牌（会话世代推进），不记手机号状态（第三方老用户 / 冷启动同口径）。
    func signIn(_ fixture: MeAppFixture, as account: String) throws {
        fixture.client.signOut()
        try fixture.tokens.save(
            access: "at-\(account)-2", refresh: "rt-\(account)-2", scope: SessionScope.full, account: account
        )
    }

    /// 让 GET /v1/me 之后的请求按 `reply` 回答，并放行挂起的 `id`。
    func release(_ id: Int, with reply: WalletStubProtocol.Reply) {
        script.on("GET /v1/me", reply)
        WalletStubProtocol.release(id, with: reply)
    }

    func describe(_ fixture: MeAppFixture, _ history: PhoneBindingColdStartRouteHistory? = nil) -> String {
        let router = fixture.router
        let bound = phoneBound(fixture).map { "\($0)" } ?? "未知"
        let decision = router.lastDecision.map { "\($0.kindRaw)→\($0.route ?? "nil")" } ?? "nil"
        let seen = history.map { " 栈历史=\($0.seen)" } ?? ""
        return "实得：queries=\(queries(fixture)) GET /v1/me=\(meHttp) 次 phone_bound 存储=\(bound) "
            + "守卫会话=\(fixture.routing.guardState.session.rawValue) path=\(router.path.map { $0.route ?? "?" }) "
            + "待办=\(router.pendingRouteName ?? "无") lastDecision=\(decision)\(seen)"
    }
}

/// Router 栈出现过的全部路由（包括被推入又弹掉的页）。
@MainActor
final class PhoneBindingColdStartRouteHistory {
    private(set) var seen: [String] = []
    private var watch: AnyCancellable?

    init(_ router: Router) {
        watch = router.$path.sink { [weak self] path in
            MainActor.assumeIsolated { self?.seen.append(contentsOf: path.compactMap(\.route)) }
        }
    }
}
