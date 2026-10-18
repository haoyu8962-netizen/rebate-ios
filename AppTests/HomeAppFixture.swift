import ClientCore
import Combine
import Config
@testable import Couli
import CouliNetwork
import Foundation
import Generated
import HomeCore
import Privacy
import Router
import Session
import SwiftUI
import Update
import XCTest

/// 首页的 App 接线测试组合（AppNetwork + AppRouting + AppLogin + AppConfig + AppUpdate + PrivacyController + EnvironmentStore +
/// AppHome；
/// 本地 WalletStubProtocol 假服务回答契约接口 listArticles / previewPage / getConfig）。全部经真实 Router、真实 ApiClient、真实隐私闸门与
/// 清理注册表；只把传输层、待定 operation 端口（G02、G03：getPage / listSectionItems）、图片加载、时钟换成本地替身。
@MainActor
struct HomeAppFixture {
    let home: AppHome
    let routing: AppRouting
    let network: AppNetwork
    let login: AppLogin
    let config: AppConfig
    let update: AppUpdate
    let privacy: PrivacyController
    let privacyStore: MemoryPrivacyStore
    let environment: EnvironmentStore
    let tokens: MemorySessionTokens
    let store: CountingSessionTokens
    let withdrawal: EnvironmentSwitchCleanerRegistry
    let environmentSwitch: EnvironmentSwitchCleanerRegistry
    let runner: WithdrawalCleanupRunner
    let port: TestHomePort
    let images: TestHomeImages
    let clock: TestHomeClock
    let storage: HomeStorage
    let events: TrackRecorder

    var router: Router {
        routing.router
    }

    var client: ApiClient {
        network.client
    }

    var controller: HomeController {
        home.controller
    }

    private struct Device: DeviceCredentials {
        var deviceId: String? = "device-fixture-0001"
        var installSecret: String? = "test-only.install.device-a"
    }

    /// `account` 为 nil 时是游客；`decision` 为 basic_mode 时是基本模式。`storageRoot` 相同的两次组合模拟「重启」（同一份本机数据）。
    static func make(
        suiteName: String, defaults: UserDefaults, storageRoot: URL, account: String? = "user-a",
        decision: String = "consented",
        update checker: StubUpdateChecker = StubUpdateChecker(.success(UpdateFixtures.ok)),
        port: TestHomePort = TestHomePort(), clock: TestHomeClock = TestHomeClock(),
        bundled: @escaping @MainActor () -> Data? = { HomeBundled.data() }, variant: HomeBuildVariant = .debug,
        portLookups: PortLookups = PortLookups()
    ) -> HomeAppFixture {
        let (tokens, privacyStore) = session(account: account, decision: decision)
        let withdrawal = EnvironmentSwitchCleanerRegistry(cleaners: [SessionTokensCleaner(tokens: tokens)])
        let environmentSwitch = EnvironmentSwitchCleanerRegistry(cleaners: [SessionTokensCleaner(tokens: tokens)])
        let runner = WithdrawalCleanupRunner(store: privacyStore, registry: withdrawal)
        let store = CountingSessionTokens(tokens)
        let network = AppNetwork(
            tokens: store, pendingBackend: MemoryPendingKeyBackend(), device: Device(), withdrawalRegistry: withdrawal,
            environmentRegistry: environmentSwitch, credentialsReadable: { runner.credentialsReadable },
            configuration: WalletStubProtocol.configuration()
        )
        let update = UpdateFixtures.makeUpdate(checker: checker)
        let environment = EnvironmentStore(defaultEnvironment: .test, defaults: defaults, registry: environmentSwitch)
        let privacy = PrivacyController(
            store: privacyStore, clock: { 1 }, bundledPolicyVersion: "1", withdrawalRunner: runner, pushStart: {}
        )
        let routing = AppRouting(environment: environment, privacy: privacy, update: update)
        let config = AppConfig(
            client: network.client, file: ClientFile(name: suiteName + ".config.json"),
            environmentRegistry: environmentSwitch
        )
        let login = AppLogin(network: network, routing: routing, update: update)
        network.attach(environment: environment, privacy: privacy, update: update)
        if account != nil {
            login.phone.record(true, generation: network.client.sessionGeneration)
        }
        routing.shellAppeared()
        let storage = storage(storageRoot, defaults, withdrawal: withdrawal, environmentSwitch: environmentSwitch)
        let images = TestHomeImages()
        let events = TrackRecorder()
        // 经生产工厂按构建变体装配（Debug 变体用测试端口替身；Release 变体工厂不得来要端口，评审 T-12）
        let home = AppHome.make(
            network: network, routing: routing, config: config, login: login, update: update, privacy: privacy,
            environment: environment, variant: variant, debugPort: { portLookups.count += 1
                return port
            }, storage: storage, timers: clock, clock: clock.clock, images: images, bundled: bundled,
            appVersion: "1.10.0", credentialsReadable: { runner.credentialsReadable }
        )
        home.track = { events.events.append($0) }
        return HomeAppFixture(
            home: home, routing: routing, network: network, login: login, config: config, update: update,
            privacy: privacy, privacyStore: privacyStore, environment: environment, tokens: tokens, store: store,
            withdrawal: withdrawal, environmentSwitch: environmentSwitch, runner: runner, port: port, images: images,
            clock: clock, storage: storage, events: events
        )
    }

    /// 会话令牌与本机隐私决定。
    private static func session(account: String?, decision: String) -> (MemorySessionTokens, MemoryPrivacyStore) {
        let tokens = account.map {
            MemorySessionTokens(access: "at-\($0)", refresh: "rt-\($0)", scope: "full", account: $0)
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

    /// 本机数据：生产存储类型、生产清理器，登记进本组合的撤回同意与切换环境注册表（与 CouliApp 的启动前登记同一个入口）。
    private static func storage(
        _ root: URL, _ defaults: UserDefaults, withdrawal: EnvironmentSwitchCleanerRegistry,
        environmentSwitch: EnvironmentSwitchCleanerRegistry
    ) -> HomeStorage {
        let storage = HomeStorage(
            lkg: HomeLkgStore(root: root.appendingPathComponent(HomeLkgStore.directoryName, isDirectory: true)),
            prefs: HomePrefsStore(defaults: defaults)
        )
        HomeDataCleaner.register(
            HomeDataCleaner(storage: storage),
            withdrawal: withdrawal,
            environmentSwitch: environmentSwitch
        )
        return storage
    }

    /// 换账号（登出后另一个账号登录；会话世代 +1），经 AppLogin 的会话状态出口通知（各模块据此换代）。
    func switchAccount(to account: String) throws {
        client.signOut()
        try tokens.save(access: "at-\(account)", refresh: "rt-\(account)", scope: "full", account: account)
        login.phone.record(true, generation: client.sessionGeneration)
        routing.sessionStateChanged(resumePending: false)
    }

    /// 会话失效 / 退出登录（本地会话清掉，变成游客）。
    func endSession() {
        client.signOut()
        routing.sessionStateChanged(resumePending: false)
    }

    /// 首页当前控制器换成某个身份（重建完成；正向等待）。
    func waitForController(account: String?, level: HomeLevel, _ message: String = "首页控制器没有按新身份重建") async {
        await waitUntil(message) {
            home.controller.identity.userId == account && home.controller.identity.level == level
        }
    }

    /// 冷启动：首页 Tab 出现（生产入口）并等这一轮已发起的任务结算。
    func launch() async {
        home.tabAppeared()
        await home.controller.whenIdle()
    }

    func open(_ route: String, params: [String: JSONValue] = [:]) {
        router.open(RouteRequest(route: route, values: params, from: .inApp))
    }

    func lkgVersion(_ identity: HomeIdentity) -> Int? {
        guard let key = identity.lkgScope, let data = storage.lkg.read(key),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return object["version"] as? Int
    }
}

/// 生产工厂来要 Debug 端口的次数（Release 变体必须为 0）。
@MainActor
final class PortLookups {
    var count = 0
}

/// 首页 App 测试的公共部分：每个用例一个独立组合（UserDefaults 套件、本机数据目录），本地假服务按脚本回答。
@MainActor
class HomeAppTestCase: XCTestCase {
    var suiteName = ""
    var defaults: UserDefaults!
    var storageRoot: URL!
    let script = WalletScript()

    override func setUpWithError() throws {
        suiteName = "\(type(of: self)).\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        storageRoot = FileManager.default.temporaryDirectory.appendingPathComponent("home-app-\(UUID().uuidString)")
        WalletStubProtocol.reset()
        script.ok("GET /v1/config", MeSamples.config)
        script.ok("GET /v1/articles", HomeAppSamples.notices)
        script.ok("POST /v1/auth/logout", "{}")
        script.install()
    }

    override func tearDown() {
        UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: storageRoot.path)
        try? FileManager.default.removeItem(at: storageRoot)
        WalletStubProtocol.reset()
    }

    func make(
        account: String? = "user-a", decision: String = "consented",
        update: StubUpdateChecker = StubUpdateChecker(.success(UpdateFixtures.ok)), port: TestHomePort = TestHomePort(),
        bundled: @escaping @MainActor () -> Data? = { HomeBundled.data() }, variant: HomeBuildVariant = .debug,
        portLookups: PortLookups = PortLookups()
    ) -> HomeAppFixture {
        HomeAppFixture.make(
            suiteName: suiteName, defaults: defaults, storageRoot: storageRoot, account: account, decision: decision,
            update: update, port: port, bundled: bundled, variant: variant, portLookups: portLookups
        )
    }

    func requests(_ method: String, _ path: String) -> [WalletStubProtocol.Recorded] {
        WalletStubProtocol.requests(method, path)
    }
}

enum HomeAppSamples {
    static let notices = MeSamples.json([
        "items": [[
            "article_id": "a1", "category": "notice", "title": "t", "version": 1,
            "published_at": "2026-10-01T00:00:00+08:00",
            "notice": [
                "item_id": "api1", "content_version": 1, "text": "确认收货后，返利随联盟月度结算入账", "target": NSNull(),
                "closable": true, "start_at": "2026-10-01T00:00:00+08:00", "end_at": NSNull(),
            ],
        ]],
        "next_cursor": NSNull(),
    ])

    static func notice(_ id: String, item: String, version: Int = 1) -> [String: Any] {
        [
            "id": id, "type": "notice_bar", "version": 1,
            "props": ["items": [[
                "item_id": item, "content_version": version, "text": "测试公告", "target": NSNull(), "closable": true,
                "start_at": "2026-10-01T00:00:00+08:00", "end_at": NSNull(),
            ]]],
            "data_source": ["kind": "static"],
        ]
    }

    static func popup(action: [String: Any] = ["route": "AuthSheet", "params": ["platform": "taobao"]])
        -> [String: Any] {
        [
            "id": "popup", "type": "popup", "version": 1,
            "props": ["image": "https://img.example.com/popup.png", "daily_max": 1, "time_window": ["09:00", "22:00"]],
            "data_source": ["kind": "static", "items": [["action": action]]],
        ]
    }

    static func activity(_ id: String, action: [String: Any]) -> [String: Any] {
        [
            "id": id, "type": "activity_entry", "version": 1, "props": [:] as [String: Any],
            "data_source": ["kind": "static", "items": [["title": "测试\(id)", "action": action]]],
        ]
    }

    static func vectors() throws -> [String: Any] {
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while !FileManager.default.fileExists(atPath: directory.appendingPathComponent("contract.lock").path) {
            directory = directory.deletingLastPathComponent()
        }
        let data = try Data(contentsOf: directory.appendingPathComponent("specs/home-sdui-vectors.json"))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}

extension HomeUiState {
    func section(_ id: String) -> HomeSectionUi? {
        sections.first { $0.id == id }
    }

    var sectionIds: [String] {
        sections.map(\.id)
    }
}
