import ClientCore
import Config
import MeCore
import Privacy
import Push
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
    @StateObject private var me: AppMe
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
        // 同意后的第一步：设备注册（APP-03b，DeviceRegistry；失败按闸门的退避重试）；推送步骤只启动 PushTokenSource（APP-12 G17）。
        let (privacy, pushSource) = Self.makePrivacy(network)
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
        let account = Self.makeAccount(web, login, update, MeShopModules(clipboard, search, orders), pushSource)
        (_wallet, _me) = (StateObject(wrappedValue: account.wallet), StateObject(wrappedValue: account.me))
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
        // APP-12：设备级本机偏好 couli_me_prefs（引导条关闭时刻、个性化开关；只进撤回同意的注册表，切换环境不清，G29）
        MeLocalCleaner.register(withdrawal: PrivacyWithdrawalCleanup.registry)
    }

    /// 隐私闸门（APP-02b）与推送令牌来源（APP-12 G17：Release 恒为无令牌；Debug 带 `-CouliFakePushToken` 时给测试令牌）。
    private static func makePrivacy(_ network: AppNetwork) -> (PrivacyController, PushTokenSource) {
        let pushSource = makePushSource()
        let privacy = PrivacyController(
            deviceRegistration: { done in network.registerDevice(done: done) }, pushStart: { pushSource.start() }
        )
        return (privacy, pushSource)
    }

    /// 推送令牌来源（APP-12 G17）：Release 恒为无令牌（不初始化任何推送 SDK、不上报）；Debug / Staging 带启动参数时用假来源。
    private static func makePushSource() -> PushTokenSource {
        #if DEBUG
        if let fake = DebugPushTokenSource.fromLaunchArguments() {
            return fake
        }
        #endif
        return NoPushTokenSource()
    }

    /// 「我的」、设置、隐私中心、关于、封禁说明与申诉、推送上报、统一客服出口（APP-12）：金额隐藏与订单、钱包页共用同一份本机偏好；复制只走剪贴板
    /// 统一写入口；统一客服出口替换登录页、授权管理、订单详情、钱包的「联系客服 → Help」占位；getMe 的读取截止时间与钱包实名查询、桥 auth.getUser
    /// 共用。Debug / Staging 打开本机假服务时接上改昵称、通知设置的假后端（Release 没有，G01、G02）。
    private static func makeAccount(
        _ web: AppWeb, _ login: AppLogin, _ update: AppUpdate, _ shop: MeShopModules, _ pushSource: PushTokenSource
    ) -> (wallet: AppWallet, me: AppMe) {
        let wallet = makeWallet(web, login, shop.clipboard, shop.orders)
        var system: MeSystemPorts = IOSMeSystem(permissions: web.permissions)
        var backends: (nickname: NicknameBackend?, notify: NotifyBackend?) = (nil, nil)
        #if DEBUG
        system = DebugMeSystem.wrap(system)
        backends = DebugFakeMe.backends()
        #endif
        let me = AppMe(
            network: web.network, routing: web.routing, config: web.config, login: login, update: update,
            system: system, mask: shop.orders.mask, pushSource: pushSource, nickname: backends.nickname,
            notify: backends.notify
        )
        me.clipboard = shop.clipboard
        let open: @MainActor (String) -> Void = { [weak me] route in me?.cs.open(from: route) }
        wallet.customerService = open
        wallet.meReadGate = me.gates.read
        web.meReadGate = me.gates.read
        shop.orders.customerService = open
        shop.search.trade?.customerService = open
        if let tips = shop.search.trade?.tips {
            me.onTipsReset = { tips.reset() }
        }
        return (wallet, me)
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
                .environmentObject(me)
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
                    // 「我的」：同样作废导航许可（10006 票据），回前台按新的一次进入取 Me（G36）
                    me.scenePhaseChanged(phase)
                }
        }
    }
}

/// 「我的」要接上的购物、订单模块（统一客服出口、剪贴板写入口、下单须知已读缓存）。
@MainActor
struct MeShopModules {
    let clipboard: AppClipboard
    let search: AppSearch
    let orders: AppOrders

    init(_ clipboard: AppClipboard, _ search: AppSearch, _ orders: AppOrders) {
        self.clipboard = clipboard
        self.search = search
        self.orders = orders
    }
}
