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

    public init(id: UUID = UUID(), route: String?, params: [String: JSONValue] = [:], readonly: Bool = false) {
        self.id = id
        self.route = route
        self.params = params
        self.readonly = readonly
    }

    public var isUpgradePrompt: Bool {
        route == nil
    }
}

/// Router：`EntryGuard.decide` → 按结论推入页面 / 登记 pending_action / 进前置页 / 排队（03 §4.4）。
/// 原生页面、首页卡片、JSBridge nav.open、推送点击、深链都走 `open`。Home 是栈底（根视图），不入栈。
@MainActor
public final class Router: ObservableObject {
    /// pending_action 里「打开路由」动作的标签（rule-gaps G13：动作编码表未定）。
    public static let openRouteAction = "open_route"

    @Published public var path: [RouteDestination] = []
    /// 守卫要求先补隐私同意（02b 接隐私弹窗）。
    @Published public private(set) var consentRequested = false
    /// 最近一次结论（调试显示、埋点用）。
    @Published public private(set) var lastDecision: GuardDecision?

    public let routes: [String: RouteSpec]
    private let pendingStore: PendingActionStore
    private let state: @MainActor () -> GuardState
    private var launchQueue = LaunchQueue()
    /// 会话 / 环境代次：退出登录、切换账号、切换环境时递增，进行中的推送回查结果据此作废。
    private var generation: UInt64 = 0

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
        let decision = EntryGuard.decide(request: request, state: state, routes: routes)
        purgeAgentPendingIfPrivacyBlocked(state)
        apply(decision, for: request)
        return decision
    }

    /// 按守卫结论执行。
    func apply(_ decision: GuardDecision, for request: RouteRequest) {
        lastDecision = decision
        switch decision.kind {
        case .open, .openReadonly:
            showOpened(decision, for: request)
        case .forceUpdate:
            path = [RouteDestination(route: RoutePolicy.forceUpdate)]
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
            consentRequested = true
        case .upgrade:
            show(RouteDestination(route: nil))
        case .deferred:
            // 外部带进来的请求排队，等条件满足后再交给 Router；App 内的操作不排队。
            if request.sourceKind != .inApp {
                launchQueue.enqueue(.route(request))
            }
        case .reject:
            // 不打开：停在当前页（冷启动时即首页）。TODO(APP-03): 记埋点 route_entry_blocked（只带路由名与入口类别）。
            break
        }
    }

    /// 打开结论：推送兜底的 Messages 不带原请求的参数；资金与实名页面丢弃全部参数（03 §4.4）。
    private func showOpened(_ decision: GuardDecision, for request: RouteRequest) {
        guard let route = decision.route else { return }
        show(RouteDestination(
            route: route,
            params: route == request.route ? EntryGuard.effectiveParams(request) : [:],
            readonly: decision.kind == .openReadonly
        ))
    }

    private func show(_ destination: RouteDestination) {
        if destination.route == RoutePolicy.home {
            path = []
        } else {
            path.append(destination)
        }
    }

    /// 登记 pending_action（`RoutePolicy.noPendingActionRoutes` 除外）：动作为打开该路由，params 为路由名与经校验、清洗后的路由参数（不含令牌，BR-ID-10），
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
        pendingStore.save(
            action: Self.openRouteAction,
            values: values,
            now: pendingStore.now,
            origin: request.sourceKind.rawValue
        )
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
        guard let pending = pendingStore.load(now: pendingStore.now) else { return }
        guard pending.action == Self.openRouteAction,
              let route = pending.paramValues["route"]?.stringValue
        else {
            pendingStore.clear()
            return
        }
        let request = RouteRequest(
            route: route,
            values: pending.paramValues["params"]?.objectValue ?? [:],
            from: .pendingAction
        )
        let current = state()
        let decision = EntryGuard.decide(request: request, state: current, routes: routes)
        if pending.origin == RouteSource.agentCard.rawValue,
           decision.isPrivacyBlock || !privacyAllowsAgentRecord(current) {
            lastDecision = decision
            pendingStore.clear()
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
        generation &+= 1
    }

    /// 隐私弹窗已处理（02b 调用）。`granted` = 用户同意。
    /// - Agent 卡片登记的动作：一律删除，要用户重新点击（BR-ID-10，R1-05）。
    /// - 其余动作：同意后计为完成一个前置步骤，按前置继续（登录、绑手机、实名）并恢复原路由（R1-06）；不同意则删除。
    public func consentHandled(granted: Bool = true) {
        consentRequested = false
        guard let pending = pendingStore.load(now: pendingStore.now) else { return }
        guard granted, pending.origin != RouteSource.agentCard.rawValue else {
            pendingStore.clear()
            return
        }
        prerequisiteCompleted()
    }

    /// 隐私状态变化（02b 在弹窗结论、撤回同意、进入基本模式时调用）：Agent 卡片登记的动作遇隐私阻断即删除。
    public func privacyChanged() {
        purgeAgentPendingIfPrivacyBlocked(state())
    }

    /// 只有隐私已同意时才保留 Agent 卡片来源的 pending_action；未决、基本模式都算隐私阻断（BR-ID-10 Agent 卡片 ②，R1-05）。
    private func privacyAllowsAgentRecord(_ state: GuardState) -> Bool {
        state.privacy == .consented
    }

    /// 任何时刻观察到隐私阻断，都删除 origin=agent_card 的记录（读记录不重置计时）。
    private func purgeAgentPendingIfPrivacyBlocked(_ state: GuardState) {
        guard !privacyAllowsAgentRecord(state),
              let pending = pendingStore.load(now: pendingStore.now),
              pending.origin == RouteSource.agentCard.rawValue
        else {
            return
        }
        pendingStore.clear()
    }

    // MARK: - 启动意图

    public func enqueueLaunch(_ intent: LaunchIntent) {
        launchQueue.enqueue(intent)
    }

    public var hasPendingLaunchIntent: Bool {
        launchQueue.pending != nil
    }

    /// 下一次该重试放行启动意图的时刻（毫秒）：闸门已通过、强更仍在检查时为「闸门通过 + 5 秒」；
    /// 闸门未就绪或没有排队的意图时为 nil（调用方不必空转计时，等状态变化再 drain）。
    public func launchRetryAt(readiness: LaunchReadiness) -> Int64? {
        launchQueue.nextRetryAt(readiness: readiness)
    }

    /// 条件满足时放行排队的启动意图；推送意图经 `PushLanding` 回查后再打开。
    /// 返回推送回查的任务（测试可等待它结束）；没有回查时为 nil。
    @discardableResult
    public func drainLaunchQueue(
        readiness: LaunchReadiness,
        now: Int64,
        pushLanding: PushLanding? = nil
    ) -> Task<Void, Never>? {
        guard let released = launchQueue.release(readiness: readiness, now: now) else { return nil }
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
            guard let pushLanding else { return nil }
            return startPush(messageId: messageId, state: guardState, using: pushLanding)
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
        return startPush(messageId: messageId, state: current, using: pushLanding)
    }

    private func startPush(messageId: String, state guardState: GuardState,
                           using pushLanding: PushLanding) -> Task<Void, Never>? {
        let issued = generation
        if let blocked = PushLanding.probe(state: guardState, routes: routes) {
            finishPush(blocked, messageId: messageId, issuedAt: issued)
            return nil
        }
        let routes = routes
        return Task { @MainActor [weak self] in
            let result = await pushLanding.land(messageId: messageId, state: guardState, routes: routes)
            self?.finishPush(result, messageId: messageId, issuedAt: issued)
        }
    }

    /// 推送回查返回：会话或环境已变（退出登录、切换账号、切换环境）则丢弃旧结果；
    /// 否则用当时最新的状态重新判定后执行（R1-01）。还要等待时把这条推送重新排队，条件满足后再回查。
    /// 代次只在 Router 内部发放与校验：没有公开的「直接执行回查结果」入口（R2-01）。
    func finishPush(_ result: PushLandingResult, messageId: String, issuedAt: UInt64) {
        guard issuedAt == generation else { return }
        let current = redecide(result)
        if current.decision.kind == .deferred {
            lastDecision = current.decision
            launchQueue.enqueue(.push(messageId: messageId))
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
        apply(result.decision, for: result.request ?? RouteRequest(route: RoutePolicy.messages, from: .push))
    }
}
