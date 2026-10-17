import ClientCore
import Clipboard
import Config
@testable import Couli
import CouliNetwork
import Foundation
import Generated
import MeCore
import Privacy
import Push
import Router
import Session
import SwiftUI
import Update
import XCTest

/// 「我的」类页面的 App 接线测试组合（AppNetwork + AppRouting + AppLogin + AppConfig + AppMe；本地 WalletStubProtocol 假服务）。全部经真实
/// Router、真实 ApiClient（签名、幂等、发送前闸门、固定归属）与页面渲染时取出的按钮回调，只把传输层与系统能力换成本地替身。
@MainActor
struct MeAppFixture {
    let me: AppMe
    let routing: AppRouting
    let tokens: MemorySessionTokens
    /// 网络层实际用的令牌存储（包着 `tokens`，记读取次数；FU-IOS-0713 用它让某一次 / 某次起的读取暂时失败）。
    let store: CountingSessionTokens
    /// 「我的」读取入口的透明计数（FU-IOS-0713：生产 `AppMe(api:)` 注入）。
    let api: CountingMeApi
    let network: AppNetwork
    let login: AppLogin
    let config: AppConfig
    let update: AppUpdate
    let privacyStore: MemoryPrivacyStore
    let runner: WithdrawalCleanupRunner
    let withdrawal: EnvironmentSwitchCleanerRegistry
    let environmentSwitch: EnvironmentSwitchCleanerRegistry
    let system: FakeMeSystem
    let push: TestPushSource
    let clipboard: RecordingClipboard
    let ledgerStore: MemoryClipboardHashStore
    let local: MeLocalStore
    /// 偏好文件（测试可让删除 / 写入失败）；作废标记是 `localFile.pendingFile`。
    let localFile: FlakyMeFile
    let nickname: TestNicknameBackend
    let notify: TestNotifyBackend

    var router: Router {
        routing.router
    }

    var client: ApiClient {
        network.client
    }

    private struct Device: DeviceCredentials {
        var deviceId: String? = "device-fixture-0001"
        var installSecret: String? = "test-only.install.device-a"
    }

    /// 会话令牌与本机隐私决定。
    private static func session(account: String?, scope: String, decision: String)
        -> (MemorySessionTokens, MemoryPrivacyStore) {
        let tokens = account.map {
            MemorySessionTokens(access: "at-\($0)", refresh: "rt-\($0)", scope: scope, account: $0)
        } ?? MemorySessionTokens()
        let privacyStore = MemoryPrivacyStore()
        privacyStore.decisionRaw = decision
        if decision == "consented" {
            privacyStore.consentedVersion = "1"
        } else {
            privacyStore.basicMode = true
        }
        return (tokens, privacyStore)
    }

    /// `account` 为 nil 时是游客；`decision` 为 basic_mode 时是基本模式。
    static func make(
        suiteName: String, defaults: UserDefaults, account: String? = "user-a", scope: String = "full",
        decision: String = "consented", pushToken: String? = nil, registered: Bool = true,
        update checker: StubUpdateChecker = StubUpdateChecker(.success(UpdateFixtures.ok)), phoneKnown: Bool = true
    ) -> MeAppFixture {
        let (tokens, privacyStore) = session(account: account, scope: scope, decision: decision)
        let withdrawal = EnvironmentSwitchCleanerRegistry(cleaners: [SessionTokensCleaner(tokens: tokens)])
        let environmentSwitch = EnvironmentSwitchCleanerRegistry(cleaners: [SessionTokensCleaner(tokens: tokens)])
        let runner = WithdrawalCleanupRunner(store: privacyStore, registry: withdrawal)
        let push = TestPushSource(token: pushToken)
        let store = CountingSessionTokens(tokens)
        let network = AppNetwork(
            tokens: store, pendingBackend: MemoryPendingKeyBackend(), device: Device(), withdrawalRegistry: withdrawal,
            environmentRegistry: environmentSwitch, credentialsReadable: { runner.credentialsReadable },
            configuration: WalletStubProtocol.configuration()
        )
        let update = UpdateFixtures.makeUpdate(checker: checker)
        let environment = EnvironmentStore(defaultEnvironment: .test, defaults: defaults, registry: environmentSwitch)
        let privacy = PrivacyController(
            store: privacyStore, clock: { 1 }, bundledPolicyVersion: "1", withdrawalRunner: runner,
            pushStart: { push.start() }
        )
        let routing = AppRouting(environment: environment, privacy: privacy, update: update)
        let config = AppConfig(
            client: network.client, file: ClientFile(name: suiteName + ".config.json"),
            environmentRegistry: environmentSwitch
        )
        let login = AppLogin(network: network, routing: routing, update: update)
        network.attach(environment: environment, privacy: privacy, update: update)
        seedPhoneBound(login, network.client, when: account != nil && phoneKnown)
        routing.shellAppeared()
        let localFile = FlakyMeFile(ClientFile(name: MeLocalStore.fileName, baseDirectory: localDirectory(suiteName)))
        let local = MeLocalStore(file: localFile, pending: localFile.sibling(MeLocalStore.pendingFileName))
        let cleaner = MeLocalCleaner(store: local)
        MeLocalCleaner.register(cleaner, withdrawal: withdrawal)
        let system = FakeMeSystem()
        let (nickname, notify, api) = (TestNicknameBackend(), TestNotifyBackend(), CountingMeApi(network.client))
        let me = AppMe(
            network: network, routing: routing, config: config, login: login, update: update, system: system,
            mask: AmountMaskStore(defaults: defaults), local: local, pushSource: push, nickname: nickname,
            notify: notify,
            credentialsReadable: { runner.credentialsReadable }, withdrawalRegistry: withdrawal,
            environmentRegistry: environmentSwitch, api: api
        )
        me.deviceId = registered ? { "device-fixture-0001" } : { nil }
        let clipboard = RecordingClipboard()
        let ledgerStore = MemoryClipboardHashStore()
        me.writer = ClipboardWriter(system: clipboard, ledger: ClipboardWriteLedger(store: ledgerStore))
        return MeAppFixture(
            me: me, routing: routing, tokens: tokens, store: store, api: api, network: network, login: login,
            config: config, update: update, privacyStore: privacyStore, runner: runner, withdrawal: withdrawal,
            environmentSwitch: environmentSwitch, system: system, push: push, clipboard: clipboard,
            ledgerStore: ledgerStore, local: local, localFile: localFile, nickname: nickname, notify: notify
        )
    }

    /// 已登录的是短信登录的账号（一定绑了手机号）：守卫按已绑手机（APP-05b：phone_bound 未知按未绑，共性第 13 条）。
    private static func seedPhoneBound(_ login: AppLogin, _ client: ApiClient, when seeded: Bool) {
        if seeded {
            login.phone.record(true, generation: client.sessionGeneration)
        }
    }

    /// 本用例的设备级偏好目录（每个用例独立，tearDown 删除）。
    nonisolated static func localDirectory(_ suiteName: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("me-prefs-" + suiteName, isDirectory: true)
    }

    /// 拉一次配置（kf、AI 公示、legal.privacy.version 来自假服务）。
    func loadConfig() async {
        config.startIfSettled(.settled)
        await waitUntil("配置没有拉到") { config.store.value(key: "kf") != nil }
    }

    /// 换账号（登出后另一个账号登录；会话世代 +1），并按 AppLogin 的出口通知（AppMe 据此换代）。
    func switchAccount(to account: String) throws {
        client.signOut()
        try tokens.save(access: "at-\(account)", refresh: "rt-\(account)", scope: "full", account: account)
        login.phone.record(true, generation: client.sessionGeneration)
        routing.sessionStateChanged(resumePending: false)
    }

    /// 真实登录成功的出口：登录页 `onLoggedIn` 在新会话保存之后带此刻的会话世代通知（AppLogin.pageConfig 的同一条路径）。
    func loginCompleted(as account: String) throws {
        client.signOut()
        try tokens.save(access: "at-\(account)", refresh: "rt-\(account)", scope: "full", account: account)
        login.phone.record(true, generation: client.sessionGeneration)
        routing.sessionStateChanged(resumePending: true)
        login.onLoginCompleted?(client.sessionGeneration)
    }

    /// 打开一个路由并取到页面（经真实 Router 与 RouteViewRegistry 同一个入口）。
    func open(_ route: String, params: [String: JSONValue] = [:]) -> MePageEntry? {
        router.open(RouteRequest(route: route, values: params, from: .inApp))
        guard let top = router.path.last, top.route == route else { return nil }
        return me.entry(for: top)
    }

    func controller<T: AnyObject>(_ route: String, as _: T.Type) throws -> T {
        let top = try XCTUnwrap(router.path.last(where: { $0.route == route }), "\(route) 不在栈里")
        let entry = try XCTUnwrap(me.entry(for: top))
        return try XCTUnwrap(entry.controller() as? T)
    }

    /// 切到「我的」Tab（经 Router 的 Tab 选择）并等这一次进入建好执行器。
    func enterMeTab() async -> MeTabController {
        _ = routing.selectTab(.me)
        await settle()
        me.enterTab()
        return me.tabHost.controller
    }
}

/// 样例数据（sample-data §0、§7、§12.3；与 Android / 鸿蒙的假服务同一份）。
enum MeSamples {
    static func me(
        account: String = "user-a", nickname: String = "凑狸用户", invite: String? = "K7M3QX", inviter: Bool = true,
        risk: String = "normal", reason: String? = nil, until: String? = nil, phoneBound: Bool = true
    ) -> String {
        let object: [String: Any] = [
            "user_id": account, "nickname": nickname, "avatar_url": "https://example.test/default.png",
            "invite_code": invite.map { $0 as Any } ?? NSNull(), "inviter_bound": inviter,
            "invite_backfill": ["eligible": false, "deadline_at": NSNull()], "identity_level": "phone",
            "phone_bound": phoneBound,
            "balance": ["available_fen": 1234, "withdrawable_fen": 1234, "estimated_total_fen": 5678],
            "union_bindings": [], "realname_status": "verified", "need_reconsent": false,
            "risk": ["state": risk, "reason_category": reason.map { $0 as Any } ?? NSNull(),
                     "frozen_until": until.map { $0 as Any } ?? NSNull()],
        ]
        return json(object)
    }

    static func appeal(_ status: String, id: String = "test-AP1", closed: Bool = false) -> [String: Any] {
        [
            "appeal_id": id, "target_type": "account", "target_id": NSNull(), "status": status,
            "content": "测试申诉，请核查。", "created_at": "2026-10-10T10:00:00+08:00",
            "closed_at": closed ? "2026-10-11T15:00:00+08:00" : NSNull(),
        ]
    }

    static func appeals(_ items: [[String: Any]]) -> String {
        json(["items": items, "next_cursor": NSNull()])
    }

    static let kf = "https://kf.example.test/kfid/test?x=%2F&entry=config#help"

    static var config: String {
        var object = (try? JSONSerialization.jsonObject(with: Data(DefaultConfig.json.utf8))) as? [String: Any] ?? [:]
        object["kf"] = ["url": kf]
        var agent = object["agent"] as? [String: Any] ?? [:]
        agent["filing_text"] = "测试模型名称\n测试登记编号：TEST-001"
        object["agent"] = agent
        object["legal"] = ["privacy": ["version": 3, "min_version": 1], "agreement": ["version": 1, "min_version": 1]]
        return json(object)
    }

    static func json(_ object: Any) -> String {
        String(bytes: (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data(),
               encoding: .utf8) ?? "{}"
    }
}

/// 「我的」类页面测试的公共部分：每个用例一个独立组合（UserDefaults 套件），本地假服务按脚本回答（缺省给 sample-data 的 Me 与配置）。
@MainActor
class MeTestCase: XCTestCase {
    var suiteName = ""
    var defaults: UserDefaults!
    let script = WalletScript()

    override func setUpWithError() throws {
        suiteName = "\(type(of: self)).\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        WalletStubProtocol.reset()
        script.ok("GET /v1/me", MeSamples.me())
        script.ok("GET /v1/config", MeSamples.config)
        script.ok("GET /v1/me/appeals", MeSamples.appeals([]))
        script.ok("POST /v1/consents", "{}")
        script.ok("POST /v1/devices/push-token", "{}")
        script.ok("DELETE /v1/me/tips/jump_tip", "{}")
        script.ok("POST /v1/auth/logout", "{}")
        script.install()
    }

    override func tearDown() {
        UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: MeAppFixture.localDirectory(suiteName))
        WalletStubProtocol.reset()
    }

    func make(account: String? = "user-a", scope: String = "full", decision: String = "consented",
              pushToken: String? = nil, registered: Bool = true,
              update: StubUpdateChecker = StubUpdateChecker(.success(UpdateFixtures.ok)),
              phoneKnown: Bool = true) -> MeAppFixture {
        MeAppFixture.make(suiteName: suiteName, defaults: defaults, account: account, scope: scope, decision: decision,
                          pushToken: pushToken, registered: registered, update: update, phoneKnown: phoneKnown)
    }

    func requests(_ method: String, _ path: String) -> [WalletStubProtocol.Recorded] {
        WalletStubProtocol.requests(method, path)
    }

    /// 「我的」Tab 进入并等 Me 到位。
    func loadedTab(_ fixture: MeAppFixture) async -> MeTabController {
        let controller = await fixture.enterMeTab()
        await waitUntil("Me 没有到位") {
            fixture.me.deps.repo.state.me != nil || fixture.me.deps.repo.state.phase == .error
        }
        return controller
    }
}
