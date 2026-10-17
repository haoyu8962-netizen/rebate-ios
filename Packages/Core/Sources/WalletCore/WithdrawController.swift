import CouliNetwork
import Foundation

/// 估算行的界面状态：隐藏、计算中（不播报）、结果（只读结果）。
public enum EstimateUi: Equatable, Sendable {
    case hidden
    case calculating
    case shown(EstimateLine, amountFen: Int64)
}

/// 提现页的一次状态快照。`version` 每次换 rules 数据加一：按钮回调带渲染时的版本与身份，执行时核对仍是它。
public struct WithdrawSnapshot: Equatable, Sendable {
    public enum Phase: Equatable, Sendable {
        case loading, content, error
    }

    public var phase: Phase = .loading
    public var loadError: Notice?
    public var rules: WithdrawRules?
    public var amountText = ""
    public var estimate: EstimateUi = .hidden
    public var payout: PayoutAccountDisplay?
    public var helpTarget: HelpLink.Target?
    public var slaText: String?
    public var version = 0
    /// 页内读取（rules、估算）失败的提示：42901、5xxxx + trace6（共性第 3、30 条）；整页已有内容时不换成错误态。
    public var readError: Notice?
    /// 收款账号行读取失败的提示（与 rules 的 `readError` 分开保存）。
    public var payoutError: Notice?
    /// 提交得到 30306 后本页记下的服务端阻断（共性第 10 条）：只有之后成功取得、明确允许的 rules 才解除。
    public var serverBlocked = false
    /// 提交已成功、等页面回到可见再进提现记录（共性第 41 条）：期间【提交】不可用。
    public var successPending = false
    /// 一次性读屏播报（键 + 金额变量；`announceId` 每次换新）。
    public var announce: TextLine?
    public var announceId = 0
    /// 收起键盘的请求编号（【提交】先收起键盘）。
    public var hideKeyboardId = 0

    public var inputFen: Int64? {
        WithdrawAmountInput.parse(amountText)
    }

    public func display(slaDefault texts: WalletTexts = WalletDraftTexts()) -> WithdrawRulesDisplay? {
        rules.map { WithdrawRulesView.of($0, inputFen: inputFen, slaText: slaText, texts: texts) }
    }

    public var guide: WithdrawBlockGuide.View {
        guard let rules, !rules.canWithdraw else { return WithdrawBlockGuide.view(blockCode: nil, blockReason: nil) }
        return WithdrawBlockGuide.view(blockCode: rules.blockCode, blockReason: rules.blockReason)
    }
}

/// 提现申请页执行器（Withdraw 路由；BR-WDR-04 / 07 细则，brief §2.4、§2.5）：
/// - 每次进入、回到前台都取 rules（同一页面实例，序号递增，带上当前合法金额；G05）；页头、上限、档位只取已应用过的最新序号；
/// - 输入变化立即「计算中…」，合法金额停顿约 0.5 秒再带 amount_fen 取 rules；估算响应四项都对得上（`WithdrawEstimateGate`）才显示；
/// - can_withdraw=false 时按 block_code 引导（用户点按钮才打开前置页），【提交】置灰；
/// - 提交与待确认由 `SensitiveFlow`（createWithdrawal、action=withdraw）；成功用 Router 以 WithdrawRecords {withdrawal_id} 替换本页（G19），
///   并标记钱包需要刷新。
/// 读请求绑定页面实例与固定身份；页面出栈（同步出口）后读请求作废。只在主线程使用。
@MainActor
public final class WithdrawController: ObservableObject, IdentityResumable {
    public static let operation = "createWithdrawal"
    public static let action = "withdraw"
    static let rulesOperation = "getWithdrawRules"
    static let payoutOperation = "getPayoutAccount"
    static let debounceNanos: UInt64 = 500_000_000

    @Published public internal(set) var state: WithdrawSnapshot
    let deps: WalletDeps
    public let flow: SensitiveFlow
    /// 页面实例（去前置页再回来仍是同一实例；关闭后再进来是新实例）。
    public let pageInstance = UUID().uuidString
    /// 本页的导航实例（App 在建页时给；成功替换只作用于它，共性第 50 条）。
    public var page: UUID?
    var left = false
    var seq: Int64 = 0
    var appliedSeq: Int64 = 0
    var payoutSeq = 0
    /// rules / 收款账号读取因身份暂时未知而中止、等身份确认后补做（FU-IOS-0712 整体重理：与钱包摘要、各资金页同一套机制）。
    public let deferral = IdentityDeferral()
    var blockedAtSeq = Int64.max
    var estimateTask: Task<Void, Never>?
    let requests = WalletRequests()
    let payoutRequests = WalletRequests()
    var announcePending = false
    var serial = 0
    /// 提交成功时页面不在栈顶可见：替换为提现记录的导航留到回到可见时再做（共性第 37、41 条）。
    var deferredSuccess: (data: Any?, alreadyDone: Bool)?

    /// `owner` 与 `restored` 来自同一次读取（共性第 65 条：App 读身份、再按它的账号读金额草稿，成对传入）。
    public init(deps: WalletDeps, owner: WalletOwner, restored: String = "") {
        self.deps = deps
        state = WithdrawSnapshot(amountText: WithdrawAmountInput.accept(current: "", next: restored))
        flow = SensitiveFlow(
            deps: deps, operationId: Self.operation, action: Self.action, outcomeOp: SensitiveOutcome.withdraw,
            gate: deps.gates.withdraw, marksWalletDirty: true, alive: { true }, owner: owner
        )
        flow.alive = { [weak self] in self.map { !$0.left } ?? false }
        flow.host = self
    }

    public var alive: Bool {
        !left
    }

    public var owner: WalletOwner {
        flow.owner
    }

    /// 进入页面：取 rules（带上恢复的合法金额）、收款账号、未决记录。
    public func start() {
        // 已确认没有会话的表单不读；身份暂时未知时构造的表单照常核对（结算为可重试，身份确认后由 App 换上身份）
        guard !left, flow.owner.account != nil || !flow.owner.identityKnown else { return }
        state.slaText = deps.env.configText("withdraw.sla_text")
        state.helpTarget = HelpLink.target(deps.env.helpLinks(), key: HelpLink.withdrawRules)
        let api = deps.api
        Task { @MainActor [weak self] in
            await api.restorePending()
            self?.flow.refreshPending()
        }
        fetchRules(amount: state.inputFen, initial: true, form: flow.owner)
        fetchPayout()
    }

    /// 回到前台（被前置页盖住后返回、App 回前台）：同一实例、保留金额，立即重取 rules（G05）与收款账号，重读未决记录；推迟的成功导航在这时消费。
    public func setVisible(_ shown: Bool) {
        let wasVisible = flow.visibility.visible
        flow.visibility.set(shown)
        guard shown, !left else { return }
        if let deferred = deferredSuccess {
            deferredSuccess = nil
            navigateSucceeded(deferred.data, alreadyDone: deferred.alreadyDone)
            return
        }
        guard !wasVisible else { return }
        flow.refreshPending()
        fetchRules(amount: state.inputFen, initial: state.rules == nil, form: flow.owner)
        fetchPayout()
    }

    func nextNotice(_ key: String) -> Notice {
        serial += 1
        return Notice(key, id: serial)
    }
}
