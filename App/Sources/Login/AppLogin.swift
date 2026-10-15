import Combine
import CouliNetwork
import DesignSystem
import Foundation
import Login
import Router

/// App 侧的登录（APP-05a、APP-05b）：组合 LoginService、第三方登录 OAuthLoginService、绑手机 BindPhoneService（ApiClient、生产出口
/// RouterLoginHost），给登录页与绑手机页配置，给守卫会话状态，登出。
/// - 守卫的会话状态由 `ApiClient.isolatedSessionScope` 与本会话的手机号绑定状态现算（游客 / 受限 / 已登录未绑手机 / 已绑手机；
///   phone_bound 未知按未绑，SessionGuardState，APP-05b 共性第 13 条）；
/// - Tracker 的 user_id 本来就由 `ApiClient.isolatedAccount` 现读（AppTracker），登录 / 登出后自动跟上，不另发通知；
/// - 会话失效（clear_session_login）：经 Router 打开登录页并提示 error.10404（LoginSessionExpired）；强更场景保持强更页。
@MainActor
final class AppLogin: ObservableObject {
    /// 会话变化时递增（设置页等据此刷新「已登录」显示）。
    @Published private(set) var sessionVersion = 0
    /// 页顶轻提示（邀请绑定结果、10405 提示等：登录页已关闭后仍要显示的）。
    @Published var toast: CouliToastMessage?
    /// 登录成功后的邀请码未生效弹窗（LoginInviteFailed）：值为正文键。
    @Published var inviteFailedKey: String?

    let service: LoginService
    let host: RouterLoginHost
    let client: ApiClient
    let routing: AppRouting
    let texts = AppLoginTexts()
    private var sessionExpiredPending = false
    /// 剪贴板识别（APP-07）：邀请码【粘贴】与游客邀请预填（CouliApp 创建后接上）。
    weak var clipboard: AppClipboard?
    /// 手机号绑定状态与查询、第三方登录、绑手机（APP-05b）。
    let phone: PhoneBindingStore
    let phoneSync: PhoneBindingSync
    let oauth: OAuthLoginService
    let bind: BindPhoneService
    /// 第三方新号的绑手机引导（LoginBindPhoneGuide）：盖在恢复页上；nil = 不显示。
    @Published var bindGuide: BindGuide?
    /// 绑手机页的导航实例（按 RouteDestination.id）。
    var bindEntries: [UUID: BindPhoneEntry] = [:]
    /// 绑定成功的共享结算出口（CouliApp 接：清钱包里全部 action 的 step-up token，APP-13a 共性第 9 条）。
    var onPhoneBound: ((BindPhoneOwner) -> Void)?
    /// 绑定成功后刷新共享 Me 资料（AppMe 接：按固定归属发新一轮 getMe，R1-02）。
    var onBoundRefresh: ((BindPhoneOwner) -> Void)?
    /// 场景在前台（scenePhase active）。
    var sceneActive = true
    var guideSerial = 0
    /// 手机号状态查询失败的会话世代：之后只在会话状态变化、进绑手机页时再查（不在每次启动协调里重试）。
    var phoneQueryFailed: UInt64?
    let network: AppNetwork
    var pathWatch: AnyCancellable?
    /// 真实登录成功（登录页拿到 logged_in，新会话已保存）：带此刻的会话世代通知（APP-12 推送上报只认这个信号，共性第 3 条）。
    var onLoginCompleted: ((UInt64) -> Void)?
    /// 统一客服出口（APP-12 AppMe.cs；没接时打开帮助中心，与接入前一致）。
    var customerService: ((String) -> Void)?

    init(network: AppNetwork, routing: AppRouting, update: AppUpdate) {
        client = network.client
        self.network = network
        self.routing = routing
        host = RouterLoginHost(
            router: routing.router,
            update: { Self.loginUpdate(update.routerStatus) },
            markBelow: { update.on10405(minSupported: nil) },
            stateChanged: { [weak routing] resume in routing?.sessionStateChanged(resumePending: resume) }
        )
        service = LoginService(client: network.client, host: host)
        // 共性 9：登录页确定出栈的同步出口立即作废本次尝试。
        host.watchLoginPage(service)
        let client = network.client
        let phone = PhoneBindingStore()
        self.phone = phone
        service.phoneBinding = phone
        phoneSync = PhoneBindingSync(client: client, store: phone)
        phoneSync.ownership = { [network] in network.ownershipNow() }
        oauth = OAuthLoginService(login: service, host: host, phone: phoneSync, authorizers: Self.authorizers())
        oauth.ownership = { [network] in network.ownershipNow() }
        bind = BindPhoneService(client: client, sync: phoneSync)
        bind.identity = { [network, client] in
            BindPhoneOwner(request: network.ownershipNow(), scope: client.isolatedSessionScope)
        }
        routing.sessionSource = {
            SessionGuardState.of(
                scope: client.isolatedSessionScope, phoneBound: phone.bound(generation: client.sessionGeneration)
            )
        }
        routing.onSessionStateChanged = { [weak self] in
            self?.sessionVersion &+= 1
            self?.sessionStateSynced()
        }
        routing.beforeLaunchCoordination = { [weak self] in
            self?.ensurePhoneBindingKnown()
        }
        wireBindPhone()
        #if DEBUG
        // 本机假服务的「已登录假账号」（-CouliFakeTradeLoggedIn）是短信登录的账号：守卫按已绑手机（假 getMe 同样回 phone_bound=true）
        DebugFakeOAuth.seedLoggedInPhone(self, arguments: ProcessInfo.processInfo.arguments)
        #endif
        network.source.onSessionEffect = { [weak self] effect, generation in
            self?.sessionEffect(effect, generation: generation)
        }
        network.source.onSessionRefreshed = { [weak self] generation, origin in
            self?.sessionRefreshed(generation, origin: origin)
        }
    }

    /// 共性 14、19：异步刷新成功（受限会话可能已变为 full）。先核对刷新所属的会话世代仍是当前的（已退出、换账号的不管）：
    /// - 冷启动或版本恢复的受限会话屏障开的刷新：通知启动协调器（AppRouting.launchConditionsChanged），由 Router 守卫按此刻
    ///   的会话与强更结论恢复待办；
    /// - 其他来源（登录尝试的受限复查等）：只同步会话状态，不恢复待办——有效的登录流程自己交 Router 恢复，已取消的复查
    ///   不能借这条通知恢复（共性 10）。
    func sessionRefreshed(_ generation: UInt64, origin: SessionRefreshOrigin) {
        guard generation == client.sessionGeneration else { return }
        routing.sessionStateChanged(resumePending: origin == .restrictedBarrier)
    }

    /// 强更检查进度 → 登录后计划用的取值。
    static func loginUpdate(_ status: UpdateCheckStatus) -> RouterLoginHost.Update {
        switch status {
        case .checking, .finished(.checking):
            .checking
        case .finished(.belowMin):
            .below
        case .finished(.unknown):
            .unknown
        case .finished(.ok), .finished(.belowRecommended):
            .supported
        }
    }

    var loggedIn: Bool {
        client.isolatedSessionScope != nil
    }

    /// 当前会话账号（经会话隔离判断）。
    var account: String? {
        client.isolatedAccount
    }

    /// 当前会话世代。
    var sessionGeneration: UInt64 {
        client.sessionGeneration
    }

    /// 网络层的会话 Effect（共性 18、26，03 §4.2）：10404 或刷新失败清了会话。类型原样保留，归属是网络层在清理发生的同一
    /// 同步区里记下的清理后会话世代（`ErrorEffect.sessionGeneration`，不在回调时读当前世代补作归属）：
    /// - 之后已换代（重新登录等）的不再处理；登出流程自己收尾（logout 回 10404 时不另开登录页）；
    /// - 先同步守卫的会话状态与强更页（不恢复待办）；
    /// - clear_session_stay_force_update，或此刻处于强更场景：保持强更页，不开登录页；
    /// - 其余（普通会话失效）：经 Router 打开 Login，并提示 error.10404（LoginSessionExpired）。
    func sessionEffect(_ effect: ErrorEffect, generation: UInt64) {
        guard effect.kind == .clearSessionLogin || effect.kind == .clearSessionStayForceUpdate else { return }
        guard generation == client.sessionGeneration else { return }
        routing.sessionStateChanged(resumePending: false)
        guard effect.kind == .clearSessionLogin, !routing.mustShowForceUpdate, !service.isLoggingOut else { return }
        openSessionExpiredLogin()
    }

    /// 打开会话失效的登录页（LoginSessionExpired）。登录页已在栈顶时不再叠一层，只提示。
    private func openSessionExpiredLogin() {
        let router = routing.router
        if router.path.last?.route == RoutePolicy.login {
            toast = CouliToastMessage(LoginDraftTexts.text(LoginKeys.sessionExpired))
            return
        }
        sessionExpiredPending = true
        let decision = router.open(RouteRequest(route: RoutePolicy.login, from: .inApp))
        if decision.kind != .open, decision.kind != .openReadonly {
            // 没打开（守卫拦下）：提示标记不留给以后别的登录页。
            sessionExpiredPending = false
        }
    }

    /// 登录页配置。restricted：从强更页进入（APP-02c 内部来源标记 `RouteDestination.fromForceUpdatePage`）。
    func pageConfig(restricted: Bool) -> LoginPageConfig {
        let config = LoginPageConfig(service: service, texts: texts)
        config.restricted = restricted
        config.sessionExpired = sessionExpiredPending
        sessionExpiredPending = false
        // 第三方登录（APP-05b）：按钮是否显示由适配器决定（正式微信恒不可用；Apple 的 entitlement 开关，rule-gaps iOS I01）
        config.oauth = oauth
        let router = routing.router
        config.onClose = { router.removeRoute(RoutePolicy.login) }
        config.onSettings = { router.open(RouteRequest(route: "Settings", from: .inApp)) }
        // login.help_entry：help_links.login_help 未配置时打开帮助中心首页（BR-TEXT-14 表 C）。TODO(N-26)：接 help_links。
        config.onHelp = { router.open(RouteRequest(route: "Help", from: .inApp)) }
        config.onAgreement = { type in
            let request = RouteRequest(route: "Agreement", values: ["type": .string(type)], from: .inApp)
            if restricted {
                router.openFromForceUpdatePage(request)
            } else {
                router.open(request)
            }
        }
        // APP-12：统一客服出口（原样 kf.url；未装微信给复制链接与帮助中心，G20）
        config.onCustomerService = { [weak self] in
            if let customerService = self?.customerService {
                customerService(RoutePolicy.login)
            } else {
                router.open(RouteRequest(route: "Help", from: .inApp))
            }
        }
        config.onLoggedIn = { [weak self] outcome in
            guard let self else { return }
            onLoginCompleted?(client.sessionGeneration)
            showInviteResult(outcome)
        }
        // 剪贴板（APP-07）：邀请码行【粘贴】（受限登录不显示邀请码，也就没有【粘贴】，H07 同口径）；游客邀请确认后的预填（G16）
        if let clipboard, !restricted {
            config.invitePaste = clipboard.makeLoginInvitePaste()
            config.takeInvitePrefill = { [weak clipboard] in clipboard?.invitePrefill.take() }
        }
        config.onForceUpdate = { [weak self] key in
            // 10405：提示先更新（error.10405.no_account 等），关闭登录页回到强更页（BR-ID-01 细则「受限登录」）。
            self?.toast = CouliToastMessage(LoginDraftTexts.text(key ?? "error.10405"))
            router.removeRoute(RoutePolicy.login)
            self?.routing.sessionStateChanged(resumePending: false)
        }
        return config
    }

    /// 登录成功后的邀请绑定结果（LoginInviteBound / LoginInviteFailed；BR-INV-06 细则）：bound → 轻提示；failed → 弹窗，
    /// 【去补填】打开「我的」（补填页另有任务）；ignored_existing_user 不提示。不改变登录后的路由计划（AFTER-03）。
    private func showInviteResult(_ outcome: LoginOutcome) {
        switch outcome.inviteResult {
        case "bound":
            toast = CouliToastMessage(LoginDraftTexts.text("login.invite_bound"))
        case "failed":
            inviteFailedKey = outcome.inviteCode == 42901
                ? "login.invite_failed.rate_limited" : "login.invite_failed.body"
        default:
            break
        }
    }

    func openInviteBackfill() {
        inviteFailedKey = nil
        routing.router.open(RouteRequest(route: "Me", from: .inApp))
    }

    /// 设置页【退出登录】确认之后。返回 true = 已回到游客。
    /// 登出在会话级作用域里执行（共性 13）：放进 AppLogin 自己的任务，不随设置页的生命周期或调用方取消而中断；LoginService
    /// 按原会话世代完成本地清理并调用 Router.sessionEnded。
    /// `owner`（APP-12 R1-04）：确认时固定的请求归属——发送绑定它、本地清理只按 `owner.generation`；确认之后已换成新会话则不动新会话。
    @discardableResult
    func logout(owner: RequestOwnership? = nil) async -> Bool {
        let service = service
        let task = Task { @MainActor in await service.logout(owner: owner) }
        return await task.value
    }
}
