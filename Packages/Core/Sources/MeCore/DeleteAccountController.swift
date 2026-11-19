import Combine
import CouliNetwork
import Foundation
import Generated
import WalletCore

/// 注销页的固定身份（APP-13a §0 第 1 条「身份固定」、共性第 36、45 条）：账号 + 会话世代 + 作废世代 + 清理次数（`WalletOwner`）+ 会话作用域
/// + 入口来源，在执行器**构造时一次性**取得。之后对当前会话只做比较；作用域变了（受限 → full）App 按新作用域重建整页（共性第 15 条）。
public struct DeletionIdentity: Equatable, Sendable {
    public let owner: WalletOwner
    /// full / deletion_only（`DeletionScope.normalized`）。
    public let scope: String
    public let source: DeletionSource

    public init(owner: WalletOwner, scope: String, source: DeletionSource) {
        self.owner = owner
        self.scope = DeletionScope.normalized(scope)
        self.source = source
    }
}

/// App 给注销页的出口（都在主线程调用；`page` 是本页的导航实例编号，只作用于这一个实例）。
@MainActor
public protocol DeleteAccountPorts: AnyObject, Sendable {
    /// 此刻的会话作用域（只用于和固定身份比较）。
    func sessionScope() -> String
    /// 经 Router 以 App 内来源打开（Withdraw、BindPhone、Login 等补办页；路由名都在 routes.json）。
    func open(_ route: String, from page: UUID)
    /// 【联系客服】：统一客服出口（APP-12），不是路由。
    func contactService()
    /// getMe 的会话级共享读取截止时间（MeGates.read；APP-12 共性第 32、33 条）。nil = 没接，用钱包读闸门。
    var meReadGate: RetryAfterGate? { get }
    /// 从强更页进入的申请成功 / 撤回成功：回到 ForceUpdate（03 §4.1），标签随之重取。
    func returnToForceUpdate(page: UUID)
    /// 从设置进入的撤回成功：出栈回 Settings 的唯一导航实例并在那里轻提示（G18）。返回是否已出栈（没出栈时本页自己轻提示）。
    func returnToSettings(page: UUID) -> Bool
    /// 注销进度变了（申请、撤回、作废得到 completed）：强更页「注销账号 / 撤销注销」标签重取。`owner` 是写请求的固定身份。
    func deletionChanged(_ owner: WalletOwner)
}

/// 注销页的页面数据（读取、勾选、本页提示）。待确认、提交中、二次验证、写请求的错误条在 `flow.state`（SensitiveFlow）。
public struct DeletionSnapshot: Equatable, Sendable {
    public var read: DeletionRead?
    public var readFailed = false
    public var readError: Notice?
    public var funds: DeletionFunds?
    public var fundsFailed = false
    public var fundsError: Notice?
    public var phoneBound: Bool?
    /// 「放弃未提现余额和预估收益」：默认不勾；会话换代随整页重建清空。
    public var waiver = false
    /// 本次申请（或确认 / 作废带回的原结果）得到 30416，还没有用户主动刷新（共性第 10、34 条）。
    public var blocked30416 = false
    public var amount30416: Int64?
    /// 30412（有进行中的提现）：错误条旁给【去提现】（受限会话、从强更进入不给，G12）。
    public var withdrawHint = false
    /// 表外码的服务端 msg（G26）：文案键 → msg。字典没有 error.<code> 时页面显示它（键是写请求错误条的文案键）。
    public var serverMsg: [String: String] = [:]
    /// 本页提示（未绑手机、撤回结果、读取的 42901 等）。
    public var notice: Notice?
    /// 撤回注销在途（按钮「提交中…」）。
    public var cancelling = false
    /// 一次性轻提示（撤回成功等）。
    public var toast: Notice?
    /// 页面数据版本：按钮回调绑定渲染时的版本，执行时核对（进度、资格变化后旧回调作废）。
    public var version = 0
}

/// 页面存活标记（流程在构造时就要一个存活判断，执行器那时还没有 self）。
final class DeletionLife {
    var alive = true
}

/// 注销页执行器（APP-13a-1；brief §2 第 2–4 项；设计稿 DeleteAccount*）：
/// - 进页读 getDeletion（与强更页标签共用 `gates.deletionRead`）、钱包摘要三项（`gates.read`）、必要时 getMe 的 phone_bound（MeGates.read）；
///   只调受限会话表内的接口（BR-ID-01），网络层的作用域拦截照用；同类读取只收最新一次，出栈 / 换代在同步出口作废；
/// - 申请、确认上一次、放弃上一次走 `SensitiveFlow.accountDeletion`（未决键、二次验证、结局表），离开页面不取消（未决记录兜底）；
/// - 撤回注销（cancelDeletion）不写未决记录、不自动重发，结果未知后按读取核对（共性第 14、33 条）；
/// - 30416 提示取本次响应的 amount_fen，与进页负余额提示分开；资格按用户主动刷新后的新读取更新（共性第 10、34、42 条）；
/// - 申请成功后不退出登录、不清会话（G19）。只在主线程使用。
@MainActor
public final class DeleteAccountController: ObservableObject, FlowHost, IdentityResumable {
    public static let route = "DeleteAccount"
    static let getDeletion = "getDeletion"
    static let cancelOperation = "cancelDeletion"
    static let walletSummary = "getWalletSummary"
    static let getMe = "getMe"
    public static let withdrawRoute = "Withdraw"
    public static let bindPhoneRoute = "BindPhone"
    public static let noPhoneKey = "step_up.no_available_method"

    @Published public internal(set) var state = DeletionSnapshot()
    public let flow: SensitiveFlow
    public let identity: DeletionIdentity
    public let page: UUID
    let deps: WalletDeps
    weak var ports: DeleteAccountPorts?
    let life: DeletionLife
    var serial = 0
    var readSerials: [String: Int] = [:]
    var readFlags: [String: RequestFlag] = [:]
    let deferral = IdentityDeferral()
    /// 撤回结果未知后的核对（读到用户撤回的 cancelled 走撤回成功结算；仍在冷静期只留人工重试）。
    var cancelReconcile = false
    /// 点【申请注销】时 phone_bound 未知：先重取 getMe，查清后按同一次点击继续（brief §2.3「未知时先重取 getMe」）。
    var submitAfterMe = false
    /// 不可见时到达的成功去向（回到可见再执行，APP-09 共性第 41 条）。
    var deferredExit: DeletionCancelOutcome.Navigate?
    var subscriptions: Set<AnyCancellable> = []
    var started = false

    public init(deps: WalletDeps, identity: DeletionIdentity, page: UUID, ports: DeleteAccountPorts) {
        self.deps = deps
        self.identity = identity
        self.page = page
        self.ports = ports
        let life = DeletionLife()
        self.life = life
        flow = SensitiveFlow.accountDeletion(deps: deps, owner: identity.owner, alive: { life.alive })
        state.phoneBound = deps.env.stepUpPhoneBound(identity.owner)
        flow.attach(self)
    }

    public var alive: Bool {
        life.alive
    }

    /// 页面订阅的几份禁用期（按钮置灰与读取失败态【重试】的可用性，共性第 19、42 条）。
    public var writeGate: RetryAfterGate {
        deps.gates.deletion
    }

    public var cancelGate: RetryAfterGate {
        deps.gates.deletionCancel
    }

    public var readGate: RetryAfterGate {
        deps.gates.deletionRead
    }

    public var fundsGate: RetryAfterGate {
        deps.gates.read
    }

    /// 服务端校准后的时钟（冷静期截止、提交时间按 BR-TEXT-11 显示）。
    public func displayNowMillis() -> Int64 {
        deps.env.displayNowMillis()
    }

    /// 显示结论（纯规则 `DeletionPresentation`）。
    public var view: DeletionView {
        DeletionPresentation.view(input)
    }

    public var input: DeletionInput {
        let flowState = flow.state
        return DeletionInput(
            read: state.read, readFailed: state.readFailed, funds: state.funds, fundsFailed: state.fundsFailed,
            phoneBound: state.phoneBound,
            pending: DeletionPresentation.pending(
                hasPendingCard: flowState.pending != nil || flowState.pendingUnreadable,
                submitting: flowState.phase == .submitting || flowState.awaitingIdentity
            ),
            scope: identity.scope, source: identity.source, blocked30416: state.blocked30416,
            amount30416: state.amount30416
        )
    }

    /// 【申请注销】此刻可点（勾选、规则允许、流程可提交、写闸门外）。
    public var applyEnabled: Bool {
        state.waiver && view.applyEnabledWhenChecked && flow.state.canSubmit && !deps.gates.deletion.blocked
    }

    /// 回调身份核对（共性第 4、36、63 条）：渲染时的版本与固定身份；固定身份仍是当前会话、作用域也没变。
    func owns(_ version: Int, _ owner: WalletOwner) -> Bool {
        alive && version == state.version && owner == identity.owner && deps.env.isCurrent(owner) && scopeHolds
    }

    /// 固定的作用域仍是此刻的作用域（受限 → full 后旧页面不再受理，等 App 重建）。
    var scopeHolds: Bool {
        guard let ports else { return false }
        return DeletionScope.normalized(ports.sessionScope()) == identity.scope
    }

    func notice(_ key: String, traceId: String? = nil, trace6: Bool = false, assertive: Bool = true) -> Notice {
        serial += 1
        return Notice(key, id: serial, traceId: traceId, showTrace6: trace6, assertive: assertive)
    }

    // MARK: - 生命周期

    /// 进入页面：恢复本账号的未决记录（冷启动、换代后）、读进度、资金与绑定状态；订阅读闸门到期后自动刷新（共性第 19 条）。
    public func start() {
        guard alive, !started else { return }
        started = true
        guard identity.owner.account != nil || !identity.owner.identityKnown else { return }
        let api = deps.api
        Task { @MainActor [weak self] in
            await api.restorePending()
            guard let self, alive else { return }
            flow.syncPending()
        }
        watchGates()
        loadAll(explicit: false)
    }

    /// 页面可见性（Router 栈顶 + 场景在前台）：回到可见时按本机记录重建待确认、刷新数据，执行被推迟的成功去向。
    public func setVisible(_ shown: Bool) {
        let was = flow.visibility.visible
        flow.visibility.set(shown)
        guard shown, alive else { return }
        if let exit = deferredExit {
            deferredExit = nil
            leaveTo(exit)
            return
        }
        guard !was, started else { return }
        flow.syncPending()
        loadAll(explicit: false)
    }

    /// 真正出栈或整页按新身份重建（同步出口）：作废读请求、收起面板与确认框；写请求不取消，结果只落到未决记录与会话级结算。
    public func leave() {
        guard alive else { return }
        life.alive = false
        for flag in readFlags.values {
            flag.invalidate()
        }
        readFlags = [:]
        deferral.reset()
        subscriptions = []
        flow.detach()
    }

    public func resumeAfterIdentityConfirmed() {
        guard alive else { return }
        flow.resumeAfterIdentityConfirmed()
        deferral.resume()
    }
}
