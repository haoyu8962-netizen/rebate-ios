import CouliNetwork
import Foundation

/// 提现记录页的一次状态快照。
public struct RecordsSnapshot: Equatable, Sendable {
    public enum Phase: Equatable, Sendable {
        case loading, content, empty, error
    }

    public var phase: Phase = .loading
    public var items: [Withdrawal] = []
    public var nextCursor: String?
    public var loadingMore = false
    public var moreError: Notice?
    public var expanded: Set<String> = []
    /// 按 withdrawal_id 定位到的那张单（列表置顶区，独立于月份分组；iOS R2-05）。
    public var pinnedId: String?
    /// 展开后取到的详情（带 channel_order_id）。
    public var details: [String: Withdrawal] = [:]
    public var error: Notice?
    public var refreshing = false
    public var toast: Notice?
    public var version = 0
    public var owner: WalletOwner
}

/// 提现记录执行器（WithdrawRecords 路由，`withdrawal_id?`；BR-TEXT-06、BR-WDR-25，G08、G27、G30）：
/// - 进入、下拉、回到本页各取一次，不轮询；翻页按 next_cursor；
/// - 带 withdrawal_id 打开时另取 GET /v1/withdrawals/{id}：成功把这张单放在列表最前并展开；30701 只显示列表，不提示；
/// - 展开一张单时取详情（交易流水号只在详情有），PAID_* 且 channel_order_id 非 null 才显示流水号与【复制】，复制只走统一写入口（G27）；
/// - 金额不受隐藏开关影响（G23）。
/// 请求绑定页面与固定身份；出栈后作废。只在主线程使用。
@MainActor
public final class WithdrawRecordsController: ObservableObject, IdentityResumable {
    static let listOperation = "listWithdrawals"
    static let detailOperation = "getWithdrawal"
    public static let pageSize = 20

    @Published public internal(set) var state: RecordsSnapshot
    let deps: WalletDeps
    let focusId: String?
    public var page: UUID?
    public let visibility = PageVisibility()
    var left = false
    var round = 0
    var serial = 0
    let requests = WalletRequests()
    /// 新一轮第一页还没回来（共性第 20、35 条）：期间禁止翻页与再次刷新，旧游标不得以新一轮的名义发出。
    public internal(set) var firstPagePending = false
    /// 因身份暂时未知中止、等身份确认后补做的读取（新一轮第一页与定位单、翻页、展开详情；FU-IOS-0712 整体重理：与钱包摘要、各资金页
    /// 同一套机制）。补做时路由定位参数（withdrawal_id）照旧带上。
    public let deferral = IdentityDeferral()
    static let roundSlot = "round"
    static let moreSlot = "more"

    /// 有因身份暂时未知中止、还没补取的读取。
    public var loadPending: Bool {
        deferral.isPending
    }

    /// 每张单最新一次详情请求的序号与请求编号（共性第 20、54 条）：同一 withdrawal_id 只收最新请求的响应。
    var detailCounter = 0
    var detailSeq: [String: Int] = [:]
    var detailRequests: [String: Int] = [:]
    /// 本轮已经接受的详情（共性第 34 条）：提交列表时保留它们，不被较早取得的列表覆盖；新一轮开始时清空。
    var roundDetails: [String: Withdrawal] = [:]
    /// 定位请求已被同单更新的详情请求取代、提交第一页时本轮还没有被接受的详情（iOS R3-01，共性第 81 条）：这张单的置顶 / 展开等最新请求
    /// 结算——成功才置顶并展开，失败只保留列表数据；新一轮开始时清空。
    var focusAwaiting: String?

    public init(deps: WalletDeps, focusId: String?) {
        self.deps = deps
        self.focusId = focusId
        state = RecordsSnapshot(owner: deps.env.currentOwner())
    }

    public var alive: Bool {
        !left
    }

    public var readGate: RetryAfterGate {
        deps.gates.read
    }

    /// 服务端校准后的当前时刻（申请时间「今天 / 昨天」，BR-TEXT-11）。
    public func displayNowMillis() -> Int64 {
        deps.env.displayNowMillis()
    }

    /// 新一轮（进入、下拉、回到本页）：第一页 + 带 withdrawal_id 时的那张单。
    public func load(refresh: Bool = false) {
        let owner = state.owner
        // 已确认没有会话的页面不读；身份暂时未知时构造的页面照常核对（结算为可重试，身份确认后由 App 换上身份）
        guard !left, owner.account != nil || !owner.identityKnown, admitRound(deps.env.check(owner)) else { return }
        if deps.gates.read.active {
            gated()
            return
        }
        round += 1
        let current = round
        requests.cancelAll()
        detailRequests = [:]
        roundDetails = [:]
        focusAwaiting = nil
        firstPagePending = true
        if state.items.isEmpty {
            state.phase = .loading
            state.error = nil
        } else {
            state.refreshing = refresh
            state.loadingMore = false
        }
        let probe = deps.gates.read.probe()
        let call = ApiCall(operationId: Self.listOperation, query: "limit=\(Self.pageSize)")
        requests.send(deps.api, call, probe: probe, expected: owner.request) { [weak self] result in
            guard let self, !left, round == current, admitRound(deps.env.check(owner)) else { return }
            // 每个请求回来先按身份结算限流等共享副作用，再决定是否发下一个（共性第 42 条）
            settleShared(result)
            listArrived(result, probe: probe, round: current, owner: owner)
        }
    }

    /// 第一页回来：成功且带定位单时先取定位详情（列表的共享副作用已结算、禁用期外才发），再一起提交。
    func listArrived(_ result: ApiResult, probe: SendProbe, round current: Int, owner: WalletOwner) {
        let listed: WithdrawalListData? = if case let .success(data, _, _) = result {
            WalletJSON.withdrawalList(WalletJSON.parse(data))
        } else {
            nil
        }
        guard let listed, let focusId, !deps.gates.read.active else {
            firstPagePending = false
            onFirstPage(result, listed: listed, focus: nil, probe: probe)
            return
        }
        // 定位读取与普通详情共用每单请求序号（共性第 54 条）：它也作废这张单更早的详情请求，自己也会被更新的取代
        detailCounter += 1
        let request = detailCounter
        detailSeq[focusId] = request
        if let old = detailRequests.removeValue(forKey: focusId) {
            requests.cancel(old)
        }
        let focusProbe = deps.gates.read.probe()
        let call = detailCall(focusId)
        requests.send(deps.api, call, probe: focusProbe, expected: owner.request) { [weak self] focused in
            guard let self, !left, round == current, admitRound(deps.env.check(owner)) else { return }
            settleShared(focused)
            firstPagePending = false
            onFirstPage(result, listed: listed, focus: FocusRead(id: focusId, request: request, result: focused),
                        probe: focusProbe)
        }
    }

    /// 身份确认之后（App 的会话核对，判据相同也调）：补做因身份暂时未知中止的一轮、翻页与详情（固定身份校验与禁用期照旧）。
    public func resumeAfterIdentityConfirmed() {
        guard !left else { return }
        deferral.resume()
    }

    /// 新一轮的身份核对（发送前、第一页与定位单响应时同一入口）：暂时未知 → 记待补取（身份确认后重开一轮）并结算；已换代 → 丢弃。
    func admitRound(_ check: IdentityCheck) -> Bool {
        deferral.admit(check, slot: Self.roundSlot, resume: { [weak self] in self?.load() }, settle: {
            identityAborted()
        })
    }

    /// 新一轮因身份暂时未知中止（RC-05）：结清在途标记（否则刷新、回前台都被拒）；没有列表时结算为可重试的失败态，已有旧列表保留显示。
    func identityAborted() {
        firstPagePending = false
        state.refreshing = false
        if state.items.isEmpty {
            state.phase = .error
            state.error = nil
            state.version += 1
        }
    }

    /// 本地限流拦下也结算（共性第 30、45、46、55 条）：没有列表的进错误态；已有旧列表的独立显示 42901 与【重试】。
    func gated() {
        serial += 1
        let message = Notice("error.42901", id: serial)
        if state.items.isEmpty {
            state.phase = .error
        }
        state.error = message
        state.refreshing = false
    }

    /// 读取结果的共享副作用（共性第 3、42 条）：42901 写入共享禁用期；10405 由网络层进强更。
    func settleShared(_ result: ApiResult) {
        let error = WalletErrors.of(result)
        if error.kind == .retryAfter {
            deps.gates.read.start(error.disableMillis)
        }
    }

    func detailCall(_ id: String) -> ApiCall {
        ApiCall(operationId: Self.detailOperation, pathParams: [WalletRoutes.withdrawalId: id])
    }

    func notice(_ key: String, assertive: Bool = true) -> Notice {
        serial += 1
        return Notice(key, id: serial, assertive: assertive)
    }
}

/// 一次定位读取：单号、它占用的每单请求序号与结果。
struct FocusRead {
    let id: String
    let request: Int
    let result: ApiResult
}
