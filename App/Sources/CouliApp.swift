import Config
import Privacy
import Router
import SwiftUI

/// 启动：系统启动屏（Info.plist UILaunchScreen，页面底色）→ 环境闸门 → 隐私闸门 → Tab 外壳（APP-02b）。
/// TODO(APP-02c): 强更。
@main
struct CouliApp: App {
    @StateObject private var environment: EnvironmentStore
    @StateObject private var router: Router
    @StateObject private var privacy: PrivacyController
    @Environment(\.scenePhase) private var scenePhase
    private let routing: AppRouting

    init() {
        // 撤回同意要清的凭证，切换环境时同样要清（两边共用占位清理器）；须在启动对账之前登记。
        PrivacyWithdrawalCleanup.registerForEnvironmentSwitch(.shared)
        // 上次撤回同意没清干净的，先重试；清干净之前任何模块不得读取会话凭据（credentialsReadable）。
        PrivacyWithdrawalCleanup.runner.retryIfPending()
        #if DEBUG
        DebugPrivacyPreset.applyFromLaunchArguments()
        #endif
        let environment = BuildInfo.makeEnvironmentStore()
        let privacy = PrivacyController()
        let routing = AppRouting(environment: environment, privacy: privacy)
        _environment = StateObject(wrappedValue: environment)
        _router = StateObject(wrappedValue: routing.router)
        _privacy = StateObject(wrappedValue: privacy)
        self.routing = routing
    }

    var body: some Scene {
        WindowGroup {
            RootView(routing: routing)
                .environmentObject(environment)
                .environmentObject(router)
                .environmentObject(privacy)
                .onOpenURL { url in
                    routing.handle(url: url)
                }
                .onChange(of: environment.gate) { _ in
                    routing.launchConditionsChanged()
                }
                .onChange(of: scenePhase) { phase in
                    if phase == .background {
                        routing.sceneEnteredBackground()
                    }
                }
        }
    }
}
