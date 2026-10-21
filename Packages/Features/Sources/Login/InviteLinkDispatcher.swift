import Foundation

/// 邀请链接拉起 App 时的输入（APP-17c；BR-INV-04 细则「邀请链接拉起 App」）。链接解析与路由注册等契约线（HM-13 decision
/// G03），这里只收解析出的邀请码与此刻的会话状态。
public struct InviteLinkInput: Equatable, Sendable {
    /// 链接里的邀请码（原样）。
    public let rawCode: String
    /// 已同意当前隐私政策且不在基本模式（统一入口守卫的结论）。
    public let consented: Bool
    public let guest: Bool
    /// 本人的邀请码；游客或还不知道时为 nil（未知不当本人码）。
    public let ownCode: String?
    /// `GET /v1/me` 的 `invite_backfill.eligible`（与 ownCode 取自同一份已确认的结果；拿不到按 false）。
    public let eligible: Bool

    public init(rawCode: String, consented: Bool, guest: Bool, ownCode: String?, eligible: Bool) {
        self.rawCode = rawCode
        self.consented = consented
        self.guest = guest
        self.ownCode = ownCode
        self.eligible = eligible
    }
}

/// 分流结论：`kindRaw` 取 drop / login / invite_backfill / home；`code` 只在 login、invite_backfill 时为规范化后的码。
public struct InviteLinkDecision: Equatable, Sendable {
    public static let drop = "drop"
    public static let login = "login"
    public static let inviteBackfill = "invite_backfill"
    public static let home = "home"

    public let kindRaw: String
    public let code: String?

    public init(kindRaw: String, code: String?) {
        self.kindRaw = kindRaw
        self.code = code
    }

    static let dropped = InviteLinkDecision(kindRaw: drop, code: nil)
}

/// InviteLink 分流（APP-17c；HM-13 scope R08，与鸿蒙 HM-13c 同口径）。处理顺序：
/// ① 未同意当前隐私政策或基本模式 → 丢弃；② 格式不符、或等于本人邀请码 → 丢弃；③ 游客 → 记为待绑定码（替换旧的）并打开 Login；
/// ④ 已登录且可补填 → 打开 InviteBackfill 并预填（不写待绑定码）；⑤ 其余 → 打开 Home，不提示。
/// 所有分支都不发请求、不自动提交。
public enum InviteLinkDispatcher {
    static let loginRoute = "Login"
    static let backfillRoute = "InviteBackfill"
    static let homeRoute = "Home"
    static let prefillParam = "prefill"

    public static func decide(_ input: InviteLinkInput) -> InviteLinkDecision {
        guard input.consented else { return .dropped }
        let code = InviteField.normalize(input.rawCode)
        guard !code.isEmpty, InviteField.decide(code, context: [:]).valid == true else { return .dropped }
        if let own = input.ownCode, InviteField.normalize(own) == code {
            return .dropped
        }
        if input.guest {
            return InviteLinkDecision(kindRaw: InviteLinkDecision.login, code: code)
        }
        if input.eligible {
            return InviteLinkDecision(kindRaw: InviteLinkDecision.inviteBackfill, code: code)
        }
        return InviteLinkDecision(kindRaw: InviteLinkDecision.home, code: nil)
    }

    /// 按结论执行：`open(路由名, 参数)` 由 App 接 Router。统一入口守卫要在调用前执行（不同意时 consented=false 直接丢弃）；
    /// login 分支先记码再打开登录页，不看打开是否成功——码已按 R08 ③ 记下，之后进登录页照样显示（HM-13c review S2-8）。
    @MainActor
    @discardableResult
    public static func dispatch(
        _ input: InviteLinkInput, pending: PendingInviteCode, open: (String, [String: String]) -> Void
    ) -> InviteLinkDecision {
        let decision = decide(input)
        switch decision.kindRaw {
        case InviteLinkDecision.login:
            guard let code = decision.code else { break }
            pending.set(code)
            open(loginRoute, [:])
        case InviteLinkDecision.inviteBackfill:
            guard let code = decision.code else { break }
            open(backfillRoute, [prefillParam: code])
        case InviteLinkDecision.home:
            open(homeRoute, [:])
        default:
            break
        }
        return decision
    }
}
