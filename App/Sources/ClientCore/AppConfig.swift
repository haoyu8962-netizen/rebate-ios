import BridgeHost
import ClientCore
import Combine
import Config
import CouliNetwork
import Foundation
import Generated
import os
import ProductSearch

/// App 的配置存储（03 §4.3；APP-03b）：持有 Core 的 `ConfigStore`，把快照发布给各 Feature。
///
/// - 环境闸门通过后才冷启动（读 LKG、后台拉取）：blocked 时任何模块都不得读缓存（EnvironmentStore）。
/// - 回前台带 ETag 拉取（304 不变）；拉取经 ApiClient（getConfig 在基本模式与隐私未决的白名单里）。
/// - LKG 文件放 Application Support（「清除缓存」不清）；切换环境时清掉（`ConfigLKGCleaner` 登记在切换环境的注册表）。
/// - 包内默认配置：`DefaultConfig.json`（gen.py 从 openapi 示例生成，TODO(N-21)：发布时改为生产配置）。
/// - bridge_origins 验签（N-22）：随包公钥表 `signKeys`（构建配置 `CouliConfigSignKeys`）+ 本应用 appId（与 X-App-Id 同源）+
///   每次现取的运行环境 id，经 BridgeHost 的 `BridgeOriginsVerifier` 验；ConfigStore 只拿到验过的 {version, origins}。
@MainActor
final class AppConfig: ObservableObject {
    static let fileName = "config-lkg.json"
    /// Info.plist 里随包配置签名公钥表的键（= $(COULI_CONFIG_SIGN_KEYS)，见 App/Config/*.xcconfig）。
    nonisolated static let signKeysInfoKey = "CouliConfigSignKeys"

    /// 随包公钥表：Info.plist `CouliConfigSignKeys` 经 `ConfigSignKeys.parse`；缺键或为空时是空表（一律验不过、白名单为空）。
    nonisolated static var bundledSignKeys: ConfigSignKeys {
        ConfigSignKeys.parse(Bundle.main.object(forInfoDictionaryKey: signKeysInfoKey) as? String ?? "")
    }

    @Published private(set) var snapshotJson: String
    @Published private(set) var source: String

    let store: ConfigStore
    let cleaner: ConfigLKGCleaner
    private var observation: ConfigObservation?
    private var started = false
    private var wasBackgrounded = false

    init(
        client: ApiClient,
        file: ClientFile = ClientFile(name: AppConfig.fileName),
        environmentRegistry: EnvironmentSwitchCleanerRegistry = .shared,
        clock: @escaping () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) },
        signKeys: ConfigSignKeys = AppConfig.bundledSignKeys,
        environmentId: @escaping () -> String = { EnvironmentStore.runtimeEnvironmentId() }
    ) {
        let store = ConfigStore(
            readFile: file.read,
            writeFile: file.write,
            fetcher: ConfigFetcher.make(client: client),
            clock: clock,
            bundled: DefaultConfig.json,
            verifyBridgeOrigins: Self.bridgeOriginsVerifier(
                appId: AppNetwork.identity.appId, signKeys: signKeys, environmentId: environmentId
            )
        )
        self.store = store
        snapshotJson = store.snapshotJson
        source = store.sourceRaw
        cleaner = ConfigLKGCleaner(store: store)
        environmentRegistry.replace(cleaner)
        observation = store.observe { [weak self] updated in
            MainActor.assumeIsolated {
                self?.snapshotJson = updated.snapshotJson
                self?.source = updated.sourceRaw
            }
        }
    }

    /// ConfigStore 的 bridge_origins 验签闭包：每次调用现取运行环境 id（切换环境后用新环境）；通过返回 {version, origins}。
    /// 验不过记一条系统日志（reason + kid + env；不写 jws 全文与 origins）。ConfigStore 只在 200 新配置生效与旧 LKG 现验时
    /// 调它，所以天然是一版文档一条。
    nonisolated static func bridgeOriginsVerifier(
        appId: String, signKeys: ConfigSignKeys, environmentId: @escaping () -> String
    ) -> ([String: Any], Int?) -> (version: Int, origins: [String])? {
        { config, lastGoodVersion in
            let env = environmentId()
            let verdict = BridgeOriginsVerifier.verify(
                config: config, appId: appId, env: env, lastGoodVersion: lastGoodVersion, keys: signKeys
            )
            switch verdict {
            case let .accepted(allowlist):
                return (allowlist.version, allowlist.origins)
            case let .rejected(reason):
                let jws = (config["bridge_origins"] as? [String: Any])?["jws"] as? String
                let kid = jws.flatMap(BridgeOriginsVerifier.headerKid)
                AppConfigLog.originsRejected(reason: reason, kid: kid, env: env)
                return nil
            }
        }
    }

    /// 环境闸门通过后调用一次：读 LKG，后台拉取。
    func startIfSettled(_ gate: EnvironmentGate) {
        guard gate == .settled, !started else {
            return
        }
        started = true
        store.onColdStart()
    }

    /// 切换环境提交完成后（LKG 已在清理阶段删掉）：在新环境重新读 LKG、重新拉取（APP-03b 共性 5）。
    func environmentChanged() {
        guard started else {
            return
        }
        store.onColdStart()
    }

    func enteredBackground() {
        wasBackgrounded = true
    }

    /// 50304 search_disabled：要一份此刻之后才发出的配置（APP-06a 共性 2、8）。还没冷启动时不拉（环境闸门未通过）。
    func requestFresh() {
        guard started else { return }
        store.requestFresh()
    }

    /// 回前台（之前进过后台）：带 ETag 拉取。
    func enteredForeground() {
        guard started, wasBackgrounded else {
            return
        }
        wasBackgrounded = false
        store.onForeground()
    }
}

/// 配置的系统日志（与 ClientCore 的 ConfigLog 同一 subsystem / category）。
enum AppConfigLog {
    static let logger = Logger(subsystem: "com.couli.app", category: "config")

    /// bridge_origins 验签不过（N-22）：只写 reason、kid（截到 64 个字符）与运行环境。
    static func originsRejected(reason: String, kid: String?, env: String) {
        let kidText = kid.map { String($0.prefix(64)) } ?? "-"
        let detail = "reason=\(reason) kid=\(kidText) env=\(env)"
        logger.warning("config: bridge_origins rejected \(detail, privacy: .public)")
    }
}

/// LKG 的清理项（只登记在切换环境的注册表：撤回同意不清配置；「清除缓存」不清 LKG，03 §4.3）。
@MainActor
final class ConfigLKGCleaner: EnvironmentSwitchCleaning {
    static let name = "ConfigStore.lkg"

    let cleanerName = ConfigLKGCleaner.name
    private let store: ConfigStore

    init(store: ConfigStore) {
        self.store = store
    }

    func cleanForEnvironmentSwitch() throws {
        try store.clearForEnvironmentSwitch()
    }
}

/// 搜索页的配置源（APP-06a）：Tab 三层取值、确认编号、刷新与订阅都转给 ConfigStore。
extension AppConfig: SearchConfigSource {
    func searchStatusLayers() -> [String: Any] {
        store.searchStatusLayers()
    }

    var confirmedSearchStatus: [String: Any]? {
        store.confirmedSearchStatus
    }

    var issuedFetchId: UInt64 {
        store.issuedFetchId
    }

    var appliedFetchId: UInt64 {
        store.appliedFetchId
    }

    func observeSearchConfig(_ handler: @escaping @MainActor () -> Void) -> SearchObservation {
        let token = store.observe { _ in
            MainActor.assumeIsolated { handler() }
        }
        return SearchObservation { token.cancel() }
    }
}

/// 详情页与搜索列表的平台购买状态（APP-06a R2-01）：`features.platform_status.<platform>` 逐个平台回落，订阅转给 ConfigStore。
extension AppConfig: PurchaseStatusSource {
    func purchaseStatus(platform: String) -> String? {
        store.platformStatus(platform: platform)
    }

    func observePurchaseStatus(_ handler: @escaping @MainActor () -> Void) -> SearchObservation {
        observeSearchConfig(handler)
    }
}
