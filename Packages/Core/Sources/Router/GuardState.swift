import Foundation

/// 隐私闸门结论（BR-ID-11）。not_decided = 首启弹窗尚未有结论。
public enum PrivacyState: String, Sendable, CaseIterable {
    case consented
    case basicMode = "basic_mode"
    case notDecided = "not_decided"
}

/// 强更检查结果（03 §4.1、§4.4）。unknown = 等待超时或检查失败；「检查中」由 `LaunchQueue` 处理，不进守卫。
public enum UpdateState: String, Sendable, CaseIterable {
    case ok
    case unknown
    case belowMin = "below_min"
    case belowRecommended = "below_recommended"
}

/// 会话状态（BR-ID-02；restricted 见 BR-ID-01 细则「受限会话」）。
public enum SessionState: String, Sendable, CaseIterable {
    case guest
    case loggedIn = "logged_in"
    case phoneBound = "phone_bound"
    case restricted
}

/// 外部网页目标白名单（03 §4.4「入口限制」，BR-ID-10）：由 /v1/config 下发，调用方注入。
/// 缺省为空，即 ExternalPage、WebPage 一律不放行（配置缺失时保守拒绝）。
public struct RouteTargetAllowlist: Sendable, Equatable {
    /// ExternalPage 的 url 主机（完整主机名匹配，不认子域通配）。
    public var externalHosts: [String]
    /// WebPage 的 url origin（`https://host[:port]`）。
    public var bridgeOrigins: [String]

    public init(externalHosts: [String] = [], bridgeOrigins: [String] = []) {
        self.externalHosts = externalHosts
        self.bridgeOrigins = bridgeOrigins
    }

    public static let empty = RouteTargetAllowlist()
}

/// 入口守卫的输入状态（任务书 §2）。
public struct GuardState: Sendable, Equatable {
    public var privacy: PrivacyState
    public var update: UpdateState
    public var session: SessionState
    public var environmentSettled: Bool
    /// 本端版本号，与 routes.json since.ios 比较。
    public var appVersion: String
    /// Debug / Staging = true（debug_only 路由只在这时可开）。
    public var isDebugBuild: Bool
    /// 本次打开是否由强更页的次要入口发起。
    public var fromForceUpdatePage: Bool
    /// 已取得明确的实名通过结论（缺省 false：未知按未实名，auth=realname 进实名前置，BR-ID-02）。
    public var realnameVerified: Bool
    /// ExternalPage / WebPage 的目标白名单（缺省空 = 全拒）。
    public var targets: RouteTargetAllowlist

    public init(
        privacyState: PrivacyState,
        updateState: UpdateState,
        sessionState: SessionState,
        environmentSettled: Bool,
        appVersion: String,
        isDebugBuild: Bool,
        fromForceUpdatePage: Bool = false,
        realnameVerified: Bool = false,
        targets: RouteTargetAllowlist = .empty
    ) {
        privacy = privacyState
        update = updateState
        session = sessionState
        self.environmentSettled = environmentSettled
        self.appVersion = appVersion
        self.isDebugBuild = isDebugBuild
        self.fromForceUpdatePage = fromForceUpdatePage
        self.realnameVerified = realnameVerified
        self.targets = targets
    }

    /// 任务书原样签名（取值为原始字符串）。不认识的取值按最保守的状态处理：
    /// 隐私按未决、强更按未知、会话按游客。
    public init(
        privacy: String,
        update: String,
        session: String,
        environmentSettled: Bool,
        appVersion: String,
        isDebugBuild: Bool,
        fromForceUpdatePage: Bool
    ) {
        self.init(
            privacyState: PrivacyState(rawValue: privacy) ?? .notDecided,
            updateState: UpdateState(rawValue: update) ?? .unknown,
            sessionState: SessionState(rawValue: session) ?? .guest,
            environmentSettled: environmentSettled,
            appVersion: appVersion,
            isDebugBuild: isDebugBuild,
            fromForceUpdatePage: fromForceUpdatePage
        )
    }
}
