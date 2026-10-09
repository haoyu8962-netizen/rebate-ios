import ClientCore
import Combine
import Config
import CouliNetwork
import Foundation
import Generated
import ProductSearch

/// App 的配置存储（03 §4.3；APP-03b）：持有 Core 的 `ConfigStore`，把快照发布给各 Feature。
///
/// - 环境闸门通过后才冷启动（读 LKG、后台拉取）：blocked 时任何模块都不得读缓存（EnvironmentStore）。
/// - 回前台带 ETag 拉取（304 不变）；拉取经 ApiClient（getConfig 在基本模式与隐私未决的白名单里）。
/// - LKG 文件放 Application Support（「清除缓存」不清）；切换环境时清掉（`ConfigLKGCleaner` 登记在切换环境的注册表）。
/// - 包内默认配置：`DefaultConfig.json`（gen.py 从 openapi 示例生成，TODO(N-21)：发布时改为生产配置）。
@MainActor
final class AppConfig: ObservableObject {
    static let fileName = "config-lkg.json"

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
        clock: @escaping () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }
    ) {
        let store = ConfigStore(
            readFile: file.read,
            writeFile: file.write,
            fetcher: ConfigFetcher.make(client: client),
            clock: clock,
            bundled: DefaultConfig.json
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
