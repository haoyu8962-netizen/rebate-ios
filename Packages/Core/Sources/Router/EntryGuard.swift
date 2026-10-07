import Foundation
import Generated

/// 统一入口守卫（03 §4.4「统一入口守卫」「入口限制」，BR-ID-10、BR-ID-02、BR-ID-11、BR-ID-01）。
/// 纯函数：同样的请求与状态得到同样的结论，不读写任何存储、不导航。
///
/// 判定顺序：环境 → 隐私闸门（未决 / 基本模式）→ 低于最低版本 → 强更检查中（外部与自动的等待）→ 路由是否存在与 since →
/// 入口 → Agent 卡片 → 参数 schema 与外部网页白名单 → 强更结果未知时的只读清单 → 登录、绑手机与实名 → 打开。
public enum EntryGuard {
    public static func decide(request: RouteRequest, state: GuardState) -> GuardDecision {
        decide(request: request, state: state, routes: Routes.all)
    }

    /// `routes` 为本构建可用的路由表（App 在 Debug / Staging 里并入 debug_only 路由）。
    public static func decide(
        request: RouteRequest,
        state: GuardState,
        routes: [String: RouteSpec]
    ) -> GuardDecision {
        decideWithTarget(request: request, state: state, routes: routes).decision
    }

    private static func decideRaw(
        request: RouteRequest,
        state: GuardState,
        routes: [String: RouteSpec]
    ) -> GuardDecision {
        // 环境未 settled：一律不放行业务路由，等待（EnvironmentGate）。
        guard state.environmentSettled else {
            return wait(GuardReason.environmentUnsettled)
        }
        if let blocked = privacyGate(request: request, state: state) {
            return blocked
        }
        // 低于最低支持版本：只放行从强更页主动进入的次要入口（03 §4.1）。
        if state.update == .belowMin {
            return decideBelowMinimum(request: request, state: state, routes: routes)
        }
        // 强更检查进行中（还没等满 5 秒）：外部来源与自动执行的动作等结果，App 内操作不等（03 §4.4 表「检查中」，F-ALL-03）。
        if state.update == .checking, request.sourceKind != .inApp {
            return wait(GuardReason.updateChecking)
        }
        // 未知路由、Release 里的 debug_only 名称、since 未发布或高于本端版本：升级提示。
        if let upgrade = availability(route: request.route, state: state, routes: routes) {
            return upgrade
        }
        guard let spec = routes[request.route] else {
            return GuardDecision(kind: .upgrade, route: nil, reason: GuardReason.unknownRoute)
        }
        if let blocked = entryCheck(request: request, spec: spec, state: state) {
            return messagesFallback(blocked, for: request, state: state, routes: routes)
        }
        if let blocked = paramsCheck(request: request, spec: spec, state: state) {
            return blocked
        }
        if let blocked = readonlyCheck(request: request, state: state) {
            return messagesFallback(blocked, for: request, state: state, routes: routes)
        }
        if let prerequisite = authPrerequisite(auth: spec.auth, state: state) {
            return prerequisite
        }
        return openDecision(request: request, state: state)
    }

    // MARK: - 分步

    /// 强更检查结果未知时，外部带进来的请求与自动执行的动作只开只读清单；
    /// 用户在原生页面上自己的操作（in_app）不受影响（03 §4.1、§4.4 表格「未知」一行）。
    private static func readonlyByUpdate(_ request: RouteRequest, _ state: GuardState) -> Bool {
        state.update == .unknown && request.sourceKind != .inApp
    }

    /// 隐私闸门：未决与基本模式。放行返回 nil。
    private static func privacyGate(request: RouteRequest, state: GuardState) -> GuardDecision? {
        let source = request.sourceKind
        switch state.privacy {
        case .notDecided:
            // 「未决时可读路由」（首启弹窗、二次说明里的协议链接，APP-02b）：同意前只允许看协议文本（BR-ID-11），
            // 只认 App 内来源，只读放行；深链、推送、pending_action 仍按下面等待。TODO(N-14): 名单待规划定稿。
            if source == .inApp, RoutePolicy.privacyUndecidedReadableRoutes.contains(request.route) {
                return nil
            }
            if source == .agentCard {
                // Agent 卡片：先补同意，同意后不自动补打开（BR-ID-10 Agent 卡片 ②）。
                return GuardDecision(kind: .requireConsent, route: nil, reason: GuardReason.agentConsentNoReplay)
            }
            // TODO(N-14): in_app 在首启弹窗有结论之前不应出现，这里同样按等待处理（rule-gaps G11）。
            return wait(GuardReason.privacyUndecided)
        case .basicMode:
            guard !RoutePolicy.basicModeRoutes.contains(request.route) else {
                return nil
            }
            if source == .inApp {
                return GuardDecision(kind: .requireConsent, route: nil, reason: GuardReason.consentRequired)
            }
            // 外部或自动入口：丢弃，不因此自动弹隐私弹窗（BR-ID-11）。
            return reject(GuardReason.basicModeBlocked)
        case .consented:
            return nil
        }
    }

    /// 守卫实际校验与打开时使用的参数：资金与实名页面先丢弃全部参数（03 §4.4「资金与实名页面」）。
    public static func effectiveParams(_ request: RouteRequest) -> [String: JSONValue] {
        RoutePolicy.paramsDroppedRoutes.contains(request.route) ? [:] : request.paramValues
    }

    /// 参数 schema（所有来源统一，03 §4.4）与 ExternalPage / WebPage 目标白名单。放行返回 nil。
    private static func paramsCheck(request: RouteRequest, spec: RouteSpec, state: GuardState) -> GuardDecision? {
        let params = effectiveParams(request)
        guard RouteParamValidator.isValid(params, spec: spec) else {
            return reject(GuardReason.paramsInvalid)
        }
        guard RouteTargetCheck.isAllowed(
            route: request.route, params: params, allowlist: state.targets, source: request.sourceKind
        ) else {
            return reject(GuardReason.targetNotAllowed)
        }
        return nil
    }

    /// 入口限制、Agent 卡片限制。放行返回 nil。
    private static func entryCheck(request: RouteRequest, spec: RouteSpec, state: GuardState) -> GuardDecision? {
        let source = request.sourceKind
        let readonly = readonlyByUpdate(request, state)
        if !spec.entries.contains(source.entry) {
            guard source == .push else {
                return reject(GuardReason.entryNotAllowed)
            }
            // 推送回查到的 route 没有声明 push：打开 Messages（BR-ID-10）。
            return GuardDecision(
                kind: readonly ? .openReadonly : .open,
                route: RoutePolicy.messages,
                reason: GuardReason.pushEntryFallback
            )
        }
        // Agent 卡片：只开 agent_guide=true 的路由，且不带参数（BR-ID-10 Agent 页面引导卡）。
        if source == .agentCard {
            guard spec.agentGuide else {
                return reject(GuardReason.agentRouteNotAllowed)
            }
            guard request.paramValues.isEmpty else {
                return reject(GuardReason.agentParamsNotAllowed)
            }
        }
        return nil
    }

    /// 强更检查结果未知时的只读清单。放行返回 nil。
    private static func readonlyCheck(request: RouteRequest, state: GuardState) -> GuardDecision? {
        let source = request.sourceKind
        if readonlyByUpdate(request, state), !RoutePolicy.updateUnknownReadonlyRoutes.contains(request.route) {
            guard source == .push else {
                return reject(GuardReason.updateUnknownBlocked)
            }
            return GuardDecision(
                kind: .openReadonly,
                route: RoutePolicy.messages,
                reason: GuardReason.updateUnknownPushFallback
            )
        }
        return nil
    }

    /// 推送兜底改落 Messages 时（目标未声明 push、强更未知），Messages 本身也要完整过一次守卫（F-IOS-07）：
    /// 守卫拦下 Messages（游客要登录、受限会话等）就按 Messages 的结论处理；放行时保留兜底原因码，任一方只读则只读。
    /// 这样直接 `Router.open(source=push)` 也不会把 Messages 开给游客，不依赖 `PushLanding` 的二次守卫。
    /// Messages 自己声明了 push 且在只读清单里，这里的递归最多一层。
    private static func messagesFallback(
        _ decision: GuardDecision,
        for request: RouteRequest,
        state: GuardState,
        routes: [String: RouteSpec]
    ) -> GuardDecision {
        guard decision.route == RoutePolicy.messages, request.route != RoutePolicy.messages else {
            return decision
        }
        let messages = decide(
            request: RouteRequest(route: RoutePolicy.messages, from: .push),
            state: state,
            routes: routes
        )
        guard messages.opensPage, messages.route == RoutePolicy.messages else {
            return messages
        }
        let readonly = decision.kind == .openReadonly || messages.kind == .openReadonly
        return GuardDecision(
            kind: readonly ? .openReadonly : .open,
            route: RoutePolicy.messages,
            reason: decision.reason
        )
    }

    /// 前置条件都满足后的打开方式。
    private static func openDecision(request: RouteRequest, state: GuardState) -> GuardDecision {
        let route = request.route
        if state.privacy == .basicMode {
            return GuardDecision(kind: .openReadonly, route: route, reason: GuardReason.basicReadonly)
        }
        if state.privacy == .notDecided {
            return GuardDecision(kind: .openReadonly, route: route, reason: GuardReason.privacyUndecidedReadonly)
        }
        if readonlyByUpdate(request, state) {
            return GuardDecision(kind: .openReadonly, route: route, reason: GuardReason.updateUnknownReadonly)
        }
        if RoutePolicy.paramsDroppedRoutes.contains(route), !request.paramValues.isEmpty {
            return GuardDecision(kind: .open, route: route, reason: GuardReason.paramsDropped)
        }
        return GuardDecision(kind: .open, route: route, reason: GuardReason.allowed)
    }

    private static func decideBelowMinimum(
        request: RouteRequest,
        state: GuardState,
        routes: [String: RouteSpec]
    ) -> GuardDecision {
        let route = request.route
        let forceUpdate = GuardDecision(
            kind: .forceUpdate,
            route: RoutePolicy.forceUpdate,
            reason: GuardReason.forceUpdateRequired
        )
        guard state.fromForceUpdatePage,
              request.sourceKind == .inApp,
              RoutePolicy.forceUpdateSecondaryRoutes.contains(route),
              availability(route: route, state: state, routes: routes) == nil,
              let spec = routes[route]
        else {
            // TODO(N-14): DeleteAccount 的 since.ios 仍为 null（未发布），按未发布处理，停在强更页（rule-gaps G02）。
            return forceUpdate
        }
        if let blocked = paramsCheck(request: request, spec: spec, state: state) {
            return blocked
        }
        // 受限会话可用于注销流程（BR-ID-01 细则「受限会话」）；游客要先登录（登录页本身也在次要入口里）。
        if spec.auth != "none", state.session == .guest {
            return GuardDecision(kind: .requireLogin, route: RoutePolicy.login, reason: GuardReason.loginRequired)
        }
        return GuardDecision(kind: .open, route: route, reason: GuardReason.forceUpdateException)
    }

    /// 路由不可用时返回升级提示结论；可用返回 nil。
    private static func availability(
        route: String,
        state: GuardState,
        routes: [String: RouteSpec]
    ) -> GuardDecision? {
        guard let spec = routes[route], !(spec.debugOnly && !state.isDebugBuild) else {
            // 升级提示页没有契约路由名（rule-gaps G03）：route 为 nil，由 Router 打开内置提示页。
            return GuardDecision(kind: .upgrade, route: nil, reason: GuardReason.unknownRoute)
        }
        guard let since = spec.sinceIOS else {
            // TODO(N-14): since.ios 为 null（本端未发布）按未知路由处理（needs N-14 的保守做法，rule-gaps G02）。
            return GuardDecision(kind: .upgrade, route: nil, reason: GuardReason.unknownRoute)
        }
        guard AppVersion.isAtLeast(state.appVersion, since) else {
            return GuardDecision(kind: .upgrade, route: nil, reason: GuardReason.routeTooNew)
        }
        return nil
    }

    /// routes.json auth 与会话状态（BR-ID-02 身份能力矩阵）。满足返回 nil。
    private static func authPrerequisite(auth: String, state: GuardState) -> GuardDecision? {
        let needLogin = GuardDecision(kind: .requireLogin, route: RoutePolicy.login, reason: GuardReason.loginRequired)
        let needPhone = GuardDecision(
            kind: .requireBindPhone,
            route: RoutePolicy.bindPhone,
            reason: GuardReason.phoneRequired
        )
        if auth == "none" {
            return nil
        }
        switch state.session {
        case .guest, .restricted:
            // TODO(N-14): 受限会话在版本恢复支持后须先刷新（rule-gaps G15），这里按需要重新登录处理。
            return needLogin
        case .loggedIn:
            return auth == "login" ? nil : needPhone
        case .phoneBound:
            // auth=realname：只有明确的实名通过结论才放行；绑手机不等于实名，未知按未实名（BR-ID-02）。
            guard auth == "realname", !state.realnameVerified else {
                return nil
            }
            return GuardDecision(
                kind: .requireRealname,
                route: RoutePolicy.realName,
                reason: GuardReason.realnameRequired
            )
        }
    }

    private static func wait(_ reason: String) -> GuardDecision {
        GuardDecision(kind: .deferred, route: nil, reason: reason)
    }

    private static func reject(_ reason: String) -> GuardDecision {
        GuardDecision(kind: .reject, route: nil, reason: reason)
    }
}

/// 推送兜底的实际目标（R1-02）：放在扩展里，与判定主体分开。
public extension EntryGuard {
    /// 同 `decide`，另给出结论实际针对的请求（R1-02）：推送兜底改落 Messages 时为清空参数的 Messages（source=push），
    /// 否则为原请求。Router 登记 pending_action、恢复待办都用这个实际目标，不用被入口限制拒绝的原始目标。
    static func decideWithTarget(
        request: RouteRequest,
        state: GuardState,
        routes: [String: RouteSpec]
    ) -> (decision: GuardDecision, target: RouteRequest) {
        let decision = decideRaw(request: request, state: state, routes: routes)
        guard isMessagesFallback(request, state: state, routes: routes) else {
            return (decision, request)
        }
        return (decision, RouteRequest(route: RoutePolicy.messages, from: .push))
    }

    /// 本次判定是否走了推送兜底 Messages（入口未声明 push，或强更未知时不在只读清单）。
    /// 与 `decideRaw` 的分步一致：只有隐私、强更、可用性、入口这几步都走到时才可能兜底。
    private static func isMessagesFallback(
        _ request: RouteRequest,
        state: GuardState,
        routes: [String: RouteSpec]
    ) -> Bool {
        guard request.sourceKind == .push, request.route != RoutePolicy.messages,
              state.environmentSettled,
              privacyGate(request: request, state: state) == nil,
              state.update != .belowMin,
              state.update != .checking,
              availability(route: request.route, state: state, routes: routes) == nil,
              let spec = routes[request.route]
        else {
            return false
        }
        if entryCheck(request: request, spec: spec, state: state) != nil {
            return true
        }
        if paramsCheck(request: request, spec: spec, state: state) != nil {
            return false
        }
        return readonlyCheck(request: request, state: state) != nil
    }
}
