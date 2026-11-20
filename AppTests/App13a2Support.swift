import ClientCore
import Clipboard
import Config
@testable import Couli
import CouliNetwork
import Foundation
import Generated
import Login
import Me
import MeCore
import Privacy
import Push
import Router
import Session
import Update
import Wallet
import WalletCore
import XCTest

/// APP-13a-2-ios 写测（独立写测方 r1）的 App 组合：AppNetwork + AppRouting + AppLogin + AppMe + AppWallet 共用一个真实 ApiClient（签名、
/// 幂等、x-step-up、未决键、发送前闸门、固定归属），传输层换成本地 WalletStubProtocol 假服务；接线照 CouliApp.makeAccount（钱包客服出口、
/// getMe 共用读取闸门、`login.connect(wallet:)`）再加本单的 `me.connect(wallet:)`。换号入口在 Debug 用 `phoneChangeOverride` 打开
/// （D10-2203 ⑤：Release 由 PhoneChangeEntry.sinceIOS 关）。未决记录后端由测试持有（T9：同时断言存储记录与请求头，共性第 7 条）。
@MainActor
struct App13a2Fixture {
    let me: AppMe
    let wallet: AppWallet
    let login: AppLogin
    let routing: AppRouting
    let network: AppNetwork
    let tokens: MemorySessionTokens
    let pending: MemoryPendingKeyBackend
    let system: FakeMeSystem

    var router: Router {
        routing.router
    }

    var client: ApiClient {
        network.client
    }

    var bind: BindPhoneService {
        login.bind
    }

    private struct Device: DeviceCredentials {
        var deviceId: String? = "device-fixture-0001"
        var installSecret: String? = "test-only.install.device-a"
    }

    static func make(
        suiteName: String, defaults: UserDefaults, account: String, scope: String,
        pending: MemoryPendingKeyBackend, phoneChange: Bool?
    ) -> App13a2Fixture {
        let tokens = MemorySessionTokens()
        try? tokens.save(
            access: "at-\(account)", refresh: "rt-\(account)", scope: scope, account: account,
            loginEpoch: "fixture-login-\(account)"
        )
        let privacyStore = MemoryPrivacyStore()
        privacyStore.decisionRaw = "consented"
        privacyStore.consentedVersion = "1"
        let withdrawal = EnvironmentSwitchCleanerRegistry(cleaners: [SessionTokensCleaner(tokens: tokens)])
        let environmentSwitch = EnvironmentSwitchCleanerRegistry(cleaners: [SessionTokensCleaner(tokens: tokens)])
        let runner = WithdrawalCleanupRunner(store: privacyStore, registry: withdrawal)
        let network = AppNetwork(
            tokens: CountingSessionTokens(tokens), pendingBackend: pending, device: Device(),
            withdrawalRegistry: withdrawal, environmentRegistry: environmentSwitch,
            credentialsReadable: { runner.credentialsReadable }, configuration: WalletStubProtocol.configuration()
        )
        let update = UpdateFixtures.makeUpdate(checker: StubUpdateChecker(.success(UpdateFixtures.ok)))
        let environment = EnvironmentStore(defaultEnvironment: .test, defaults: defaults, registry: environmentSwitch)
        let privacy = PrivacyController(
            store: privacyStore, clock: { 1 }, bundledPolicyVersion: "1", withdrawalRunner: runner
        )
        let routing = AppRouting(environment: environment, privacy: privacy, update: update)
        let config = AppConfig(
            client: network.client, file: ClientFile(name: suiteName + ".config.json"),
            environmentRegistry: environmentSwitch
        )
        let login = AppLogin(network: network, routing: routing, update: update)
        network.attach(environment: environment, privacy: privacy, update: update)
        // 短信登录的账号（一定绑了手机号）：守卫与二次验证面板按已绑手机
        login.phone.record(true, generation: network.client.sessionGeneration)
        routing.shellAppeared()
        let localFile = FlakyMeFile(ClientFile(
            name: MeLocalStore.fileName, baseDirectory: MeAppFixture.localDirectory(suiteName)
        ))
        let local = MeLocalStore(file: localFile, pending: localFile.sibling(MeLocalStore.pendingFileName))
        let system = FakeMeSystem()
        let mask = AmountMaskStore(defaults: defaults)
        let me = AppMe(
            network: network, routing: routing, config: config, login: login, update: update, system: system,
            mask: mask, local: local, pushSource: TestPushSource(token: nil),
            credentialsReadable: { runner.credentialsReadable }, withdrawalRegistry: withdrawal,
            environmentRegistry: environmentSwitch
        )
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(suiteName + "/wallet")
        let cleaner = WalletCacheCleaner(store: WalletCacheStore(root: root, flag: nil))
        let wallet = AppWallet(
            network: network, config: config, routing: routing, login: login, mask: mask, cleaner: cleaner,
            credentialsReadable: { runner.credentialsReadable }
        )
        wallet.phoneProvider = { _ in "13800005678" }
        // 照 CouliApp.makeAccount 接线
        let open: @MainActor (String) -> Void = { [weak me] route in me?.cs.open(from: route) }
        wallet.customerService = open
        wallet.meReadGate = me.gates.read
        login.phoneSync.readGate = me.gates.read
        login.connect(wallet: wallet)
        me.connect(wallet: wallet)
        me.phoneChangeOverride = phoneChange
        return App13a2Fixture(
            me: me, wallet: wallet, login: login, routing: routing, network: network, tokens: tokens,
            pending: pending, system: system
        )
    }
}

/// 换号用例的公共部分（MeTestCase：每个用例独立的 UserDefaults 套件与假服务脚本，GET /v1/me 缺省 phone_bound=true）。
@MainActor
class App13a2TestCase: MeTestCase {
    static let account = "user-a"
    static let bindWrite = "POST /v1/me/phone"
    static let smsSend = "POST /v1/auth/sms-codes"
    static let stepUpVerify = "POST /v1/auth/step-up"
    static let abandonWrite = "POST /v1/idempotency-keys/abandon"
    static let meRead = "GET /v1/me"
    static let newPhone = "13900001234"
    static let newMasked = "139****1234"
    static let oldBody = "{\"action\":\"phone_change\",\"purpose\":\"step_up\"}"
    static let stepToken = "tok-step1"
    static let panelToken = "tok-panel"

    var backend = MemoryPendingKeyBackend()

    override func setUpWithError() throws {
        try super.setUpWithError()
        backend = MemoryPendingKeyBackend()
        script.on(Self.stepUpVerify, Self.token(Self.stepToken), Self.token(Self.panelToken))
    }

    func fixture(phoneChange: Bool? = true, scope: String = "full") -> App13a2Fixture {
        App13a2Fixture.make(
            suiteName: suiteName, defaults: defaults, account: Self.account, scope: scope, pending: backend,
            phoneChange: phoneChange
        )
    }

    // MARK: - 假服务

    static func token(_ value: String) -> WalletStubProtocol.Reply {
        .envelope(code: 0, data: "{\"step_up_token\":\"\(value)\",\"expire_at\":\"2099-01-01T00:05:00+08:00\"}",
                  headers: [:])
    }

    static func code(_ code: Int, _ data: String = "null", headers: [String: String] = [:])
        -> WalletStubProtocol.Reply {
        .envelope(code: code, data: data, headers: headers)
    }

    static func retryAfter(_ seconds: Int) -> WalletStubProtocol.Reply {
        .envelope(code: 42901, data: "null", headers: ["Retry-After": "\(seconds)"])
    }

    func sent(_ key: String) -> [WalletStubProtocol.Recorded] {
        let parts = key.split(separator: " ", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return [] }
        return WalletStubProtocol.requests(parts[0], parts[1])
    }

    var binds: [WalletStubProtocol.Recorded] {
        sent(Self.bindWrite)
    }

    var stepSms: [WalletStubProtocol.Recorded] {
        sent(Self.smsSend).filter { $0.json["purpose"] as? String == "step_up" }
    }

    var bindSms: [WalletStubProtocol.Recorded] {
        sent(Self.smsSend).filter { $0.json["purpose"] as? String == "bind" }
    }

    func heldId(_ key: String) -> Int? {
        let held = Set(WalletStubProtocol.heldIds)
        return sent(key).map(\.id).last { held.contains($0) }
    }

    /// 本账号 bindPhone 的未决记录（存储原始视图，不经故障注入）。
    func records(_ account: String = App13a2TestCase.account) -> [PendingKeyRecord] {
        backend.list(account: account).filter { $0.operationId == BindPhoneService.operationId }
    }

    /// 结果未知过的 bindPhone 记录（预置：首次绑定或换号留下的都算，G07）。
    func seedUnknown(key: String = "pc-seeded-key-0001", phone: String = App13a2TestCase.newPhone,
                     at millis: Int64 = 1_763_600_000_000) throws {
        try backend.write(PendingKeyRecord(
            key: key, operationId: BindPhoneService.operationId, body: "{\"code\":\"654321\",\"phone\":\"\(phone)\"}",
            account: Self.account, summary: "{\"phone\":\"\(Self.newMasked)\"}", stateRaw: PendingKeyStore.unknown,
            everUnknown: true, createdAtMillis: millis
        ))
    }

    // MARK: - 页面

    /// 经真实 Router 打开设置页、等 Me 到位（手机号行按 phone_bound 取值）。
    func settings(_ fixture: App13a2Fixture) async throws -> SettingsController {
        fixture.router.open(RouteRequest(route: "Settings", from: .inApp))
        let top = try XCTUnwrap(fixture.router.path.last, "设置页没有打开")
        let entry = try XCTUnwrap(fixture.me.entry(for: top))
        entry.appeared()
        let controller = try XCTUnwrap(entry.controller() as? SettingsController)
        await waitUntil("Me 没有到位") {
            fixture.me.deps.repo.state.me != nil || fixture.me.deps.repo.state.phase == .error
        }
        return controller
    }

    func phoneRow(_ settings: SettingsController) throws -> SettingsRow {
        try XCTUnwrap(settings.model().groups.flatMap(\.rows).first { $0.id == SettingsItems.idPhone }, "没有手机号行")
    }

    /// 点「账号与安全 → 手机号」进换号子页（设置页渲染时的回调）。
    func enter(_ fixture: App13a2Fixture) async throws -> (SettingsController, PhoneChangeController) {
        let settings = try await settings(fixture)
        let row = try phoneRow(settings)
        SettingsActions.make(settings, settings.state).row(row)
        let controller = try XCTUnwrap(settings.phoneChange, "点手机号行没有建换号子页")
        XCTAssertEqual(settings.state.sub, .phoneChange)
        await settle()
        return (settings, controller)
    }

    /// 渲染时取出的子页回调。
    func act(_ controller: PhoneChangeController) -> PhoneChangeActions {
        PhoneChangeActions.make(controller, controller.state)
    }

    /// 第 1 步：获取验证码 → 输入 → 【下一步】→ 第 2 步。
    func passStep1(_ controller: PhoneChangeController, code: String = "123456") async {
        let before = stepSms.count
        act(controller).requestOldCode()
        await waitUntil("第 1 步没有发码") { self.stepSms.count > before }
        await waitUntil("第 1 步发码没有回来") { !controller.state.oldSending }
        act(controller).oldCode(code)
        act(controller).next()
        await waitUntil("没有进入第 2 步") { controller.state.step == .step2 }
    }

    /// 第 2 步填新号与验证码（不发码；提交只看「6 位 + 新号非空」）。
    func fillStep2(_ controller: PhoneChangeController, phone: String = App13a2TestCase.newPhone,
                   code: String = "654321") {
        act(controller).newPhone(phone)
        act(controller).newCode(code)
    }

    /// 第 1 步 + 第 2 步填好，停在【提交】可点。
    func readyToSubmit(_ fixture: App13a2Fixture, phone: String = App13a2TestCase.newPhone) async throws
        -> (SettingsController, PhoneChangeController) {
        let (settings, controller) = try await enter(fixture)
        await passStep1(controller)
        fillStep2(controller, phone: phone)
        XCTAssertTrue(controller.submitEnabled, "前提：【提交】可点")
        return (settings, controller)
    }

    /// 点【提交】并等它到达假服务。
    func submit(_ controller: PhoneChangeController) async {
        let before = binds.count
        act(controller).submit()
        await waitUntil("提交没有发出") { self.binds.count > before }
    }

    /// 提交得到无外壳的断连 → 结果未知 → 待确认卡。
    func enterPending(_ fixture: App13a2Fixture) async throws -> (SettingsController, PhoneChangeController) {
        script.on(Self.bindWrite, .disconnect)
        let (settings, controller) = try await readyToSubmit(fixture)
        await submit(controller)
        await waitUntil("没有进入待确认") { controller.state.step == .pending && controller.state.pending != nil }
        return (settings, controller)
    }

    /// 页面上所有提示的文案键（字段提示、页内提示、待确认提示）。
    func keys(_ state: PhoneChangeState) -> [String] {
        [state.oldError, state.phoneError, state.codeError, state.notice, state.pendingNotice].compactMap { $0?.key }
    }

    /// 换账号（登出后另一个账号登录；会话世代 +1），走 App 的会话同步出口。
    func switchAccount(_ fixture: App13a2Fixture, to account: String) throws {
        fixture.client.signOut()
        try fixture.tokens.save(access: "at-\(account)", refresh: "rt-\(account)", scope: "full", account: account,
                                loginEpoch: "fixture-login-\(account)")
        fixture.login.phone.record(true, generation: fixture.client.sessionGeneration)
        fixture.routing.sessionStateChanged(resumePending: false)
    }

    /// 同账号、同登录世代只换作用域（不登出），走会话同步出口。
    func switchScope(_ fixture: App13a2Fixture, to scope: String) throws {
        try fixture.tokens.save(access: "at-\(Self.account)", refresh: "rt-\(Self.account)", scope: scope,
                                account: Self.account, loginEpoch: "fixture-login-\(Self.account)")
        fixture.routing.sessionStateChanged(resumePending: false)
        fixture.wallet.checkSession()
    }
}
