import Foundation

/// 推送上报策略的事件（三端同名）。
public enum PushEvent {
    public static let loginSuccess = "login_success"
    public static let coldStart = "cold_start"
    public static let tokenChanged = "token_changed"
    public static let sessionChanged = "session_changed"
    public static let responseOk = "response_ok"
    public static let responseError = "response_error"
    public static let response10405 = "response_10405"
    public static let logout = "logout"
    public static let consentWithdrawn = "consent_withdrawn"
}

/// 推送上报策略的动作。
public enum PushAction {
    public static let none = "none"
    public static let send = "send"
    public static let markPending = "mark_pending"
    public static let drop = "drop"
    public static let forceUpdate = "force_update"
}

/// 推送上报的纯策略（G18，BR-ID-07 细则「推送令牌与会话」）。状态：当前会话的身份档、会话作用域、有无令牌、令牌值、强更结论、会话世代；
/// 在途的会话世代；待报标记。
/// - 触发只有三种：登录成功（新会话保存之后）、已登录冷启动（强更检查有结果且不低于）、已登录期间令牌值变化；
/// - 同一时刻只一条在途：在途期间同一会话的新触发只记待报；在途结束后按当时的会话与令牌值再发一次（只发最新值）；
/// - 每条绑定发起时的会话世代：响应的会话不是在途那条的 → drop（不改任何状态）；会话换代（session_changed）清掉在途与待报；
/// - 不报：未同意 / 基本模式 / 游客（level 不是 member）、deletion_only、没有令牌、强更低于最低版本；
/// - 失败不自动重试；10405 交强更分流（force_update），不重发；
/// - 退出、撤回之后本实例终止，所有事件 none（重新启用另建实例）。
/// 非响应事件的 state 是当前状态补丁；响应事件的 state.session 是原请求的会话世代，不覆盖当前会话。令牌值只在返回的 sendToken 里交给发送方。
public struct PushReportPolicy {
    private var level = ""
    private var scope = ""
    private var hasToken = false
    private var token = ""
    private var update = "unknown"
    private var session = ""
    private var inFlightSession: String?
    private var pendingFlag = false
    private var terminated = false
    /// 实例编号（执行器据此判断「还是发出时的那个策略实例」）。
    public let instance = UUID()

    public init() {}

    public var inFlight: Bool {
        inFlightSession != nil
    }

    public var pending: Bool {
        pendingFlag
    }

    /// 这条响应会不会被接纳（FU-IOS-0712，F-X-08 ②）：响应所属会话就是在途那条的会话。只读，不改状态；执行器据此决定是否开始限流计时。
    public func accepts(responseFrom session: String) -> Bool {
        !terminated && inFlightSession != nil && inFlightSession == session
    }

    public var stopped: Bool {
        terminated
    }

    private mutating func apply(_ patch: [String: Any]) {
        if let value = patch["levelRaw"] as? String {
            level = value
        }
        if let value = patch["sessionScopeRaw"] as? String {
            scope = value
        }
        if let value = JSONKind.bool(patch["hasToken"]) ?? (patch["hasToken"] as? Bool) {
            hasToken = value
        }
        if let value = patch["token"] as? String {
            token = value
        }
        if let value = patch["forceUpdateRaw"] as? String {
            update = value
        }
        if let value = patch["session"] as? String {
            session = value
        }
    }

    private var eligible: Bool {
        !terminated && level == MeLevel.member && scope == "full" && hasToken && !token.isEmpty && !session.isEmpty
            && update != "below"
    }

    private mutating func send() -> [String: Any] {
        inFlightSession = session
        pendingFlag = false
        return ["actionRaw": PushAction.send, "sendToken": token, "sendSession": session]
    }

    private func action(_ raw: String) -> [String: Any] {
        ["actionRaw": raw]
    }

    private mutating func trigger() -> [String: Any] {
        guard eligible else { return action(PushAction.none) }
        if let inFlightSession, inFlightSession == session {
            pendingFlag = true
            return action(PushAction.markPending)
        }
        return send()
    }

    public mutating func on(event: String, state: [String: Any]) -> [String: Any] {
        guard !terminated else { return action(PushAction.none) }
        switch event {
        case PushEvent.loginSuccess, PushEvent.tokenChanged:
            apply(state)
            return trigger()
        case PushEvent.coldStart:
            apply(state)
            return update == "supported" ? trigger() : action(PushAction.none)
        case PushEvent.sessionChanged:
            apply(state)
            inFlightSession = nil
            pendingFlag = false
            return action(PushAction.none)
        case PushEvent.responseOk, PushEvent.responseError, PushEvent.response10405:
            let origin = state["session"] as? String
            guard let inFlightSession, origin == inFlightSession else { return action(PushAction.drop) }
            self.inFlightSession = nil
            if event == PushEvent.response10405 {
                pendingFlag = false
                return action(PushAction.forceUpdate)
            }
            if pendingFlag {
                pendingFlag = false
                // 在途期间有新触发：按当时的会话与令牌值补发最新值（失败的那条不重发——这是新的触发）
                return trigger()
            }
            return action(PushAction.none)
        case PushEvent.logout, PushEvent.consentWithdrawn:
            terminated = true
            inFlightSession = nil
            pendingFlag = false
            return action(PushAction.none)
        default:
            return action(PushAction.none)
        }
    }
}
