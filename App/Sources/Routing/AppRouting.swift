import Combine
import Config
import Foundation
import Generated
import Router

/// App 侧的 Router 接线：本构建的路由表、守卫状态源、深链入站配置，以及冷启动协调（03 §4.4）。
///
/// 冷启动顺序：环境闸门 → 隐私闸门有结论（APP-02b，`PrivacyController`）→ 强更检查有结果或等满 5 秒（APP-02c，
/// `AppUpdate`）→ Tab 外壳就绪 → 恢复 pending_action、放行启动意图（`Router.launchConditionsChanged`，F-IOS-08）。
/// 会话由 APP-05 接入；这里先用可注入的占位状态源。
/// 强更（APP-02c）：below_min 时无论在哪个页面都进入 ForceUpdate（隐私闸门有结论之后）；解除后回到外壳。
@MainActor
final class AppRouting {
    /// 守卫状态里由其他任务提供的几项（占位，可在调试时替换）。
    struct Placeholders {
        /// 会话状态源未接上（`sessionSource` 为 nil，测试等）时用的会话状态。APP-05a 起生产由 AppLogin 接上 `sessionSource`。
        var session: SessionState = .guest
        // TODO(APP-05): 接实名结论；未知按未实名（auth=realname 进实名前置）。
        var realnameVerified = false
        // TODO(APP-03): 接 /v1/config 的 external_hosts 与 bridge_origins；缺省空 = ExternalPage、WebPage 全拒。
        var targets: RouteTargetAllowlist = .empty
    }

    let environment: EnvironmentStore
    let privacy: PrivacyController
    let update: AppUpdate
    var placeholders = Placeholders()
    /// 守卫的会话状态源（APP-05a：AppLogin 按 ApiClient 的会话现算：游客 / 受限 / 已绑手机）。隐私未同意时一律按游客。
    var sessionSource: (@MainActor () -> SessionState)?
    /// 守卫的实名结论来源（APP-09：AppWallet 按 GET /v1/me 的 realname_status 给，只认本会话查到的 verified；未知按未实名，BR-ID-02）。
    /// 没接时用占位（false）。
    var realnameSource: (@MainActor () -> Bool)?
    /// 会话状态变化（登录、登出、会话被清）后通知（AppLogin 刷新设置页等）。
    var onSessionStateChanged: (@MainActor () -> Void)?
    /// 每次启动协调之前（APP-05b 共性第 8 条）：AppLogin 在会话有效、手机号状态未知且有手机号级待办时先查一次当前会话的 getMe。
    var beforeLaunchCoordination: (@MainActor () -> Void)?
    /// Tab 外壳（或基本模式页）已经显示。
    private(set) var shellReady = false
    /// 等启动协调的自动动作（APP-06a R2-03：进程回收后的页面恢复）。它们和启动意图、pending_action 一样属于「自动执行的
    /// 动作」（03 §4.4 统一入口守卫）：等环境与隐私闸门、本轮强更检查有结果或等满 5 秒、外壳就绪之后才执行一次。
    var launchAutoActions: [LaunchAutoAction] = []
    private var consentObservation: AnyCancellable?
    private var pathObservation: AnyCancellable?
    private(set) lazy var router: Router = .init(
        routes: Self.routeTable,
        pendingStore: PendingActionStore(backend: UserDefaultsPendingBackend()),
        state: { [unowned self] in guardState }
    )

    init(environment: EnvironmentStore, privacy: PrivacyController, update: AppUpdate) {
        self.environment = environment
        self.privacy = privacy
        self.update = update
        update.onChange = { [weak self] in
            self?.updateChanged()
        }
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
        // 启动队列新增或重新排队（含检查开始后才进来的外部请求、检查期间排队的热推送）：按检查起点安排 5 秒超时（R1-03）。
        router.onLaunchQueueChanged = { [weak self] in
            self?.scheduleLaunchRetry()
        }
        // 强更状态下不能离开强更页（侧滑等任何方式把强更页弹出栈时拉回来，03 §4.1）。
        pathObservation = router.$path
            .sink { [weak self] path in
                MainActor.assumeIsolated {
                    guard let self, path.first?.route != RoutePolicy.forceUpdate,
                          self.mustShowForceUpdate else { return }
                    // 在本次发布之后再改（不在 willSet 里改写正在发布的值）。
                    Task { @MainActor [weak self] in
                        self?.syncForceUpdate()
                    }
                }
            }
        // 冷启动时环境与隐私已就绪（已同意的老用户）：立即发冷启动检查。
        update.conditionsChanged(
            environmentSettled: environment.gate == .settled,
            consented: privacy.routerPrivacy == .consented,
            basicMode: privacy.routerPrivacy == .basicMode
        )
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
            update: update.routerStatus
        )
    }

    var guardState: GuardState {
        // 还在等强更检查（没等满 5 秒）：checking——外部来源与 pending 恢复得到 defer（update_checking），
        // App 内操作不等（F-ALL-03）；等满按 unknown。
        let effective = LaunchQueue.effectiveUpdate(
            update.routerStatus,
            now: PendingActionStore.wallClockMillis(),
            waitFrom: router.launchGatesOpenedAt
        )
        return GuardState(
            privacyState: privacy.routerPrivacy,
            updateState: effective ?? .checking,
            sessionState: currentSession,
            environmentSettled: environment.gate == .settled,
            appVersion: Self.appVersion,
            isDebugBuild: Self.isDebugBuild,
            realnameVerified: realnameSource?() ?? placeholders.realnameVerified,
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
            // 回查器随消息编号一起交给 Router 保存，放行时用它回查（R1-02）。
            router.enqueueLaunch(.push(messageId: messageId), pushLanding: pushLanding)
            launchConditionsChanged()
            return nil
        }
        if privacy.isPrompting {
            return nil
        }
        return router.handlePush(messageId: messageId, using: pushLanding)
    }

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

    /// 回到前台（进过后台之后）：强更按间隔复查（03 §4.1）。
    func sceneBecameActive() {
        guard wasBackgrounded else { return }
        update.enteredForeground()
    }

    /// 环境闸门变化（就绪、阻断）：先告诉强更检查（能不能发 check），再协调启动。
    func environmentGateChanged() {
        updateConditions()
        launchConditionsChanged()
    }

    /// 网络层收到 10405（APP-03 调用）：直接进 below_min → 强更页（03 §4.2）。
    func on10405(minSupported: String?) {
        update.on10405(minSupported: minSupported)
    }

    // MARK: - 强更

    private func updateConditions() {
        update.conditionsChanged(
            environmentSettled: environment.gate == .settled,
            consented: privacy.routerPrivacy == .consented,
            basicMode: privacy.routerPrivacy == .basicMode
        )
    }

    /// 此刻应当停在强更页：环境就绪、隐私闸门有结论（首启弹窗先于强更，03 §4.4 冷启动顺序）、强更 below_min。
    var mustShowForceUpdate: Bool {
        environment.gate == .settled && privacy.routerPrivacy != .notDecided && update
            .routerStatus == .finished(.belowMin)
    }

    /// 强更结论变化（`AppUpdate.onChange`）：进出强更页，再协调启动（恢复待办——below_min 时守卫删除待办，F-AND-07 对应；
    /// 放行排队的启动意图——below_min 时丢弃并停在强更页）。
    private func updateChanged() {
        syncForceUpdate()
        launchConditionsChanged()
    }

    private func syncForceUpdate() {
        if mustShowForceUpdate {
            router.enterForceUpdate()
        } else if update.routerStatus != .finished(.belowMin) {
            router.leaveForceUpdate()
        }
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
        // 先让强更检查知道能不能发 check（同意后补发冷启动检查），Router 读到的才是「检查中」而不是「还没开始」。
        updateConditions()
        router.privacyChanged()
        syncForceUpdate()
        launchConditionsChanged()
    }

    /// 用户在隐私弹窗 / 隐私中心的操作（APP-02b 评审，三端统一）：
    /// - 同意 = 完成一个前置步骤：守卫发起的补同意走 `consentResolved(granted: true)`，否则走 `recordPrerequisiteCompleted`
    ///   （重置计时）；待办的恢复（按前置继续，如进登录页）交给启动协调，等强更检查有结果或等满 5 秒、Tab 就绪（F-IOS-09）；
    /// - 同意没生效（撤回清理重试仍失败，弹窗关闭、仍是基本模式）：结束这次补同意，复位 Router 的两个标记并丢弃本次待办，
    ///   受限 Tab 之后还能再弹隐私提示（F-IOS-10）；
    /// - 基本模式里再次不同意 / 仍不同意（或守卫发起的补同意被拒）：丢弃本次登记的待办，之后同意也不自动打开被拒的目标；
    /// - 进入基本模式（仍不同意、撤回同意）：清空导航栈，回到基本模式页。
    private func privacyAction(_ action: PrivacyController.Action) {
        switch action {
        case .agree:
            guard privacy.state.decision == .consented else {
                if router.awaitingConsentResult || router.consentRequested {
                    router.consentResolved(granted: false)
                }
                return
            }
            if router.awaitingConsentResult || router.consentRequested {
                router.consentResolved(granted: true)
            } else {
                router.recordPrerequisiteCompleted()
            }
            // 先处理本次前置结果，再协调启动恢复（R1-01）；条件不满足时等下一次协调（F-IOS-09）。
            launchConditionsChanged()
        case .disagree, .stillDisagree:
            if router.awaitingConsentResult || router.consentRequested || privacy.state.decision == .basicMode {
                router.consentResolved(granted: false)
            }
            if action == .stillDisagree {
                router.enteredBasicMode()
            }
            launchConditionsChanged()
        case .withdraw:
            router.enteredBasicMode()
            // 基本模式不发检查：本机记着 below_min 的仍停在强更页（BR-ID-11 细则「基本模式与强更检查」）。
            syncForceUpdate()
        case .requestFullFunction:
            break
        }
    }

    /// 强更仍在检查时，到「闸门通过 + 5 秒」再协调一次的唯一计时（闸门未就绪或无事可做时不计时）。
    private var retryTask: Task<Void, Never>?
    /// 已安排的那次超时协调的时刻（毫秒，测试与调试用）；没有安排时为 nil。
    private(set) var scheduledLaunchRetryAt: Int64?

    /// 状态变化（环境就绪、隐私结论、强更结果、外壳就绪、会话变化）后调用：
    /// 恢复 pending_action、放行排队的启动意图（Router.launchConditionsChanged，F-IOS-08）。
    func launchConditionsChanged() {
        beforeLaunchCoordination?()
        let readiness = readiness
        let now = PendingActionStore.wallClockMillis()
        router.launchConditionsChanged(readiness: readiness, shellReady: shellReady, now: now)
        runLaunchAutoActions(readiness: readiness, now: now)
        scheduleLaunchRetry(readiness: readiness, now: now)
    }

    /// 按此刻的启动队列与待办重新安排（或取消）超时协调。入队时也调用（R1-03）：检查开始后才排进来的入口同样在
    /// 「检查起点（不早于闸门通过）+ 5 秒」按 unknown 处理。
    func scheduleLaunchRetry() {
        scheduleLaunchRetry(readiness: readiness, now: PendingActionStore.wallClockMillis())
    }

    private func scheduleLaunchRetry(readiness: LaunchReadiness, now: Int64) {
        retryTask?.cancel()
        retryTask = nil
        scheduledLaunchRetryAt = nil
        // 截止时间已过（超时那次已协调）时为 nil：只等状态变化再协调（R1-06）。
        guard let retryAt = router.launchConditionsRetryAt(readiness: readiness, now: now)
            ?? autoActionRetryAt(readiness: readiness, now: now)
        else { return }
        scheduledLaunchRetryAt = retryAt
        let delay = max(retryAt - now, 0)
        retryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(delay))
            guard !Task.isCancelled else { return }
            self?.launchConditionsChanged()
        }
    }
}

extension AppRouting {
    // MARK: - 隐私弹窗与强更页的叠放

    /// 隐私弹窗（首启弹窗、二次说明、补同意）此刻显示：在 Tab 外壳上（导航栈为空），或叠在强更页上（栈顶是 ForceUpdate，
    /// R1-01：基本模式下从强更页进需要同意的入口时弹补同意）。从弹窗里的协议链接推入的 Agreement 盖住时先让出，读完返回再出现。
    var showsPrivacyDialog: Bool {
        Self.privacyDialogVisible(isPrompting: privacy.isPrompting, path: router.path)
    }

    static func privacyDialogVisible(isPrompting: Bool, path: [RouteDestination]) -> Bool {
        isPrompting && (path.isEmpty || path.last?.route == RoutePolicy.forceUpdate)
    }

    /// 隐私弹窗里的协议链接（F-ALL-06）：强更状态下按强更来源打开 Agreement，否则照常 App 内打开。
    func openAgreementFromPrivacyDialog(type: String?) {
        var params: [String: JSONValue] = [:]
        if let type {
            params["type"] = .string(type)
        }
        router.openFromPrivacyDialog(RouteRequest(route: "Agreement", values: params, from: .inApp))
    }
}

extension AppRouting {
    // MARK: - 会话（APP-05a）

    var currentSession: SessionState {
        guard let sessionSource else { return placeholders.session }
        return privacy.routerPrivacy == .consented ? sessionSource() : .guest
    }

    /// 会话变化后的路由同步（APP-05a，LoginHost 的出口）：先同步强更页，再通知各处刷新会话显示；
    /// `resumePending = true`（有效的登录流程）时协调启动（满足条件的 pending_action 随之恢复）；false 时只同步，
    /// 不恢复待办（APP-05a 共性 10：已作废的登录尝试、登出、会话被清）。
    func sessionStateChanged(resumePending: Bool) {
        syncForceUpdate()
        onSessionStateChanged?()
        if resumePending {
            launchConditionsChanged()
        }
    }
}
