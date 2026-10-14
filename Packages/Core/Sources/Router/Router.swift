import Combine
import Foundation
import Generated

/// 导航栈里的一页。`route` 为 nil 表示内置的升级提示页（routes.json 没有它的路由名，rule-gaps G03）。
public struct RouteDestination: Hashable, Sendable, Identifiable {
    public let id: UUID
    public let route: String?
    public let params: [String: JSONValue]
    /// 只读打开（基本模式、强更检查结果未知）：页面不得自动发起写请求或授权（03 §4.4）。
    public let readonly: Bool
    /// 从强更页的次要入口进入（APP-02c，03 §4.1）：登录页据此按「受限登录」显示——不显示【设置】、「登录遇到问题」
    /// 与邀请码等业务输入（BR-ID-01 细则「受限会话」）。路由参数不能带它（Login 的 params schema 不允许多余字段）。
    public let fromForceUpdatePage: Bool

    public init(
        id: UUID = UUID(),
        route: String?,
        params: [String: JSONValue] = [:],
        readonly: Bool = false,
        fromForceUpdatePage: Bool = false
    ) {
        self.id = id
        self.route = route
        self.params = params
        self.readonly = readonly
        self.fromForceUpdatePage = fromForceUpdatePage
    }

    public var isUpgradePrompt: Bool {
        route == nil
    }
}

/// Router：`EntryGuard.decide` → 按结论推入页面 / 登记 pending_action / 进前置页 / 排队（03 §4.4）。
/// 原生页面、首页卡片、JSBridge nav.open、推送点击、深链都走 `open`。Tab 根路由（含 Home）是栈底，不入栈，改切 `tabRoot`。
@MainActor
public final class Router: ObservableObject {
    /// pending_action 里「打开路由」动作的标签（rule-gaps G13：动作编码表未定）。
    public static let openRouteAction = "open_route"

    @Published public var path: [RouteDestination] = []
    /// 当前一级 Tab 的根页面（R1-05）：Router → 外壳的 Tab 选择接口。打开 Tab 根路由（Home、AgentChat、OrderList、Me）时
    /// 清空导航栈并切到该 Tab，保留只读标记；外壳按它决定选中哪个 Tab、以什么目的地渲染 Tab 根页面。
    @Published public internal(set) var tabRoot = RouteDestination(route: RoutePolicy.home)
    /// 守卫要求先补隐私同意（02b 接隐私弹窗）。
    @Published public internal(set) var consentRequested = false
    /// 用户在 App 内发起、正等待隐私弹窗结论的动作（R1-01）：只在内存，进程重启即无。
    /// 置位期间启动协调不自动恢复 pending_action（那条待办归弹窗结论处理）。
    /// 不用 `consentRequested` 本身判断：@Published 在 willSet 时就通知订阅方，订阅方（弹出弹窗 → 启动协调）
    /// 读到的还是旧值。所以这里先置位、再发布 `consentRequested`。
    public internal(set) var awaitingConsentResult = false
    /// 刚完成一个前置步骤（同意隐私政策等）、待办等启动协调恢复（F-IOS-09）：下一次条件都满足的协调按「完成前置」
    /// 恢复（还缺前置时进下一个前置页），而不是在回调里直接恢复——那会绕过强更等待与 Tab 就绪。
    var resumeAfterPrerequisite = false
    /// 最近一次结论（调试显示、埋点用）。
    @Published public internal(set) var lastDecision: GuardDecision?

    public let routes: [String: RouteSpec]
    let pendingStore: PendingActionStore
    let state: @MainActor () -> GuardState
    var launchQueue = LaunchQueue()
    /// 排队的推送意图对应的回查器（APP-02c R1-02）：随消息编号一起保存，放行时用它回查；放行、丢弃或被新意图覆盖时清掉。
    var queuedPushLanding: PushLanding?
    /// 启动队列新增或重新排队一条意图时调用（APP-02c R1-03）：App 的启动协调据此按检查起点安排 5 秒超时，
    /// 检查开始后才排进来的外部请求同样会在第 5 秒按 unknown 放行。
    public var onLaunchQueueChanged: (@MainActor () -> Void)?
    /// 从强更页次要入口发起、正在等隐私补同意的请求（APP-02c R1-01）：只在内存，不登记 pending_action；
    /// 同意后仍是强更状态时按强更来源继续（受限登录等），拒绝或强更已解除时丢弃。
    var forceUpdateConsentRequest: RouteRequest?
    /// 会话 / 环境代次：退出登录、切换账号、切换环境时递增，进行中的推送回查结果据此作废。
    private var generation: UInt64 = 0
    /// 资金与实名页面带参数打开、参数被丢弃时调用（路由名、丢弃个数；APP-09）。App 记 route_params_dropped。没接时不记。
    public var onParamsDropped: (@MainActor (String, Int) -> Void)?
    /// 会话归属标签来源（APP-05a 共性 25；App 接 ApiClient.sessionGeneration）：登记 pending_action、发起推送回查时记下，
    /// 登出收尾按它只清原会话归属的部分。nil = 未接（按旧口径整体清理）。
    public var sessionTag: (@MainActor () -> UInt64)?
    /// 当前这条 pending_action 登记时的会话标签（只在内存；记录内容对不上的，例如进程重启前登记的，按归属未知处理）。
    var pendingTag: (record: PendingAction, tag: UInt64)?
    /// 已结束的会话标签上界：发起时标签不大于它的推送回查结果丢弃（`sessionEnded(throughSession:)`）。
    var endedSessionTag: UInt64?

    public init(
        routes: [String: RouteSpec] = Routes.all,
        pendingStore: PendingActionStore,
        state: @escaping @MainActor () -> GuardState
    ) {
        self.routes = routes
        self.pendingStore = pendingStore
        self.state = state
    }

    // MARK: - 打开

    @discardableResult
    public func open(_ request: RouteRequest) -> GuardDecision {
        open(request, state: state())
    }

    @discardableResult
    func open(_ request: RouteRequest, state: GuardState) -> GuardDecision {
        // 推送兜底改落 Messages 时，登记与执行都针对实际目标 Messages（清空参数），不登记被拒绝的原始目标（R1-02）。
        // 原始目标是敏感动作（BR-ID-10「不适用的动作」）时同样如此（第 2 轮评审 R2-02）：敏感原目标本身从不登记，
        // 但兜底的 Messages 要登记，登录后落到 Messages（BR-ID-10 推送兜底与登录后落点）。
        // 是否禁止登记由 `remember` 按实际目标判断。
        let (decision, target) = EntryGuard.decideWithTarget(request: request, state: state, routes: routes)
        purgeAgentPendingIfPrivacyBlocked(state)
        apply(decision, for: target)
        return decision
    }

    /// 按守卫结论执行。
    func apply(_ decision: GuardDecision, for request: RouteRequest) {
        lastDecision = decision
        switch decision.kind {
        case .open, .openReadonly:
            showOpened(decision, for: request)
        case .forceUpdate:
            enterForceUpdate()
        case .requireLogin, .requireBindPhone, .requireRealname:
            remember(request)
            if let route = decision.route {
                show(RouteDestination(route: route))
            }
        case .requireConsent:
            // 普通 App 内请求先登记，同意后按前置继续并恢复原路由（R1-06）；
            // Agent 卡片要求用户重新点击，不登记（BR-ID-10 Agent 卡片 ②）。
            if request.sourceKind != .agentCard {
                remember(request)
            }
            awaitingConsentResult = true
            consentRequested = true
        case .upgrade:
            show(RouteDestination(route: nil))
        case .deferred:
            // 外部带进来的请求排队，等条件满足后再交给 Router；App 内的操作不排队。
            // 桥调用（nav.open）也不排队、不补执行：结果以桥的回复为准，调用方已收到「没打开」或被取消
            // （APP-04 共性 65）。
            if request.sourceKind != .inApp, request.sourceKind != .bridge {
                queueLaunch(.route(request), pushLanding: nil)
            }
        case .reject:
            // 不打开：停在当前页（冷启动时即首页）。TODO(APP-03): 记埋点 route_entry_blocked（只带路由名与入口类别）。
            break
        }
    }

    func show(_ destination: RouteDestination) {
        if let route = destination.route, RoutePolicy.tabRootRoutes.contains(route) {
            path = []
            tabRoot = destination
        } else {
            path.append(destination)
        }
    }

    /// 登记 pending_action（实际目标属于 `RoutePolicy.noPendingActionRoutes` 的除外）：动作为打开该路由，
    /// params 为路由名与经校验、清洗后的路由参数（不含令牌，BR-ID-10），
    /// 并记下原始来源（origin）。参数不符合 routes.json schema 的不登记。
    private func remember(_ request: RouteRequest) {
        // 需二次验证的操作及其前置步骤不登记（BR-ID-10 细则「不适用的动作」）。
        guard !RoutePolicy.noPendingActionRoutes.contains(request.route) else { return }
        // Agent 卡片只带路由名；资金与实名页面不带参数。
        // Agent 卡片在隐私阻断时不登记（遇隐私阻断即删，BR-ID-10 Agent 卡片 ②）。
        if request.sourceKind == .agentCard, !privacyAllowsAgentRecord(state()) {
            return
        }
        let params = request.sourceKind == .agentCard ? [:] : EntryGuard.effectiveParams(request)
        // 只存通过 routes.json schema 的参数；路由表里没有的路由不登记（R3：只存清洗且通过 schema 的参数）。
        guard let spec = routes[request.route], RouteParamValidator.isValid(params, spec: spec) else {
            return
        }
        var values: [String: JSONValue] = ["route": .string(request.route)]
        if !params.isEmpty {
            values["params"] = .object(params)
        }
        if pendingStore.save(
            action: Self.openRouteAction,
            values: values,
            now: pendingStore.now,
            origin: request.sourceKind.rawValue
        ) {
            tagPending()
        }
    }

    // MARK: - pending_action

    /// 完成了一个前置步骤（登录、绑手机、实名、隐私同意等）：重置计时后尝试恢复。
    public func prerequisiteCompleted() {
        pendingStore.markStepDone(now: pendingStore.now)
        resumePending()
    }

    /// 恢复 pending_action：再过一次守卫（source=pending_action）。还缺前置时保留记录并进前置页；其余情况执行 1 次后删除。
    /// Agent 卡片登记的动作遇隐私阻断直接删除，不自动执行（BR-ID-10，R1-05）。
    public func resumePending() {
        resumePending(state: state(), entersPrerequisite: true)
    }

    /// 恢复 pending_action 的公共实现。
    /// - `entersPrerequisite`：还缺前置时是否进前置页。用户刚完成一个前置步骤时为 true（继续下一个前置）；
    ///   冷启动与条件变化时为 false——前置未满足（登录、绑手机、实名、隐私同意）一律保留记录、不自动拉起前置页（F-IOS-08）。
    func resumePending(state current: GuardState, entersPrerequisite: Bool) {
        guard let pending = pendingStore.load(now: pendingStore.now) else { return }
        // 不是「打开路由」的待办（APP-06b 购买 open_link）由登记它的发起页自己执行一次（Router 只负责同一份本地记录的计时与清除）：
        // 这里既不执行也不删除（H02 同口径）。记录损坏（open_route 却没有路由名）仍删除。
        guard pending.action == Self.openRouteAction else { return }
        guard let route = pending.paramValues["route"]?.stringValue else {
            pendingStore.clear()
            return
        }
        let request = RouteRequest(
            route: route,
            values: pending.paramValues["params"]?.objectValue ?? [:],
            from: .pendingAction
        )
        let decision = EntryGuard.decide(request: request, state: current, routes: routes)
        if pending.origin == RouteSource.agentCard.rawValue,
           decision.isPrivacyBlock || !privacyAllowsAgentRecord(current) {
            lastDecision = decision
            pendingStore.clear()
            return
        }
        if !entersPrerequisite, decision.isPrerequisite || decision.kind == .requireConsent {
            // 前置未满足：保留记录（计时不重置，过期后由读取时删除），不弹前置页、不弹隐私弹窗。
            // 等待类（defer）在下面的 switch 里同样保留；reject（含 basic_mode_blocked、entry_not_allowed、
            // params_invalid）一律删除、不补执行（F-ALL-04）。
            lastDecision = decision
            return
        }
        if decision.isPrerequisite {
            lastDecision = decision
            if let next = decision.route {
                show(RouteDestination(route: next))
            }
            return
        }
        switch decision.kind {
        case .deferred:
            break
        case .requireConsent:
            // 恢复来源不会得到 require_consent（基本模式下按外部请求丢弃）；保守起见保留记录、请求同意。
            lastDecision = decision
            awaitingConsentResult = true
            consentRequested = true
        default:
            pendingStore.clear()
            apply(decision, for: request)
        }
    }

    /// 退出登录、切换账号：清除 pending_action（BR-ID-10），并作废进行中的推送回查（R1-01）。
    public func sessionEnded() {
        pendingStore.clear()
        generation &+= 1
    }

    /// 切换环境：作废进行中的推送回查与排队的启动意图（pending_action 随命名空间清理一并删除）。
    public func environmentChanged() {
        pendingStore.clear()
        launchQueue = LaunchQueue()
        queuedPushLanding = nil
        generation &+= 1
    }

    // MARK: - 启动意图

    /// 条件满足时放行排队的启动意图；推送意图经 `PushLanding` 回查后再打开。
    /// 返回推送回查的任务（测试可等待它结束）；没有回查时为 nil。
    @discardableResult
    public func drainLaunchQueue(
        readiness: LaunchReadiness,
        now: Int64,
        pushLanding: PushLanding? = nil
    ) -> Task<Void, Never>? {
        guard let released = launchQueue.release(readiness: readiness, now: now) else { return nil }
        // 排队时保存的回查器优先（热推送在检查期间排队，R1-02）；冷启动推送没有保存时用调用方给的。
        let landing = queuedPushLanding ?? pushLanding
        queuedPushLanding = nil
        var guardState = state()
        guardState.environmentSettled = readiness.environmentSettled
        guardState.privacy = readiness.privacy
        guardState.update = released.update
        purgeAgentPendingIfPrivacyBlocked(guardState)
        switch released.intent {
        case let .route(request):
            open(request, state: guardState)
            return nil
        case let .push(messageId):
            guard let landing else { return nil }
            return startPush(messageId: messageId, state: guardState, using: landing)
        }
    }

    /// 运行中点击推送（热启动）的唯一入口：发起时绑定会话 / 环境代次，回查返回时代次不符一律丢弃（R2-01）。
    /// 回查之前先过守卫里与目标无关的几步（环境未就绪、隐私未决、强更、受限会话 / 未登录都不发回查）；
    /// 还要等待时把这条推送排进启动队列，条件满足后再回查。
    /// 返回推送回查的任务（测试可等待它结束）；没有发起回查时为 nil。
    @discardableResult
    public func handlePush(messageId: String, using pushLanding: PushLanding) -> Task<Void, Never>? {
        let current = state()
        purgeAgentPendingIfPrivacyBlocked(current)
        // 运行中隐私未决 = 正停在首启弹窗 / 二次说明：热推送直接丢弃，不入启动队列（03 §4.4 末句，R1-04）。
        // 只有冷启动捕获的推送（`enqueueLaunch(.push)`）才等待隐私结论。
        if current.privacy == .notDecided {
            lastDecision = GuardDecision(kind: .deferred, route: nil, reason: GuardReason.privacyUndecided)
            return nil
        }
        return startPush(messageId: messageId, state: current, using: pushLanding, hot: true)
    }

    private func startPush(messageId: String, state guardState: GuardState,
                           using pushLanding: PushLanding, hot: Bool = false) -> Task<Void, Never>? {
        let issued = generation
        let session = sessionTag?()
        if let blocked = PushLanding.probe(state: guardState, routes: routes) {
            finishPush(blocked, messageId: messageId, issuedAt: issued, hot: hot, landing: pushLanding)
            return nil
        }
        let routes = routes
        return Task { @MainActor [weak self] in
            let result = await pushLanding.land(messageId: messageId, state: guardState, routes: routes)
            guard let self, !sessionTagEnded(session) else { return }
            finishPush(result, messageId: messageId, issuedAt: issued, hot: hot, landing: pushLanding)
        }
    }

    /// 推送回查返回：会话或环境已变（退出登录、切换账号、切换环境）则丢弃旧结果；
    /// 否则用当时最新的状态重新判定后执行（R1-01）。还要等待时把这条推送重新排队，条件满足后再回查。
    /// 代次只在 Router 内部发放与校验：没有公开的「直接执行回查结果」入口（R2-01）。
    /// `hot`：运行中点击的推送。等待隐私结论（首启弹窗期间）时丢弃，不排队（R1-04）；其余等待照常排队。
    /// `landing`：这条推送的回查器，重新排队时一起保存，放行时照常回查（R1-02）。
    func finishPush(_ result: PushLandingResult, messageId: String, issuedAt: UInt64, hot: Bool = false,
                    landing: PushLanding? = nil) {
        guard issuedAt == generation else { return }
        let current = redecide(result)
        if current.decision.kind == .deferred {
            lastDecision = current.decision
            if hot, current.decision.reason == GuardReason.privacyUndecided {
                return
            }
            queueLaunch(.push(messageId: messageId), pushLanding: landing)
            return
        }
        execute(current)
    }

    /// 测试与内部用：执行一条推送落点结论，必须带发起时的代次；代次不符丢弃。
    func applyPush(_ result: PushLandingResult, issuedAt: UInt64) {
        guard issuedAt == generation else { return }
        execute(redecide(result))
    }

    /// 当前会话 / 环境代次（测试用）。
    var currentGeneration: UInt64 {
        generation
    }

    private func redecide(_ result: PushLandingResult) -> PushLandingResult {
        let lookedUp = result.request ?? RouteRequest(route: RoutePolicy.messages, from: .push)
        return PushLanding.resolve(lookedUp: lookedUp, state: state(), routes: routes)
    }

    private func execute(_ result: PushLandingResult) {
        if let afterLogin = result.afterLogin {
            remember(afterLogin)
            lastDecision = result.decision
            if let route = result.decision.route {
                show(RouteDestination(route: route))
            }
            return
        }
        let request = result.request ?? RouteRequest(route: RoutePolicy.messages, from: .push)
        // 兜底 Messages 时按实际目标登记 / 打开（R1-02）；敏感原目标兜底时同样登记 Messages（R2-02）。
        let target = EntryGuard.decideWithTarget(request: request, state: state(), routes: routes).target
        apply(result.decision, for: target)
    }
}
