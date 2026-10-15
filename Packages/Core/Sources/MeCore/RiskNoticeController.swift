import Combine
import CouliNetwork
import Foundation
import WalletCore

/// 进行中的一笔提现（G16、BR-ID-31 细则）：金额与提现记录页同一份显示结论（APP-09 `WithdrawalText.of`：状态标题 + 副文案，R2-03）。
/// 副文案在页面用 `WithdrawalText.render` 与统一金额格式化展示；SLA（manual / null 的 withdraw.sla_text）与提现记录页同源（Config texts）。
public struct PendingWithdrawalRow: Equatable, Sendable {
    public let id: String
    public let amountFen: Int64
    public let display: WithdrawalDisplay

    public init(id: String, amountFen: Int64, display: WithdrawalDisplay) {
        self.id = id
        self.amountFen = amountFen
        self.display = display
    }

    /// BR-TEXT-06 状态标题的文案键。
    public var titleKey: String {
        display.titleKey
    }
}

/// 封禁 / 冻结说明的页面状态。
public struct RiskState {
    public enum Phase: Equatable, Sendable {
        case loading, content, error
    }

    public var phase: Phase = .loading
    public var risk: [String: Any]?
    public var latestAppeal: [String: Any]?
    /// 最近一次申诉摘要读取失败（统一错误文案 + trace6 + 本区重试，R1-07）；失败时摘要已清空。
    public var appealsError: MeNotice?
    public var withdrawals: [PendingWithdrawalRow] = []
    public var withdrawalsError: MeNotice?
    public var error: MeNotice?
    /// 已有说明内容时的刷新失败（Android R2-04 / A34，共性第 31 条）：保留上次读到的内容，但明确标示「没有刷新」并给受共享截止时间控制的【重试】。
    public var refreshError: MeNotice?
    /// 退出确认框的一次性编号（R1-02）；nil = 没有显示。
    public var logoutDialog: Int?
    public var version = 0

    public init() {}
}

/// 封禁 / 冻结说明执行器（RiskNotice 路由；brief §2.10，§0 第 4 条；G08、G09、G10、G16、G30；BR-ID-31、BR-TEXT-23）：
/// - 进入即取 GET /v1/me，版式只按服务端 risk.state（`RiskNoticeView`）；不缓存封禁结论、不本地推算解冻或解封、不显示处理时限；
/// - 最近一次账户申诉维持且仍受限时附「最近一次申诉：维持原处理结果」（再取 listAppeals）；读取失败清掉摘要，显示统一错误、trace6 与本区【重试】；
/// - 进行中的提现只取 GET /v1/withdrawals 第一页的 PENDING_REVIEW、APPROVED、PAYING（读取失败只影响这一节，只重取提现，G16）；
/// - 三个读取共用 getMe 的读取闸门（共性第 22、33 条）：禁用期内不发（执行层 + 页面），各自的 42901 到达即按 Retry-After 启动禁用期；
/// - 读取失败：没有内容 → 错误态 + trace6 +【重试】；已有内容 → 保留并标示「没有刷新」（A34）；banned 场景下【退出登录】与联系客服始终可用。
/// 构造时固定身份与「本次运行是否因 10006 进入」；出栈在同步出口作废读请求（`leave`）；会话换代时整页由 App 移出导航栈。
@MainActor
public final class RiskNoticeController: ObservableObject {
    public static let route = "RiskNotice"
    public static let appeal = "Appeal"
    public static let home = "Home"
    public static let listAppeals = "listAppeals"
    public static let listWithdrawals = "listWithdrawals"
    /// 提现审核时限的配置键（与提现记录页 `AppWallet.configText` 同一来源：生效配置 texts 里的这一项）。
    public static let slaTextKey = "withdraw.sla_text"

    public let identity: MeIdentity
    public let deps: MeDeps
    public let page: UUID?
    /// 本次运行是否因 10006 进入（G10，进入时固定）。
    public let enteredBy10006: Bool
    @Published public private(set) var state = RiskState()
    private var left = false
    private var seq = 0
    private var appealSeq = 0
    private var withdrawalSeq = 0
    private var ids = 0
    private let requests = MeRequests()

    public init(deps: MeDeps, identity: MeIdentity, page: UUID?) {
        self.deps = deps
        self.identity = identity
        self.page = page
        enteredBy10006 = deps.env.enteredBy10006(identity)
    }

    public var alive: Bool {
        !left && deps.env.isCurrent(identity)
    }

    /// 提现状态标题与副文案的文案表（与提现记录页同一份 WalletTexts）。
    public let walletTexts: WalletTexts = WalletDraftTexts()

    /// 提现审核时限（Config texts 的 withdraw.sla_text，与提现记录页同源；没下发为 nil，由 WithdrawalText 回落 BR-TEXT-07 原文）。
    public func slaText() -> String? {
        (deps.env.configObject("texts") as? [String: Any])?[Self.slaTextKey] as? String
    }

    public var readGate: RetryAfterGate {
        deps.gates.read
    }

    public func model() -> RiskNoticeModel? {
        guard let risk = state.risk else { return nil }
        return RiskNoticeView.model(risk: risk, enteredBy10006: enteredBy10006, latestAccountAppeal: state.latestAppeal,
                                    nowMs: deps.env.displayNowMillis())
    }

    private func nextId() -> Int {
        ids += 1
        return ids
    }

    /// 进入、【重试】、回到本页（提交申诉后返回时重取，brief §2.11）。
    public func load() {
        guard alive, identity.member else { return }
        if readGate.active {
            refreshFailed(MeNotice(MeCodes.rateKey, id: nextId()))
            return
        }
        seq += 1
        let request = seq
        requests.cancelAll()
        if state.risk == nil {
            state.phase = .loading
            state.error = nil
        }
        let probe = readGate.probe()
        requests.send(deps.api, ApiCall(operationId: MeRepository.operation), probe: probe,
                      expected: identity.request) { [weak self] result in
            guard let self, current(request) else { return }
            meArrived(result, probe: probe, request: request)
        }
    }

    private func meArrived(_ result: ApiResult, probe: SendProbe, request: Int) {
        guard case let .success(data, traceId, _) = result else {
            if let notice = MeErrors.readFailure(result, probe: probe, gate: readGate, id: nextId) {
                refreshFailed(notice)
            }
            return
        }
        guard let me = MeJson.me(MeJson.object(data)) else {
            refreshFailed(MeNotice("error.50001", id: nextId(), traceId: traceId, showTrace6: true))
            return
        }
        var next = RiskState()
        next.phase = .content
        next.risk = me.risk
        next.logoutDialog = state.logoutDialog
        next.version = state.version + 1
        state = next
        if me.riskState != "normal" {
            loadAppeals(request)
            loadWithdrawals(request)
        }
    }

    private func current(_ request: Int) -> Bool {
        !left && seq == request && deps.env.isCurrent(identity)
    }

    /// 附加读取可以发：页面有效、已有非 normal 的说明内容。
    private var sectionsLive: Bool {
        alive && (state.risk?["state"] as? String).map { $0 != "normal" } == true
    }

    /// 申诉摘要区的【重试】：只重取申诉摘要。
    public func retryAppeals() {
        if sectionsLive {
            loadAppeals(seq)
        }
    }

    /// 提现区的【重试】：只重取提现（G16）。
    public func retryWithdrawals() {
        if sectionsLive {
            loadWithdrawals(seq)
        }
    }

    private func loadAppeals(_ request: Int) {
        appealSeq += 1
        let mine = appealSeq
        if readGate.active {
            state.latestAppeal = nil
            state.appealsError = MeNotice(MeCodes.rateKey, id: nextId())
            state.version += 1
            return
        }
        state.appealsError = nil
        let probe = readGate.probe()
        requests.send(deps.api, ApiCall(operationId: Self.listAppeals), probe: probe,
                      expected: identity.request) { [weak self] result in
            guard let self, current(request), appealSeq == mine else { return }
            if case let .success(data, _, _) = result, let list = MeJson.appealList(MeJson.object(data)) {
                state.latestAppeal = AppealView.latestAccount(list.items)
                state.appealsError = nil
                state.version += 1
                return
            }
            guard let notice = MeErrors.readFailure(result, probe: probe, gate: readGate, id: nextId) else { return }
            state.latestAppeal = nil
            state.appealsError = notice
            state.version += 1
        }
    }

    private func loadWithdrawals(_ request: Int) {
        withdrawalSeq += 1
        let mine = withdrawalSeq
        if readGate.active {
            state.withdrawals = []
            state.withdrawalsError = MeNotice(MeCodes.rateKey, id: nextId())
            state.version += 1
            return
        }
        state.withdrawalsError = nil
        let probe = readGate.probe()
        requests.send(deps.api, ApiCall(operationId: Self.listWithdrawals), probe: probe,
                      expected: identity.request) { [weak self] result in
            guard let self, current(request), withdrawalSeq == mine else { return }
            if case let .success(data, _, _) = result, let list = WalletJSON.withdrawalList(WalletJSON.parse(data)) {
                // 状态标题 + 副文案都保留（R2-03）：与提现记录页同一个 WithdrawalText.of、同一份 SLA 来源与文案表
                let sla = slaText()
                state.withdrawals = list.items.filter { PendingWithdrawals.statuses.contains($0.status) }.map {
                    PendingWithdrawalRow(id: $0.withdrawalId, amountFen: $0.amountFen,
                                         display: WithdrawalText.of($0, slaText: sla, texts: walletTexts))
                }
                state.withdrawalsError = nil
                state.version += 1
                return
            }
            guard let notice = MeErrors.readFailure(result, probe: probe, gate: readGate, id: nextId) else { return }
            state.withdrawals = []
            state.withdrawalsError = notice
            state.version += 1
        }
    }

    /// 读取失败：没有内容 → 错误态（统一错误 + trace6 +【重试】）；已有内容 → 保留内容并标示「没有刷新」+【重试】（A34）。
    private func refreshFailed(_ notice: MeNotice) {
        if state.risk == nil {
            var next = RiskState()
            next.phase = .error
            next.error = notice
            next.logoutDialog = state.logoutDialog
            next.version = state.version + 1
            state = next
        } else {
            state.refreshError = notice
            state.version += 1
        }
    }

    /// 主按钮（渲染时的版本）：【提交申诉】/【查看申诉进度】→ Appeal；normal 的【返回首页】→ Home。
    public func primary(version: Int) {
        guard alive, state.version == version, let model = model() else { return }
        switch model.primaryRaw {
        case RiskNoticeView.submit, RiskNoticeView.viewProgress:
            deps.env.open(Self.appeal, params: [:], from: page)
        case RiskNoticeView.backHome:
            deps.env.open(Self.home, params: [:], from: page)
        default:
            break
        }
    }

    public func contactCs() {
        guard alive else { return }
        deps.env.customerService(from: Self.route)
    }

    public func askLogout() {
        guard alive else { return }
        ids += 1
        state.logoutDialog = ids
    }

    /// 【取消】（同一编号才生效，R1-02）。
    public func cancelLogout(_ dialog: Int) {
        if state.logoutDialog == dialog {
            state.logoutDialog = nil
        }
    }

    /// 【退出登录】确认（确认框生成时的编号）：只认正显示的这一个，用过即作废；再核对身份与页面（R1-02）。
    public func confirmLogout(_ dialog: Int) {
        guard state.logoutDialog == dialog else { return }
        state.logoutDialog = nil
        guard alive else { return }
        deps.env.logout(identity, from: page)
    }

    /// 出栈的同步出口：作废并取消读请求，清掉已显示的内容。
    public func leave() {
        guard !left else { return }
        left = true
        seq += 1
        requests.cancelAll()
        state = RiskState()
    }

    public var hasLeft: Bool {
        left
    }
}
