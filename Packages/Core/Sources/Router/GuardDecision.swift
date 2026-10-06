import Foundation

/// 守卫结论的类别（任务书 §2）。
public enum GuardDecisionKind: String, Sendable, CaseIterable {
    case open
    case openReadonly = "open_readonly"
    case reject
    case upgrade
    case requireLogin = "require_login"
    case requireBindPhone = "require_bind_phone"
    case requireConsent = "require_consent"
    /// auth=realname 而尚无实名通过结论：登记 pending_action 后进 RealName（BR-ID-02；三端统一裁定）。
    case requireRealname = "require_realname"
    case forceUpdate = "force_update"
    case deferred = "defer"
}

/// 机读原因码，取值照 `specs/router-vectors.json` 的 reasons。
public enum GuardReason {
    public static let allowed = "allowed"
    public static let entryNotAllowed = "entry_not_allowed"
    public static let pushEntryFallback = "push_entry_fallback"
    public static let loginRequired = "login_required"
    public static let phoneRequired = "phone_required"
    public static let basicReadonly = "basic_readonly"
    public static let consentRequired = "consent_required"
    public static let basicModeBlocked = "basic_mode_blocked"
    public static let privacyUndecided = "privacy_undecided"
    public static let environmentUnsettled = "environment_unsettled"
    public static let updateUnknownReadonly = "update_unknown_readonly"
    public static let updateUnknownBlocked = "update_unknown_blocked"
    public static let updateUnknownPushFallback = "update_unknown_push_fallback"
    public static let forceUpdateRequired = "force_update_required"
    public static let forceUpdateException = "force_update_exception"
    public static let unknownRoute = "unknown_route"
    public static let routeTooNew = "route_too_new"
    public static let agentRouteNotAllowed = "agent_route_not_allowed"
    public static let agentParamsNotAllowed = "agent_params_not_allowed"
    public static let agentConsentNoReplay = "agent_consent_no_replay"
    public static let paramsDropped = "params_dropped"
    /// 参数不符合 routes.json params schema（类型、必填、多余字段、枚举、长度、pattern）。
    public static let paramsInvalid = "params_invalid"
    /// ExternalPage / WebPage 的目标地址不在 external_hosts / bridge_origins 白名单。
    public static let targetNotAllowed = "target_not_allowed"
    public static let realnameRequired = "realname_required"
}

/// 守卫结论。
public struct GuardDecision: Sendable, Equatable {
    public let kind: GuardDecisionKind
    /// 实际要打开的路由（被拒、升级提示、等待时为 nil）。
    public let route: String?
    /// 机读原因码（`GuardReason`）。
    public let reason: String

    public init(kind: GuardDecisionKind, route: String?, reason: String) {
        self.kind = kind
        self.route = route
        self.reason = reason
    }

    public var kindRaw: String {
        kind.rawValue
    }

    /// 隐私闸门造成的阻断（未决、要同意、基本模式丢弃）。
    public var isPrivacyBlock: Bool {
        [
            GuardReason.privacyUndecided, GuardReason.consentRequired,
            GuardReason.basicModeBlocked, GuardReason.agentConsentNoReplay,
        ].contains(reason)
    }

    /// 前置步骤（登录、绑手机、实名）：登记 pending_action 后进前置页。
    public var isPrerequisite: Bool {
        kind == .requireLogin || kind == .requireBindPhone || kind == .requireRealname
    }

    /// 结论为打开页面（含只读打开）。
    public var opensPage: Bool {
        kind == .open || kind == .openReadonly
    }
}
