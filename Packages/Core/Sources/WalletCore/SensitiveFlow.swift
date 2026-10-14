import CouliNetwork
import Foundation

/// 待确认的上一笔（取自本机未决记录，按账号隔离；不按时间解除）。
public struct PendingView: Equatable, Sendable {
    public let key: String
    /// 未决记录里的展示摘要（提现：{"amount_fen":…}；收款账号：本机脱敏的 {"method","account","payee"}，G15）。
    public let summary: String
    public let createdAtMillis: Int64
    /// 本进程正在确认或作废（两个按钮都置灰，WithdrawPendingBusy）。
    public var inFlight: Bool
}

/// 44001 弹窗（WithdrawBlocked / PayoutAccountBlocked）：标题先查 risk_msg.<code>，回落 error.44001。`id` 是弹窗实例编号。
public struct RiskDialog: Equatable, Sendable {
    public let titleKey: String
    public let id: Int
}

/// 敏感写操作的页面状态（提现、收款账号变更共用）。`pendingVersion` 每次进入或离开待确认加一：一个键结束后，其余在途请求的响应只用于核对，
/// 不再改变页面（BR-ID-10 细则）。
public struct FlowState: Equatable, Sendable {
    public enum Phase: Equatable, Sendable {
        /// 可编辑、可提交。
        case editing
        /// 提交中（含二次验证后的重放）。
        case submitting
        /// 待确认。
        case pending
    }

    public var phase: Phase = .editing
    public var pending: PendingView?
    public var pendingVersion = 0
    /// 待确认卡片里的提示（retry_later、cannot_confirm、abandon_busy、正在处理）。
    public var pendingNotice: Notice?
    /// 编辑态的错误条（键结束的业务错误、5xxxx + trace6、42901）。
    public var error: Notice?
    /// 20001 的字段（提现 amount_fen；收款账号表单字段）。
    public var fieldErrors: [String] = []
    public var fieldErrorKey: String?
    /// 字段错误事件编号：每次 20001 换新（移焦点并播报一次，APP-09 共性第 24 条）。
    public var fieldErrorId = 0
    public var riskDialog: RiskDialog?
    /// 放弃的二次确认（绑定点击时的键与表单身份）。
    public var abandonConfirmKey: String?
    /// 未决记录读不出（安全存储故障）：不能确认未决状态，【提交】置灰。
    public var pendingUnreadable = false
    /// 一次性轻提示（已放弃、已经处理完成）。
    public var toast: Notice?
    /// 被拦下的自动引导（APP-09 共性第 51 条）：页面上给可点的手动入口，已填内容保留、不自动重提。
    public var guideRoute: String?
    /// 本表单所属的身份（APP-09 共性第 52 条）：按钮回调带上它，执行前核对。
    public var owner: WalletOwner

    public var canSubmit: Bool {
        phase == .editing && pending == nil && !pendingUnreadable
    }
}

/// 一次提交的原键、原请求体与展示摘要（二次验证后沿用原键、原体重放）。
struct Submission {
    let key: String
    let body: String
    let summary: String
}

/// 发起页接线：成功、引导补办、键结束后的刷新。
@MainActor
public protocol FlowHost: AnyObject {
    /// 业务成功（首次提交、确认上一笔、放弃得到 completed 且原结果成功）：`data` 为原操作的 data。
    func onSucceeded(_ data: Any?, alreadyDone: Bool)
    /// 键结束或待确认解除后：重取页面数据（rules、收款账号）。
    func onSettled()
    /// 前置补办（RealName、PayoutAccount、LaborAgreement、BindPhone、Login）：补办完回到发起页，不重放。
    func onGuide(_ route: String)
    /// 键结束的业务错误（提现 30306 等，APP-09 共性第 10 条）。
    func onBusinessError(_ code: Int)
}

/// 提现与收款账号变更的提交、二次验证、未决键与待确认（brief §0 第 3、4 条；BR-ID-10 细则「敏感操作的幂等键」；BR-WDR-07 细则）：
/// - 每次用户点【提交】（【保存】）生成一个新的 Idempotency-Key（结局要求沿用原键的除外），首次发送前由网络层 PendingKeyStore 写入未决记录
///   （键、operation、原请求体、脱敏摘要、账号；生产后端是 Keychain 的 SecurePendingKeyBackend）；
/// - 10003 → 二次验证面板，拿到 token 后沿用原键重放 1 次；10002 / 10402 网络层自动处理；补办类只引导、不重放；
/// - 结果未知 → 待确认：新的提交入口置灰，只有【确认上一笔】（原键原体重发，二次验证照常）与【放弃上一笔】（二次确认后作废）；
/// - 待确认状态的来源始终是本机未决记录（`refreshPending`），进入页面、回前台、登录成功、会话换代后都按表单身份重读；不按时间解除；
/// - 提交、确认、放弃离开页面不取消（未决记录兜底）：页面出栈后迟到的响应不改页面，结论只落到未决记录（网络层结算）。
/// 只在主线程使用。
@MainActor
public final class SensitiveFlow: ObservableObject {
    @Published public internal(set) var state: FlowState
    let deps: WalletDeps
    /// openapi operationId：createWithdrawal / savePayoutAccount。
    public let operationId: String
    /// step-up action：withdraw / payout_account_change。
    public let action: String
    /// 结局表的 op：withdraw / payout_account。
    let outcomeOp: String
    let gate: RetryAfterGate
    /// 原操作成功时通知钱包刷新（提现为 true；共享结算由 `WalletSettlement` 按任务持有的 `WriteTicket` 完成）。
    let marksWalletDirty: Bool
    weak var host: FlowHost?
    var alive: () -> Bool
    public let stepUp: StepUpController
    public let visibility = PageVisibility()

    /// 当前（或下次提交沿用的）键；nil = 下次用新键。
    var reuseKey: String?
    /// 最近一次提交的请求体与摘要（二次验证后沿用原键、原体重放）。
    var lastBody: String?
    var lastSummary = ""
    /// 最近一次点击【提交】/【保存】时固定的身份（二次验证后的原键重放沿用它，共性第 39 条）。
    var lastClick: WalletOwner?
    var serial = 0
    /// 同一个流程同时只有一个提交 / 确认 / 放弃在途：发出时的可见世代。
    var sentViewGen = 0
    /// 确认流程打开的二次验证属于哪个未决键（共性第 49 条）。
    var stepUpIntent: PendingIntent?
    var guideOwner: WalletOwner?
    /// 本页自己正在确认或作废。
    var localBusy = false
    var refreshSerial = 0
    var unsubscribe: (() -> Void)?

    init(deps: WalletDeps, operationId: String, action: String, outcomeOp: String, gate: RetryAfterGate,
         marksWalletDirty: Bool, alive: @escaping () -> Bool, owner: WalletOwner) {
        self.deps = deps
        self.operationId = operationId
        self.action = action
        self.outcomeOp = outcomeOp
        self.gate = gate
        self.marksWalletDirty = marksWalletDirty
        self.alive = alive
        state = FlowState(owner: owner)
        stepUp = StepUpController(deps: deps, alive: alive)
        stepUp.alive = { [weak self] in self?.alive() ?? false }
        // 未决记录结算后（别的页面、已出栈页面的迟到响应、本页）按本机记录重新同步当前页（共性第 1 条）：只收本表单身份的账号
        unsubscribe = deps.pending.subscribe { [weak self] settled in
            MainActor.assumeIsolated {
                guard let self, settled.operationId == operationId, self.alive(),
                      settled.account == self.state.owner.account
                else { return }
                self.refreshPending()
            }
        }
    }

    /// 本表单的固定身份。
    public var owner: WalletOwner {
        state.owner
    }

    /// 页面此刻可见、且可见世代与发出时相同（原导航许可仍有效）。
    var onScreen: Bool {
        alive() && visibility.showing(sentViewGen)
    }

    /// 页面此刻在栈顶且可见（延后的成功结果在这时安全消费，共性第 41 条）。
    public var visibleNow: Bool {
        alive() && visibility.now
    }

    /// 渲染快照的身份就是本流程当前的表单身份，且仍是当前会话（共性第 52 条）。
    func owns(_ owner: WalletOwner) -> Bool {
        owner == state.owner && deps.env.isCurrent(owner)
    }

    // MARK: - 提交

    /// 用户点【提交】（【保存】）。`body` 原始请求体（签名与重放都用这份），`summary` 未决记录的展示摘要，`owner` 渲染这张表单时的身份。
    func submit(body: String, summary: String, owner: WalletOwner) {
        guard alive(), state.canSubmit else { return }
        if gate.active {
            state.error = notice("error.42901")
            return
        }
        // 表单所属身份先于生成键、读取 token 核对（共性第 52 条）：会话已换而清空通知还没执行时，旧表单不发、不登记到新账号
        guard owns(owner), let account = owner.account else { return }
        let key = reuseKey ?? deps.newKey()
        reuseKey = key
        lastBody = body
        lastSummary = summary
        lastClick = owner
        state.phase = .submitting
        state.error = nil
        state.fieldErrors = []
        state.fieldErrorKey = nil
        state.guideRoute = nil
        let token = deps.tokens.take(action: action, account: account, nowMs: deps.env.nowMillis())
        send(click: owner, payload: Submission(key: key, body: body, summary: summary), token: token, replayed: false)
    }

    /// `replayed`：这次是本次用户提交在二次验证之后的原键重放（10003 重放预算已用，共性第 16 条）。请求不随页面取消（共性第 40 条），
    /// 带点击时的网络归属（共性第 39 条）。
    func send(click: WalletOwner, payload: Submission, token: String?, replayed: Bool) {
        // 发送前核对：会话已换（二次验证期间、排队期间）的不发，键不用了
        guard deps.env.isCurrent(click), let account = click.account else {
            reuseKey = nil
            if alive() {
                state.phase = .editing
            }
            return
        }
        sentViewGen = visibility.generation
        let probe = gate.probe()
        let call = ApiCall(
            operationId: operationId, body: payload.body, idempotencyKey: payload.key, stepUpToken: token,
            summary: payload.summary
        )
        let api = deps.api
        // 共享结算由任务持有的固定依据直接完成（共性第 66 条）：页面执行器释放后迟到的成功、42901 照常结算
        let ticket = writeTicket(click)
        let settlement = deps.settlement
        Task { @MainActor [weak self, deps, operationId, outcomeOp] in
            let result = await api.send(call, isValid: { true }, sendAllowed: probe.allowed, expected: click.request)
            let outcome = Self.isLocal(result) ? nil : SensitiveOutcome.of(
                op: outcomeOp, phase: SensitiveOutcome.submit, keyEverUnknown: false,
                input: WalletErrors.outcomeInput(result)
            )
            settlement.settleWrite(ticket, result, outcome, consumesToken: true)
            if let self, alive(), deps.env.isCurrent(click) {
                onSubmitResult(result, outcome, replayed: replayed, probe: probe)
            }
            // 结算通知放在本页处理完之后（共性第 1 条）
            deps.pending.send(PendingSettled(account: account, operationId: operationId))
        }
    }

    static func isLocal(_ result: ApiResult) -> Bool {
        switch result {
        case .localReject, .sessionCleared, .sessionNotSaved: true
        default: false
        }
    }

    /// 本次写请求的固定结算依据（点击时的身份、action、共享禁用期；共性第 66 条）。之后由页面按自己是否有效更新界面。10405 由网络层管线
    /// 进强更（已有分流）。
    func writeTicket(_ click: WalletOwner) -> WriteTicket {
        WriteTicket(owner: click, action: action, gate: gate, marksWalletDirty: marksWalletDirty)
    }

    func onSubmitResult(_ result: ApiResult, _ outcome: Outcome?, replayed: Bool, probe: SendProbe) {
        guard let outcome else {
            localRejected(result, probe: probe)
            return
        }
        apply(outcome, result: result, phase: SensitiveOutcome.submit, replayed: replayed, intent: nil)
    }

    /// 没有发出（本地拒绝）：同一操作已有未决键 → 按记录进待确认；限流闸门 → 限流提示；其余提示网络错误，键不用了。
    func localRejected(_ result: ApiResult, probe: SendProbe) {
        reuseKey = nil
        state.phase = .editing
        if probe.gated(result) {
            state.error = notice("error.42901")
        } else if case let .localReject(reason) = result, reason == LocalRejectReason.pendingKeyUnresolved {
            state.error = nil
        } else {
            state.error = notice(WalletErrors.networkKey)
        }
        refreshPending()
    }

    func notice(_ key: String) -> Notice {
        serial += 1
        return Notice(key, id: serial)
    }
}
