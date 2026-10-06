import Combine
import Config
import Foundation
import Generated
import Router

/// App 侧的 Router 接线：本构建的路由表、守卫状态源、深链入站配置，以及冷启动协调（03 §4.4）。
///
/// 冷启动顺序：环境闸门 → 隐私闸门有结论（APP-02b，`PrivacyController`）→ 强更检查有结果或等满 5 秒（02c）
/// → Tab 外壳就绪 → 恢复 pending_action、放行启动意图（`Router.launchConditionsChanged`，F-IOS-08）。
/// 强更、会话由 02c、APP-05 接入；这里先用可注入的占位状态源。
@MainActor
final class AppRouting {
    /// 守卫状态里由其他任务提供的几项（占位，可在调试时替换）。
    struct Placeholders {
        // TODO(APP-02c): 接强更检查（检查中 / 结果 / 超时按 unknown）。
        var update: UpdateCheckStatus = .finished(.ok)
        // TODO(APP-05): 接 Session（游客 / 已登录 / 已绑手机 / 受限会话）；会话变化时调 `launchConditionsChanged()`。
        var session: SessionState = .guest
        // TODO(APP-05): 接实名结论；未知按未实名（auth=realname 进实名前置）。
        var realnameVerified = false
        // TODO(APP-03): 接 /v1/config 的 external_hosts 与 bridge_origins；缺省空 = ExternalPage、WebPage 全拒。
        var targets: RouteTargetAllowlist = .empty
    }

    let environment: EnvironmentStore
    let privacy: PrivacyController
    var placeholders = Placeholders()
    /// Tab 外壳（或基本模式页）已经显示。
    private(set) var shellReady = false
    private var consentObservation: AnyCancellable?
    private(set) lazy var router: Router = .init(
        routes: Self.routeTable,
        pendingStore: PendingActionStore(backend: UserDefaultsPendingBackend()),
        state: { [unowned self] in guardState }
    )

    init(environment: EnvironmentStore, privacy: PrivacyController) {
        self.environment = environment
        self.privacy = privacy
        privacy.onChange = { [weak self] in
            self?.privacyChanged()
        }
        privacy.onAction = { [weak self] action in
            self?.privacyAction(action)
        }
        // 守卫要求先补隐私同意（基本模式下 App 内点了需要同意的页面）：弹首启弹窗（BR-ID-02）。
        consentObservation = router.$consentRequested
            .removeDuplicates()
            .filter(\.self)
            .sink { [weak privacy] _ in
                MainActor.assumeIsolated {
                    privacy?.requestFullFunction()
                }
            }
    }

    /// 本构建可用的路由表：Release 只有 Routes.all；Debug / Staging 并入 debug_only 路由（Staging 下包里看不到 DEBUG）。
    static var routeTable: [String: RouteSpec] {
        var table = Routes.all
        #if DEBUG
        table.merge(DebugOnlyRoutes.all) { current, _ in current }
        #endif
        return table
    }

    static var isDebugBuild: Bool {
        #if DEBUG
        true
        #else
        false
        #endif
    }

    /// 深链入站配置。正式的 scheme 与 `l.` 子域未定（needs N-05），apps.json inbound 为空：Release 不认任何深链。
    /// Debug / Staging 只认测试 scheme `couli-debug`（Info.plist 也只在这两套配置声明它）。
    static var deepLinkConfig: DeepLinkConfig {
        #if DEBUG
        DeepLinkConfig(schemes: ["couli-debug"], hosts: [])
        #else
        // TODO(N-05): 负责人给定 scheme 与链接域名后由 apps.json 生成。
        .empty
        #endif
    }

    static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
    }

    var readiness: LaunchReadiness {
        LaunchReadiness(
            environmentSettled: environment.gate == .settled,
            privacy: privacy.routerPrivacy,
            update: placeholders.update
        )
    }

    var guardState: GuardState {
        let update = LaunchQueue.effectiveUpdate(
            placeholders.update,
            now: PendingActionStore.wallClockMillis(),
            waitFrom: router.launchGatesOpenedAt
        )
        return GuardState(
            privacyState: privacy.routerPrivacy,
            updateState: update ?? .unknown,
            sessionState: placeholders.session,
            environmentSettled: environment.gate == .settled,
            appVersion: Self.appVersion,
            isDebugBuild: Self.isDebugBuild,
            realnameVerified: placeholders.realnameVerified,
            targets: placeholders.targets
        )
    }

    /// 外部打开的 URL（深链 / 自定义 scheme）：解析失败的丢弃；成功的作为启动意图排队，条件满足即交给 Router。
    /// App 已在运行（外壳已显示过，或进过后台——之后收到的都不是冷启动带来的）且正停在首启弹窗时收到的，
    /// 只丢弃这条新输入；冷启动带来、已经排队的原意图保留，继续等闸门结论（03 §4.4，R1-03）。
    func handle(url: URL) {
        let request = DeepLinkParser.parse(
            url: url.absoluteString,
            config: Self.deepLinkConfig,
            routes: router.routes
        )
        guard let request else { return }
        if isRunningOnPrivacyPrompt {
            return
        }
        router.enqueueLaunch(.route(request))
        launchConditionsChanged()
    }

    /// 推送点击（TODO(推送任务): MobPush 接入后从这里进；回查函数由推送任务注入）。
    /// - 冷启动带来的（`coldStart`）：只记消息编号排进启动队列，等闸门结论后再回查；
    /// - 运行中点击的（热推送）：正停在首启弹窗时直接丢弃、不入队（03 §4.4，R1-04）；否则交 `Router.handlePush`
    ///   （Router 那一层同样在隐私未决时丢弃热推送）。
    @discardableResult
    func handlePush(messageId: String, coldStart: Bool, using pushLanding: PushLanding) -> Task<Void, Never>? {
        if coldStart, !isRunningOnPrivacyPrompt {
            router.enqueueLaunch(.push(messageId: messageId))
            pendingPushLanding = pushLanding
            launchConditionsChanged()
            return nil
        }
        if privacy.isPrompting {
            return nil
        }
        return router.handlePush(messageId: messageId, using: pushLanding)
    }

    /// 冷启动推送放行时用的回查函数（推送任务接入前为 nil）。
    private var pendingPushLanding: PushLanding?

    /// App 已在运行（外壳已显示过或进过后台）且正停在首启弹窗 / 二次说明。
    private var isRunningOnPrivacyPrompt: Bool {
        (shellReady || wasBackgrounded) && privacy.isPrompting
    }

    /// Tab 外壳（或基本模式页）出现。
    func shellAppeared() {
        guard !shellReady else { return }
        shellReady = true
        launchConditionsChanged()
    }

    /// 进过后台（之后收到的深链都算「运行中收到」）。
    private(set) var wasBackgrounded = false

    func sceneEnteredBackground() {
        wasBackgrounded = true
    }

    /// 一级 Tab 点击：经 Router 过守卫（需要登录 → 登记 pending_action 并去登录；基本模式 → 补同意）。
    /// 放行时 Router 自己切 Tab（更新 `Router.tabRoot`，外壳跟随，R1-05）。
    /// 返回 nil 表示不切换；否则返回 Tab 根页面是否只读打开（保留守卫的只读标记）。
    func selectTab(_ tab: ShellTab) -> Bool? {
        let result = router.selectTab(route: tab.route)
        guard result.allowsSwitch else { return nil }
        return result.decision.kind == .openReadonly
    }

    /// 隐私结论或弹窗阶段变化（`PrivacyController.onChange`）。
    private func privacyChanged() {
        router.privacyChanged()
        launchConditionsChanged()
    }

    /// 用户在隐私弹窗 / 隐私中心的操作（APP-02b 评审，三端统一）：
    /// - 同意 = 完成一个前置步骤：守卫发起的补同意走 `consentHandled(granted: true)`，否则走 `prerequisiteCompleted`
    ///   （重置计时，按前置继续，如进登录页）；
    /// - 基本模式里再次不同意 / 仍不同意（或守卫发起的补同意被拒）：丢弃本次登记的待办，之后同意也不自动打开被拒的目标；
    /// - 进入基本模式（仍不同意、撤回同意）：清空导航栈，回到基本模式页。
    private func privacyAction(_ action: PrivacyController.Action) {
        switch action {
        case .agree:
            guard privacy.state.decision == .consented else { return }
            if router.awaitingConsentResult || router.consentRequested {
                router.consentHandled(granted: true)
            } else {
                router.prerequisiteCompleted()
            }
            // 先处理本次前置结果，再协调启动恢复（R1-01）。
            launchConditionsChanged()
        case .disagree, .stillDisagree:
            if router.awaitingConsentResult || router.consentRequested || privacy.state.decision == .basicMode {
                router.consentHandled(granted: false)
            }
            if action == .stillDisagree {
                router.enteredBasicMode()
            }
            launchConditionsChanged()
        case .withdraw:
            router.enteredBasicMode()
        case .requestFullFunction:
            break
        }
    }

    /// 强更仍在检查时，到「闸门通过 + 5 秒」再协调一次的唯一计时（闸门未就绪或无事可做时不计时）。
    private var retryTask: Task<Void, Never>?

    /// 状态变化（环境就绪、隐私结论、强更结果、外壳就绪、会话变化）后调用：
    /// 恢复 pending_action、放行排队的启动意图（Router.launchConditionsChanged，F-IOS-08）。
    func launchConditionsChanged() {
        let readiness = readiness
        let now = PendingActionStore.wallClockMillis()
        router.launchConditionsChanged(
            readiness: readiness,
            shellReady: shellReady,
            now: now,
            pushLanding: pendingPushLanding
        )
        retryTask?.cancel()
        retryTask = nil
        // 截止时间已过（超时那次已协调）时为 nil：只等状态变化再协调（R1-06）。
        guard let retryAt = router.launchConditionsRetryAt(readiness: readiness, now: now) else { return }
        let delay = max(retryAt - now, 0)
        retryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(delay))
            guard !Task.isCancelled else { return }
            self?.launchConditionsChanged()
        }
    }
}
