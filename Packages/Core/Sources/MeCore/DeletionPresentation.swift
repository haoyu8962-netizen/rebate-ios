import Foundation

/// 注销页从哪里进入（不走路由参数：DeleteAccount 丢参，由 App 按导航栈交接一次，共性第 4 条）。
public enum DeletionSource: String, Sendable, Equatable {
    case settings
    case forceUpdate = "force_update"
    case riskNotice = "risk_notice"
    case error10007 = "error_10007"
    case other
}

/// 会话作用域（session_scope）。
public enum DeletionScope {
    public static let full = "full"
    public static let deletionOnly = "deletion_only"

    /// 没有会话或读不出（空串）按 full 对待（MeEnv.sessionScope 同口径）。
    public static func normalized(_ raw: String?) -> String {
        raw == deletionOnly ? deletionOnly : full
    }
}

/// 本账号 requestDeletion 的未决状态（取自 SensitiveFlow 的页面状态，来源是本机未决记录）。
public enum DeletionPending: String, Sendable, Equatable {
    case none
    /// 本进程首次提交在途（含二次验证后的重放）。
    case inFlight = "in_flight"
    /// 有结果未知的上一次提交（待确认卡）。
    case unknown
}

/// 注销页的显示状态（brief §2.2；设计稿 DeleteAccount*）。
public enum DeletionStateKind: String, Sendable, Equatable {
    /// 进度还在读（首帧）。
    case loading
    case initial
    /// 余额为负（进页 negative_fen > 0，或本次申请得到 30416 且还没有明确刷新）。
    case negative
    /// 钱包摘要读取失败：申请前必须展示余额（BR-ID-27），申请置灰。
    case fundsUnavailable = "funds_unavailable"
    case cooling
    /// processing / done：只提示 error.10007，没有操作。
    case processing
    case pendingConfirm = "pending_confirm"
    /// 账号没绑手机（Me.phone_bound=false）：申请可点，点后只提示 BR-ID-08 原句，不发请求（G10）。
    case noPhone = "no_phone_step_up"
    /// getDeletion 失败或坏数据：整页错误 + 【重试】，申请与撤回都不可用（不能当成「从未申请」）。
    case loadFailed = "load_failed"
}

/// 显示规则的输入（纯值，向量 / 单测直接构造）。
public struct DeletionInput: Equatable, Sendable {
    /// getDeletion：nil = 还在读（且没有失败）。
    public var read: DeletionRead?
    public var readFailed = false
    /// 钱包摘要：nil = 还在读或失败（看 `fundsFailed`）。
    public var funds: DeletionFunds?
    public var fundsFailed = false
    public var phoneBound: Bool?
    public var pending: DeletionPending = .none
    public var scope: String = DeletionScope.full
    public var source: DeletionSource = .other
    /// 本次申请（或确认 / 作废带回的原结果）得到 30416，且之后还没有用户主动刷新（共性第 34 条：资格按明确刷新后的新读取更新）。
    public var blocked30416 = false
    /// 那次 30416 的 data.amount_fen（缺失为 nil，用不带金额的兜底句；共性第 10 条：不被自动重取的 negative_fen 替换）。
    public var amount30416: Int64?

    public init(read: DeletionRead? = nil, readFailed: Bool = false, funds: DeletionFunds? = nil,
                fundsFailed: Bool = false, phoneBound: Bool? = nil, pending: DeletionPending = .none,
                scope: String = DeletionScope.full, source: DeletionSource = .other, blocked30416: Bool = false,
                amount30416: Int64? = nil) {
        self.read = read
        self.readFailed = readFailed
        self.funds = funds
        self.fundsFailed = fundsFailed
        self.phoneBound = phoneBound
        self.pending = pending
        self.scope = scope
        self.source = source
        self.blocked30416 = blocked30416
        self.amount30416 = amount30416
    }
}

/// 显示结论。
public struct DeletionView: Equatable, Sendable {
    public let kind: DeletionStateKind
    /// 勾选框可用。
    public let waiverEnabled: Bool
    /// 勾选之后【申请注销】可用（还要勾选、页面不在提交中）。
    public let applyEnabledWhenChecked: Bool
    /// 【去提现】：只在 full 会话、不是从强更进入时（G12）。
    public let showGoWithdraw: Bool
    /// 【撤回注销】：只看服务端 can_cancel（G15）。
    public let showCancel: Bool
    /// 余额为负提示里的金额：进页取 negative_fen；本次 30416 取 data.amount_fen（nil = 不带金额的兜底句）。
    public let negativeFen: Int64?
    /// 负余额提示的来源：true = 本次 30416（error.30416 的 {amount} 取响应），false = 进页 negative_fen。
    public let negativeFromSubmit: Bool
    /// 【联系客服】（余额为负）。
    public let showContactService: Bool
    /// 资金区显示的数字（读到时）。
    public let funds: DeletionFunds?
    public let deletion: Deletion?
}

/// 注销页显示规则（brief §2.2，Android DeletionPresentation 对照）。优先级：pending_confirm > load_failed > 读取中 > cooling / processing >
/// negative（30416 > negative_fen）> funds_unavailable > 资金读取中 > no_phone_step_up > initial。
/// cancelled 按 initial 判断，是否为负只看这一次 negative_fen（G20）。
public enum DeletionPresentation {
    public static func view(_ input: DeletionInput) -> DeletionView {
        let maker = Maker(input: input)
        if input.pending == .unknown {
            // 待确认卡独立于进度 / 资金读取（共性第 46 条）：资金区与须知保留，勾选与申请置灰
            return maker.make(.pendingConfirm, withdraw: maker.canWithdraw && input.funds != nil)
        }
        return progress(input, maker) ?? form(input, maker)
    }

    /// 进度决定的几种（读取失败、读取中、冷静期、处理中）；从未申请或 cancelled 为 nil（交给表单规则）。
    static func progress(_ input: DeletionInput, _ maker: Maker) -> DeletionView? {
        if input.readFailed || input.read == .bad {
            return maker.make(.loadFailed)
        }
        guard let read = input.read else {
            return maker.make(.loading)
        }
        switch read.deletion?.status {
        case .some(Deletion.cooling):
            return maker.make(.cooling, cancel: read.deletion?.canCancel == true)
        case .some(Deletion.processing), .some(Deletion.done):
            return maker.make(.processing)
        default:
            return nil
        }
    }

    /// 说明与条件确认一族（negative > funds_unavailable > 资金读取中 > no_phone_step_up > initial）。
    static func form(_ input: DeletionInput, _ maker: Maker) -> DeletionView {
        let editable = input.pending == .none
        if input.blocked30416 {
            return maker.make(.negative, negative: input.amount30416, fromSubmit: true, cs: true)
        }
        if let funds = input.funds, funds.negativeFen > 0 {
            return maker.make(.negative, negative: funds.negativeFen, cs: true)
        }
        if input.fundsFailed {
            return maker.make(.fundsUnavailable)
        }
        guard input.funds != nil else {
            // 申请前必须展示余额（BR-ID-27）：资金没读到之前申请置灰
            return maker.make(.initial, waiver: editable)
        }
        let kind: DeletionStateKind = input.phoneBound == false ? .noPhone : .initial
        return maker.make(kind, waiver: editable, apply: editable, withdraw: maker.canWithdraw)
    }

    /// 按同一份输入拼显示结论。
    struct Maker {
        let input: DeletionInput

        /// 【去提现】只在 full 会话、不是从强更进入时（G12）。
        var canWithdraw: Bool {
            DeletionScope.normalized(input.scope) == DeletionScope.full && input.source != .forceUpdate
        }

        func make(_ kind: DeletionStateKind, waiver: Bool = false, apply: Bool = false, withdraw: Bool = false,
                  cancel: Bool = false, negative: Int64? = nil, fromSubmit: Bool = false,
                  cs: Bool = false) -> DeletionView {
            DeletionView(
                kind: kind, waiverEnabled: waiver, applyEnabledWhenChecked: apply, showGoWithdraw: withdraw,
                showCancel: cancel, negativeFen: negative, negativeFromSubmit: fromSubmit, showContactService: cs,
                funds: input.funds, deletion: input.read?.deletion
            )
        }
    }

    /// 页面状态里的未决：有待确认卡 → unknown；本进程首次提交在途 → in_flight。
    public static func pending(hasPendingCard: Bool, submitting: Bool) -> DeletionPending {
        hasPendingCard ? .unknown : (submitting ? .inFlight : .none)
    }
}

/// 撤回注销的结局（brief §2.4；不写未决记录、不自动重发）。
public struct DeletionCancelOutcome: Equatable, Sendable {
    public enum Next: String, Sendable {
        /// 撤回成功：按来源去向。
        case cancelled
        /// 停在冷静期页（附提示），视 `refetch` 重取进度。
        case stay
    }

    public enum Navigate: String, Sendable {
        case none
        /// 出栈回 Settings 的唯一导航实例并轻提示。
        case settings
        /// 回到强更页（标签随之重取）。
        case forceUpdate = "force_update"
    }

    public let next: Next
    /// 提示文案键（成功为轻提示 deletion.withdrawn_toast；其余为页内提示）。
    public let textKey: String
    public let navigate: Navigate
    /// 结果之后重取 getDeletion（10007、结果未知；成功由调用方另推进读取世代）。
    public let refetch: Bool
    /// 结果未知后的核对读取（共性第 14、33 条）：读到用户撤回的 cancelled 就按撤回成功结算。
    public let reconcile: Bool
    public let showTrace6: Bool

    public static let withdrawnKey = "deletion.withdrawn_toast"
    /// 撤回得到 10007（冷静期已过）：显示契约的 error.10007（D10-2094 ①）。
    public static let expiredKey = "error.10007"
    /// TODO(N-37) 草稿键：撤回结果未知。
    public static let unknownKey = "deletion.cooling.cancel_unknown"

    /// `code`：nil = 没有统一外壳（超时、断连、网关错误页）；0 = 成功。`code` 为 5xxxx 时 `serverKey` 是统一错误文案键。
    public static func of(code: Int?, source: DeletionSource, serverKey: (Int) -> String,
                          errorKey: (Int) -> String) -> DeletionCancelOutcome {
        guard let code else {
            return DeletionCancelOutcome(next: .stay, textKey: unknownKey, navigate: .none, refetch: true,
                                         reconcile: true, showTrace6: false)
        }
        switch code {
        case 0:
            let navigate: Navigate = switch source {
            case .settings: .settings
            case .forceUpdate: .forceUpdate
            default: .none
            }
            return DeletionCancelOutcome(next: .cancelled, textKey: withdrawnKey, navigate: navigate, refetch: false,
                                         reconcile: false, showTrace6: false)
        case 10007:
            return DeletionCancelOutcome(next: .stay, textKey: expiredKey, navigate: .none, refetch: true,
                                         reconcile: false, showTrace6: false)
        case 42901:
            return DeletionCancelOutcome(next: .stay, textKey: "error.42901", navigate: .none, refetch: false,
                                         reconcile: false, showTrace6: false)
        default:
            if code / 10000 == 5 {
                return DeletionCancelOutcome(next: .stay, textKey: serverKey(code), navigate: .none, refetch: false,
                                             reconcile: false, showTrace6: true)
            }
            return DeletionCancelOutcome(next: .stay, textKey: errorKey(code), navigate: .none, refetch: false,
                                         reconcile: false, showTrace6: false)
        }
    }
}
