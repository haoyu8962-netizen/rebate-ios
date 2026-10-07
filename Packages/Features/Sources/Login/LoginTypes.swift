import CouliNetwork
import Foundation
import Generated
import Session

/// 登录执行器要 App 提供的出口（生产实现是 `RouterLoginHost`，集成测试用同一份代码）。
@MainActor
public protocol LoginHost: AnyObject {
    /// 强更状态（AfterLoginUpdate：supported / below / unknown / checking），取这一刻的值。
    func updateState() -> String
    /// 本机有没有持久化的 pending_action。
    func hasPendingAction() -> Bool
    /// 关闭登录页（恢复 pending_action、进强更页之前都先出栈；受限登录也不停在验证码页，APP-05a 共性 2）。
    func closeLogin()
    /// 交给 Router 守卫恢复 pending_action（再过一次守卫，执行一次后删除）。
    func resumePending()
    /// 删除 pending_action，不执行。
    func discardPending()
    /// 进入强更页。执行器先 closeLogin 再调它。
    func enterForceUpdate()
    /// 会话建立（登录成功的有效流程）：守卫的会话状态、各模块刷新；允许恢复满足条件的 pending_action。
    func sessionChanged()
    /// 只通知会话变了，不恢复 pending_action（APP-05a 共性 10）：已作废的尝试在会话确已保存或被清除时用。
    func sessionSynced()
    /// 登出的 Router 清理（APP-05a 共性 23、25）：只清归属不晚于 `throughSession` 这一会话世代的 pending_action 与推送回查
    /// （登出开始时那一代及更早）；原会话被清之后（游客、新登录流程里）新建的待办与回查不动。
    func sessionEnded(throughSession: UInt64)
    /// 接上 Router 清理归属用的会话世代来源（LoginService 创建时调用一次：ApiClient.sessionGeneration）。
    func bindSessionTag(_ tag: @escaping @MainActor () -> UInt64)
}

/// 一次成功保存了会话的短信登录（APP-04 共性 68）：`serial` 每次加一；`generation` 是 ApiClient 在保存那把锁里给出的
/// 保存后会话世代。桥 auth.login 据此确认「登录页结束时的会话就是这次登录保存的」。
public struct LoginCommit: Sendable, Equatable {
    public let serial: UInt64
    public let generation: UInt64
}

/// 一次登录请求保存会话后的世代（ApiClient 在保存那把锁里写入，之后在主线程读）。
final class SavedGeneration: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: UInt64?

    var value: UInt64? {
        lock.withLock { stored }
    }

    func record(_ generation: UInt64) {
        lock.withLock { stored = generation }
    }
}

/// 发码结果。
public struct SendCodeOutcome: Equatable, Sendable {
    /// 这个号码上次成功发码的倒计时还没到：不再发出，页面直接进验证码步继续输入已收到的码（APP-05a 共性 5）。
    public static let countdownActive = "countdown_active"

    /// code_sent / rate_limited / countdown_active / field_error / … / stale（页面已换号或离开，忽略）/ busy。
    public let stateRaw: String
    public let countdownSec: Int
    public let textKey: String?
    public let field: String?
    /// 规范化后的号码。
    public let phone: String?
    /// 外壳 trace_id 后 6 位（通用错误态附注，BR-TEXT-14）；没有为空串。
    public let trace6: String
    /// 这个号码在有效期内收到过验证码（发码被限流时页面仍可进验证码步继续输入，APP-05a 共性 12）。
    public let hasReceivedCode: Bool

    init(_ stateRaw: String, countdownSec: Int = 0, textKey: String? = nil, field: String? = nil,
         phone: String? = nil, trace6: String = "", hasReceivedCode: Bool = false) {
        self.stateRaw = stateRaw
        self.countdownSec = countdownSec
        self.textKey = textKey
        self.field = field
        self.phone = phone
        self.trace6 = trace6
        self.hasReceivedCode = hasReceivedCode
    }
}

/// 登录结果。
public struct LoginOutcome: Equatable, Sendable {
    public static let loggedIn = "logged_in"
    public static let stale = "stale"
    public static let busy = "busy"
    public static let agreementRequired = "agreement_required"
    public static let codeIncomplete = "code_incomplete"

    /// logged_in / LoginErrorResult.stateRaw 的取值 / stale / busy / agreement_required / code_incomplete。
    public let stateRaw: String
    public let textKey: String?
    public let field: String?
    public let disableMillis: Int64
    /// 执行了的登录后计划（AfterLogin.plan，含 refresh_restricted / hold_pending）；没有登录成功为空。
    public let actions: [String]
    /// invite_bind.result（bound / failed / ignored_existing_user）；响应没有或受限登录为 nil。
    public let inviteResult: String?
    public let inviteCode: Int?
    public let trace6: String

    init(_ stateRaw: String, textKey: String? = nil, field: String? = nil, disableMillis: Int64 = 0,
         actions: [String] = [], inviteResult: String? = nil, inviteCode: Int? = nil, trace6: String = "") {
        self.stateRaw = stateRaw
        self.textKey = textKey
        self.field = field
        self.disableMillis = disableMillis
        self.actions = actions
        self.inviteResult = inviteResult
        self.inviteCode = inviteCode
        self.trace6 = trace6
    }
}

/// 发码截止时间，按规范化后的手机号维护（APP-05a 共性 5）：成功发码记 60 秒（或服务端更长的 resend_after_sec），
/// 42901 记 Retry-After；另记每个号码最近一次成功发码的时刻（有效期内可继续输入已收到的码，共性 12）。
/// 所有发码入口都经 `LoginService.sendCode`，同一号码在截止前不再发出。随执行器存活，关掉登录页再进来照样生效。
public struct SmsSendDeadlines {
    struct Deadline {
        let untilMillis: Int64
        /// code_sent / rate_limited。
        let kind: String
    }

    private var byPhone: [String: Deadline] = [:]
    private var sentAt: [String: Int64] = [:]

    mutating func record(_ phone: String, until: Int64, kind: String) {
        byPhone[phone] = Deadline(untilMillis: until, kind: kind)
    }

    mutating func recordSent(_ phone: String, at now: Int64) {
        sentAt[phone] = now
    }

    func active(_ phone: String, now: Int64) -> Deadline? {
        guard let found = byPhone[phone], now < found.untilMillis else { return nil }
        return found
    }

    /// 剩余秒数（向上取整；没有为 0）。
    func remainingSec(_ phone: String, now: Int64) -> Int {
        active(phone, now: now).map { Int(($0.untilMillis - now + 999) / 1000) } ?? 0
    }

    /// 这个号码在验证码有效期内成功发过码（服务端判定码是否仍有效，这里只决定能否进验证码步，CODE-01）。
    func hasReceivedCode(_ phone: String, now: Int64) -> Bool {
        guard let sent = sentAt[phone] else { return false }
        return now - sent < Int64(CodeInput.validSeconds) * 1000
    }
}

/// 登录按钮的 42901 禁用截止时刻（APP-05a 共性 11，03 §4.2「按 Retry-After 禁用触发的按钮」）：登录收到 42901 才禁用
/// 登录按钮。发码入口的禁用与倒计时按号码记在 LoginService（`SmsSendDeadlines`，共性 21），不在这里。
public struct LoginRateLimits: Equatable {
    public private(set) var loginUntil: Int64 = 0

    public init() {}

    public mutating func limitLogin(now: Int64, millis: Int64) {
        loginUntil = max(loginUntil, now + max(0, millis))
    }

    public func loginBlocked(now: Int64) -> Bool {
        now < loginUntil
    }
}

/// 一次登录尝试的归属（APP-05a 共性 1）：换号、取消、登录页出栈、登出时作废。线程安全（ApiClient 在任意线程读）。
final class AttemptOwner: @unchecked Sendable {
    private let lock = NSLock()
    private var valid = true

    var isValid: Bool {
        lock.withLock { valid }
    }

    func invalidate() {
        lock.withLock { valid = false }
    }
}
