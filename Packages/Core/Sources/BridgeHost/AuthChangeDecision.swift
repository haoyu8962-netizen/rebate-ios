import Foundation

/// 可信容器关心的会话身份（F-X-25，三端口径一致）：是否已确认、账号、持久化登录世代。
/// 刻意不含令牌与 session_scope：仅刷新令牌、受限会话转为完整会话都不是身份变化。
public struct WebSessionIdentity: Equatable, Sendable {
    public let known: Bool
    public let account: String?
    public let loginEpoch: String?

    public init(known: Bool, account: String?, loginEpoch: String?) {
        self.known = known
        self.account = known ? account.flatMap { $0.isEmpty ? nil : $0 } : nil
        self.loginEpoch = known ? loginEpoch.flatMap { $0.isEmpty ? nil : $0 } : nil
    }

    /// 身份暂时读不出（凭据不可读、禁读屏障竖着、Keychain 读失败）。不等于游客。
    public static let unknown = WebSessionIdentity(known: false, account: nil, loginEpoch: nil)
    /// 已确认没有会话（游客）。
    public static let guest = WebSessionIdentity(known: true, account: nil, loginEpoch: nil)
}

/// 切号判定（F-X-25 触发表，纯函数，三端同一份样例 specs/fx25-auth-change-vectors.json）：
/// - none：不动（仅刷新令牌、同一游客、任一侧身份未知——冷启动首次确认、暂时读不出都不算变化）；
/// - notify：只发 `auth.changed`（同账号、登录世代变化：重新登录同一账号）；
/// - notifyReload：发 `auth.changed`，并清可信容器的 Web 存储、整页重新加载（账号变化、登录、登出）；
/// - reload：只清存储并重新加载、不发事件（已确认游客时遇到明确清除会话的入口：存储事务，不是身份事件）。
public struct AuthChangeDecision: Equatable, Sendable {
    public let rawValue: String
    /// 事件载荷 `logged_in`（契约 bridge.schema.json auth.changed 只有这一个布尔字段）；不发事件时为 nil。
    public let loggedIn: Bool?

    public static let none = AuthChangeDecision(rawValue: "none", loggedIn: nil)
    public static let reload = AuthChangeDecision(rawValue: "reload", loggedIn: nil)

    public static func notify(loggedIn: Bool) -> AuthChangeDecision {
        AuthChangeDecision(rawValue: "notify", loggedIn: loggedIn)
    }

    public static func notifyReload(loggedIn: Bool) -> AuthChangeDecision {
        AuthChangeDecision(rawValue: "notifyReload", loggedIn: loggedIn)
    }

    /// 要不要向在开的可信文档发 `auth.changed`。
    public var notifies: Bool {
        loggedIn != nil
    }

    /// 要不要清可信容器的 Web 存储并重新加载（先持久登记待清理、同步隔离全部可信文档）。
    public var reloads: Bool {
        rawValue == "notifyReload" || rawValue == "reload"
    }

    public static func decide(previous: WebSessionIdentity, next: WebSessionIdentity) -> AuthChangeDecision {
        guard previous.known, next.known else {
            return .none
        }
        if previous.account != next.account {
            return .notifyReload(loggedIn: next.account != nil)
        }
        guard next.account != nil, previous.loginEpoch != next.loginEpoch else {
            return .none
        }
        return .notify(loggedIn: true)
    }
}

/// 最近一次已确认的身份与判定（每个 ApiClient / 可信容器协调器一份，主线程使用）。
/// - 未知快照不覆盖已确认身份（D08：暂时读不出不是登出；恢复后继续与最近确认的身份比较）；
/// - 冷启动未知 → 已知只记下基线、不判变化（D06 / D07）；
/// - 同一次变化的重复唤醒判 none（已记下新身份）；两次独立变化（登出再登录）各判一次；
/// - 明确清除会话（切环境、撤回同意、退出、注销、10404、刷新被拒）不读凭据：按「变成游客」判定——此前不是已确认游客时
///   notifyReload(false)，已确认游客时 reload（只清存储）。之后读到的游客快照判 none。
public struct AuthChangeTracker: Equatable, Sendable {
    public private(set) var confirmed: WebSessionIdentity?

    public init(confirmed: WebSessionIdentity? = nil) {
        self.confirmed = confirmed.flatMap { $0.known ? $0 : nil }
    }

    public mutating func observe(_ next: WebSessionIdentity) -> AuthChangeDecision {
        guard next.known else {
            return .none
        }
        let decision = AuthChangeDecision.decide(previous: confirmed ?? .unknown, next: next)
        confirmed = next
        return decision
    }

    public mutating func explicitlyCleared() -> AuthChangeDecision {
        defer { confirmed = .guest }
        if confirmed == .guest {
            return .reload
        }
        return .notifyReload(loggedIn: false)
    }
}
