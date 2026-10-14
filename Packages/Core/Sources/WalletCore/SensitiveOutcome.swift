import CouliNetwork
import Foundation
import Generated

/// 一次敏感写操作（提现、收款账号变更）的已解包结果：`kind` 为 ok / error / transport（没有统一外壳：超时、断连、进程被杀、网关错误页）/
/// abandon_result（作废接口的 abandoned 或 completed）。`retryAfterMillis` 是 42901 的禁用时长（Retry-After，缺省或非法 5 秒）。
public struct OutcomeInput: Sendable {
    public static let okKind = "ok"
    public static let errorKind = "error"
    public static let transportKind = "transport"
    public static let abandonResultKind = "abandon_result"

    public var kind: String
    public var code: Int?
    public var data: [String: String]
    public var fields: [String]
    public var retryAfterMillis: Int64?
    public var abandonOutcome: String?
    public var originalCode: Int?

    public init(
        _ kind: String, code: Int? = nil, data: [String: String] = [:], fields: [String] = [],
        retryAfterMillis: Int64? = nil
    ) {
        self.kind = kind
        self.code = code
        self.data = data
        self.fields = fields
        self.retryAfterMillis = retryAfterMillis
    }

    static func abandonResult(_ outcome: String, originalCode: Int? = nil, data: [String: String] = [:]) -> Self {
        var input = OutcomeInput(abandonResultKind, data: data)
        input.abandonOutcome = outcome
        input.originalCode = originalCode
        return input
    }
}

/// 判定结论：`actionRaw` 是页面要做的事；`keyEnds` = 这个键结束（对从未结果未知的键表示本次键不用了）；`nextSubmitNewKey` = 用户下次点
/// 【提交】用新键；`textKey` 文案键；`route` 引导或展示的目的地（不是补办后的返回路由）；`disableMillis` 42901 禁用时长；`showTrace6` 附 trace6。
public struct Outcome: Equatable, Sendable {
    public var actionRaw: String
    public var keyEnds: Bool
    public var nextSubmitNewKey: Bool
    public var textKey: String?
    public var route: String?
    public var disableMillis: Int64?
    public var showTrace6 = false
    /// 10004 的 consent_type（privacy / agreement 交给已有的协议重新同意组件；iOS 还没有，I04）。
    public var consentType: String?
    /// 20001 的 data.fields。
    public var fields: [String] = []
    /// 44001 的 data.risk_msg_code（弹窗标题先查 risk_msg.<code>）。
    public var riskMsgCode: String?

    init(_ action: String, ends: Bool, newKey: Bool, text: String? = nil, route: String? = nil,
         disable: Int64? = nil) {
        actionRaw = action
        keyEnds = ends
        nextSubmitNewKey = newKey
        textKey = text
        self.route = route
        disableMillis = disable
    }

    static func pending(_ text: String, disable: Int64? = nil, trace: Bool = false) -> Outcome {
        var outcome = Outcome(SensitiveOutcome.pendingConfirm, ends: false, newKey: false, text: text, disable: disable)
        outcome.showTrace6 = trace
        return outcome
    }
}

/// 提现与收款账号变更两个操作的结局表（BR-ID-10 细则「敏感操作的幂等键」、BR-WDR-07 细则、brief §0 第 3、4 条、§2.5）：
/// - 键只在三种结果下结束：业务成功；写入幂等记录的 3xxxx；已作废（abandoned 或 20903）。1xxxx、20903 以外的 2xxxx、40901、42901、5xxxx、
///   10405、没有响应都不结束（从未结果未知的键在这些情况下「这次键不用了」，下次用新键；编排者 2026-10-10 补充）。
/// - 10003 沿用原键（拿到 token 后重放 1 次）；10002 / 10402 由网络层沿用原键自动重发至多 1 次。
/// - 10001 / 10004 / 10005 / 30304 / 30305 / 30307 只引导补办，补办完回到发起页，不重放、不登记 pending_action，由用户再点。
/// - 结果未知：不换键、不自动重发，进待确认；【确认上一笔】【放弃上一笔】都只由用户点击。
public enum SensitiveOutcome {
    public static let withdraw = "withdraw"
    public static let payoutAccount = "payout_account"
    public static let submit = "submit"
    public static let confirm = "confirm"
    public static let abandon = "abandon"

    public static let done = "done"
    public static let stepUp = "step_up_same_key"
    public static let autoResend = "auto_resend_same_key"
    public static let guide = "guide_prereq"
    public static let showErrorKeyEnds = "show_error_key_ends"
    public static let showErrorKeepPending = "show_error_keep_pending"
    public static let riskBlocked = "risk_blocked"
    public static let fieldError = "field_error"
    public static let retryAfter = "retry_after"
    public static let errorTrace6 = "error_trace6"
    public static let forceUpdate = "force_update"
    public static let pendingConfirm = "pending_confirm"
    public static let abandoned = "abandoned"
    public static let alreadyDone = "already_done"
    public static let abandonBusy = "abandon_busy"
    /// 同键在途（40901）且这个键从未结果未知：提示 error.40901、恢复按钮，不自动重发；键结束，下次点击用新键（编排者 2026-10-10 口径）。
    public static let busyRetry = "busy_retry"

    public static let titleKey = "pending_confirm.title"
    public static let retryLaterKey = "pending_confirm.retry_later"
    public static let cannotConfirmKey = "pending_confirm.cannot_confirm"
    public static let abandonedKey = "pending_confirm.abandoned"
    public static let alreadyDoneKey = "pending_confirm.already_done"
    public static let abandonBusyKey = "pending_confirm.abandon_busy"
    public static let defaultRetryMillis = ErrorActionMapper.defaultRetryAfterMillis

    static let abandonedCode = 20903
    static let busyCode = 40901
    static let rateLimited = 42901
    static let forceUpdateCode = 10405

    public static func of(op: String, phase: String, keyEverUnknown: Bool, input: OutcomeInput) -> Outcome {
        switch phase {
        case confirm: confirmOutcome(op, input)
        case abandon: abandonOutcome(op, input)
        default: submitOutcome(op, keyEverUnknown: keyEverUnknown, input)
        }
    }

    // MARK: - 首次提交

    static func submitOutcome(_ op: String, keyEverUnknown: Bool, _ input: OutcomeInput) -> Outcome {
        if input.kind == OutcomeInput.okKind {
            return Outcome(done, ends: true, newKey: true, route: successRoute(op))
        }
        guard input.kind == OutcomeInput.errorKind, let code = input.code else {
            return Outcome(pendingConfirm, ends: false, newKey: false, text: titleKey)
        }
        if let shared = shared(op, code, input, pending: false) {
            return shared
        }
        if let ended = submitEnded(code, input) {
            return ended
        }
        if code == forceUpdateCode {
            return Outcome(forceUpdate, ends: false, newKey: !keyEverUnknown, text: "error.10405")
        }
        if ErrorActionMapper.isBusinessCode(code) {
            return Outcome(showErrorKeyEnds, ends: true, newKey: true, text: businessKey(code, input),
                           route: stayRoute(op, code))
        }
        return Outcome(showErrorKeyEnds, ends: true, newKey: true, text: errorKey(code))
    }

    /// 首次提交里键结束的几类（42901、40901、5xxxx、20903、20001、44001）。
    static func submitEnded(_ code: Int, _ input: OutcomeInput) -> Outcome? {
        switch code {
        case rateLimited:
            return Outcome(retryAfter, ends: true, newKey: true, text: "error.42901",
                           disable: input.retryAfterMillis ?? defaultRetryMillis)
        case busyCode:
            return Outcome(busyRetry, ends: true, newKey: true, text: "error.40901")
        case abandonedCode:
            return Outcome(showErrorKeyEnds, ends: true, newKey: true, text: "error.20903")
        case 20001:
            return fieldErrorOutcome(input)
        case 44001:
            var outcome = Outcome(riskBlocked, ends: true, newKey: true, text: "error.44001")
            outcome.riskMsgCode = input.data["risk_msg_code"]
            return outcome
        default:
            guard code / 10000 == 5 else { return nil }
            var outcome = Outcome(errorTrace6, ends: true, newKey: true, text: serverKey(code))
            outcome.showTrace6 = true
            return outcome
        }
    }

    // MARK: - 确认上一笔

    static func confirmOutcome(_ op: String, _ input: OutcomeInput) -> Outcome {
        if input.kind == OutcomeInput.okKind {
            return Outcome(done, ends: true, newKey: true, route: successRoute(op))
        }
        guard input.kind == OutcomeInput.errorKind, let code = input.code else { return .pending(retryLaterKey) }
        if let shared = shared(op, code, input, pending: true) {
            return shared
        }
        if let kept = keptPending(code, input) {
            return kept
        }
        if code == abandonedCode {
            return Outcome(showErrorKeyEnds, ends: true, newKey: true, text: "error.20903")
        }
        // 写入幂等记录的业务错误（3xxxx）：键结束，显示该错误并恢复【提交】（AC-S2-62 ⑯）；收款账号页的账号类错误留在本页
        if ErrorActionMapper.isBusinessCode(code) {
            return Outcome(showErrorKeyEnds, ends: true, newKey: true, text: businessKey(code, input),
                           route: stayRoute(op, code))
        }
        if code / 10000 == 2 {
            return Outcome(showErrorKeepPending, ends: false, newKey: false, text: cannotConfirmKey)
        }
        return .pending(retryLaterKey)
    }

    /// 确认 / 放弃里保持待确认的几类（10405、42901、40901、5xxxx）。
    static func keptPending(_ code: Int, _ input: OutcomeInput) -> Outcome? {
        switch code {
        case forceUpdateCode:
            Outcome(forceUpdate, ends: false, newKey: false, text: "error.10405")
        case rateLimited:
            .pending(retryLaterKey, disable: input.retryAfterMillis ?? defaultRetryMillis)
        case busyCode:
            .pending(retryLaterKey)
        default:
            code / 10000 == 5 ? .pending(retryLaterKey, trace: true) : nil
        }
    }

    // MARK: - 放弃上一笔

    static func abandonOutcome(_ op: String, _ input: OutcomeInput) -> Outcome {
        if input.kind == OutcomeInput.abandonResultKind {
            if input.abandonOutcome == abandoned {
                return Outcome(abandoned, ends: true, newKey: true, text: abandonedKey)
            }
            let original = input.originalCode ?? 0
            return original == 0
                ? Outcome(alreadyDone, ends: true, newKey: true, text: alreadyDoneKey, route: successRoute(op))
                : Outcome(alreadyDone, ends: true, newKey: true, text: businessKey(original, input),
                          route: stayRoute(op, original))
        }
        guard input.kind == OutcomeInput.errorKind, let code = input.code else { return .pending(retryLaterKey) }
        switch code {
        case 10002, 10402:
            return Outcome(autoResend, ends: false, newKey: false)
        case 10001, 10004, 10005:
            // 前置码（BR-ID-10、APP-09 共性第 18 条）：与确认共用映射，打开对应页、保留未决键，补办回来等用户再点
            return shared(op, code, input, pending: true) ?? .pending(retryLaterKey)
        case busyCode:
            return Outcome(abandonBusy, ends: false, newKey: false, text: abandonBusyKey)
        case abandonedCode:
            return Outcome(abandoned, ends: true, newKey: true, text: abandonedKey)
        default:
            return keptPending(code, input) ?? .pending(retryLaterKey)
        }
    }

    // MARK: - 共用

    /// 提交与确认共用：二次验证、自动重发、前置补办（补办期间：首次提交的键结束；结果未知过的键保持待确认）。
    static func shared(_ op: String, _ code: Int, _ input: OutcomeInput, pending: Bool) -> Outcome? {
        let ends = !pending
        switch code {
        case 10003:
            return Outcome(stepUp, ends: false, newKey: false, text: "error.10003")
        case 10002, 10402:
            return Outcome(autoResend, ends: false, newKey: false)
        case 10001:
            return Outcome(guide, ends: ends, newKey: ends, text: "error.10001", route: WalletRoutes.login)
        case 10005:
            return Outcome(guide, ends: ends, newKey: ends, text: "error.10005", route: WalletRoutes.bindPhone)
        case 10004:
            let consent = input.data["consent_type"]
            let route = consent == "labor_agreement"
                ? WalletRoutes.laborAgreement : (consent == "id_verification" ? WalletRoutes.realName : nil)
            var outcome = Outcome(guide, ends: ends, newKey: ends, text: "error.10004", route: route)
            outcome.consentType = consent
            return outcome
        default:
            return pending ? nil : prerequisite(op, code)
        }
    }

    /// 首次提交得到 3xxxx 前置码：引导补办（30304 → RealName；30305 / 30307 → PayoutAccount）。
    static func prerequisite(_ op: String, _ code: Int) -> Outcome? {
        if code == 30304 {
            return Outcome(guide, ends: true, newKey: true, text: "error.30304", route: WalletRoutes.realName)
        }
        if (code == 30305 && op == withdraw) || code == 30307 {
            return Outcome(guide, ends: true, newKey: true, text: "error.\(code)", route: WalletRoutes.payoutAccount)
        }
        return nil
    }

    static func fieldErrorOutcome(_ input: OutcomeInput) -> Outcome {
        let reasonKey = input.data["reason"].map { "error.20001.\($0)" }
        let key = reasonKey.flatMap { DefaultTexts.text($0) != nil ? $0 : nil } ?? "error.20001"
        var outcome = Outcome(fieldError, ends: true, newKey: true, text: key)
        outcome.fields = input.fields
        return outcome
    }

    /// 收款账号页的账号类错误（30303、30307、30308）：显示在本页（route 表示留在 PayoutAccount，不重复压入同名页）。
    static func stayRoute(_ op: String, _ code: Int) -> String? {
        op == payoutAccount && [30303, 30307, 30308].contains(code) ? WalletRoutes.payoutAccount : nil
    }

    static func businessKey(_ code: Int, _ input: OutcomeInput) -> String {
        code == 30303 ? WithdrawConditionText.view(input.data["reason"]).textKey : errorKey(code)
    }

    static func successRoute(_ op: String) -> String? {
        op == withdraw ? WalletRoutes.withdrawRecords : nil
    }

    /// 5xxxx：已收录且非空的用 error.<code>，未收录回落 error.50001（trace6 由统一错误消息函数另外追加）。
    public static func serverKey(_ code: Int) -> String {
        let key = "error.\(code)"
        return (DefaultTexts.text(key) ?? "").isEmpty ? "error.50001" : key
    }

    static func errorKey(_ code: Int) -> String {
        DefaultTexts.text("error.\(code)") != nil ? "error.\(code)" : "error.50001"
    }
}

/// 二次验证 token 的复用（G17）：只放内存，按会话、账号与 action 隔离，不落盘。本机时钟早于 expire_at 才带上；成功提交（服务端核销）后
/// 立即丢弃；会话换代、登出、换账号、撤回同意时清空；得到 10003 就丢弃并重新弹面板。`take` 只读，不核销服务端 token。
public final class StepUpTokenCache: @unchecked Sendable {
    private struct Entry {
        let account: String
        let token: String
        let expireAtMs: Int64
    }

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]

    public init() {}

    public func put(action: String, account: String, token: String, expireAtMs: Int64) {
        lock.withLock { entries[action] = Entry(account: account, token: token, expireAtMs: expireAtMs) }
    }

    public func take(action: String, account: String, nowMs: Int64) -> String? {
        lock.withLock {
            guard let entry = entries[action], entry.account == account, nowMs < entry.expireAtMs else { return nil }
            return entry.token
        }
    }

    public func onSuccess(action: String) {
        lock.withLock { entries[action] = nil }
    }

    public func onSessionChanged() {
        lock.withLock { entries = [:] }
    }

    public func on10003(action: String) {
        lock.withLock { entries[action] = nil }
    }
}
