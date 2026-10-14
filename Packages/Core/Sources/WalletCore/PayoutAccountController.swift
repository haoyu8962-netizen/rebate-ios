import CouliNetwork
import Foundation

/// 收款账号页的一次状态快照。`form` 是用户填写的原文（只在内存，不进日志、恢复记录与截图）。
public struct PayoutSnapshot: Equatable, Sendable {
    public enum Phase: Equatable, Sendable {
        case loading, content, error
    }

    public var phase: Phase = .loading
    public var account: PayoutAccountDisplay?
    public var editing = false
    public var form = PayoutForm()
    /// 本地校验没过的字段（必填为空等）。
    public var localErrors: [String] = []
    /// 本地校验错误事件编号（每次【保存】校验不过换新，共性第 24 条）。
    public var localErrorId = 0
    public var loadError: Notice?
    public var version = 0
    /// 保存成功、停在本页时的轻提示。
    public var toast: Notice?
    /// 读取得到 30304 而页面当时不可见：不自动打开实名页，保留目标并给手动入口（共性第 47、51 条）。
    public var guideRoute: String?
}

/// 收款账号页执行器（PayoutAccount 路由；BR-WDR-02，FUND-03，brief §2.7，G12–G15）：已绑定显示服务端脱敏字段与「本月还能变更 {n} 次」+
/// 【更换收款账号】；未绑定直接显示表单（支付宝 / 本人借记卡，不显示微信零钱）。【保存】经 `SensitiveFlow`（savePayoutAccount、
/// action=payout_account_change，首次绑定也要二次验证），未决键规则与提现相同；待确认摘要本机按 BR-ID-33 细则脱敏（G15）。成功后显示服务端
/// 返回的脱敏串，清空表单与内存中的完整输入，再按 App 的判断出栈回发起页（从 Withdraw 进来）或停在本页。只在主线程使用。
@MainActor
public final class PayoutAccountController: ObservableObject {
    public static let operation = "savePayoutAccount"
    public static let action = "payout_account_change"
    static let getOperation = "getPayoutAccount"

    @Published public internal(set) var state = PayoutSnapshot()
    let deps: WalletDeps
    public let flow: SensitiveFlow
    public var page: UUID?
    var left = false
    var seq = 0
    var serial = 0
    let requests = WalletRequests()
    var deferredSaved: Bool?
    var guideOwner: WalletOwner?

    public init(deps: WalletDeps, owner: WalletOwner) {
        self.deps = deps
        flow = SensitiveFlow(
            deps: deps, operationId: Self.operation, action: Self.action, outcomeOp: SensitiveOutcome.payoutAccount,
            gate: deps.gates.payout, marksWalletDirty: false, alive: { true }, owner: owner
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

    /// 服务端校准后的当前时刻（待确认卡的提交时间）。
    public func displayNowMillis() -> Int64 {
        deps.env.displayNowMillis()
    }

    public func start() {
        guard !left, flow.owner.account != nil else { return }
        let api = deps.api
        Task { @MainActor [weak self] in
            await api.restorePending()
            self?.flow.refreshPending()
        }
        load()
    }

    /// 页面可见性（共性第 37、41、47 条）：回到本页（实名补办后返回，G05）保留已填内容，重读收款账号与未决记录；推迟的保存后动作在这时消费。
    public func setVisible(_ shown: Bool) {
        let wasVisible = flow.visibility.visible
        flow.visibility.set(shown)
        guard shown, !left else { return }
        if let done = deferredSaved {
            deferredSaved = nil
            afterSaved(done)
        }
        guard !wasVisible else { return }
        flow.refreshPending()
        load()
    }

    /// 读取（进入、回流、【重试】）：绑定本表单的固定身份（共性第 65 条）；本地限流拦下也结算（共性第 30、45、56 条）。
    public func load() {
        let form = flow.owner
        guard !left, form.account != nil, ownsForm(form) else { return }
        if deps.gates.read.active {
            gatedLoad()
            return
        }
        seq += 1
        let request = seq
        let navTicket = flow.visibility.generation
        if state.account == nil {
            state.phase = .loading
            state.loadError = nil
        }
        let probe = deps.gates.read.probe()
        let call = ApiCall(operationId: Self.getOperation)
        requests.send(deps.api, call, probe: probe, expected: form.request) { [weak self] result in
            guard let self, !left, seq == request, ownsForm(form) else { return }
            onLoaded(result, navTicket: navTicket, probe: probe)
        }
    }

    func gatedLoad() {
        serial += 1
        invalidateShown(Notice("error.42901", id: serial))
    }

    /// 重读没有取得当前账号（失败、被本地限流拦下；共性第 30、44、73 条，iOS R1-10）：旧账号展示作废——清掉当前账号行与依赖它的内容
    /// （剩余次数、【更换收款账号】），进可重试的错误态；已填的表单内容只在内存保留，重读成功后照常显示。待确认卡独立显示，不受影响。
    func invalidateShown(_ notice: Notice) {
        if state.account != nil {
            state.account = nil
            state.version += 1
        }
        state.phase = .error
        state.loadError = notice
    }

    func onLoaded(_ result: ApiResult, navTicket: Int, probe: SendProbe) {
        if case let .success(data, _, _) = result, let account = WalletJSON.payoutAccount(WalletJSON.parse(data)) {
            let view = PayoutAccountView.view(account)
            state.phase = .content
            state.account = view
            state.editing = state.editing || !view.bound
            state.loadError = nil
            state.guideRoute = nil
            state.version += 1
            return
        }
        let error = WalletErrors.of(result, probe: probe)
        switch error.kind {
        case .cancelled:
            return
        case .gated:
            gatedLoad()
            return
        case .retryAfter:
            deps.gates.read.start(error.disableMillis)
        default:
            break
        }
        if case let .failure(code, _, _, _, _, _) = result, code == 30304 {
            // 30304（未实名）：去实名，回来仍在本页（G05）。页面被覆盖或导航世代已变时只保存，不导航（共性第 47、51 条）
            if flow.visibility.showing(navTicket) {
                navigate(WalletRoutes.realName)
            } else {
                guideOwner = flow.owner
                state.guideRoute = WalletRoutes.realName
            }
        }
        serial += 1
        invalidateShown(error.notice(id: serial))
    }

    func ownsForm(_ owner: WalletOwner) -> Bool {
        !left && owner == flow.owner && deps.env.isCurrent(owner)
    }

    func navigate(_ route: String) {
        flow.visibility.navigated()
        deps.env.open(route, params: [:], from: page)
    }
}
