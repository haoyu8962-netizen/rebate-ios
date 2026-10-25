import ClientCore
import Clipboard
import Combine
import CouliNetwork
import Foundation
import Generated
import Privacy
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
    /// 撤回清理已完成（`WithdrawalCleanupRunner.credentialsReadable`；测试可换）。
    private let readable: @MainActor () -> Bool
    private var sceneActive = true
    private var pages: [UUID: Page] = [:]
    private var subscriptions: Set<AnyCancellable> = []

    private struct Page {
        weak var purchase: OpenPurchaseController?
        weak var manage: AuthManageController?
        var visible: Bool
    }

    /// 发起页回到前台（场景在前台且它是导航栈顶）：APP-08 待跟单卡在外跳回来后拉一次（G07）。
    var onPageForeground: (@MainActor (UUID) -> Void)?

    /// 购买弹层出现（任一页的加载层、确认框、AuthSheet、外跳提示等，H06 同口径）：剪贴板在显示的同步出口作废（APP-07 共性第 4 条）。
    var onSensitiveOverlay: (@MainActor () -> Void)?
    /// 统一客服出口（APP-12 AppMe.cs；授权管理页【联系客服】）。
    var customerService: (@MainActor (String) -> Void)?

    init(
        network: AppNetwork, config: AppConfig, privacy: PrivacyController, routing: AppRouting, login: AppLogin,
        writer: ClipboardWriter? = nil,
        credentialsReadable: @escaping @MainActor () -> Bool = { PrivacyWithdrawalCleanup.runner.credentialsReadable },
        track: @escaping @MainActor (TrackEvent, TrackAttribution?) -> Void
    ) {
        readable = credentialsReadable
        client = network.client
        self.config = config
        self.privacy = privacy
        router = routing.router
        overrides = PlatformStatusOverrides(
            issuedMark: { config.issuedFetchId }, appliedMark: { config.appliedFetchId }
        )
        sink = AppLinkJumpSink(
            track: track,
            ownership: Self.ownershipReader(network.client, privacy, credentialsReadable)
        )
        #if DEBUG
        ports = DebugFakeTrade.ports(wrapping: AppJumpPorts(writer: writer))
        #else
        ports = AppJumpPorts(writer: writer)
        #endif
        executor = TradeJumpExecutor(ports: ports, baichuan: AppTradeStartup.shared.baichuan, sink: sink)
        pending = RouterPurchasePending(router: router)
        let client = network.client
        // 撤回清理未完成时不读凭据（按没有会话：不查、不显示 JumpTip；iOS NEW-01 同口径）
        tips = JumpTipService(api: client) {
            PrivacyWithdrawalCleanup.runner.credentialsReadable ? client.isolatedAccount : nil
        }
        webCode = Self.makeWebCode()
        // 百川启动初始化失败（同意隐私后的联盟步骤）：phase=startup 上报 sdk_init_failed
        let executor = executor
        AppTradeStartup.shared.reporter = { executor.reportStartupInitFailed() }
        // 发起页在前台 = 场景在前台且它是导航栈顶（被别的页面盖住、进后台都作废续执行许可）
        router.$path.sink { [weak self] path in
            MainActor.assumeIsolated { self?.refreshVisibility(path: path) }
        }.store(in: &subscriptions)
        observeLoginResume(router: router, login: login)
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

    /// 登录后的购买待办恢复：会话变为已登录时本页登记的登录待办自动重放一次（发起页不在前台时等回到前台）；待办暂缓明确释放
    /// （APP-05b R1-01）：暂缓期间 resumeAfterLogin 只保留记录，释放后通知原购买页重新核对归属、前置与页面许可，再恢复一次。
    private func observeLoginResume(router: Router, login: AppLogin) {
        // 会话变为已登录：本页登记的登录待办自动重放一次（发起页不在前台时等回到前台）
        login.$sessionVersion.dropFirst().sink { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                // 会话变化（退出、换号、重新登录）：授权管理页比较构造时的归属，不是当前的就清空 A 的状态并作废（r3f NEW-04）
                for page in self.pages.values {
                    page.manage?.sessionChanged()
                }
                guard login.loggedIn else { return }
                for page in self.pages.values {
                    page.purchase?.resumeAfterLogin()
                }
            }
        }.store(in: &subscriptions)
        // 待办暂缓明确释放（APP-05b R1-01）
        router.pendingHoldReleased.sink { [weak self, weak login] _ in
            MainActor.assumeIsolated {
                guard let self, login?.loggedIn == true else { return }
                for page in self.pages.values {
                    page.purchase?.resumeAfterLogin()
                }
            }
        }.store(in: &subscriptions)
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
        refetchCard: @escaping AppPurchaseEnv.Refetch
    ) -> OpenPurchaseController {
        let env = AppPurchaseEnv(trade: self, updateCard: updateCard, refetchCard: refetchCard)
        let controller = OpenPurchaseController(
            api: client, executor: executor, ports: ports, env: env, pending: pending, counter: counter, tips: tips,
            webCode: webCode, baichuan: AppTradeStartup.shared.baichuan
        )
        env.retain = controller
        // 缺省的来源与请求归属（APP-08 iOS 第五次修复）：没接待跟单卡的页面也在新尝试第一次发送时固定一次，open、授权请求带着它交
        // 网络层比较；来源键由同一份归属组成（账号、会话世代、作废世代），之后只比较。有待跟单卡时 AppOrders 换成带 slot 世代的那一份。
        controller.jumpOrigin = { [weak self] in self?.ownershipKey(self?.requestOwnership()) }
        controller.jumpSource = { [weak self] in
            let request = self?.requestOwnership()
            return JumpSource(origin: self?.ownershipKey(request), request: request)
        }
        pages[destination.id] = Page(purchase: controller, manage: nil, visible: true)
        // 弹层从无到有：同步通知剪贴板作废（APP-07 共性第 4 条）；是否在显示一律按此刻仍在栈里的页面现算（不留登记，F-HM-15 教训）
        controller.$state.map(Self.showsOverlay).removeDuplicates().filter(\.self).sink { [weak self] _ in
            MainActor.assumeIsolated { self?.onSensitiveOverlay?() }
        }.store(in: &subscriptions)
        refreshVisibility(path: router.path)
        return controller
    }

    /// 授权管理页（routes.json AuthManage；入口只在「我的」与设置页，经 Router 打开，守卫保留）。
    func authManagePage(_ destination: RouteDestination) -> AuthManagePageConfig {
        // 页面构造时一次固定请求归属（APP-09 共性第 65 条）：之后换号的旧页面零发送
        // 之后只比较（r3f NEW-04）：会话世代、作废世代仍是构造时的那一份；只读内存世代，不读令牌
        let ownership = requestOwnership()
        let client = client
        let controller = AuthManageController(
            api: client, executor: executor, ports: ports, webCode: webCode, baichuan: AppTradeStartup.shared.baichuan,
            ownership: ownership,
            stillOwned: {
                client.sessionGeneration == ownership.generation && client.invalidationTicket == ownership.epoch
            }
        )
        pages[destination.id] = Page(purchase: nil, manage: controller, visible: true)
        refreshVisibility(path: router.path)
        let page = AuthManagePageConfig(controller: controller, texts: texts)
        let router = router
        page.onBack = { router.close(destination) }
        // APP-12：统一客服出口（没接时打开帮助中心，与接入前一致）
        page.onContact = { [weak self] in
            if let customerService = self?.customerService {
                customerService(AppTradeRoutes.authManage)
            } else {
                router.open(RouteRequest(route: AppTradeRoutes.help, from: .inApp))
            }
        }
        return page
    }

    /// 页面真正出栈（AppSearch.lifetimes / 本类的栈观察）：执行器 leave 并注销。
    func pageLeft(_ id: UUID) {
        guard let page = pages.removeValue(forKey: id) else { return }
        page.purchase?.leave()
        page.manage?.leave()
    }

    /// 购买流程的界面此刻盖在页面上（加载层、确认框、AuthSheet、授权说明、外跳提示）。
    nonisolated static func showsOverlay(_ state: PurchaseState) -> Bool {
        state.phase == .loading || state.dialog != nil || state.browserNotice
    }

    /// 剪贴板的敏感浮层（G12、H06：购买弹层一律按 auth_sheet 处理）：只看此刻仍在栈里的页面。
    var sensitiveOverlay: String? {
        let alive = Set(router.path.map(\.id))
        let showing = pages.contains { id, page in
            alive.contains(id) && (page.purchase.map { Self.showsOverlay($0.state) } ?? false)
        }
        return showing ? ClipboardSensitive.overlayAuthSheet : nil
    }

    // MARK: - 前后台

    /// 这个发起页此刻在前台（场景在前台且它是导航栈顶）。
    func isPageVisible(_ id: UUID) -> Bool {
        pages[id]?.visible == true
    }

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
                onPageForeground?(id)
            } else {
                page.purchase?.onBackground()
                page.manage?.onBackground()
            }
        }
    }

    // MARK: - 环境

    /// 此刻是否已登录。基本模式或撤回清理未完成（凭据不可读）时一律按未登录，**不读令牌**（发起页 onForeground 等处每次
    /// 都会问它；APP-08 iOS 第五次修复，既有旁路）。
    var loggedIn: Bool {
        guard credentialsReadable() else { return false }
        return client.isolatedSessionScope != nil
    }

    /// 会话凭据此刻可读：不在基本模式且撤回清理已完成。
    func credentialsReadable() -> Bool {
        !basicMode && readable()
    }

    /// link_jump 的归属比较用与购买来源同一种读取（`requestOwnership()`，r3g NEW-06）；sink 在 self 初始化前创建，所以单独给出。
    static func ownershipReader(
        _ client: ApiClient, _ privacy: PrivacyController, _ readable: @escaping @MainActor () -> Bool
    ) -> @MainActor () -> RequestOwnership {
        { client.currentOwnership(credentialsReadable: privacy.state.decision != .basicMode && readable()) }
    }

    /// 此刻的请求归属（网络层同一把锁里一次读出；不可读时只取内存世代、不读令牌）。只在固定来源时调用，之后只比较。
    func requestOwnership() -> RequestOwnership {
        client.currentOwnership(credentialsReadable: credentialsReadable())
    }

    /// 由请求归属组成的来源键（只比较）。
    func ownershipKey(_ request: RequestOwnership?) -> String? {
        request.map { "\($0.account ?? "-")#\($0.generation)#\($0.epoch)" }
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
        #if DEBUG
        // 商品详情视觉 UI 测试的只读记录（APP-06v-b 评审 r1，见 DebugPurchaseLog）
        DebugPurchaseLog.record("route:\(route)")
        #endif
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

    var held: Bool {
        router.pendingHeld
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
