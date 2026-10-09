import Config
import DesignSystem
import Generated
import Privacy
import Router
import SwiftUI

/// 根视图：环境闸门 → 隐私闸门 → Tab 外壳（03 §4.4 冷启动顺序，APP-02b）。
/// - 未决（首次启动、政策版本升级后的冷启动）：启动底 + 首启弹窗 / 二次说明，Tab 外壳尚未出现；
/// - 基本模式：Tab 外壳，首页 Tab 是基本模式页；点【开启完整功能】或需要同意的 Tab 时弹首启弹窗；
/// - 已同意：Tab 外壳。Router 推入的页面盖在外壳之上（NavigationStack）。
/// DEBUG 下首页占位下方另显示令牌版本、构建配置、最近一次路由结论与调试面板入口（英文开发字样）。
struct RootView: View {
    let routing: AppRouting
    @EnvironmentObject private var environment: EnvironmentStore
    @EnvironmentObject private var router: Router
    @EnvironmentObject private var privacy: PrivacyController
    @EnvironmentObject private var update: AppUpdate
    @EnvironmentObject private var permissions: AppPermissions
    @EnvironmentObject private var login: AppLogin
    @EnvironmentObject private var search: AppSearch
    #if DEBUG
    @State private var showsDebugPanel = false
    #endif

    var body: some View {
        #if DEBUG
        if let width = DebugLayoutWidth.value {
            // 截图用（APP-05a）：`-CouliDebugLayoutWidth 320` 把根布局限制为窄屏宽度（模拟器没有 320pt 宽机型）。
            gatedByEnvironment.frame(width: width).frame(maxWidth: .infinity)
        } else {
            gatedByEnvironment
        }
        #else
        gatedByEnvironment
        #endif
    }

    @ViewBuilder private var gatedByEnvironment: some View {
        switch environment.gate {
        case .settled:
            #if DEBUG
            if let page = CatalogLaunch.page {
                // 截图用：启动参数直达组件目录的某一页（DS-01）。
                CatalogLaunchView(page: page, section: CatalogLaunch.section)
            } else {
                gated
            }
            #else
            gated
            #endif
        case .blocked:
            EnvironmentBlockedView(retry: environment.retryLaunchCleanup)
        }
    }

    /// 弹窗盖在整个导航栈上（Tab 外壳或强更页之上）；从弹窗里的协议链接经 Router 推入 Agreement 时先让出（读完返回，弹窗回来）——
    /// 弹窗本身仍不能被关闭，只能点按钮（BR-ID-11）。
    private var gated: some View {
        navigation
            .couliDialog(isPresented: privacyDialogShown) {
                privacyDialog()
            }
            .couliDialog(isPresented: showsUpdatePrompt) {
                UpdatePromptDialog(
                    result: UpdateCheckResultView(
                        title: update.ui.result?.updateTitle,
                        notes: update.ui.result?.updateNotes,
                        latest: update.ui.targetVersion
                    ),
                    onLater: update.dismissPrompt,
                    onGo: update.promptGoStore
                ).dialog
            }
            .couliDialog(isPresented: permissions.rationale != nil) {
                permissions.rationaleDialog
            }
            .couliDialog(isPresented: permissions.settingsGuide != nil) {
                permissions.settingsGuideDialog
            }
            .couliDialog(isPresented: login.inviteFailedKey != nil) {
                InviteFailedDialog.make(login, bodyKey: login.inviteFailedKey ?? "login.invite_failed.body")
            }
            .couliToast($update.toast)
            .couliToast($login.toast)
    }

    /// 隐私弹窗显示条件（R1-01，判定见 `AppRouting.privacyDialogVisible`）；读发布值，界面随之刷新。
    private var privacyDialogShown: Bool {
        AppRouting.privacyDialogVisible(isPrompting: privacy.isPrompting, path: router.path)
    }

    /// 可关闭更新提示（MainUpdatePrompt）：已同意隐私政策、停在 Tab 外壳（导航栈为空）、没有首启弹窗时才弹。
    private var showsUpdatePrompt: Bool {
        update.showsPrompt && privacy.state.decision == .consented && !privacy.isPrompting && router.path.isEmpty
    }

    private func privacyDialog() -> CouliDialog {
        let open: (AgreementLink) -> Void = { link in
            // 强更状态下带强更来源打开（F-ALL-06）。
            routing.openAgreementFromPrivacyDialog(type: link.agreementType)
        }
        if privacy.state.promptStage == .second {
            return SecondNoticeDialog(
                onAgree: privacy.agree,
                onStillDisagree: privacy.stillDisagree,
                onOpen: open
            ).dialog
        }
        return LaunchPrivacyDialog(onAgree: privacy.agree, onDisagree: privacy.disagree, onOpen: open).dialog
    }

    /// 栈底：隐私未决时是启动底（首启弹窗背后），有结论后是 Tab 外壳；其余路由由 Router 推入。
    private var navigation: some View {
        NavigationStack(path: $router.path) {
            stackRoot
                .toolbar(.hidden, for: .navigationBar)
                .navigationDestination(for: RouteDestination.self) { destination in
                    RouteViewRegistry.view(for: destination)
                }
        }
        #if DEBUG
        .sheet(isPresented: $showsDebugPanel) {
            DebugPanelView(store: environment, update: update)
                .environmentObject(login)
                .environmentObject(router)
        }
        .overlay(alignment: .bottomTrailing) {
            // 一致性页的逐项结果与路由状态（UI 测试读取；被其他路由盖住时仍在）。
            if showsConformance {
                DebugConformanceResultsOverlay()
            }
        }
        #endif
    }

    @ViewBuilder private var stackRoot: some View {
        if privacy.state.decision == .notDecided {
            LaunchBackdropView()
        } else if showsConformance {
            #if DEBUG
            // 桥一致性页（APP-04，启动参数 -CouliBridgeConformance）：作为栈底，nav.open / auth.login 照常压到它上面。
            if let mode = DebugBridgeConformance.launchMode {
                DebugBridgeConformanceView(mode: mode)
                    .toolbar(.hidden, for: .navigationBar)
            }
            #endif
        } else {
            TabShellView(
                root: router.tabRoot,
                onSelect: { _ = routing.selectTab($0) },
                home: { root in homeTab(root) }
            )
            .onAppear {
                // 外壳就绪：启动协调随之放行启动意图、恢复待办，以及进程回收前的搜索与详情页（共性 20；R2-03 页面恢复
                // 登记在启动协调里，等本轮强更检查有结果或等满 5 秒）。
                routing.shellAppeared()
            }
        }
    }

    private var showsConformance: Bool {
        #if DEBUG
        DebugBridgeConformance.launchMode != nil
        #else
        false
        #endif
    }

    /// 首页 Tab：已同意时按 Router 的实际目的地渲染（保留只读标记，R1-05）。
    @ViewBuilder private func homeTab(_ root: RouteDestination) -> some View {
        if privacy.state.decision == .basicMode {
            BasicModeHomeView(
                onSearch: { router.open(RouteRequest(route: "Search", from: .inApp)) },
                onSettings: { router.open(RouteRequest(route: "Settings", from: .inApp)) },
                onEnableFull: privacy.requestFullFunction
            )
        } else {
            VStack(spacing: 0) {
                // 首页的搜索入口（APP-06a 冒烟：首页 → Search）。首页内容本身在 APP-11。
                HomeSearchEntry { router.open(RouteRequest(route: "Search", from: .inApp)) }
                    .padding(.horizontal, CouliSpacing.s4)
                    .padding(.top, CouliSpacing.s2)
                RouteViewRegistry.view(for: root)
                #if DEBUG
                if !DebugPrivacyPreset.hidesDebugInfo {
                    debugInfo
                        .padding(CouliSpacing.s4)
                }
                #endif
            }
        }
    }

    #if DEBUG
    private var debugInfo: some View {
        VStack(spacing: CouliSpacing.s2) {
            Text(verbatim: "tokens \(DesignTokens.version)")
                .accessibilityIdentifier("root.tokensVersion")
            Text(verbatim: "config \(BuildInfo.configurationName) · env \(environment.current.id)")
                .accessibilityIdentifier("root.buildConfiguration")
            if let decision = router.lastDecision {
                Text(verbatim: "route \(decision.kindRaw) \(decision.route ?? "-") · \(decision.reason)")
                    .accessibilityIdentifier("root.lastRouteDecision")
            }
            Button {
                showsDebugPanel = true
            } label: {
                Text(verbatim: "Debug panel")
                    .frame(minWidth: CouliHitTarget.minimum, minHeight: CouliHitTarget.minimum)
            }
            .accessibilityIdentifier("root.debugPanelButton")
        }
        .couliFont(.footnote)
        .foregroundColor(CouliColor.textSecondary)
    }
    #endif
}

/// 启动对账清理失败（自动重试一次后仍失败）时的阻断页：一句说明 +「重试」。不进入正常界面。
/// 文案取包内默认文案：通用失败用 error.50001 的 fallback（不带追踪号），按钮用 external_page.retry。
/// TODO(APP-02): 契约补通用键（如 common.load_failed / common.retry）后改用通用键。
private struct EnvironmentBlockedView: View {
    let retry: () -> Void

    var body: some View {
        ZStack {
            CouliColor.backgroundCanvas
                .ignoresSafeArea()
            VStack(spacing: CouliSpacing.s4) {
                Text(verbatim: DefaultTexts.fallback("error.50001") ?? "")
                    .couliFont(.body)
                    .foregroundColor(CouliColor.textPrimary)
                    .multilineTextAlignment(.center)
                    .accessibilityIdentifier("environment.blocked.message")
                Button(action: retry) {
                    Text(verbatim: DefaultTexts.text("external_page.retry") ?? "")
                        .frame(minWidth: CouliHitTarget.minimum, minHeight: CouliHitTarget.minimum)
                }
                .accessibilityIdentifier("environment.blocked.retry")
            }
            .padding(CouliSpacing.s6)
        }
    }
}
