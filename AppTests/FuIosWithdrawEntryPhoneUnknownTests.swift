import Combine
@testable import Couli
import CouliNetwork
import Foundation
import Login
import Router
import Session
import Wallet
import WalletCore
import XCTest

/// FU-IOS-WITHDRAW-ENTRY-SILENT 实跑真根因：冷启动后 PhoneBindingStore（只在内存）里手机绑定状态未知；钱包【提现】的实名查询 GET /v1/me
/// 回包带 phone_bound，客户端只读 realname_status、不写回 → 守卫判 require_bind_phone 推入 BindPhone → BindPhone 进页自查已绑立即出栈
/// （Withdraw 不登记待办）→ 用户看到「没反应」。修复：成功回包按 PhoneBinding.swift 同口径（会话世代仍是发起时那一代、scope full、
/// phone_bound 严格布尔、发送前取的 ticket）写回同一个 PhoneBindingStore。
///
/// 夹具：不改 `WalletAppFixture`。它在 make 里预写了已绑；这里打开钱包页之后、点击之前用 PhoneBindingStore 的公开接口把状态还原成冷启动
/// 态（`forgetPhoneBinding`：登录世代来源暂时给 nil 再 record → 记录被清空，与进程重启后的「未知」相同，更新世代仍为 0）。BindPhone 页
/// 不经 SwiftUI 渲染，用 `renderTopBindPhone` 照 BindPhoneView.onAppear 调 `controller.appeared()`（进页自查），复现实跑的「推入又弹掉」。
final class FuIosWithdrawEntryPhoneUnknownTests: FuIosWithdrawEntrySilentTestCase {
    static let phoneFalseMe = "{\"user_id\":\"user-a\",\"realname_status\":\"none\",\"phone_bound\":false}"
    static let missingPhoneMe = "{\"user_id\":\"user-a\",\"realname_status\":\"none\"}"
    static let numberPhoneMe = "{\"user_id\":\"user-a\",\"realname_status\":\"none\",\"phone_bound\":1}"
    static let stringPhoneMe = "{\"user_id\":\"user-a\",\"realname_status\":\"none\",\"phone_bound\":\"true\"}"
    static let smsLogin = "{\"user_id\":\"user-a\",\"is_new_user\":false,\"tokens\":{\"access_token\":\"at-sms\","
        + "\"refresh_token\":\"rt-sms\",\"session_scope\":\"full\"}}"

    /// Router 栈出现过的全部路由（包括被推入又弹掉的页）。
    @MainActor
    final class RouteHistory {
        private(set) var seen: [String] = []
        private var watch: AnyCancellable?

        init(_ router: Router) {
            watch = router.$path.sink { [weak self] path in
                MainActor.assumeIsolated { self?.seen.append(contentsOf: path.compactMap(\.route)) }
            }
        }
    }

    // MARK: - 第 1、2 条：phone_bound=true 写回，不进 BindPhone

    /// 第 1 条：未知 + phone_bound:true + 未实名 → 栈顶 RealName、栈里从没出现 BindPhone、守卫会话为 phoneBound、GET /v1/me 只 1 次。
    func testUnknownPhoneBoundTrueUnverifiedOpensRealName() async throws {
        let (opened, history) = try await openWithUnknownPhone(Self.unverified)
        tapWithdraw(opened)
        await settleQueryAndBindPhone(opened, "第 1 条")
        let name = "第 1 条（未知 + 已绑 + 未实名）"
        XCTAssertEqual(top(opened), WalletRoutes.realName, "\(name)：栈顶应是 RealName。\(detail(opened, history))")
        XCTAssertFalse(
            history.seen.contains(RoutePolicy.bindPhone),
            "\(name)：不得推入 BindPhone。\(detail(opened, history))"
        )
        XCTAssertEqual(
            opened.fixture.routing.guardState.session,
            .phoneBound,
            "\(name)：守卫会话。\(detail(opened, history))"
        )
        XCTAssertEqual(phoneBound(opened.fixture), true, "\(name)：回包写回已绑。\(detail(opened, history))")
        XCTAssertEqual(meRequests(opened).count, 1, "\(name)：GET /v1/me 只 1 次。\(detail(opened, history))")
    }

    /// 第 2 条：未知 + phone_bound:true + 已实名 → 栈顶 Withdraw（不经 BindPhone）。
    func testUnknownPhoneBoundTrueVerifiedOpensWithdraw() async throws {
        let (opened, history) = try await openWithUnknownPhone(Self.verified)
        tapWithdraw(opened)
        await settleQueryAndBindPhone(opened, "第 2 条")
        let name = "第 2 条（未知 + 已绑 + 已实名）"
        XCTAssertEqual(top(opened), WalletRoutes.withdraw, "\(name)：栈顶应是 Withdraw。\(detail(opened, history))")
        XCTAssertFalse(
            history.seen.contains(RoutePolicy.bindPhone),
            "\(name)：不得推入 BindPhone。\(detail(opened, history))"
        )
        XCTAssertEqual(meRequests(opened).count, 1, "\(name)：GET /v1/me 只 1 次。\(detail(opened, history))")
    }

    // MARK: - 第 3 条：phone_bound=false 写回，BindPhone 留在栈中

    /// 第 3 条：未知 + phone_bound:false → 栈顶 BindPhone，推入时存储已记 false；进页自查后等稳定仍在栈中、不再查 GET /v1/me。
    func testUnknownPhoneBoundFalseKeepsBindPhone() async throws {
        let name = "第 3 条（未知 + 未绑）"
        let (opened, history) = try await openWithUnknownPhone(.envelope(
            code: 0,
            data: Self.phoneFalseMe,
            headers: [:]
        ))
        tapWithdraw(opened)
        await waitUntil("\(name)：没有推入 BindPhone") { top(opened) == RoutePolicy.bindPhone }
        XCTAssertEqual(phoneBound(opened.fixture), false, "\(name)：推入 BindPhone 时存储应已记 false（钱包回包写回）。"
            + detail(opened, history))
        renderTopBindPhone(opened.fixture)
        await quietWindow()
        XCTAssertEqual(top(opened), RoutePolicy.bindPhone, "\(name)：自查后仍在栈中。\(detail(opened, history))")
        XCTAssertEqual(phoneBound(opened.fixture), false, "\(name)：存储仍为 false。\(detail(opened, history))")
        XCTAssertEqual(meRequests(opened).count, 1, "\(name)：BindPhone 自查不再查 GET /v1/me。\(detail(opened, history))")
    }

    // MARK: - 第 4 条：phone_bound 缺失或不是严格布尔 → 保持未知

    func testMissingPhoneBoundStaysUnknown() async throws {
        try await assertStaysUnknown(Self.missingPhoneMe, "第 4 条·缺 phone_bound")
    }

    func testNumberPhoneBoundStaysUnknown() async throws {
        try await assertStaysUnknown(Self.numberPhoneMe, "第 4 条·phone_bound=1")
    }

    func testStringPhoneBoundStaysUnknown() async throws {
        try await assertStaysUnknown(Self.stringPhoneMe, "第 4 条·phone_bound=\"true\"")
    }

    // MARK: - 第 5 条：查询在途时完成绑定，迟到回包不覆盖

    /// 第 5 条：GET /v1/me 挂起时绑定成功（BindPhoneService 共享结算同一调用 `recordBindSucceeded`，更新世代推进）→ 迟到回包
    /// phone_bound:false 不得覆盖；守卫按已绑走实名前置，进 RealName、不进 BindPhone。
    func testLateArrivalDoesNotOverrideBindResult() async throws {
        let name = "第 5 条（在途绑定后迟到回包）"
        let (opened, history) = try await openWithUnknownPhone(.hold)
        let fixture = opened.fixture
        tapWithdraw(opened)
        let held = try await heldMe(opened, name)
        fixture.login.phone.recordBindSucceeded(generation: fixture.network.client.sessionGeneration)
        XCTAssertEqual(phoneBound(fixture), true, "\(name) 前提：绑定结果已记")
        release(held, with: .envelope(code: 0, data: Self.phoneFalseMe, headers: [:]))
        await settleQueryAndBindPhone(opened, name)
        XCTAssertEqual(phoneBound(fixture), true, "\(name)：迟到回包不得覆盖绑定结果。\(detail(opened, history))")
        XCTAssertFalse(history.seen.contains(RoutePolicy.bindPhone), "\(name)：不进 BindPhone。\(detail(opened, history))")
        XCTAssertEqual(top(opened), WalletRoutes.realName, "\(name)：按已绑进 RealName。\(detail(opened, history))")
    }

    // MARK: - 第 6 条：同进程短信登录后的对照

    /// 第 6 条：游客走一遍真实短信登录（生产 LoginViewModel + LoginService，假服务回登录成功），同进程直接进钱包点【提现】→ 不进
    /// BindPhone（短信登录记已绑），进 RealName。74b66f3 起就绿：同进程路径一直正常，坏的只是冷启动态。
    func testInProcessSmsLoginThenWithdrawSkipsBindPhone() async throws {
        let name = "第 6 条（同进程短信登录）"
        script.on("GET /v1/me", Self.unverified)
        script.ok("POST /v1/auth/login/sms", Self.smsLogin)
        script.ok("GET /v1/wallet/summary", Self.zeroBalance)
        let fixture = make()
        try await smsLoginFromGuest(fixture, name)
        let opened = try await openLoggedInWallet(fixture, name)
        let history = RouteHistory(fixture.router)
        tapWithdraw(opened)
        await settleQueryAndBindPhone(opened, name)
        XCTAssertEqual(top(opened), WalletRoutes.realName, "\(name)：栈顶应是 RealName。\(detail(opened, history))")
        XCTAssertFalse(history.seen.contains(RoutePolicy.bindPhone), "\(name)：不进 BindPhone。\(detail(opened, history))")
        XCTAssertEqual(meRequests(opened).count, 1, "\(name)：GET /v1/me 只 1 次。\(detail(opened, history))")
    }

    // MARK: - 搭法

    /// 打开钱包页（GET /v1/me 按 `me` 回答）后把手机绑定状态还原成冷启动的未知，并开始记录栈历史。
    private func openWithUnknownPhone(_ me: WalletStubProtocol.Reply, file: StaticString = #filePath,
                                      line: UInt = #line) async throws -> (Opened, RouteHistory) {
        script.on("GET /v1/me", me)
        let opened = try await openWallet(file: file, line: line)
        forgetPhoneBinding(opened.fixture, file: file, line: line)
        return (opened, RouteHistory(opened.fixture.router))
    }

    /// 冷启动态：PhoneBindingStore 没有记录（只在内存，进程重启后即如此）。登录世代来源暂时给 nil 时 record 会清空记录，随后恢复来源。
    private func forgetPhoneBinding(_ fixture: WalletAppFixture, file: StaticString = #filePath, line: UInt = #line) {
        let store = fixture.login.phone
        let source = store.loginEpoch
        store.loginEpoch = { _ in nil }
        store.record(true, generation: fixture.network.client.sessionGeneration)
        store.loginEpoch = source
        XCTAssertNil(phoneBound(fixture), "前提：手机绑定状态未知（冷启动态）", file: file, line: line)
        XCTAssertEqual(fixture.routing.guardState.session, .loggedIn, "前提：守卫按已登录未绑手机", file: file, line: line)
    }

    private func phoneBound(_ fixture: WalletAppFixture) -> Bool? {
        fixture.login.phone.bound(generation: fixture.network.client.sessionGeneration)
    }

    /// 照 BindPhoneView.onAppear：栈顶是 BindPhone 时建页并调 `appeared()`（进页自查手机号状态）。
    private func renderTopBindPhone(_ fixture: WalletAppFixture) {
        guard let top = fixture.router.path.last, top.route == RoutePolicy.bindPhone else { return }
        fixture.login.bindEntry(for: top).controller.appeared()
    }

    /// 等实名查询结论到达（成功回包都会写实名结论）→ 栈顶若是 BindPhone 就让它进页自查 → 观察窗（自查查询与出栈都落定）。
    private func settleQueryAndBindPhone(_ opened: Opened, _ name: String, file: StaticString = #filePath,
                                         line: UInt = #line) async {
        await waitUntil("\(name)：实名查询结论没有到", file: file, line: line) {
            opened.fixture.wallet.realnameState != nil
        }
        await settle()
        renderTopBindPhone(opened.fixture)
        await quietWindow()
    }

    private func detail(_ opened: Opened, _ history: RouteHistory) -> String {
        let bound = phoneBound(opened.fixture).map { "\($0)" } ?? "未知"
        return observed(opened) + " 栈历史=\(history.seen) phone_bound 存储=\(bound) "
            + "守卫会话=\(opened.fixture.routing.guardState.session.rawValue)"
    }

    /// 第 4 条判据：回包 phone_bound 不是严格布尔 → 存储保持未知、守卫仍按已登录未绑手机。
    private func assertStaysUnknown(_ me: String, _ name: String, file: StaticString = #filePath,
                                    line: UInt = #line) async throws {
        let (opened, history) = try await openWithUnknownPhone(.envelope(code: 0, data: me, headers: [:]),
                                                               file: file, line: line)
        tapWithdraw(opened)
        await waitUntil("\(name)：实名查询结论没有到", file: file, line: line) {
            opened.fixture.wallet.realnameState != nil
        }
        await quietWindow()
        XCTAssertNil(phoneBound(opened.fixture), "\(name)：不得写成已知。\(detail(opened, history))", file: file, line: line)
        XCTAssertEqual(opened.fixture.routing.guardState.session, .loggedIn, "\(name)：守卫会话。\(detail(opened, history))",
                       file: file, line: line)
    }

    /// 退出夹具的 user-a，以游客打开 Login，走生产 LoginViewModel 的短信登录，等登录页关闭、短信登录记下已绑。
    private func smsLoginFromGuest(_ fixture: WalletAppFixture, _ name: String) async throws {
        fixture.network.client.signOut()
        fixture.routing.sessionStateChanged(resumePending: false)
        XCTAssertNil(fixture.network.client.isolatedSessionScope, "\(name) 前提：游客")
        fixture.router.open(RouteRequest(route: RoutePolicy.login, from: .inApp))
        XCTAssertEqual(fixture.router.path.last?.route, RoutePolicy.login, "\(name) 前提：进登录页")
        let model = LoginViewModel(config: fixture.login.pageConfig(restricted: false))
        model.setPhone("13800138000")
        model.toggleAgreement()
        model.requestCode()
        await waitUntil("\(name)：没有进验证码步") { model.step == .code }
        model.setCode("123456")
        model.submit()
        await waitUntil("\(name)：短信登录没有结算") {
            !model.submitting && fixture.network.client.isolatedSessionScope == SessionScope.full
        }
        await waitUntil("\(name)：登录页没有关闭") { !fixture.router.path.contains { $0.route == RoutePolicy.login } }
        await settle()
        XCTAssertEqual(phoneBound(fixture), true, "\(name) 前提：短信登录记已绑")
    }

    /// 登录后清空栈、打开钱包页并等摘要到位且可见（同 `openWallet` 的前提核对）。
    private func openLoggedInWallet(_ fixture: WalletAppFixture, _ name: String) async throws -> Opened {
        fixture.router.path.removeAll()
        let entry = try XCTUnwrap(fixture.open(WalletRoutes.wallet), "\(name)：钱包没有打开")
        let origin = try XCTUnwrap(fixture.router.path.last?.id)
        let controller = try XCTUnwrap(entry.controller as? WalletController)
        controller.load()
        await waitUntil("\(name)：钱包摘要没有加载") { controller.state.phase == .content }
        await waitUntil("\(name)：钱包页没有变为可见") { fixture.wallet.lastVisible[origin] == true }
        await settle()
        XCTAssertTrue(controller.state.withdrawEnabled, "\(name) 前提：【提现】可点")
        XCTAssertTrue(fixture.wallet.realnameState == nil, "\(name) 前提：本会话还没查过实名")
        let baseline = WalletStubProtocol.requests.map(\.id).max() ?? 0
        return Opened(fixture: fixture, entry: entry, controller: controller, origin: origin, baseline: baseline)
    }
}
