import Config
import Foundation
import Generated
import Router

/// App 侧的 Router 接线（APP-02a 最小外壳）：本构建的路由表、守卫状态源、深链入站配置。
///
/// 隐私闸门、强更检查、会话由 02b、02c、APP-05 接入；这里先用可注入的占位状态源。
@MainActor
final class AppRouting {
    /// 守卫状态里由其他任务提供的几项（占位，可在调试时替换）。
    struct Placeholders {
        // TODO(APP-02b): 接 PrivacyGate 的首启弹窗结论（同意 / 基本模式 / 未决）。
        var privacy: PrivacyState = .consented
        // TODO(APP-02c): 接强更检查（检查中 / 结果 / 超时按 unknown）。
        var update: UpdateCheckStatus = .finished(.ok)
        // TODO(APP-05): 接 Session（游客 / 已登录 / 已绑手机 / 受限会话）。
        var session: SessionState = .guest
        // TODO(APP-05): 接实名结论；未知按未实名（auth=realname 进实名前置）。
        var realnameVerified = false
        // TODO(APP-03): 接 /v1/config 的 external_hosts 与 bridge_origins；缺省空 = ExternalPage、WebPage 全拒。
        var targets: RouteTargetAllowlist = .empty
    }

    let environment: EnvironmentStore
    var placeholders = Placeholders()
    private(set) lazy var router: Router = .init(
        routes: Self.routeTable,
        pendingStore: PendingActionStore(backend: UserDefaultsPendingBackend()),
        state: { [unowned self] in guardState }
    )

    init(environment: EnvironmentStore) {
        self.environment = environment
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
            privacy: placeholders.privacy,
            update: placeholders.update
        )
    }

    var guardState: GuardState {
        let update = LaunchQueue.effectiveUpdate(placeholders.update, now: PendingActionStore.wallClockMillis())
        return GuardState(
            privacyState: placeholders.privacy,
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
    func handle(url: URL) {
        let request = DeepLinkParser.parse(
            url: url.absoluteString,
            config: Self.deepLinkConfig,
            routes: router.routes
        )
        guard let request else { return }
        router.enqueueLaunch(.route(request))
        drainLaunchQueue()
    }

    /// 强更仍在检查时，到「闸门通过 + 5 秒」再 drain 一次的唯一计时（闸门未就绪时不计时）。
    private var retryTask: Task<Void, Never>?

    /// 状态变化（环境就绪、隐私结论、强更结果）后调用。
    func drainLaunchQueue() {
        let readiness = readiness
        let now = PendingActionStore.wallClockMillis()
        router.drainLaunchQueue(readiness: readiness, now: now)
        retryTask?.cancel()
        retryTask = nil
        guard let retryAt = router.launchRetryAt(readiness: readiness) else { return }
        let delay = max(retryAt - now, 0)
        retryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(delay))
            guard !Task.isCancelled else { return }
            self?.drainLaunchQueue()
        }
    }
}
