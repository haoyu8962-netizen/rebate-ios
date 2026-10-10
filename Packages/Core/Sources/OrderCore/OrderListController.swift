import Combine
import CouliNetwork
import Foundation

/// 订单列表的阶段。
public enum OrderListPhase: String, Sendable {
    case idle
    case loading
    case content
    case empty
    case error
    /// 传输失败、显示默认视图的缓存（OrdersStale）。
    case stale
}

/// 订单列表的状态（执行器每次变化都整体发布）。
public struct OrderListSnapshot: Equatable {
    public var query: OrderQuery
    /// 搜索框里的文字（提交前不发请求，G11；最多 40 个 Unicode 码点）。
    public var searchText = ""
    public var phase: OrderListPhase = .idle
    public var items: [OrderSummary] = []
    public var nextCursor: String?
    public var earliestVisibleDate: String?
    public var loadingMore = false
    /// 翻页失败（保留已有结果；底部错误文案 + trace6 +【重试】）。
    public var pageError: OrderErrorView?
    /// 整页错误（无结果时）。
    public var error: OrderErrorView?
    /// 缓存的成功获取时刻（phase = stale 时）。
    public var staleAt: Int64?
    /// 下拉刷新在途（保留已有结果）。
    public var refreshing = false
    /// 共享 42901 禁用期中：刷新、翻页、筛选、搜索提交、【重试】都不可用。
    public var blocked = false
    public var toast: OrderToast?

    public init(query: OrderQuery) {
        self.query = query
    }

    /// 还能再翻一页。
    public var canLoadMore: Bool {
        phase == .content && nextCursor != nil && !loadingMore && pageError == nil && !blocked && !refreshing
    }

    /// 已到底（翻完）。
    public var endReached: Bool {
        phase == .content && nextCursor == nil
    }
}

/// 订单列表执行器要的环境（App 给）。
@MainActor
public protocol OrderListEnv: OrderOwnerSource {
    /// 当前时刻（毫秒；缓存的获取时刻）。
    func now() -> Int64
}

/// 订单列表执行器（OrderList 路由，订单 Tab 根；APP-08）。一个会话一份（App 持有；被详情盖住、切到别的 Tab 都保留筛选、搜索词与结果）。
/// - 请求归属：会话（会话换代时 App 换一份新的，旧的 leave）+ 查询轮次（每次筛选、切子 Tab、搜索、下拉刷新、重试开新一轮，旧轮次的响应含
///   翻页一律丢弃，APP-06a 第 33 条）+ 页面没离开；
/// - 共享 42901 禁用期（`gate`）：用户入口与执行层（发送前闸门）两处拦；
/// - 下拉刷新开新轮次时同步清掉旧轮次的 loadingMore；刷新失败保留旧列表与原游标（还能继续翻页），轻提示带 trace6（共性第 7、8 条）；
/// - 断网缓存（G10）：只有传输失败且是默认视图的第一页才显示缓存（stale，不能翻页）；默认视图第一页成功时更新缓存；
/// - 详情返回只替换那一行（G17）。
@MainActor
public final class OrderListController: ObservableObject {
    public static let operation = "listOrders"

    @Published public internal(set) var snapshot: OrderListSnapshot
    public let gate: OrderRateGate
    let api: OrderApi
    weak var env: OrderListEnv?
    let cache: OrderCacheStore?
    let requests = OrderInFlight()
    var left = false
    var toastSeq = 0
    private var subscriptions: Set<AnyCancellable> = []
    /// 固定身份（构造时一次性取得，APP-09 共性第 65 条）：结果、【复制】票据、缓存读写、恢复记录保存都只用它；之后只与当前会话比较。
    public let owner: OrderOwner

    public init(api: OrderApi, gate: OrderRateGate, env: OrderListEnv, cache: OrderCacheStore?, scope: String? = nil) {
        self.api = api
        self.gate = gate
        self.env = env
        self.cache = cache
        owner = env.currentOwner()
        snapshot = OrderListSnapshot(query: .initial(scope))
        snapshot.blocked = gate.blocked
        gate.$blocked.dropFirst().sink { [weak self] blocked in
            MainActor.assumeIsolated {
                guard let self, !self.left else { return }
                self.snapshot.blocked = blocked
            }
        }.store(in: &subscriptions)
    }

    public var inFlight: Int {
        requests.count
    }

    public var isLeft: Bool {
        left
    }

    /// 固定身份仍是当前会话（只比较，不重新绑定）。会话已换代而 App 还没换掉这一份时：不发请求、不结算、不读写缓存。
    public var ownerCurrent: Bool {
        guard let env else { return false }
        return env.isCurrent(owner)
    }

    /// 页面出现：还没加载过就加载第一页。
    public func start() {
        guard !left, ownerCurrent, snapshot.phase == .idle else { return }
        load(keepItems: false)
    }

    /// 恢复保存的条件（进程回收后；只在还没加载过时生效）。
    public func restore(_ conditions: OrderConditions) {
        guard !left, snapshot.phase == .idle else { return }
        snapshot.query = .restore(conditions)
        snapshot.searchText = snapshot.query.keyword ?? ""
    }

    /// 路由参数 scope=share 直接进分享子 Tab（与当前不同时才切）。
    public func openScope(_ scope: String?) {
        guard let scope, OrderQuery.normalizeScope(scope) != snapshot.query.scope else { return }
        setScope(scope)
    }

    // MARK: - 条件（42901 禁用期内一律不改，返回 false）

    @discardableResult
    public func setScope(_ scope: String) -> Bool {
        change { $0.setScope(scope) }
    }

    @discardableResult
    public func setGroup(_ group: String) -> Bool {
        change { $0.setGroup(group) }
    }

    @discardableResult
    public func setPlatform(_ platform: String?) -> Bool {
        change { $0.setPlatform(platform) }
    }

    @discardableResult
    public func setMonth(_ month: String?) -> Bool {
        change { $0.setMonth(month) }
    }

    /// 搜索框输入（只改文字，不发请求；超过 40 个码点截掉）。
    public func updateSearchText(_ text: String) {
        let limited = OrderQuery.limit(text)
        guard limited != snapshot.searchText else { return }
        snapshot.searchText = limited
    }

    /// 键盘「搜索」：按规整后的搜索词开新一轮（与当前相同也重新查）。
    @discardableResult
    public func submitSearch() -> Bool {
        let text = snapshot.searchText
        return change { $0.setQ(text) }
    }

    /// 清空搜索框：有搜索词时开新一轮。
    @discardableResult
    public func clearSearch() -> Bool {
        guard !gate.active, !left else { return false }
        snapshot.searchText = ""
        guard snapshot.query.keyword != nil else { return true }
        return change { $0.setQ(nil) }
    }

    private func change(_ mutate: (inout OrderQuery) -> Void) -> Bool {
        guard !gate.active, !left, ownerCurrent else { return false }
        let before = snapshot.query
        var query = before
        mutate(&query)
        snapshot.query = query
        if query.scope != before.scope {
            // 切子 Tab：搜索框一并清空（BR-TEXT-02 细则）
            snapshot.searchText = ""
        } else if query.keyword != before.keyword || query.keyword != nil {
            snapshot.searchText = query.keyword ?? ""
        }
        load(keepItems: false)
        return true
    }

    // MARK: - 刷新、重试、翻页

    /// 下拉刷新：新一轮第一页，保留已有结果直到新结果回来。返回是否发出。
    @discardableResult
    public func refresh() -> Bool {
        guard !gate.active, !left, ownerCurrent else { return false }
        snapshot.query.newRound()
        let keep = !snapshot.items.isEmpty && [.content, .stale].contains(snapshot.phase)
        load(keepItems: keep)
        return true
    }

    /// `.refreshable` 用：发出后只等**本次**查询轮次结束（共性第 30 条）。页面离开 / 会话换代 / 被新一轮取代 / 刷新任务被取消都立即返回，
    /// 不依赖已被取消的响应；`Task.sleep` 的取消错误不吞掉。
    public func refreshAndWait() async {
        guard refresh() else { return }
        let round = snapshot.query.round
        while waitingRefresh(round) {
            do {
                try await Task.sleep(nanoseconds: 50_000_000)
            } catch {
                return
            }
        }
    }

    /// 本轮刷新是否还值得等。
    func waitingRefresh(_ round: Int) -> Bool {
        !Task.isCancelled && !left && snapshot.query.round == round
            && (snapshot.refreshing || snapshot.phase == .loading)
    }

    /// 整页错误的【重试】。
    @discardableResult
    public func retry() -> Bool {
        guard !gate.active, !left, ownerCurrent else { return false }
        snapshot.query.newRound()
        load(keepItems: false)
        return true
    }

    private func load(keepItems: Bool) {
        requests.cancelAll()
        let query = snapshot.query
        let round = query.round
        // 新轮次：清掉旧轮次的翻页状态（共性第 7 条）
        snapshot.loadingMore = false
        snapshot.pageError = nil
        snapshot.toast = nil
        if keepItems {
            snapshot.refreshing = true
        } else {
            snapshot.refreshing = false
            snapshot.items = []
            snapshot.nextCursor = nil
            snapshot.earliestVisibleDate = nil
            snapshot.error = nil
            snapshot.staleAt = nil
            snapshot.phase = .loading
        }
        // 禁用期内不发（执行层；页面显示 error.42901、【重试】置灰）
        if gate.active {
            settleFirst(.localReject(reason: LocalRejectReason.sendBlocked), query: query, keepItems: keepItems)
            return
        }
        let call = ApiCall(operationId: Self.operation, query: query.queryString())
        requests.send(api, call, gate: gate, owner: owner) { [weak self] result in
            // 结算时固定身份已不是当前会话（响应可能按新会话取得）：丢弃，不绑定进这一份
            guard let self, !left, ownerCurrent, snapshot.query.round == round else { return }
            settleFirst(result, query: query, keepItems: keepItems)
        }
    }

    private func settleFirst(_ result: ApiResult, query: OrderQuery, keepItems: Bool) {
        snapshot.refreshing = false
        if case let .success(data, traceId, _) = result {
            guard let page = OrderJSON.listData(JSONPick.parse(data)) else {
                failFirst(OrderErrorView(actionRaw: OrderErrorKind.errorTrace6, textKey: "error.50001",
                                         showTrace6: true, traceId: traceId), keepItems: keepItems)
                return
            }
            snapshot.items = page.items
            snapshot.nextCursor = page.nextCursor
            snapshot.earliestVisibleDate = page.earliestVisibleDate
            snapshot.error = nil
            snapshot.staleAt = nil
            snapshot.phase = page.items.isEmpty ? .empty : .content
            if OrderStaleCache.isCacheable(OrderStaleCache.kindList, query.params()), let env, ownerCurrent {
                cache?.writeList(account: owner.account, scope: query.scope, data: page, fetchedAt: env.now())
            }
            return
        }
        if case let .localReject(reason) = result {
            if reason == LocalRejectReason.sendBlocked {
                let view = OrderErrorView(
                    actionRaw: OrderErrorKind.retryAfter, textKey: "error.42901", disableMs: gate.remainingMillis
                )
                failFirst(view, keepItems: keepItems)
            } else if reason != LocalRejectReason.callCancelled {
                failFirst(OrderErrorAction.view(
                    target: OrderErrorAction.listFirst, result: result, hasCache: false, filtered: true
                ), keepItems: keepItems)
            }
            return
        }
        let cached = query.isDefaultView && ownerCurrent ? cache?
            .readList(account: owner.account, scope: query.scope) : nil
        let view = OrderErrorAction.view(
            target: OrderErrorAction.listFirst, result: result, hasCache: cached != nil, filtered: query.filtered
        )
        if view.actionRaw == OrderErrorKind.retryAfter {
            gate.start(view.disableMs ?? ErrorActionMapper.defaultRetryAfterMillis)
        }
        if view.actionRaw == OrderErrorKind.showStale, let cached {
            showStale(cached, keepItems: keepItems)
            return
        }
        failFirst(view, keepItems: keepItems)
    }

    private func showStale(_ cached: CachedOrderList, keepItems: Bool) {
        if keepItems, snapshot.phase == .content {
            // 已有本轮之前的新鲜结果：保留并轻提示，不用更旧的缓存覆盖
            toast(OrderErrorView(actionRaw: OrderErrorKind.networkError, textKey: OrderErrorAction.networkKey))
            return
        }
        snapshot.items = cached.data.items
        snapshot.nextCursor = nil
        snapshot.earliestVisibleDate = cached.data.earliestVisibleDate
        snapshot.staleAt = cached.fetchedAt
        snapshot.error = nil
        snapshot.phase = .stale
    }

    private func failFirst(_ view: OrderErrorView, keepItems: Bool) {
        snapshot.refreshing = false
        if keepItems, !snapshot.items.isEmpty {
            // 刷新失败：保留旧列表与原游标（还能继续翻页），轻提示经统一的错误消息（带 trace6）
            toast(view)
            return
        }
        snapshot.items = []
        snapshot.nextCursor = nil
        snapshot.error = view
        snapshot.phase = .error
    }

    /// 离开（会话换代时整份换掉；同步出口作废并取消在途请求）。
    public func leave() {
        guard !left else { return }
        left = true
        requests.cancelAll()
        // 同步结束刷新与翻页状态：等待方不再依赖已被取消的响应（共性第 30 条）
        snapshot.refreshing = false
        snapshot.loadingMore = false
        subscriptions.removeAll()
    }
}
