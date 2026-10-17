import ClientCore
import Clipboard
import Combine
import Config
import CouliNetwork
import Foundation
import Generated
import Login
import MeCore
import Privacy
import Push
import Router
import WalletCore

/// App 侧的「我的」、设置、隐私中心、关于、封禁说明与申诉、推送上报与统一客服出口（APP-12）：
/// - 身份（`identity`）：身份档（隐私结论 + 会话）+ 账号 + 网络归属（会话世代、作废世代）+ 撤回 / 切环境清理次数；会话、隐私、环境、强更状态
///   变化时同步重算（`syncIdentity`）。账号或会话世代变了：清空 Me 快照、重置禁用期、只能登录访问的页面（RiskNotice、Appeal）移出导航栈、
///   其余页面按新身份重建执行器（旧确认框、草稿、回调随之作废，共性第 18 条）；
/// - 10006 统一落点（`on10006`，网络层一处）：调用仍有效、入口时的导航票据与此刻一致、强更不在显示、栈顶不是 RiskNotice → 清栈再经 Router 打开
///   RiskNotice（栈里只留它），并记「本次运行因 10006 进入」（G10，绑定触发时的身份）；
/// - 撤回同意的应用级协调器（`withdrawConsent`，不随隐私中心出栈销毁，F-HM-24）：同步停报推送 → 设备级 recordConsent(privacy, false)（设备未注册
///   跳过）→ 无论结果调已有的 PrivacyController.withdraw() → 基本模式；落盘失败在当前界面提示并可重试；
/// - 退出登录（`logout`）：同步停报推送 → 已有 AppLogin.logout()（失败也完成本地退出，已有行为）→ 按发起实例与导航判断回「我的」游客态；
/// - 推送令牌上报（`push`）：登录成功（只认登录页的完成通知）、已登录冷启动（等版本检查）、令牌变化；退出、撤回、基本模式、deletion_only 不报；
/// - 统一客服出口（`cs`）：原样 kf.url。
@MainActor
final class AppMe: ObservableObject {
    static let me = "Me"
    static let riskNotice = "RiskNotice"
    static let appeal = "Appeal"
    static let agreement = "Agreement"
    static let help = "Help"
    static let recordConsent = "recordConsent"
    static let loginOnly: Set<String> = [riskNotice, appeal]

    let client: ApiClient
    let router: Router
    let routing: AppRouting
    let config: AppConfig
    let privacy: PrivacyController
    let update: AppUpdate
    weak var login: AppLogin?
    let system: MeSystemPorts
    let local: MeLocalStore
    let mask: AmountMaskStore
    let gates: MeGates
    let tickets: NavigationTickets
    let credentialsReadable: @MainActor () -> Bool
    let lifetimes: WebRouteLifetimes
    private(set) var deps: MeDeps!
    private(set) var cs: CustomerServiceEntry!
    private(set) var push: PushTokenReporter!
    private(set) var pushTracker: PushSessionTracker!
    let pushSource: PushTokenSource
    /// 剪贴板的统一写入口（APP-07）；nil = 没接（复制提示失败，不写剪贴板）。
    weak var clipboard: AppClipboard?
    /// 统一写入口的替身（测试注入同一个 ClipboardWriter 实现与假系统剪贴板）；nil = 用 `clipboard.writer`。
    var writer: ClipboardWriter?
    /// 设备 id（撤回同意的服务端记录要设备已注册，G25；诊断信息只取后 6 位）。生产为 DeviceRegistry.deviceId。
    var deviceId: () -> String?
    /// 「重新显示下单须知」成功：下单须知已读缓存推进世代（AppTrade.tips.reset）。
    var onTipsReset: () -> Void = {}
    /// 诊断信息「最近 3 个 trace_id」：网络层没有记录（rule-gaps I 段），整行省略。
    var recentTraceIds: () -> [String] = { [] }
    /// 本机时钟（测试注入）。
    var clock: () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }

    private(set) var currentIdentity: MeIdentity
    /// 因 10006 进入过 RiskNotice 的那个身份（G10；共性第 30 条：绑定触发时固定的身份，身份任一部分变化即清除）。
    private(set) var entered10006: MeIdentity?
    /// 撤回同意 / 切换环境清理的次数（身份键的一部分）。
    private(set) var clearedCount = 0
    var loggingOutNow = false
    /// 用户导航次数（经 Router 的栈 / Tab 变化、离开前台；不含本类自己做的清栈与 10006 落点）：退出登录的落点据此判断「发起之后又导航过」。
    var userNavigations = 0
    var internalNavigation = false
    var sceneActive = true
    /// 栈里的「我的」类页面（导航实例 → 页面）。
    var pages: [UUID: MePageEntry] = [:]
    /// 「我的」Tab 根（每一次进入一个执行器，R1-03 / R2-01）。
    private(set) var tabHost: MePageHost<MeTabController>!
    let scroll = MeScrollMemory()
    var tabEntered = false
    var tabEnterScheduled = false
    var withdrawFailureSerial = 0
    /// 撤回清理重试（生产为 `PrivacyWithdrawalCleanup.runner.retryIfPending`；测试注入）。
    var retryWithdrawal: () -> Bool = { PrivacyWithdrawalCleanup.runner.retryIfPending() }
    private var subscriptions: Set<AnyCancellable> = []
    /// 绑定后 getMe 的会话级发起方（不随页面离开；身份变化由 MeRepository 按身份核对作废）。
    private let boundReader = MeSessionReader()

    init(
        network: AppNetwork, routing: AppRouting, config: AppConfig, login: AppLogin, update: AppUpdate,
        system: MeSystemPorts, mask: AmountMaskStore, local: MeLocalStore = MeLocalCleaner.shared.store,
        pushSource: PushTokenSource, nickname: NicknameBackend? = nil, notify: NotifyBackend? = nil,
        credentialsReadable: @escaping @MainActor () -> Bool = { PrivacyWithdrawalCleanup.runner.credentialsReadable },
        withdrawalRegistry: EnvironmentSwitchCleanerRegistry = PrivacyWithdrawalCleanup.registry,
        environmentRegistry: EnvironmentSwitchCleanerRegistry = .shared,
        api: MeApi? = nil
    ) {
        client = network.client
        router = routing.router
        self.routing = routing
        self.config = config
        privacy = routing.privacy
        self.update = update
        self.login = login
        self.system = system
        self.mask = mask
        self.local = local
        self.pushSource = pushSource
        self.credentialsReadable = credentialsReadable
        tickets = network.source.tickets
        gates = MeGates()
        lifetimes = WebRouteLifetimes(router: routing.router)
        let registry = network.registry
        deviceId = { registry.deviceId }
        currentIdentity = .none
        deps = MeDeps(
            api: api ?? network.client, env: self, gates: gates, texts: AppMeTexts(), local: local, mask: mask,
            nickname: nickname, notify: notify
        )
        cs = CustomerServiceEntry(ports: self)
        push = PushTokenReporter(source: pushSource, state: self, api: network.client)
        let client = network.client
        pushTracker = PushSessionTracker(
            reporter: push, sessionKey: { [weak self] in self?.sessionKey() ?? "" },
            generation: { client.sessionGeneration }, update: { [weak self] in self?.updateRaw() ?? "unknown" }
        )
        currentIdentity = computeIdentity()
        tabHost = MePageHost(MeTabController(deps: deps, identity: currentIdentity))
        tabHost.onAppear = { [weak self] in self?.enterTab() }
        wire(network: network, login: login, update: update)
        // 会话级清理（撤回同意、切换环境）：内存里的 Me 快照、草稿、推送上报状态、客服半屏、禁用期（G29）
        MeSessionCleaner.register(withdrawal: withdrawalRegistry, environmentSwitch: environmentRegistry, owner: self)
    }

    private func wire(network: AppNetwork, login: AppLogin, update: AppUpdate) {
        network.source.personalizationOff = { [local] in local.personalizationOffNow }
        network.source
            .onRiskNotice = { [weak self] ticket, owner, stillValid in
                self?.on10006(ticket, owner: owner, stillValid: stillValid)
            }
        login.onLoginCompleted = { [weak self] generation in self?.pushTracker.loginCompleted(generation) }
        login.customerService = { [weak self] route in self?.cs.open(from: route) }
        login.onBoundRefresh = { [weak self] owner in self?.refreshAfterBind(owner) }
        login.$sessionVersion.dropFirst().sink { [weak self] _ in
            Task { @MainActor [weak self] in self?.syncIdentity() }
        }.store(in: &subscriptions)
        privacy.observeState { [weak self] _ in
            Task { @MainActor [weak self] in self?.syncIdentity() }
        }
        update.observeRouterStatus { [weak self] _ in
            Task { @MainActor [weak self] in self?.syncIdentity() }
        }
        router.$path.sink { [weak self] path in
            MainActor.assumeIsolated { self?.pathChanged(path) }
        }.store(in: &subscriptions)
        router.$tabRoot.sink { [weak self] root in
            MainActor.assumeIsolated { self?.tabRootChanged(root) }
        }.store(in: &subscriptions)
        MeLocalCleaner.shared.onCleared = { [weak self] in self?.objectWillChange.send() }
    }

    // MARK: - 绑定手机号之后

    /// 绑定成功的共享结算（APP-05b R1-02，APP-13a 共性第 25 条）：按绑定请求的固定归属发新一轮 getMe，更新「我的」与设置共用的 Me 快照。
    /// - 只在此刻身份仍是该归属（同账号、同会话世代与作废世代）时发；换了会话的不动新会话；
    /// - 遵守 getMe 的共享读取限流（MeGates.read 禁用期内不发，不另写错误态）；
    /// - 新发一次（不并入绑定前已在途的读取，它们按读取序号被取代、结果不再结算），发起方是会话级读取者（页面在不在都结算）。
    func refreshAfterBind(_ owner: BindPhoneOwner) {
        syncIdentity()
        let identity = currentIdentity
        guard identity.member, identity.request == owner.request, !gates.read.active else { return }
        deps.repo.refresh(identity, page: boundReader)
    }

    // MARK: - 身份

    /// 此刻的身份（现算，一次读取）。
    func computeIdentity() -> MeIdentity {
        identity(from: client.identitySnapshot(credentialsReadable: credentialsReadable()))
    }

    func identity(from snapshot: IdentitySnapshot) -> MeIdentity {
        // 未知时继续保留上一次已确认的身份档；是否可执行必须另走 check 三态。
        if !snapshot.known, snapshot.readable, privacy.routerPrivacy == .consented {
            return currentIdentity
        }
        let level = privacy.routerPrivacy != .consented || !snapshot.readable
            ? MeLevel.basic : (snapshot.member ? MeLevel.member : MeLevel.guest)
        let account = level == MeLevel.member ? snapshot.account : nil
        let key = "\(level)|\(account ?? "-")|\(snapshot.generation)|\(snapshot.epoch)|\(clearedCount)"
        return MeIdentity(level: level, account: account, request: snapshot.request, key: key)
    }

    /// 会话、隐私、环境、版本状态变化后同步：身份变了 → 账号或会话世代变了就清空 Me 快照、重置禁用期、移出只能登录访问的页面；页面按新身份
    /// 重建执行器；推送会话跟踪同步。
    func syncIdentity() {
        let snapshot = client.identitySnapshot(credentialsReadable: credentialsReadable())
        guard snapshot.known || !snapshot.readable || privacy.routerPrivacy != .consented else { return }
        let next = identity(from: snapshot)
        let previous = currentIdentity
        if next != previous {
            currentIdentity = next
            // 10006 版式依据绑定触发时的身份（共性第 30 条）：身份任一部分变了（换账号、退出、撤回、切环境）同步清除
            if entered10006 != nil, entered10006 != next {
                entered10006 = nil
            }
            let sessionChanged = next.account != previous.account || next.request != previous.request
                || next.level != previous.level
            if sessionChanged {
                gates.reset()
                deps.repo.reset(next)
                if previous.member {
                    closeLoginOnlyPages()
                }
            }
            rebuildPages(next)
            objectWillChange.send()
        }
        for entry in Array(pages.values) {
            (entry.controller() as? IdentityResumable)?.resumeAfterIdentityConfirmed()
        }
        if tabEntered {
            tabHost.controller.resumeAfterIdentityConfirmed()
        }
        pushTracker.sync()
    }

    /// 会话换代（会话失效、登出、换账号）：只能登录访问的页面移出导航栈（APP-09 共性第 13 条的「移出导航栈」做法）。
    private func closeLoginOnlyPages() {
        guard let index = router.path.firstIndex(where: { Self.loginOnly.contains($0.route ?? "") }) else { return }
        navigateInternally { router.path.removeSubrange(index...) }
    }

    /// 本类自己做的导航（清栈、10006 落点）：不算用户导航。
    func navigateInternally(_ change: () -> Void) {
        internalNavigation = true
        change()
        internalNavigation = false
    }

    func enteredBy10006(_ identity: MeIdentity) -> Bool {
        entered10006.map { $0 == identity && identity.member } ?? false
    }

    var sessionKeyValue: String {
        sessionKey()
    }

    func sessionKey() -> String {
        let id = computeIdentity()
        return id.member ? "\(id.request?.generation ?? 0)|\(id.account ?? "")" : ""
    }

    /// 强更结论：supported / below / unknown（与网络层同一映射）。
    func updateRaw() -> String {
        AppNetwork.networkUpdate(update.routerStatus)
    }

    // MARK: - 10006

    /// 10006 → RiskNotice（G09，只此一处；已切到主线程）：调用仍有效、发起之后没有再导航（票据一致，空票据不放行）、强更不在显示、栈顶不是
    /// RiskNotice → 清栈再经 Router 打开 RiskNotice（栈里只留它），并记「本次运行因 10006 进入」（G10）。
    /// `owner` 是网络层带出的请求发起时归属（账号 + 登录世代 + 作废世代，R2-01）：与此刻的身份**只比较**，任一项不同（同栈换账号、退出、撤回、
    /// 切环境之后迟到的旧 10006）不导航、不记、不清栈；不拿此刻的身份补作旧响应的归属（共性第 30、34 条）。
    func on10006(_ ticket: UInt64?, owner request: RequestOwnership, stillValid: @Sendable () -> Bool) {
        guard let ticket, ticket == tickets.value, sceneActive, stillValid() else { return }
        let owner = computeIdentity()
        guard owner.member, owner.request == request else { return }
        let top = router.path.last?.route ?? router.tabRoot.route ?? ""
        let forced = routing.mustShowForceUpdate || router.isOnForceUpdate
        guard Route10006.decide(topRoute: top, forceUpdateShowing: forced) == Route10006.replace else { return }
        entered10006 = owner
        navigateInternally {
            router.path = []
            router.open(RouteRequest(route: Self.riskNotice, from: .inApp))
        }
    }

    // MARK: - 会话级清理

    /// 撤回同意的清理（撤回清理名单的一项）：Me 快照、草稿（随页面执行器重建作废）、推送上报状态（停令牌来源）、客服半屏、禁用期。
    func clearForConsentRevoked() {
        entered10006 = nil
        push.consentWithdrawn()
        pushTracker.cancelColdStart()
        clearSessionMemory()
    }

    /// 切换环境（清理名单的一项）：会话级数据清空（设备级偏好不清，G29）。
    func clearForEnvironmentSwitch() {
        entered10006 = nil
        push.loggedOut()
        pushTracker.cancelColdStart()
        clearSessionMemory()
    }

    private func clearSessionMemory() {
        clearedCount += 1
        cs.invalidate()
        gates.reset()
        deps.repo.reset()
        scroll.reset()
    }

    // MARK: - 推送

    /// 推送令牌来源变化后（Debug 假来源）重新同步一次（测试用）。
    func pushStateChanged() {
        pushTracker.sync()
    }
}

/// 会话级的 Me 读取发起方（绑定手机号后的刷新，R1-02）：不属于任何页面，始终可读；结果仍按身份与读取序号核对。
@MainActor
final class MeSessionReader: MeReader {
    var reading: Bool {
        true
    }
}
