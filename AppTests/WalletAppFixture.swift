import ClientCore
import Clipboard
import Config
@testable import Couli
import CouliNetwork
import Foundation
import Generated
import OrderCore
import Privacy
import Router
import Session
import Update
import Wallet
import WalletCore
import XCTest

/// 钱包 App 接线测试的组合（AppNetwork + AppRouting + AppLogin + AppWallet；本地 WalletStubProtocol 假服务，已登录 user-a）。全部经真实
/// Router、真实 ApiClient（签名、step-up、幂等、未决键）与页面配置的按钮回调，只把传输层换成本地假服务。
@MainActor
struct WalletAppFixture {
    let wallet: AppWallet
    let routing: AppRouting
    let tokens: MemorySessionTokens
    /// 网络层实际用的令牌存储（包着 `tokens`，记读取次数；末轮窄修二用 `failRead(nth:)` 让某一次读取暂时失败）。
    let store: CountingSessionTokens
    /// 钱包调用入口的透明计数（FU-IOS-0713：生产 `AppWallet(api:)` 注入，先计数再转给真实 ApiClient）。
    let api: CountingWalletApi
    let network: AppNetwork
    let login: AppLogin
    let runner: WithdrawalCleanupRunner
    let withdrawal: EnvironmentSwitchCleanerRegistry
    let environmentSwitch: EnvironmentSwitchCleanerRegistry
    let cleaner: WalletCacheCleaner
    let pendingBackend: MemoryPendingKeyBackend
    let system: RecordingClipboard
    let ledgerStore: MemoryClipboardHashStore
    let tracked: TrackedEvents

    var router: Router {
        routing.router
    }

    private struct Device: DeviceCredentials {
        var deviceId: String? = "device-fixture"
        var installSecret: String? = "test-only.install.device-a"
    }

    /// `pending` 传入同一个未决记录后端可模拟「杀进程后冷启动」：新组合（新的 ApiClient 与 AppWallet）读同一份本机记录。
    /// `cacheFlag`：缓存目录之外的待清理标记（nil = 缺省文件标记；FU-IOS-0712 R1-01 用它在写入路径里插入交错）。
    static func make(suiteName: String, defaults: UserDefaults, account: String = "user-a",
                     pending: MemoryPendingKeyBackend = MemoryPendingKeyBackend(),
                     cacheFlag: OrderPendingClearFlag? = nil, scope: String = "full",
                     unknownIdentityAtInit: Bool = false) -> WalletAppFixture {
        let tokens = MemorySessionTokens()
        // FU-IOS-0712：同一账号的夹具代表同一次登录（「杀进程后冷启动」读同一份会话，持久化登录世代相同）；换账号另有世代
        try? tokens.save(
            access: "at", refresh: "rt", scope: scope, account: account, loginEpoch: "fixture-login-\(account)"
        )
        let withdrawal = EnvironmentSwitchCleanerRegistry(cleaners: [SessionTokensCleaner(tokens: tokens)])
        let environmentSwitch = EnvironmentSwitchCleanerRegistry(cleaners: [SessionTokensCleaner(tokens: tokens)])
        let privacyStore = MemoryPrivacyStore()
        privacyStore.decisionRaw = "consented"
        privacyStore.consentedVersion = "1"
        let runner = WithdrawalCleanupRunner(store: privacyStore, registry: withdrawal)
        let store = CountingSessionTokens(tokens)
        let network = AppNetwork(
            tokens: store, pendingBackend: pending, device: Device(), withdrawalRegistry: withdrawal,
            environmentRegistry: environmentSwitch, credentialsReadable: { runner.credentialsReadable },
            configuration: WalletStubProtocol.configuration()
        )
        let update = UpdateFixtures.makeUpdate()
        let environment = EnvironmentStore(defaultEnvironment: .test, defaults: defaults, registry: environmentSwitch)
        let privacy = PrivacyController(
            store: privacyStore, clock: { 1 }, bundledPolicyVersion: "1", withdrawalRunner: runner
        )
        let routing = AppRouting(environment: environment, privacy: privacy, update: update)
        let config = AppConfig(
            client: network.client, file: ClientFile(name: suiteName + ".json"),
            environmentRegistry: EnvironmentSwitchCleanerRegistry(cleaners: [])
        )
        let login = AppLogin(network: network, routing: routing, update: update)
        network.attach(environment: environment, privacy: privacy, update: update)
        // 已登录的是短信登录的账号（一定绑了手机号）：守卫按已绑手机（APP-05b：phone_bound 未知按未绑，共性第 13 条）
        login.phone.record(true, generation: network.client.sessionGeneration)
        routing.shellAppeared()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(suiteName + "/wallet")
        let cleaner = WalletCacheCleaner(store: WalletCacheStore(root: root, flag: cacheFlag))
        WalletCacheCleaner.register(cleaner, withdrawal: withdrawal, environmentSwitch: environmentSwitch)
        // FU-IOS-0712 末轮 R3-02：生产初始化时 Keychain 暂时读失败（身份暂时未知），初始化之后恢复
        tokens.failReads = unknownIdentityAtInit ? .readFailed : nil
        let api = CountingWalletApi(network.client)
        let wallet = AppWallet(network: network, config: config, routing: routing, login: login,
                               mask: AmountMaskStore(defaults: defaults), cleaner: cleaner,
                               credentialsReadable: { runner.credentialsReadable }, api: api)
        tokens.failReads = nil
        let system = RecordingClipboard()
        let ledgerStore = MemoryClipboardHashStore()
        wallet.writer = ClipboardWriter(system: system, ledger: ClipboardWriteLedger(store: ledgerStore))
        let tracked = TrackedEvents()
        wallet.track = { tracked.events.append($0) }
        wallet.phoneProvider = { _ in "13800005678" }
        return WalletAppFixture(
            wallet: wallet, routing: routing, tokens: tokens, store: store, api: api, network: network, login: login,
            runner: runner, withdrawal: withdrawal, environmentSwitch: environmentSwitch, cleaner: cleaner,
            pendingBackend: pending, system: system, ledgerStore: ledgerStore, tracked: tracked
        )
    }

    /// 换账号（登出后另一个账号登录；会话世代 +1），并按 AppLogin 的出口通知（钱包据此换代）。
    func switchAccount(to account: String) throws {
        network.client.signOut()
        try tokens.save(access: "at-\(account)", refresh: "rt-\(account)", scope: "full", account: account)
        login.phone.record(true, generation: network.client.sessionGeneration)
        routing.sessionStateChanged(resumePending: false)
    }

    /// 令牌已换、清空通知还没执行的窗口（共性第 52、59、65 条）：只换存储里的会话，不通知。
    func swapTokensSilently(to account: String) throws {
        network.client.signOut()
        try tokens.save(access: "at-\(account)", refresh: "rt-\(account)", scope: "full", account: account)
        login.phone.record(true, generation: network.client.sessionGeneration)
    }

    /// 打开一个路由并取到页面（经真实 Router 与 RouteViewRegistry 同一个入口）。
    func open(_ route: String, params: [String: JSONValue] = [:]) -> WalletPageEntry? {
        router.open(RouteRequest(route: route, values: params, from: .inApp))
        guard let top = router.path.last, top.route == route else { return nil }
        return wallet.entry(for: top)
    }

    func page(_ route: String) -> WalletPageEntry? {
        guard let top = router.path.last(where: { $0.route == route }) else { return nil }
        return wallet.entry(for: top)
    }
}

/// 记下最后一次写入的假系统剪贴板（不读正文以外的东西）。
@MainActor
final class RecordingClipboard: SystemClipboard {
    var changeCount = 0
    private(set) var last: String?

    func detectLink(_ completion: @escaping @MainActor (Bool) -> Void) {
        completion(false)
    }

    func write(_ text: String) {
        last = text
        changeCount += 1
    }
}

@MainActor
final class TrackedEvents {
    var events: [TrackEvent] = []
}

/// 等到条件成立（主线程轮询；超时判失败）。
@MainActor
func waitUntil(
    _ message: String = "等待超时", timeout: TimeInterval = 5, file: StaticString = #filePath, line: UInt = #line,
    _ condition: () -> Bool
) async {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
        if Date() > deadline {
            XCTFail(message, file: file, line: line)
            return
        }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
}

/// 让在途的主线程任务跑完（不等网络）。
@MainActor
func settle(_ rounds: Int = 20) async {
    for _ in 0..<rounds {
        await Task.yield()
        try? await Task.sleep(nanoseconds: 2_000_000)
    }
}

/// 观察窗（FU-IOS-0733）：「什么都不该发生」的断言等满 `seconds` 再判——在途的异步请求（如实名查询 GET /v1/me）与其后的导航都已落定。
/// 主线程在等待期间照常执行其他任务。
@MainActor
func quietWindow(_ seconds: TimeInterval = 1.5) async {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
}
