import ClientCore
import Config
@testable import Couli
import CouliNetwork
import Foundation
import Generated
import OrderCore
import Orders
import Privacy
import Router
import Session
import Update

/// 订单 App 接线测试的组合（AppNetwork + AppRouting + AppLogin + AppOrders；本地 AppStubProtocol 假服务，已登录 user-a）。
@MainActor
struct OrdersAppFixture {
    let orders: AppOrders
    let routing: AppRouting
    let tokens: MemorySessionTokens
    let network: AppNetwork
    let login: AppLogin
    /// 本组合自己的订单清理项（不碰生产的 OrderCacheCleaner.shared；撤回 / 切环境测试直接调它）。
    let cleaner: OrderCacheCleaner
    /// 购买接线测试建 AppTrade 用（iOS RC-06）。
    let config: AppConfig
    let privacy: PrivacyController
    /// 网络层实际用的令牌存储（包着 `tokens`，记读取次数；iOS NEW-01）。
    let store: CountingSessionTokens
    /// 本组合的撤回清理执行器与清理名单（AppOrders 的凭据可读性取它；撤回测试直接跑它）。
    let runner: WithdrawalCleanupRunner
    let withdrawal: EnvironmentSwitchCleanerRegistry

    private struct Device: DeviceCredentials {
        var deviceId: String? = "device-fixture"
        var installSecret: String? = "test-only.install.device-a"
    }

    /// `cacheFlag`：缓存目录之外的待清理标记（nil = 缺省文件标记；FU-IOS-0712 R1-01 用它在写入路径里插入交错）。
    static func make(
        suiteName: String, defaults: UserDefaults, cacheFlag: OrderPendingClearFlag? = nil
    ) -> OrdersAppFixture {
        let tokens = MemorySessionTokens(access: "at", refresh: "rt", scope: "full", account: "user-a")
        let store = CountingSessionTokens(tokens)
        let withdrawal = EnvironmentSwitchCleanerRegistry(cleaners: [SessionTokensCleaner(tokens: store)])
        let environmentSwitch = EnvironmentSwitchCleanerRegistry(cleaners: [SessionTokensCleaner(tokens: tokens)])
        let privacyStore = MemoryPrivacyStore()
        privacyStore.decisionRaw = "consented"
        privacyStore.consentedVersion = "1"
        let runner = WithdrawalCleanupRunner(store: privacyStore, registry: withdrawal)
        let network = AppNetwork(
            tokens: store, pendingBackend: MemoryPendingKeyBackend(), device: Device(),
            withdrawalRegistry: withdrawal, environmentRegistry: environmentSwitch,
            credentialsReadable: { runner.credentialsReadable }, configuration: AppStubProtocol.configuration()
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
        routing.shellAppeared()
        let cache = OrderCacheStore(
            root: FileManager.default.temporaryDirectory.appendingPathComponent(suiteName)
                .appendingPathComponent("orders"),
            flag: cacheFlag, legacyPageStateDefaults: defaults
        )
        let cleaner = OrderCacheCleaner(store: cache)
        let orders = AppOrders(
            network: network, config: config, routing: routing, login: login, cleaner: cleaner, defaults: defaults,
            credentialsReadable: { runner.credentialsReadable }
        )
        return OrdersAppFixture(
            orders: orders, routing: routing, tokens: tokens, network: network, login: login, cleaner: cleaner,
            config: config, privacy: privacy, store: store, runner: runner, withdrawal: withdrawal
        )
    }
}

/// 记读取次数的令牌存储（转给内存实现；iOS NEW-01：撤回清理未完成期间读取次数必须为零）。
final class CountingSessionTokens: SessionTokens, @unchecked Sendable {
    private let inner: MemorySessionTokens
    private let lock = NSLock()
    private var count = 0
    /// 第几次读取（按 `reads` 计数）抛读取失败（FU-IOS-0712 R3-01：只让某一次读取暂时失败）。
    private var failAt: Int?
    /// 从第几次读取起持续失败（含），直到 `stopFailing()`（末轮窄修二 RC-03：换代识别那次之后的读取全部暂时失败，与读取次数无关）。
    private var failFrom: Int?

    init(_ inner: MemorySessionTokens) {
        self.inner = inner
    }

    var reads: Int {
        lock.withLock { count }
    }

    /// 从现在起的第 `nth` 次读取暂时失败一次（其余照常）。
    func failRead(nth: Int) {
        lock.withLock { failAt = count + nth }
    }

    /// 从现在起的第 `nth` 次读取开始持续失败，直到 `stopFailing()`。
    func failReads(fromNth nth: Int) {
        lock.withLock { failFrom = count + nth }
    }

    func stopFailing() {
        lock.withLock { failFrom = nil }
    }

    func readSession() throws -> SessionSnapshot? {
        let fail = lock.withLock { () -> Bool in
            count += 1
            return count == failAt || failFrom.map { count >= $0 } == true
        }
        if fail {
            throw SessionReadError.readFailed
        }
        return try inner.readSession()
    }

    func save(access: String, refresh: String, scope: String, account: String?) throws {
        try inner.save(access: access, refresh: refresh, scope: scope, account: account)
    }

    /// FU-IOS-0712：带登录世代的写入原样转给内层（刷新沿用世代）。
    func save(access: String, refresh: String, scope: String, account: String?, loginEpoch: String?) throws {
        try inner.save(access: access, refresh: refresh, scope: scope, account: account, loginEpoch: loginEpoch)
    }

    func clear() throws {
        try inner.clear()
    }
}
