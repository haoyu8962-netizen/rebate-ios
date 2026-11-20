import CouliNetwork
import Foundation

/// 二次验证面板的状态（WithdrawStepUp；BR-ID-08、BR-WDR-01）。`phase`：sending（正在发码）、ready（可输入）、noPhone（账号没绑手机：
/// Me.phone_bound 已知为 false，或面板没有账号；不发码，D10-1682 ②）、verifying（正在验证）。`resendLeftSec` 为 0 时可重新获取。
public struct StepUpUiState: Equatable, Sendable {
    public enum Phase: Equatable, Sendable {
        case sending, ready, noPhone, verifying
    }

    public static let codeLength = 6

    public let action: String
    public var phase: Phase
    public var code = ""
    public var resendLeftSec: Int64 = 0
    public var error: Notice?
    public var awaitingIdentity = false
    /// 最近一次发码没有发出（本地拒绝、一条没发，或结果回来时身份核对不过）：说明位不显示「已发送」；再次发码时清掉（D10-1790）。
    public var sendFailed = false
    public var showsSending: Bool {
        phase == .sending && !awaitingIdentity
    }

    public var showsVerifying: Bool {
        phase == .verifying && !awaitingIdentity
    }

    public var showsRecheck: Bool {
        awaitingIdentity
    }

    /// 面板实例编号（每次打开换新）：面板上的回调带渲染时的编号，执行时核对（APP-11 第 28 条）。
    public let instance: Int
    /// 打开面板的提交 / 确认所属的身份（APP-09 共性第 60 条）：发码、重新获取、验证、读取绑定状态、占用发码槽位、发包前都核对它仍是当前会话，
    /// 并按它取绑定状态与槽位键、带账号；不重新绑定执行时的会话。
    public let owner: WalletOwner

    public var canVerify: Bool {
        !awaitingIdentity && phase == .ready && code.count == Self.codeLength
    }
}

/// 二次验证执行器（短信方式；第三方方式只给注销，不在本任务）：打开即对当前 action 发码（sendSmsCode {purpose: step_up, action}，不带 phone：
/// 服务端按本人令牌发到账号绑定的手机，B1-02zzz、D10-1658 ①；调用置 `requiresSession`，没有就绪的本人会话本地拒、零发送，S2-1）。
/// Me.phone_bound 已知为 false 时不发码（noPhone，D10-1682 ②）；未知照常发，没绑手机由服务端回 20001 data.fields=[code]，按现有错误处理。
/// 倒计时按 resend_after_sec（未返回按 60 秒）；输满 6 位才能【验证并提交】→ stepUp {action, code[, summary]}（改收款带业务摘要，提现不带，
/// D10-1665 / D10-1667），成功把 token 交给发起方（发起方沿用原键重放）。20002 / 20003 清空输入并 assertive 播报；发码与
/// 验证的 42901 分开限流（执行层发送前闸门 + 页面置灰）。面板出现期间属于敏感浮层，关闭后迟到的结果只丢弃。只在主线程使用。
@MainActor
public final class StepUpController: ObservableObject {
    public static let sendOperation = "sendSmsCode"
    public static let verifyOperation = "stepUp"
    public static let purpose = "step_up"
    public nonisolated static let defaultResendSec: Int64 = 60
    /// 发码槽位里代表「账号当前绑定的手机号」的占位（App 没给槽位键时；不含数字、不上送、不显示，同 Android BOUND_SLOT）。
    static let boundSlot = "bound"
    /// 发码的本地拒绝里「一条没发、面板身份仍有效」的原因：落到发送失败（共用分类器 `WalletErrors.of` 对 account_mismatch 的静默口径不动）。
    static let unsentRejects = [LocalRejectReason.accountMismatch, LocalRejectReason.sessionUnreadable]

    @Published public internal(set) var state: StepUpUiState?
    let deps: WalletDeps
    var alive: () -> Bool
    var instance = 0
    var serial = 0
    var onToken: ((String) -> Void)?
    var onClosed: (() -> Void)?
    /// 本次面板要绑定进令牌的业务摘要（改收款；提现为 nil）。只在内存、只随本面板实例，不进界面状态与日志；收起面板即清。
    var summary: [String: String]?
    /// 所属注销流程固定的会话作用域此刻仍未变（只有注销流程的面板有；发码 / 验证的 42901 作用域已变不写共享禁用期，
    /// FU-IOS-WALLETSETTLEMENT-SCOPE）。提现 / 收款账号的面板为 nil（行为不变）。
    var scopeStill: (@Sendable () -> Bool)?
    var ticker: Task<Void, Never>?
    var resendUntil: Int64 = 0
    let requests = WalletRequests()
    let tasks = SettlingTasks()
    let deferral = IdentityDeferral()
    var waitOther: (() -> Void)?

    init(deps: WalletDeps, alive: @escaping () -> Bool) {
        self.deps = deps
        self.alive = alive
    }

    public var showing: Bool {
        state != nil
    }

    /// 打开面板并发码。`owner` 是打开它的提交 / 确认的身份（共性第 60 条）；`summary` 是验证时带上的业务摘要（`StepUpSummary`，提现为 nil）。
    func open(action: String, owner: WalletOwner, summary: [String: String]? = nil,
              onToken: @escaping (String) -> Void, onClosed: @escaping () -> Void) {
        instance += 1
        self.onToken = onToken
        self.onClosed = onClosed
        self.summary = summary
        state = StepUpUiState(action: action, phase: .sending, instance: instance, owner: owner)
        deps.env.sensitiveOverlay(true)
        send()
    }

    /// 面板上的回调都带渲染时面板的实例与身份（共性第 60、63 条）：不是这个面板的、或已不是当前会话的不受理。
    func owns(_ current: StepUpUiState, instance: Int) -> Bool {
        current.instance == instance && !current.awaitingIdentity && deps.env.isCurrent(current.owner)
    }

    /// 输入回调（渲染时的面板实例）：只留数字，最多 6 位。
    public func onCodeChange(_ text: String, instance: Int) {
        guard var current = state, owns(current, instance: instance), current.phase != .verifying else { return }
        current.code = String(text.filter { $0.isASCII && $0.isNumber }.prefix(StepUpUiState.codeLength))
        state = current
    }

    /// 【重新获取】（倒计时结束、发码禁用期外）。
    public func resend(instance: Int) {
        guard let current = state, owns(current, instance: instance), current.resendLeftSec == 0,
              !deps.gates.sms.active, current.phase == .ready
        else { return }
        send()
    }

    /// 【验证并提交】。
    public func verify(instance: Int) {
        guard var current = state, owns(current, instance: instance), current.canVerify,
              current.owner.account != nil
        else { return }
        if deps.gates.verify.active {
            current.error = notice("error.42901")
            state = current
            return
        }
        let owner = current.owner
        current.phase = .verifying
        current.error = nil
        state = current
        let summary = summary
        let body = StepUpSummary.verifyBody(action: current.action, code: current.code, summary: summary)
        let probe = deps.gates.verify.probe()
        let panel = instance
        let deps = deps
        let scopeStill = scopeStill
        requests.send(deps.api, ApiCall(operationId: Self.verifyOperation, body: body), probe: probe,
                      expected: owner.request) { [weak self] result in
            // 42901 先按归属写入共享禁用期（会话级，不依赖面板存活），再看面板是否有效（共性第 27、40、66 条）
            deps.settlement.settleRetryAfter(result, gate: deps.gates.verify, owner: owner, scopeStill: scopeStill)
            self?.verifiedArrived(result, panel: panel, current: current, probe: probe, summary: summary)
        }
    }

    func verifiedArrived(_ result: ApiResult, panel: Int, current: StepUpUiState, probe: SendProbe,
                         summary: [String: String]? = nil) {
        guard let account = current.owner.account, admit(panel, current.owner, resume: { [weak self] in
            self?.verifiedArrived(result, panel: panel, current: current, probe: probe, summary: summary)
        }) else { return }
        onVerified(result, account: account, action: current.action, probe: probe, summary: StepUpSummary.key(summary))
    }

    /// 固定面板的结果只延后采用；重试只请 App 核对身份。核对不过（stale）时执行 `stale`（发码结果落到发送失败，其余调用方不动面板）。
    func admit(_ panel: Int, _ owner: WalletOwner, waiting: Bool = false, stale: () -> Void = {},
               resume: @escaping @MainActor () -> Void) -> Bool {
        guard alive(), panel == instance, state != nil else { return false }
        let check = waiting ? IdentityCheck.unknown : deps.env.check(owner)
        guard deferral.admit(check, slot: "panel", resume: resume, settle: {
            state?.awaitingIdentity = true
            state?.error = nil
        }) else {
            if check == .stale {
                stale()
            }
            return false
        }
        state?.awaitingIdentity = false
        return true
    }

    public func recheckIdentity(instance: Int) {
        guard state?.instance == instance, state?.awaitingIdentity == true else { return }
        deps.env.recheckIdentity()
    }

    public func resumeAfterIdentityConfirmed() {
        deferral.resume()
    }

    public func whenIdle() async {
        repeat {
            await tasks.whenIdle()
            await requests.settling.whenIdle()
        } while !tasks.isIdle || !requests.settling.isIdle
    }

    /// `summary` 是签发时绑定的摘要键（`StepUpSummary.key`）：令牌按它缓存，摘要不同的请求不复用（D10-1667）。
    func onVerified(_ result: ApiResult, account: String, action: String, probe: SendProbe, summary: String? = nil) {
        guard var current = state else { return }
        if case let .success(data, _, _) = result, let parsed = WalletJSON.stepUp(WalletJSON.parse(data)) {
            deps.tokens.put(
                action: action, account: account, token: parsed.token, expireAtMs: parsed.expireAtMillis,
                summary: summary
            )
            let deliver = onToken
            dismiss()
            deliver?(parsed.token)
            return
        }
        var clear = false
        if case let .failure(code, _, _, _, _, _) = result {
            clear = code == 20002 || code == 20003
        }
        current.phase = .ready
        if clear {
            current.code = ""
        }
        if case .success = result {
            current.error = notice("error.50001")
        } else {
            current.error = failure(result, probe: probe)
        }
        state = current
    }

    /// 用户点【关闭】（点遮罩、下滑不关闭；系统返回、读屏擦除走同一出口）。`instance` 是渲染时的面板实例（APP-11 第 17 条）。
    public func close(instance: Int) {
        guard let current = state, current.instance == instance else { return }
        let closed = onClosed
        dismiss()
        closed?()
    }

    /// 收起面板（拿到 token、会话换代、离页）：在途的验证作废，迟到的结果只丢弃；已发出的发码照常结算共享倒计时（共性第 40 条）。
    func dismiss() {
        deferral.reset()
        instance += 1
        ticker?.cancel()
        ticker = nil
        requests.cancelAll()
        waitOther?()
        waitOther = nil
        if state != nil {
            deps.env.sensitiveOverlay(false)
        }
        state = nil
        onToken = nil
        onClosed = nil
        summary = nil
    }

    func notice(_ key: String) -> Notice {
        serial += 1
        return Notice(key, id: serial)
    }

    func failure(_ result: ApiResult, probe: SendProbe) -> Notice? {
        let error = WalletErrors.of(result, probe: probe)
        switch error.kind {
        case .cancelled:
            return nil
        case .gated, .retryAfter:
            // 禁用期已在结果回来时按归属写入；本请求被发送前限流拦下的同样提示 42901（共性第 62 条）
            return notice("error.42901")
        case .forceUpdate:
            return notice("error.10405")
        default:
            serial += 1
            return error.notice(id: serial)
        }
    }
}

/// 二次验证令牌的业务摘要（BR-ID-08 细则「绑定业务摘要」；openapi StepUpBySmsRequest.summary / StepUpSummary）：只有改收款
/// （payout_account_change）带，取自将要发给 PUT /v1/me/payout-account 的原请求体（首次保存取保存的请求体，确认上一笔取未决记录原体），
/// 原样上送账号字段（服务端规范化、算 HMAC）：支付宝 {payout_method: alipay, alipay_logon_id}，借记卡 {payout_method: bank_card, card_no}；
/// 不带收款人姓名、开户行，客户端不算指纹（不是本机脱敏的展示摘要 `PayoutPendingSummary`，G15）。提现不带（D10-1665 / D10-1667：
/// withdraw 带 summary 回 20001），iOS 没有微信收款（StepUpSummaryWechat 不接）。
public enum StepUpSummary {
    public static let field = "summary"

    /// 改收款的摘要；请求体读不出、方式不认识或账号字段缺失为 nil。
    public static func payoutChange(body: String?) -> [String: String]? {
        guard let object = WalletJSON.parse(body.map { Data($0.utf8) }) as? [String: Any],
              let method = object[PayoutAccountForm.payoutMethod] as? String
        else { return nil }
        let accountField = switch method {
        case WalletJSON.alipay: PayoutAccountForm.alipayLogonId
        case WalletJSON.bankCard: PayoutAccountForm.cardNo
        default: ""
        }
        guard !accountField.isEmpty, let account = object[accountField] as? String, !account.isEmpty else { return nil }
        return [PayoutAccountForm.payoutMethod: method, accountField: account]
    }

    /// 令牌缓存的摘要键（键排序的 JSON 文本）；没有摘要为 nil。
    public static func key(_ summary: [String: String]?) -> String? {
        summary.map { WalletJSON.text($0) }
    }

    /// stepUp 请求体：{action, code}，有摘要时加 summary（openapi StepUpBySmsRequest）。
    public static func verifyBody(action: String, code: String, summary: [String: String]?) -> String {
        var body: [String: Any] = ["action": action, "code": code]
        if let summary {
            body[field] = summary
        }
        return WalletJSON.text(body)
    }
}
