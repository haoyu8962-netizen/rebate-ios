import Combine
import CouliNetwork
import Foundation
import Generated
import ProductSearch
import Purchase
import Router
import Trade
import TradeJump

/// 本页面打开的路由名（routes.json；TradeWiringTests 逐个核对）。
enum AppTradeRoutes {
    static let authManage = "AuthManage"
    static let login = "Login"
    static let search = "Search"
    static let help = "Help"
    static let all = [authManage, login, search, help]
}

/// App 侧的购买（APP-06b）：一个进程一份的 AuthSheet 计数、点击结果确认的平台状态、百川、外跳端口、link_jump 上报、购买待办（Router 的
/// 同一份本地记录）；给详情页、搜索页各建一份 OpenPurchaseController，给授权管理页建 AuthManageController；按 Router 导航栈与场景
/// 前后台通知每个发起页「在前台 / 被覆盖或进后台」（03 §4.5，共性第 3、25 条），会话变为已登录、隐私变为已同意时通知发起页恢复一次。
@MainActor
final class AppTrade {
    let counter = AuthSheetCounter()
    let overrides: PlatformStatusOverrides
    /// 外跳端口：Release 只有系统实现 `AppJumpPorts`；Debug / Staging 在假服务打开时包一层 `DebugJumpPorts`（共性第 42 条）。
    let ports: JumpPorts
    let sink: AppLinkJumpSink
    let executor: TradeJumpExecutor
    let pending: RouterPurchasePending
    let tips: JumpTipService
    let webCode: WebCodeAuthorizer
    let texts = AppSearchTexts()
    private let client: ApiClient
    private let config: AppConfig
    private let privacy: PrivacyController
    private let router: Router
    private var sceneActive = true
    private var pages: [UUID: Page] = [:]
    private var subscriptions: Set<AnyCancellable> = []

    private struct Page {
        weak var purchase: OpenPurchaseController?
        weak var manage: AuthManageController?
        var visible: Bool
    }

    init(
        network: AppNetwork, config: AppConfig, privacy: PrivacyController, routing: AppRouting, login: AppLogin,
        track: @escaping @MainActor (TrackEvent) -> Void
    ) {
        client = network.client
        self.config = config
        self.privacy = privacy
        router = routing.router
        overrides = PlatformStatusOverrides(
            issuedMark: { config.issuedFetchId }, appliedMark: { config.appliedFetchId }
        )
        sink = AppLinkJumpSink(track: track)
        #if DEBUG
        ports = DebugFakeTrade.ports(wrapping: AppJumpPorts())
        #else
        ports = AppJumpPorts()
        #endif
        executor = TradeJumpExecutor(ports: ports, baichuan: AppTradeStartup.shared.baichuan, sink: sink)
        pending = RouterPurchasePending(router: router)
        let client = network.client
        tips = JumpTipService(api: client) { client.isolatedAccount }
        webCode = Self.makeWebCode()
        // 百川启动初始化失败（同意隐私后的联盟步骤）：phase=startup 上报 sdk_init_failed
        let executor = executor
        AppTradeStartup.shared.reporter = { executor.reportStartupInitFailed() }
        // 发起页在前台 = 场景在前台且它是导航栈顶（被别的页面盖住、进后台都作废续执行许可）
        router.$path.sink { [weak self] path in
            MainActor.assumeIsolated { self?.refreshVisibility(path: path) }
        }.store(in: &subscriptions)
        // 会话变为已登录：本页登记的登录待办自动重放一次（发起页不在前台时等回到前台）
        login.$sessionVersion.dropFirst().sink { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, login.loggedIn else { return }
                for page in self.pages.values {
                    page.purchase?.resumeAfterLogin()
                }
            }
        }.store(in: &subscriptions)
        // 补同意完成：本页登记的购买待办恢复一次（原点击的卡与报价基准，共性第 24 条）
        privacy.observeState { [weak self] state in
            guard state.decision == .consented else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                for page in pages.values {
                    page.purchase?.resumeAfterConsent()
                }
            }
        }
    }

    private static func makeWebCode() -> WebCodeAuthorizer {
        #if DEBUG
        if let fake = DebugFakeTrade.webCodeAuthorizer() {
            return fake
        }
        #endif
        return UnavailableWebCodeAuthorizer()
    }

    // MARK: - 页面

    /// 发起页（详情、搜索）的购买执行器。`updateCard` / `refetchCard` 是这一页的卡片写回。
    func makePurchase(
        for destination: RouteDestination,
        updateCard: @escaping @MainActor (TradeObject, @escaping (TradeObject) -> TradeObject) -> Void,
        refetchCard: @escaping @MainActor (TradeObject, @escaping (TradeObject, TradeObject) -> TradeObject) -> Void
    ) -> OpenPurchaseController {
        let env = AppPurchaseEnv(trade: self, updateCard: updateCard, refetchCard: refetchCard)
        let controller = OpenPurchaseController(
            api: client, executor: executor, ports: ports, env: env, pending: pending, counter: counter, tips: tips,
            webCode: webCode, baichuan: AppTradeStartup.shared.baichuan
        )
        env.retain = controller
        pages[destination.id] = Page(purchase: controller, manage: nil, visible: true)
        refreshVisibility(path: router.path)
        return controller
    }

    /// 授权管理页（routes.json AuthManage；入口只在「我的」与设置页，经 Router 打开，守卫保留）。
    func authManagePage(_ destination: RouteDestination) -> AuthManagePageConfig {
        let controller = AuthManageController(
            api: client, executor: executor, ports: ports, webCode: webCode, baichuan: AppTradeStartup.shared.baichuan
        )
        pages[destination.id] = Page(purchase: nil, manage: controller, visible: true)
        refreshVisibility(path: router.path)
        let page = AuthManagePageConfig(controller: controller, texts: texts)
        let router = router
        page.onBack = { router.close(destination) }
        page.onContact = { router.open(RouteRequest(route: AppTradeRoutes.help, from: .inApp)) }
        return page
    }

    /// 页面真正出栈（AppSearch.lifetimes / 本类的栈观察）：执行器 leave 并注销。
    func pageLeft(_ id: UUID) {
        guard let page = pages.removeValue(forKey: id) else { return }
        page.purchase?.leave()
        page.manage?.leave()
    }

    // MARK: - 前后台

    func sceneChanged(active: Bool) {
        sceneActive = active
        if active {
            counter.onForeground()
        } else {
            counter.onBackground()
        }
        refreshVisibility(path: router.path)
    }

    private func refreshVisibility(path: [RouteDestination]) {
        let alive = Set(path.map(\.id))
        for id in pages.keys where !alive.contains(id) {
            pageLeft(id)
        }
        let top = path.last?.id
        for (id, page) in pages {
            let visible = sceneActive && id == top
            guard visible != page.visible else { continue }
            pages[id]?.visible = visible
            if visible {
                page.purchase?.onForeground()
                page.manage?.onForeground()
            } else {
                page.purchase?.onBackground()
                page.manage?.onBackground()
            }
        }
    }

    // MARK: - 环境

    var loggedIn: Bool {
        client.isolatedSessionScope != nil
    }

    var basicMode: Bool {
        privacy.state.decision == .basicMode
    }

    func requestConsent() {
        privacy.requestFullFunction()
    }

    func platformStatus(_ platform: String) -> String? {
        overrides.status(platform) ?? config.purchaseStatus(platform: platform)
    }

    func open(route: String, params: [String: String]) {
        router.open(RouteRequest(route: route, values: params.mapValues { .string($0) }, from: .inApp))
    }

    /// /v1/config.help_links.<key>：{route, params}；没有配置为 nil。
    func helpLink(_ key: String) -> (route: String, params: [String: String])? {
        guard let text = config.store.value(key: "help_links." + key),
              let object = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any],
              let route = object["route"] as? String, !route.isEmpty
        else { return nil }
        let params = (object["params"] as? [String: Any] ?? [:]).compactMapValues { $0 as? String }
        return (route, params)
    }
}

/// 一个发起页的购买环境（PurchaseEnv）。
@MainActor
final class AppPurchaseEnv: PurchaseEnv {
    private weak var trade: AppTrade?
    private let update: @MainActor (TradeObject, @escaping (TradeObject) -> TradeObject) -> Void
    private let refetch: @MainActor (TradeObject, @escaping (TradeObject, TradeObject) -> TradeObject) -> Void
    /// 执行器（弱引用即可；只为调试时能从环境找到它）。
    weak var retain: OpenPurchaseController?

    init(
        trade: AppTrade,
        updateCard: @escaping @MainActor (TradeObject, @escaping (TradeObject) -> TradeObject) -> Void,
        refetchCard: @escaping @MainActor (TradeObject, @escaping (TradeObject, TradeObject) -> TradeObject) -> Void
    ) {
        self.trade = trade
        update = updateCard
        refetch = refetchCard
    }

    func loggedIn() -> Bool {
        trade?.loggedIn ?? false
    }

    func basicMode() -> Bool {
        trade?.basicMode ?? true
    }

    func requestConsent() {
        trade?.requestConsent()
    }

    func platformStatus(_ platform: String) -> String? {
        trade?.platformStatus(platform)
    }

    func markPlatformStatus(_ platform: String, status: String) {
        trade?.overrides.mark(platform, status: status)
    }

    func updateCard(_ target: TradeObject, transform: @escaping (TradeObject) -> TradeObject) {
        update(target, transform)
    }

    func open(route: String, params: [String: String]) {
        trade?.open(route: route, params: params)
    }

    func refetchCard(_ target: TradeObject, merge: @escaping (TradeObject, TradeObject) -> TradeObject) {
        refetch(target, merge)
    }

    func helpLink(_ key: String) -> (route: String, params: [String: String])? {
        trade?.helpLink(key)
    }
}

/// 购买待办（BR-ID-10）：Router 的同一份本地记录（只存 1 条、10 分钟、完成一步重新计时、退出登录 / 切换环境清除），动作名 open_link。
@MainActor
final class RouterPurchasePending: PurchasePending {
    private let router: Router

    init(router: Router) {
        self.router = router
    }

    @discardableResult
    func register(_ params: TradeObject) -> Bool {
        router.registerAction(PurchasePendingKeys.action, params: params)
    }

    func peek() -> TradeObject? {
        router.pendingAction(PurchasePendingKeys.action)
    }

    func stepDone() {
        router.markActionStepDone(PurchasePendingKeys.action)
    }

    func clear() {
        router.clearAction(PurchasePendingKeys.action)
    }
}

/// 点击结果确认的平台状态并入配置（列表、详情的卡片映射与点击前核对都先读它，共性第 5、6 条）。
@MainActor
final class TradePurchaseStatusSource: PurchaseStatusSource {
    private let config: AppConfig
    private let overrides: PlatformStatusOverrides

    init(config: AppConfig, overrides: PlatformStatusOverrides) {
        self.config = config
        self.overrides = overrides
    }

    func purchaseStatus(platform: String) -> String? {
        overrides.status(platform) ?? config.purchaseStatus(platform: platform)
    }

    func observePurchaseStatus(_ handler: @escaping @MainActor () -> Void) -> SearchObservation {
        let configObservation = config.observePurchaseStatus(handler)
        let cancelOverrides = overrides.subscribe(handler)
        return SearchObservation {
            MainActor.assumeIsolated {
                configObservation.cancel()
                cancelOverrides()
            }
        }
    }
}
