import BridgeHost
import ClientCore
import Combine
import Config
import CouliNetwork
import Foundation
import Generated
import Privacy
import Router
import SwiftUI
import UIKit
import Web

/// 两类 WebView 容器与 JSBridge 的 App 接线（APP-04）：配置（可信源、链接形态表、开关）、BridgeHost 的业务能力
/// （Router、ApiClient、Tracker、PermissionRequester）、调用方状态（隐私、会话、强更）。
///
/// 新建的宿主登记进 `hosts`：撤回同意与切换环境时（`BridgeHostsCleaner` 登记在两个清理注册表的第一位）所有容器里在途的
/// 桥调用作废，晚到的结果不交回。
@MainActor
final class AppWeb: ObservableObject {
    static let page = "WebPage"

    let config: AppConfig
    let network: AppNetwork
    let routing: AppRouting
    let privacy: PrivacyController
    let update: AppUpdate
    let tracker: AppTracker
    let permissions: AppPermissions
    let hosts = BridgeHostRegistry()
    /// 容器页随路由真正出栈 teardown（三端共性第 28 条）。
    let routeLifetimes: WebRouteLifetimes
    private let cleaner: BridgeHostsCleaner

    init(
        config: AppConfig,
        network: AppNetwork,
        routing: AppRouting,
        privacy: PrivacyController,
        update: AppUpdate,
        tracker: AppTracker,
        permissions: AppPermissions,
        withdrawalRegistry: EnvironmentSwitchCleanerRegistry = PrivacyWithdrawalCleanup.registry,
        environmentRegistry: EnvironmentSwitchCleanerRegistry = .shared
    ) {
        self.config = config
        self.network = network
        self.routing = routing
        self.privacy = privacy
        self.update = update
        self.tracker = tracker
        self.permissions = permissions
        cleaner = BridgeHostsCleaner(registry: hosts)
        routeLifetimes = WebRouteLifetimes(router: routing.router)
        // 作废在途桥调用排在网络层作废在途请求之后、清令牌之前（APP-04 三端共性第 4 条；网络层仍在第一位，APP-03a 共性第 35 条）。
        PrivacyWithdrawalCleanup.register(
            cleaner, after: NetworkInvalidationCleaner.name,
            withdrawal: withdrawalRegistry, environmentSwitch: environmentRegistry
        )
    }

    static var appVersion: String {
        AppNetwork.identity.appVersion
    }

    /// 生效配置（current → LKG → 包内）。
    var configJson: String {
        config.store.snapshotJson
    }

    /// 当前链接形态表（current → 上一次成功 → 包内）。
    var linkPatternsJson: String? {
        config.store.linkPatternsJson
    }

    // MARK: - 可信容器

    /// 生产的协议判定：可信源只取 bridge_origins（三端共性第 3 条），规则表与分享域取生效配置。不含任何回环源。
    func productionProtocol() -> BridgeProtocol {
        let current = configJson
        return BridgeProtocol(
            trustedOrigins: WebConfigReader.trustedOrigins(configJson: current),
            linkPatterns: linkPatternsJson.flatMap(Self.object) ?? [:],
            shareDomains: WebConfigReader.shareDomains(configJson: current)
        )
    }

    /// 调用方状态：隐私（撤回清理未完成按基本模式）、会话账号（经隔离判断，凭据可读才取）、强更进度。
    func callerState(fromForceUpdatePage: Bool) -> BridgeCallerState {
        let readable = PrivacyWithdrawalCleanup.runner.credentialsReadable
        let privacyRaw: String = switch privacy.routerPrivacy {
        case .consented: readable ? BridgePrivacy.consented : BridgePrivacy.basicMode
        case .basicMode: BridgePrivacy.basicMode
        case .notDecided: BridgePrivacy.notDecided
        }
        // 归属键 = 账号 + 会话世代：同一账号退出后重新登录也算换了归属（三端共性第 15 条）。
        let client = network.client
        let account = privacyRaw == BridgePrivacy.consented
            ? client.isolatedAccount.map { "\($0)#\(client.sessionGeneration)" } : nil
        return BridgeCallerState(
            privacy: privacyRaw,
            accountKey: account,
            update: Self.bridgeUpdate(update.routerStatus),
            fromForceUpdatePage: fromForceUpdatePage
        )
    }

    /// 新建一个可信容器（生产取值：可信源只取 bridge_origins，调用方状态取真实的隐私、会话与强更进度）。
    func makeTrustedController(
        url: URL?,
        fromForceUpdatePage: Bool,
        onClose: @escaping @MainActor () -> Void
    ) -> TrustedWebController {
        makeTrustedController(
            url: url,
            protocolProvider: { [weak self] in
                self?.productionProtocol() ?? BridgeProtocol(trustedOrigins: [], linkPatterns: [:], shareDomains: [])
            },
            caller: { [weak self] in
                self?.callerState(fromForceUpdatePage: fromForceUpdatePage)
                    ?? BridgeCallerState(
                        privacy: BridgePrivacy.notDecided, accountKey: nil, update: BridgeUpdateState.unknown
                    )
            },
            onClose: onClose
        )
    }

    /// 容器装配（业务能力、宿主登记、外跳）。可信源与调用方状态由调用方给：生产只有上面一个入口；Debug 构建的一致性页入口
    /// （App/Sources/Debug，Release 不编译）另给本机源与契约示例规则（APP-04 三端共性第 2 条）。
    func makeTrustedController(
        url: URL?,
        protocolProvider: @escaping @MainActor () -> BridgeProtocol,
        caller: @escaping @MainActor () -> BridgeCallerState,
        onClose: @escaping @MainActor () -> Void
    ) -> TrustedWebController {
        let services = AppBridgeServices(web: self)
        return TrustedWebController(
            url: url,
            appVersion: Self.appVersion,
            hostFactory: { [hosts] ui in
                let host = BridgeHost(
                    protocol: protocolProvider,
                    caller: caller,
                    services: services,
                    ui: ui,
                    awaitUpdate: { [weak self] in await self?.awaitUpdate() ?? BridgeUpdateState.unknown }
                )
                hosts.add(host)
                return host
            },
            onOpenExternal: { [weak self] target in
                self?.openExternal(target)
            },
            onClose: onClose
        )
    }

    /// 可信容器跳到白名单外的 https 地址：在新的 ExternalWebView 打开（经 Router，App 内来源，不受 external_hosts 限制）。
    func openExternal(_ url: URL) {
        routing.router.open(RouteRequest(
            route: RoutePolicy.externalPage, values: ["url": .string(url.absoluteString)], from: .inApp
        ))
    }

    /// 检查中最多等 5 秒（03 §4.4），到时按未知。
    func awaitUpdate() async -> String {
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        while ProcessInfo.processInfo.systemUptime < deadline {
            let state = Self.bridgeUpdate(update.routerStatus)
            if state != BridgeUpdateState.checking {
                return state
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return BridgeUpdateState.unknown
    }

    // MARK: - 第三方页容器

    /// 第三方页容器的判定（包内快照来自 DefaultConfig；TODO(N-21) 包内规则目前为空）。
    lazy var externalPolicy: ExternalNavPolicy = {
        let bundled = Self.object(DefaultConfig.json)?["link_patterns"] as? [String: Any]
        return ExternalNavPolicy(bundledLinkPatterns: bundled ?? [:])
    }()

    func makeExternalController(url: URL?, onClose: @escaping @MainActor () -> Void) -> ExternalWebController {
        let deps = ExternalWebDependencies(
            policy: externalPolicy,
            linkPatterns: { [weak self] in self?.linkPatternsJson },
            consented: { [weak self] in
                self?.callerState(fromForceUpdatePage: false).privacy == BridgePrivacy.consented
            },
            productIntercept: { [weak self] in
                guard let self else { return false }
                return WebConfigReader.flag(
                    configJson: configJson, name: "external_page.product_intercept", defaultValue: false
                )
            },
            navHostSampleBp: { [weak self] in
                self.map { WebConfigReader.navHostSampleBp(configJson: $0.configJson) } ?? 0
            },
            track: { [weak self] event in
                self?.tracker.track(event)
            },
            onProductIntent: { [weak self] url, platform in
                self?.productIntent(url: url, platform: platform) ?? false
            },
            onSearch: { [weak self] in
                self?.routing.router.open(RouteRequest(route: "Search", from: .inApp))
            },
            searchLabel: WebDraftTexts.goSearch
        )
        return ExternalWebController(url: url, appVersion: Self.appVersion, deps: deps, onClose: onClose)
    }

    /// 商品回流（APP-04 三端共性第 8 条，03 §5.1）：取消原导航后向 Router 发出 ProductDetail 意图，item_ref 是去掉片段的商品页 URL
    /// （BR-PROD-11 原样透传）。product_key 只能由服务端识别给出（TODO(APP-06)：先调识别接口再带上 product_key）；识别接入前 Router
    /// 按参数不合 schema 拒绝，返回 false，由容器提示 external_page.product_unresolved（留在原页，不只写日志）。
    func productIntent(url: String, platform: String) -> Bool {
        let decision = routing.router.open(RouteRequest(
            route: "ProductDetail",
            values: ["platform": .string(platform), "item_ref": .string(String(url.prefix(1024)))],
            from: .inApp
        ))
        return decision.kind == .open || decision.kind == .openReadonly
    }

    // MARK: - 工具

    static func object(_ text: String) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any]
    }

    /// Router 的强更进度 → 桥的强更状态（三端共性第 6 条：只有 OK、低于推荐算 supported）。
    static func bridgeUpdate(_ status: UpdateCheckStatus) -> String {
        switch status {
        case .finished(.ok), .finished(.belowRecommended): BridgeUpdateState.supported
        case .finished(.belowMin): BridgeUpdateState.below
        case .checking, .finished(.checking): BridgeUpdateState.checking
        case .finished(.unknown): BridgeUpdateState.unknown
        }
    }
}

/// 活着的 BridgeHost（弱引用，容器销毁后自动消失）。撤回同意、切换环境时 `invalidateAll`：作废全部在途桥调用。
@MainActor
final class BridgeHostRegistry {
    private let hosts = NSHashTable<BridgeHost>.weakObjects()

    func add(_ host: BridgeHost) {
        hosts.add(host)
    }

    var count: Int {
        hosts.allObjects.count
    }

    func invalidateAll() {
        for host in hosts.allObjects {
            host.invalidate()
        }
    }
}

/// 撤回同意、切换环境的清理项：作废全部容器里的在途桥调用（不抛错）。
@MainActor
final class BridgeHostsCleaner: EnvironmentSwitchCleaning {
    static let name = "BridgeHost.inFlight"

    let cleanerName = BridgeHostsCleaner.name
    private let registry: BridgeHostRegistry

    init(registry: BridgeHostRegistry) {
        self.registry = registry
    }

    func cleanForEnvironmentSwitch() throws {
        registry.invalidateAll()
    }
}

/// 字典里还没有的 Web 容器文案（草稿）。TODO(N-21)：BR-TEXT-14 补「去搜索」按钮键后改为取键。
enum WebDraftTexts {
    static let goSearch = "去搜索"
}
