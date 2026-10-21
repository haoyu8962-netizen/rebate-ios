import ClientCore
import Clipboard
@testable import Couli
import CouliNetwork
import Foundation
import Login
import Me
import MeCore
import Privacy
import Router
import SwiftUI
import XCTest

/// APP-17c-ios（对标鸿蒙 HM-13c）App 接线：待绑定码在整个进程里只有一份（G21）——剪贴板确认、邀请链接分流、登录页小字行、短信登录
/// 请求、第三方登录与绑手机都用同一个容器。
///
/// 组合：真实 AppNetwork + AppRouting + AppLogin + AppConfig + AppMe（MeAppFixture，本地 WalletStubProtocol 假服务按请求同步记录），
/// 剪贴板走生产组装 `AppClipboard.make(...)`，并照 CouliApp 接上 `login.clipboard`；只替换系统剪贴板（FakeSystemClipboard）与剪贴板
/// 记录文件位置。登录页状态取生产 `LoginViewModel(config: login.pageConfig(restricted:))`。负向断言都在结算之后；等待都是条件等待。
@MainActor
final class PendingInviteApp17cWiringTests: MeTestCase {
    /// 测试用码（不与样例数据的本人码 K7M3QX 相同）。
    let codeK = "K7M2QX"
    private let codeT = "T3ST22"
    private let codeW = "W4XY56"
    private let codeQ = "Q8R5TZ"

    private static let attempt = "{\"attempt_id\":\"att-1\",\"nonce\":\"nonce-for-test-0001\","
        + "\"expire_at\":\"2099-01-01T00:10:00+08:00\"}"

    private static func login(_ account: String, isNew: Bool, bind: String? = nil) -> String {
        let invite = bind.map { ",\"invite_bind\":\($0)" } ?? ""
        return "{\"user_id\":\"\(account)\",\"is_new_user\":\(isNew),\"tokens\":{\"access_token\":\"at-\(account)\","
            + "\"refresh_token\":\"rt-\(account)\",\"session_scope\":\"full\"}\(invite)}"
    }

    override func setUpWithError() throws {
        try super.setUpWithError()
        UserDefaultsPendingBackend().delete()
        script.ok("POST /v1/auth/oauth-attempts", Self.attempt)
        script.ok("POST /v1/auth/login/wechat", Self.login("user-oauth", isNew: true))
        script.ok("POST /v1/auth/login/sms", Self.login("user-sms", isNew: true,
                                                        bind: "{\"result\":\"bound\",\"code\":null}"))
        script.ok("POST /v1/auth/sms-codes", "{\"resend_after_sec\":60,\"expires_in_sec\":300}")
        script.ok("POST /v1/me/phone", "{}")
        script.install()
    }

    override func tearDown() {
        UserDefaultsPendingBackend().delete()
        try? FileManager.default.removeItem(at: recordsDirectory)
        super.tearDown()
    }

    private var recordsDirectory: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("app17c-clip-" + suiteName, isDirectory: true)
    }

    struct Shell {
        let fixture: MeAppFixture
        let clipboard: AppClipboard
        let system: FakeSystemClipboard
    }

    /// 生产组装（CouliApp.makeShopping 的同一入口）：AppLogin 先于剪贴板构造，`AppClipboard.make` 接上，再 `login.clipboard = clipboard`。
    func shell(account: String? = nil, registered: Bool = true, wireEnvironmentSwitch: Bool = false) -> Shell {
        let fixture = make(account: account, registered: registered)
        let records = ClipboardRecordsCleaner(store: ClipboardFileStore(
            file: ClientFile(name: "records.json", baseDirectory: recordsDirectory)
        ))
        let system = FakeSystemClipboard()
        let clipboard = AppClipboard.make(
            network: fixture.network, routing: fixture.routing, privacy: fixture.routing.privacy,
            config: fixture.config,
            login: fixture.login, system: system, records: records
        )
        if wireEnvironmentSwitch {
            // make 默认登记全局注册表；本用例通过同一生产 connect 入口接到组合自带的独立注册表。
            clipboard.connect(privacy: fixture.routing.privacy, login: fixture.login, records: records,
                              environmentRegistry: fixture.environmentSwitch)
        }
        fixture.login.clipboard = clipboard
        clipboard.sceneActive()
        return Shell(fixture: fixture, clipboard: clipboard, system: system)
    }

    /// 游客在首页手动粘贴一段邀请文案并点邀请提示条的确认（生产入口 pasted → confirmInvite）。
    func guestConfirms(_ code: String, in shell: Shell, file: StaticString = #filePath, line: UInt = #line) {
        shell.clipboard.pasted(entry: ManualPasteAction.entryHome, text: "邀请码 \(code) 快来")
        guard let result = shell.clipboard.result, case let .inviteConfirm(found) = result.kind else {
            return XCTFail("游客应出邀请确认", file: file, line: line)
        }
        XCTAssertEqual(found, code, file: file, line: line)
        shell.clipboard.confirmInvite(result.id)
    }

    /// 确认入口的结算信号（第 2 版，review r1 S1-1）：`confirmInvite` 是同步入口，返回时结果条已清；剪贴板没有留下任何在途工作
    /// （任务表为空、不忙、没有未交付的系统读取）。确认后的负向断言都在这之后做，不靠固定等待。
    func assertConfirmSettled(_ app: Shell, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertNil(app.clipboard.result, "确认后结果条已清", file: file, line: line)
        XCTAssertTrue(app.clipboard.tasks.isEmpty, "确认没有留下在途任务", file: file, line: line)
        XCTAssertFalse(app.clipboard.busy, file: file, line: line)
        XCTAssertNil(app.clipboard.reading, file: file, line: line)
    }

    /// 整个用例期间（在明确结算之后调用）：没有任何 parse / 绑定邀请人请求。
    private func assertNoParseOrBindRequests(file: StaticString = #filePath, line: UInt = #line) {
        let paths = WalletStubProtocol.requests.map(\.path)
        XCTAssertFalse(paths.contains("/v1/inputs/parse"), "确认邀请不 parse", file: file, line: line)
        XCTAssertFalse(paths.contains { $0.contains("inviter") }, "不自动绑定", file: file, line: line)
    }

    /// 登录页（生产 pageConfig）的小字行显示的码；没有行为 nil。
    func rowCode(_ fixture: MeAppFixture, restricted: Bool = false) -> String? {
        LoginViewModel(config: fixture.login.pageConfig(restricted: restricted)).pendingInviteRow?.code
    }

    /// 游客点「订单」：守卫登记待办并推入 Login。
    private func openLogin(_ fixture: MeAppFixture, file: StaticString = #filePath, line: UInt = #line) {
        fixture.router.open(RouteRequest(route: "OrderList", from: .inApp))
        XCTAssertEqual(fixture.router.path.last?.route, RoutePolicy.login, "游客进登录页", file: file, line: line)
    }

    /// 在登录页走一次短信登录（生产 LoginViewModel：输号 → 勾选 → 获取验证码 → 输码 → 登录），等登录请求结算。
    private func smsLogin(_ fixture: MeAppFixture) async -> LoginViewModel {
        let model = LoginViewModel(config: fixture.login.pageConfig(restricted: false))
        model.setPhone("13800138000")
        model.toggleAgreement()
        model.requestCode()
        await waitUntil("没有进验证码步") { model.step == .code }
        let before = requests("POST", "/v1/auth/login/sms").count
        model.setCode("123456")
        model.submit()
        await waitUntil("登录请求没有发出") { requests("POST", "/v1/auth/login/sms").count == before + 1 }
        await waitUntil("登录没有结算") { !model.submitting }
        return model
    }

    private func bindEntry(_ fixture: MeAppFixture) throws -> BindPhoneEntry {
        let top = try XCTUnwrap(fixture.router.path.last)
        XCTAssertEqual(top.route, RoutePolicy.bindPhone)
        return fixture.login.bindEntry(for: top)
    }

    // MARK: - AC-S1-63 ①（G19）与 G21

    /// AC-S1-63 ①：游客点确认 → 记为待绑定码，不跳登录页、不发请求；之后进入登录页显示待绑定码提示；短信登录请求带上（只一次），
    /// 带完清除、小字行消失。剪贴板、登录页、登录请求用的是 AppLogin 里同一份容器（G21）。
    func testGuestConfirmRecordsPendingWithoutLoginThenLoginPageShowsAndRequestCarriesIt() async {
        let app = shell()
        let fixture = app.fixture
        XCTAssertTrue(app.clipboard.pendingInvite === fixture.login.pendingInvite, "G21：剪贴板用 AppLogin 的那一份")
        XCTAssertTrue(fixture.login.service.pendingInvite === fixture.login.pendingInvite, "G21：登录请求用同一份")
        let postsBefore = WalletStubProtocol.requests.filter { $0.method == "POST" }.count
        guestConfirms(codeK, in: app)
        assertConfirmSettled(app)
        XCTAssertTrue(fixture.router.path.isEmpty, "不跳登录页（F-CLIP-06、AC-S1-63 ①）")
        XCTAssertEqual(fixture.router.tabRoot.route, "Home")
        XCTAssertEqual(WalletStubProtocol.requests.filter { $0.method == "POST" }.count, postsBefore, "确认不发请求")
        XCTAssertEqual(fixture.login.pendingInvite.peek(), codeK)

        openLogin(fixture)
        XCTAssertEqual(rowCode(fixture), codeK, "登录页显示待绑定码提示")
        XCTAssertNil(rowCode(fixture, restricted: true), "受限登录页不显示（G20）")
        XCTAssertEqual(fixture.login.pendingInvite.peek(), codeK, "显示不消费")

        _ = await smsLogin(fixture)
        let sent = requests("POST", "/v1/auth/login/sms")
        XCTAssertEqual(sent.count, 1)
        XCTAssertEqual(sent.first?.json["invite_code"] as? String, codeK, "随登录请求带上")
        await waitUntil("登录页没有关闭") { !fixture.router.path.contains { $0.route == RoutePolicy.login } }
        XCTAssertNil(fixture.login.pendingInvite.peek(), "提交后清除")
        XCTAssertNil(rowCode(fixture), "小字行消失")
        // 登录请求已结算（上面等到了请求与 submitting 结束）：整段期间确认路径没有发出 parse / 绑定请求，登录只发了一次。
        assertNoParseOrBindRequests()
        XCTAssertEqual(requests("POST", "/v1/auth/login/sms").count, 1)
        XCTAssertTrue(fixture.router.path.allSatisfy { $0.route != RoutePolicy.login })
    }

    /// 剪贴板确认第二个码替换第一个；之后关闭（放弃）第三个提示，不影响已有的待绑定码。
    func testClipboardConfirmReplacesOldAndClosingPromptKeepsPending() throws {
        let app = shell()
        let fixture = app.fixture
        guestConfirms(codeK, in: app)
        guestConfirms(codeT, in: app)
        XCTAssertEqual(rowCode(fixture), codeT, "新码替换旧码")
        app.clipboard.pasted(entry: ManualPasteAction.entryHome, text: "邀请码 \(codeW) 快来")
        let third = try XCTUnwrap(app.clipboard.result)
        app.clipboard.dismissResult(third.id)
        assertConfirmSettled(app)
        XCTAssertEqual(fixture.login.pendingInvite.peek(), codeT, "关闭提示条不动已有待绑定码")
        XCTAssertEqual(rowCode(fixture), codeT)
        XCTAssertTrue(fixture.router.path.isEmpty)
        assertNoParseOrBindRequests()
    }

    /// 有效期为本次进程：登录页出栈（用户关闭登录页）不丢弃；再进登录页仍显示。邀请链接分流写进的就是登录页读的那一份（G21）。
    func testLeavingLoginPageKeepsPendingForProcessLifetime() async {
        let app = shell()
        let fixture = app.fixture
        var opened: [String] = []
        let decision = InviteLinkDispatcher.dispatch(
            InviteLinkInput(rawCode: codeK, consented: true, guest: true, ownCode: nil, eligible: false),
            pending: fixture.login.pendingInvite
        ) { route, _ in
            opened.append(route)
            fixture.router.open(RouteRequest(route: route, from: .inApp))
        }
        XCTAssertEqual(decision.kindRaw, InviteLinkDecision.login)
        XCTAssertEqual(opened, ["Login"])
        XCTAssertEqual(fixture.router.path.last?.route, RoutePolicy.login)
        XCTAssertEqual(rowCode(fixture), codeK, "分流后登录页显示待绑定码")
        let config = fixture.login.pageConfig(restricted: false)
        config.onClose()
        await waitUntil("登录页没有出栈") { !fixture.router.path.contains { $0.route == RoutePolicy.login } }
        XCTAssertFalse(fixture.router.path.contains { $0.route == RoutePolicy.login }, "登录页已出栈")
        XCTAssertEqual(fixture.login.pendingInvite.peek(), codeK, "出栈不丢弃（进程内有效）")
        openLogin(fixture)
        XCTAssertEqual(rowCode(fixture), codeK, "再进登录页仍显示")
        XCTAssertTrue(requests("POST", "/v1/auth/login/sms").isEmpty)
    }

    // MARK: - 撤回同意 / 基本模式 / 普通状态同步

    /// 撤回同意进入基本模式：清掉待绑定码与小字行。对照：普通的会话 / 界面状态同步不清。
    func testWithdrawalToBasicModeClearsPendingButOrdinarySyncDoesNot() async throws {
        let app = shell(registered: false)
        let fixture = app.fixture
        guestConfirms(codeK, in: app)
        fixture.routing.sessionStateChanged(resumePending: false)
        app.clipboard.screenChanged()
        app.clipboard.sceneBackground()
        app.clipboard.sceneActive()
        XCTAssertEqual(fixture.login.pendingInvite.peek(), codeK, "对照：普通状态同步、进出后台不清（同步出口之后）")
        // 明确结算点：再走一次真实网络往返（拉配置，等到配置到位），之后码仍在
        await fixture.loadConfig()
        XCTAssertNotNil(fixture.config.store.value(key: "kf"), "配置已到位")
        XCTAssertEqual(fixture.login.pendingInvite.peek(), codeK, "对照：结算后仍在")
        let entry = try XCTUnwrap(fixture.open("PrivacyCenter"))
        entry.appeared()
        let center = try XCTUnwrap(entry.controller() as? PrivacyCenterController)
        PrivacyCenterActions.make(center, center.state).askWithdraw()
        PrivacyCenterActions.make(center, center.state).confirmWithdraw(try XCTUnwrap(center.state.dialog))
        await waitUntil("没进基本模式") { fixture.me.privacy.state.decision == .basicMode }
        await waitUntil("撤回同意后待绑定码没有清") { fixture.login.pendingInvite.peek() == nil }
        XCTAssertNil(fixture.login.pendingInvite.peek(), "撤回同意 / 基本模式清除待绑定码")
        XCTAssertNil(rowCode(fixture), "小字行消失")
        XCTAssertTrue(requests("POST", "/v1/auth/login/sms").isEmpty)
    }

    // MARK: - 进程重启

    /// 「重启」（同一份本机存储上重新组装整套 App）后待绑定码为空；本机存储（UserDefaults 套件、剪贴板记录、偏好目录）里没有这个码。
    func testProcessRestartStartsEmptyAndNothingPersisted() {
        let first = shell()
        guestConfirms(codeQ, in: first)
        XCTAssertEqual(rowCode(first.fixture), codeQ)
        assertConfirmSettled(first)
        let second = shell()
        XCTAssertNil(second.fixture.login.pendingInvite.peek(), "新进程为空")
        XCTAssertNil(rowCode(second.fixture))
        let stored = (defaults.persistentDomain(forName: suiteName) ?? [:]).description
            + UserDefaults.standard.dictionaryRepresentation().description
        XCTAssertFalse(stored.contains(codeQ), "UserDefaults（套件与 standard）里没有待绑定码")
        for directory in [recordsDirectory, MeAppFixture.localDirectory(suiteName)] {
            let files = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil)?
                .compactMap { $0 as? URL } ?? []
            for file in files {
                let text = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
                XCTAssertFalse(text.contains(codeQ), "\(file.lastPathComponent) 里没有待绑定码")
            }
        }
    }

    // MARK: - 第三方登录（R05）

    /// 第三方（微信）新号登录不消费待绑定码：登录请求与绑手机的发码、绑定请求都不带 invite_code；绑完手机后码仍在
    /// （留给 InviteBackfill 预填，BR-INV-03 细则；预填页属 APP-17b）。
    func testThirdPartyLoginDoesNotConsumeAndCodeSurvivesBindPhone() async throws {
        let app = shell()
        let fixture = app.fixture
        guestConfirms(codeK, in: app)
        let wechat = AppFakeAuthorizer(OAuthProvider.wechat)
        fixture.login.oauth.authorizers = [OAuthProvider.wechat: wechat]
        fixture.router.open(RouteRequest(route: "InviteShare", from: .inApp))
        XCTAssertEqual(fixture.router.path.last?.route, RoutePolicy.login)
        XCTAssertEqual(rowCode(fixture), codeK)
        let model = LoginViewModel(config: fixture.login.pageConfig(restricted: false))
        model.toggleAgreement()
        model.startOAuth(OAuthProvider.wechat)
        await waitUntil("没有拉起授权") { wechat.authorizing }
        XCTAssertTrue(wechat.authorizing)
        wechat.complete(.credential(.wechat(code: "code-from-sdk")))
        await waitUntil("没有弹绑手机引导") { fixture.login.bindGuide != nil }
        let oauthBody = try XCTUnwrap(requests("POST", "/v1/auth/login/wechat").first).json
        XCTAssertNil(oauthBody["invite_code"], "第三方登录接口不收 invite_code")
        XCTAssertEqual(fixture.login.pendingInvite.peek(), codeK, "第三方登录不消费")

        fixture.login.goBindPhone(try XCTUnwrap(fixture.login.bindGuide).id)
        let entry = try bindEntry(fixture)
        let host = HostedPage(AnyView(BindPhoneScreen(entry: entry, texts: fixture.login.texts)))
        defer { host.close() }
        await host.pump()
        let controller = entry.controller
        controller.setPhone("13800138000")
        controller.sendCode()
        await host.pump(until: { controller.resendRemaining > 0 })
        controller.setCode("123456")
        controller.submit()
        await host
            .pump(until: {
                !requests("POST", "/v1/me/phone").isEmpty && fixture.router.path.last?.route == "InviteShare"
            })
        XCTAssertEqual(fixture.router.path.last?.route, "InviteShare", "绑定完成")
        for recorded in requests("POST", "/v1/auth/sms-codes") + requests("POST", "/v1/me/phone") {
            XCTAssertNil(recorded.json["invite_code"], "\(recorded.path) 不带 invite_code")
        }
        XCTAssertTrue(requests("POST", "/v1/auth/login/sms").isEmpty, "没有短信登录")
        XCTAssertEqual(fixture.login.pendingInvite.peek(), codeK, "绑完手机后码仍在（留给 InviteBackfill 预填）")
    }
}
