import ClientCore
import Config
import Privacy
import Router
import SwiftUI
import Update

/// 启动：系统启动屏（Info.plist UILaunchScreen，页面底色）→ 环境闸门 → 隐私闸门 → 强更检查（APP-02c）→ Tab 外壳（APP-02b）。
@main
struct CouliApp: App {
    @StateObject private var environment: EnvironmentStore
    @StateObject private var router: Router
    @StateObject private var privacy: PrivacyController
    @StateObject private var update: AppUpdate
    @StateObject private var config: AppConfig
    @StateObject private var permissions: AppPermissions
    @StateObject private var web: AppWeb
    @StateObject private var login: AppLogin
    @StateObject private var search: AppSearch
    @StateObject private var clipboard: AppClipboard
    @StateObject private var orders: AppOrders
    @StateObject private var wallet: AppWallet
    @Environment(\.scenePhase) private var scenePhase
    private let routing: AppRouting
    private let network: AppNetwork
    private let tracker: AppTracker

    init() {
        Self.registerEarlyCleaners()
        // 网络核心（APP-03a）：创建即把「作废并取消在途请求」登记到撤回同意、切换环境两个注册表的第一位；
        // 在 attach 之前它不发任何请求。
        let network = Self.makeNetwork()
        // 配置存储（APP-03b）：LKG 清理项要在启动对账（创建 EnvironmentStore）之前登记进切换环境的注册表。
        let config = AppConfig(client: network.client)
        // 埋点队列的清理器先登记（直接删队列文件），再重试上次没清干净的撤回清理（清干净之前任何模块不得读取会话凭据），
        // 最后创建 EnvironmentStore 做启动对账：覆盖安装换了环境时旧队列也被清掉（APP-03b 共性 23）。
        let launch = AppLaunchCleanup.reconcile(
            retryWithdrawal: {
                PrivacyWithdrawalCleanup.runner.retryIfPending()
                #if DEBUG
                DebugPrivacyPreset.applyFromLaunchArguments()
                #endif
            },
            makeEnvironment: BuildInfo.makeEnvironmentStore
        )
        let environment = launch.environment
        // 同意后的第一步：设备注册（APP-03b，DeviceRegistry；失败按闸门的退避重试）。
        let privacy = PrivacyController(deviceRegistration: { done in network.registerDevice(done: done) })
        let update = Self.makeUpdate()
        let routing = AppRouting(environment: environment, privacy: privacy, update: update)
        // 短信登录（APP-05a）：守卫的会话状态源、会话 Effect 与刷新通知的接收方、登录页配置、登出。在 attach 之前接上：
        // attach 之后 ApiClient 可能立即发起受限会话刷新，它的通知要有人接。
        let login = AppLogin(network: network, routing: routing, update: update)
        network.attach(environment: environment, privacy: privacy, update: update) {
            config.environmentChanged()
        }
        // 埋点（APP-03b）：沿用启动对账前登记的清理器；隐私离开「已同意」立即清空。
        let tracker = AppTracker(
            privacy: privacy, update: update, network: network, cleaner: launch.trackerCleaner
        ) { [weak environment] in
            environment.map { $0.gate == .settled && !$0.switching } ?? false
        }
        config.startIfSettled(environment.gate)
        // 冷启动流程里显式启动埋点（环境、隐私都就绪后；APP-03b 共性 15）。
        tracker.startIfReady()
        _environment = StateObject(wrappedValue: environment)
        _router = StateObject(wrappedValue: routing.router)
        _privacy = StateObject(wrappedValue: privacy)
        _update = StateObject(wrappedValue: update)
        _config = StateObject(wrappedValue: config)
        let permissions = AppPermissions()
        // 两类 WebView 容器与 JSBridge（APP-04）：创建即把「作废在途桥调用」登记进撤回同意、切换环境两个注册表的第一位。
        let web = AppWeb(
            config: config, network: network, routing: routing, privacy: privacy, update: update,
            tracker: tracker, permissions: permissions
        )
        let (clipboard, search) = Self.makeShopping(web: web, login: login)
        let orders = Self.makeOrders(web: web, login: login, clipboard: clipboard, search: search)
        _orders = StateObject(wrappedValue: orders)
        _wallet = StateObject(wrappedValue: Self.makeWallet(web, login, clipboard, orders))
        _permissions = StateObject(wrappedValue: permissions)
        _web = StateObject(wrappedValue: web)
        _login = StateObject(wrappedValue: login)
        _clipboard = StateObject(wrappedValue: clipboard)
        _search = StateObject(wrappedValue: search)
        self.tracker = tracker
        self.routing = routing
        self.network = network
    }

    /// 须在启动对账之前登记的清理项：撤回同意要清的凭证（切换环境时同样要清，两边共用占位清理器）；剪贴板 hash 记录的撤回清理
    /// （APP-07：在启动对账重试上次没清干净的撤回之前登记，只进撤回同意的注册表）。
    private static func registerEarlyCleaners() {
        PrivacyWithdrawalCleanup.registerForEnvironmentSwitch(.shared)
        ClipboardRecordsCleaner.register()
        // APP-08：订单断网缓存（撤回同意与切换环境都删；待清理状态在缓存目录之外，启动对账重试撤回清理时一并完成）
        OrderCacheCleaner.register()
        // APP-09：钱包摘要缓存与提现金额草稿（同上）
        WalletCacheCleaner.register()
    }

    /// 剪贴板（APP-07）、购买（APP-06b）与搜索 / 详情（APP-06a）的组装。
    private static func makeShopping(web: AppWeb, login: AppLogin) -> (AppClipboard, AppSearch) {
        let (network, routing, privacy) = (web.network, web.routing, web.privacy)
        let (config, tracker) = (web.config, web.tracker)
        web.login = login
        // 剪贴板识别（APP-07）：写剪贴板的唯一入口、自动识别、粘贴入口与 parse；桥与登录页经它。
        let clipboard = AppClipboard.make(
            network: network, routing: routing, privacy: privacy, config: config, login: login
        )
        web.clipboard = clipboard
        login.clipboard = clipboard
        // 购买（APP-06b）：AuthSheet 计数、点击结果确认的平台状态、外跳端口、link_jump 上报（经埋点本地队列）、购买待办。
        let trade = AppTrade(
            network: network, config: config, privacy: privacy, routing: routing, login: login,
            writer: clipboard.writer
        ) { event, attribution in tracker.track(event, attribution: attribution) }
        // 购买弹层是剪贴板的敏感浮层（G12、H06）
        trade.onSensitiveOverlay = { [weak clipboard] in clipboard?.sensitiveOverlayShown() }
        clipboard.overlaySource = { [weak trade] in trade?.sensitiveOverlay }
        // 搜索与商品详情（APP-06a）：搜索页订阅配置变化（search_status），路由出栈时作废在途请求。
        let search = AppSearch(network: network, config: config, privacy: privacy, routing: routing, trade: trade)
        search.clipboard = clipboard
        return (clipboard, search)
    }

    /// 订单（APP-08）：订单列表、详情与待跟单卡；商品详情 / 搜索页的待跟单卡经 AppSearch 接上（外跳回前台后拉一次）。
    private static func makeOrders(web: AppWeb, login: AppLogin, clipboard: AppClipboard,
                                   search: AppSearch) -> AppOrders {
        let orders = AppOrders(network: web.network, config: web.config, routing: web.routing, login: login)
        orders.clipboard = clipboard
        orders.permissions = web.permissions
        search.orders = orders
        search.trade?.onPageForeground = { [weak orders] id in orders?.pageForeground(id) }
        return orders
    }

    /// 钱包（APP-09）：金额隐藏与订单页共用同一份本机偏好（AppOrders.mask）；交易流水号复制走剪贴板统一写入口；route_params_dropped 进埋点。
    /// Debug / Staging 打开本机假服务时接上假实名、假劳务协议与测试号码（Release 没有，G01、G02、G31）。
    private static func makeWallet(_ web: AppWeb, _ login: AppLogin, _ clipboard: AppClipboard,
                                   _ orders: AppOrders) -> AppWallet {
        let wallet = AppWallet(
            network: web.network, config: web.config, routing: web.routing, login: login, mask: orders.mask
        )
        wallet.clipboard = clipboard
        let tracker = web.tracker
        wallet.track = { event in _ = tracker.track(event) }
        #if DEBUG
        DebugFakeWallet.install(wallet)
        #endif
        return wallet
    }

    /// 网络核心。Debug / Staging 带启动参数 `-CouliFakeLoginServer` 时用本机假服务（URLProtocol 桩，不连任何地址；
    /// APP-04 共性 2：假登录只在调试构建编译，Release 制品扫描查标记）。
    private static func makeNetwork() -> AppNetwork {
        #if DEBUG
        if let configuration = DebugFakeLoginServer.configurationIfEnabled() {
            return AppNetwork(configuration: configuration)
        }
        #endif
        return AppNetwork()
    }

    private static func makeUpdate() -> AppUpdate {
        #if DEBUG
        DebugUpdateScenario.applyResetArgument()
        #endif
        return AppUpdate.makeForBuild()
    }

    var body: some Scene {
        WindowGroup {
            RootView(routing: routing)
                .environmentObject(environment)
                .environmentObject(router)
                .environmentObject(privacy)
                .environmentObject(update)
                .environmentObject(config)
                .environmentObject(permissions)
                .environmentObject(web)
                .environmentObject(login)
                .environmentObject(search)
                .environmentObject(clipboard)
                .environmentObject(orders)
                .environmentObject(wallet)
                .onOpenURL { url in
                    routing.handle(url: url)
                }
                .onChange(of: environment.gate) { gate in
                    routing.environmentGateChanged()
                    config.startIfSettled(gate)
                    tracker.startIfReady()
                }
                .onChange(of: scenePhase) { phase in
                    switch phase {
                    case .background:
                        routing.sceneEnteredBackground()
                        config.enteredBackground()
                        search.restoration.sceneEnteredBackground()
                        search.trade?.sceneChanged(active: false)
                        clipboard.sceneBackground()
                        orders.sceneEnteredBackground()
                    case .active:
                        routing.sceneBecameActive()
                        config.enteredForeground()
                        search.restoration.sceneBecameActive()
                        search.trade?.sceneChanged(active: true)
                        // 剪贴板：冷启动第一次与进过后台之后的那一次才判定（下拉通知等 inactive → active 不算，共性第 1 条）
                        clipboard.sceneActive()
                        orders.sceneBecameActive()
                    case .inactive:
                        // 系统弹窗、切换 App 的过渡：同样作废续执行许可（03 §4.5「进入后台不外跳」，保守）
                        search.trade?.sceneChanged(active: false)
                    @unknown default: break
                    }
                    // 钱包：active 之外（inactive、background）都立即作废等待中的导航与浮层许可（APP-09 iOS R2-03）
                    wallet.scenePhaseChanged(phase)
                }
        }
    }
}
