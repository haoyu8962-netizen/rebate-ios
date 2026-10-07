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
    @Environment(\.scenePhase) private var scenePhase
    private let routing: AppRouting
    private let network: AppNetwork
    private let tracker: AppTracker

    init() {
        // 撤回同意要清的凭证，切换环境时同样要清（两边共用占位清理器）；须在启动对账之前登记。
        PrivacyWithdrawalCleanup.registerForEnvironmentSwitch(.shared)
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
        _permissions = StateObject(wrappedValue: permissions)
        // 两类 WebView 容器与 JSBridge（APP-04）：创建即把「作废在途桥调用」登记进撤回同意、切换环境两个注册表的第一位。
        let web = AppWeb(
            config: config, network: network, routing: routing, privacy: privacy, update: update,
            tracker: tracker, permissions: permissions
        )
        web.login = login
        _web = StateObject(wrappedValue: web)
        _login = StateObject(wrappedValue: login)
        self.tracker = tracker
        self.routing = routing
        self.network = network
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
                    case .active:
                        routing.sceneBecameActive()
                        config.enteredForeground()
                    default: break
                    }
                }
        }
    }
}
