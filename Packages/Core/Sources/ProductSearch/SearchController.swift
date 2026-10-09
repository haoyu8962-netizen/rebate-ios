import Combine
import CouliNetwork
import Foundation
import Generated

/// 搜索页的阶段。
public enum SearchPhase: String, Sendable {
    /// 还没搜（输入态 SearchTyping）。
    case idle
    case loading
    case content
    case empty
    case error
    /// 没有 search_status=on 的平台（不发请求，BR-PROD-10 细则）。
    case unavailable
}

/// 搜索页的状态（执行器每次变化都整体发布）。
public struct SearchSnapshot {
    public var keyword = ""
    public var platform: String?
    public var tabs: [String] = []
    public var sort = "relevance"
    public var hasCoupon = false
    public var priceMinFen: Int64?
    public var priceMaxFen: Int64?
    public var phase: SearchPhase = .idle
    public var items: [[String: Any]] = []
    public var fallbackItems: [[String: Any]] = []
    public var endReached = true
    public var loadingMore = false
    /// 翻页失败（保留已展示结果；底部先显示错误文案与 trace6，再给【重试】，共性 9）。
    public var loadMoreError: SearchResultView?
    public var error: SearchResultView?
    /// 当前展示的结果来自哪个请求序号（测试核对迟到响应）。
    public var shownSeq: Int64?
    /// 50304 search_disabled 的提示（平台已移除、已回落；不带重试，共性 2、7）。用户下一次主动换条件时清除。
    public var notice: SearchResultView?
    /// 结果里有缓存降级的报价（stale=true 或 age_sec > 300）：结果顶部提示价格可能已变化（共性 3）。
    public var stale = false
    /// 42901 限时禁用中：搜索、换条件、翻页、重试入口都不可用，到期恢复（共性 4、11）。
    public var blocked = false
    /// 第几轮新查询（首屏请求开始时 +1；翻页不变）。页面只在它变化时回到列表顶部（共性 17）。
    public var queryRound = 0

    public init() {}

    public var loadMoreFailed: Bool {
        loadMoreError != nil
    }

    /// 当前的查询条件（页面持久化用，共性 20）。
    public var conditions: SearchConditions {
        SearchConditions(
            keyword: keyword, platform: platform, sort: sort, hasCoupon: hasCoupon,
            priceMinFen: priceMinFen, priceMaxFen: priceMaxFen
        )
    }
}

/// 搜索页的查询条件（关键词、平台、排序、筛选）。进程被系统回收后从页面的持久化状态恢复（共性 20）。
public struct SearchConditions: Codable, Equatable, Sendable {
    public var keyword: String
    public var platform: String?
    public var sort: String
    public var hasCoupon: Bool
    public var priceMinFen: Int64?
    public var priceMaxFen: Int64?

    public init(
        keyword: String = "", platform: String? = nil, sort: String = "relevance", hasCoupon: Bool = false,
        priceMinFen: Int64? = nil, priceMaxFen: Int64? = nil
    ) {
        self.keyword = keyword
        self.platform = platform
        self.sort = sort
        self.hasCoupon = hasCoupon
        self.priceMinFen = priceMinFen
        self.priceMaxFen = priceMaxFen
    }
}

/// 搜索页执行器（APP-06a）。请求归属与页面世代（lessons：APP-05a 共性 1、9，APP-04 共性 22、47）：
/// - 每个请求 begin 一个序号，归属 = 「序号仍是当前、页面没离开」，交给 ApiClient（`send(_:isValid:)`）；
/// - 换关键词、换 Tab、换排序、换筛选、翻页、离开页面时，先让旧序号失效，再作废并取消旧请求的传输；
/// - 响应到达（await 之后）再经 SearchSession.accept 复核，旧响应只丢弃，不改界面；
/// - 42901 限流统一在发送入口检查（共性 11）：用户入口直接拒绝；配置变化触发的回落搜索照样取消旧请求、更新 Tab，
///   但等限流结束才发；
/// - search_disabled 不自动循环（共性 18）：同一轮自动回落不再选刚返回 search_disabled 的平台，下一次由用户触发。
@MainActor
public final class SearchController: ObservableObject {
    @Published public internal(set) var snapshot = SearchSnapshot()

    let api: SearchApi
    let config: SearchConfigSource?
    let staticLayers: (() -> [String: Any])?
    var session = SearchSession()
    let block: RetryBlock
    var pager = SearchPager()
    let requests = InFlightRequests()
    /// 购买结果写回后的权威卡重取（APP-06b）：与搜索请求分开作废，离开页面时一并取消。
    let patchRequests = InFlightRequests()
    var patchSeq: Int64 = 0
    var left = false
    var observation: SearchObservation?
    /// 本页收到 search_disabled 的平台 → 收到时配置拉取的分界（issuedFetchId）。只有分界之后发出并被服务端确认的配置
    /// （appliedFetchId > 分界）里该平台明确为 on 时才恢复（共性 8、10）；之前或同一次在途拉取的旧配置不能提前恢复。
    var disabled: [String: UInt64] = [:]
    /// 本轮自动回落里返回过 search_disabled 的平台（共性 18）：自动选 Tab 时跳过，用户下一次主动操作时清空。
    var roundDisabled: Set<String> = []
    /// 限流期间被推迟的自动回落搜索（共性 11）：限流结束后发出。
    var deferredAutoRun = false
    /// 恢复页面（共性 20）时要加载到的条数（滚动锚点所在的卡片要在列表里）：不够且还有下一页时自动翻页。
    /// 用户任何主动操作、翻页失败、到底时清除。
    var restoreTarget: Int?

    /// - config：生产为 AppConfig；nil 时用 `layers`（测试）。
    public init(
        api: SearchApi,
        config: SearchConfigSource?,
        layers: (() -> [String: Any])? = nil,
        clock: @escaping () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }
    ) {
        self.api = api
        self.config = config
        staticLayers = layers
        block = RetryBlock(clock: clock)
    }

    public var blocked: Bool {
        block.active
    }

    /// 在途请求个数（测试核对取消）。
    public var inFlightCount: Int {
        requests.count
    }

    /// 页面打开：按路由参数 q、platform（routes.json Search）。有 q 时直接搜。只在第一次生效。
    /// 没有可搜索的平台时立即进入「无可搜索平台」（共性 26），不必等用户点搜索。
    public func open(query: String?, platform: String?) {
        guard observation == nil, !left else { return }
        refreshTabs(wanted: platform)
        observeConfig()
        if let query, !SearchQuery.normalizeKeyword(query).isEmpty {
            _ = submit(query)
        } else {
            settleWithoutKeyword()
            publish()
        }
    }

    /// 进程被系统回收后重建页面（共性 20）：先恢复条件（排序、筛选、平台；平台已不可搜时按可用平台回落），再按条件加载
    /// 结果；`minimumItems` 是滚动锚点需要的条数，第一页不够时自动翻页直到够数或到底。只在第一次生效（与 `open` 互斥）。
    public func restore(_ conditions: SearchConditions, minimumItems: Int = 0) {
        guard observation == nil, !left else { return }
        if Sort.allCases.contains(where: { $0.rawValue == conditions.sort }) {
            snapshot.sort = conditions.sort
        }
        if Self.filtersValid(
            hasCoupon: conditions.hasCoupon, minFen: conditions.priceMinFen, maxFen: conditions.priceMaxFen
        ) {
            snapshot.hasCoupon = conditions.hasCoupon
            snapshot.priceMinFen = conditions.priceMinFen
            snapshot.priceMaxFen = conditions.priceMaxFen
        }
        refreshTabs(wanted: conditions.platform)
        observeConfig()
        let keyword = SearchQuery.normalizeKeyword(conditions.keyword)
        snapshot.keyword = keyword
        if keyword.isEmpty || !run(auto: false) {
            snapshot.keyword = ""
            settleWithoutKeyword()
        } else if minimumItems > 0, snapshot.platform != nil {
            restoreTarget = minimumItems
        }
        publish()
    }

    private func observeConfig() {
        if let config {
            observation = config.observeSearchConfig { [weak self] in self?.configChanged() }
        }
    }

    /// 还没有关键词时的阶段：没有可搜索的平台 → unavailable（作废在途请求）；有 → 输入态（共性 19、26）。
    func settleWithoutKeyword() {
        if snapshot.platform == nil {
            _ = beginRequest("config")
            resetResults(phase: .unavailable)
        } else if snapshot.phase == .unavailable || snapshot.phase == .idle {
            resetResults(phase: .idle)
        }
    }

    /// 输入框【搜索】：关键词不合法（空、超长）、限流中返回 false，不发请求。
    @discardableResult
    public func submit(_ keyword: String) -> Bool {
        guard !block.active, !left else { return false }
        userAction()
        let normalized = SearchQuery.normalizeKeyword(keyword)
        refreshTabs(wanted: snapshot.platform)
        let previous = snapshot.keyword
        snapshot.keyword = normalized
        guard run(auto: false) else {
            snapshot.keyword = previous
            publish()
            return false
        }
        snapshot.notice = nil
        publish()
        return true
    }

    /// 换 Tab；限流中、Tab 不可用、已选中时返回 false。
    @discardableResult
    public func selectTab(_ platform: String) -> Bool {
        guard !block.active, snapshot.tabs.contains(platform), platform != snapshot.platform else { return false }
        userAction()
        snapshot.platform = platform
        snapshot.notice = nil
        rerun()
        return true
    }

    @discardableResult
    public func selectSort(_ sort: String) -> Bool {
        guard !block.active, sort != snapshot.sort, Sort.allCases.contains(where: { $0.rawValue == sort }) else {
            return false
        }
        userAction()
        snapshot.sort = sort
        snapshot.notice = nil
        rerun()
        return true
    }

    /// 只看有券、价格区间（整数分，nil 为不限）。区间不合法（BR-PRICE-15）返回 false，不改筛选。
    @discardableResult
    public func setFilters(hasCoupon: Bool, minFen: Int64?, maxFen: Int64?) -> Bool {
        guard !block.active, Self.filtersValid(hasCoupon: hasCoupon, minFen: minFen, maxFen: maxFen) else {
            return false
        }
        userAction()
        snapshot.hasCoupon = hasCoupon
        snapshot.priceMinFen = minFen
        snapshot.priceMaxFen = maxFen
        snapshot.notice = nil
        rerun()
        return true
    }

    /// 价格区间是否合法（与 SearchQuery.build 同一规则）。
    public static func filtersValid(hasCoupon: Bool, minFen: Int64?, maxFen: Int64?) -> Bool {
        SearchQuery.build([
            "keyword": "x", "platform": SearchTabs.candidates[0],
            "filters": filterObject(hasCoupon: hasCoupon, minFen: minFen, maxFen: maxFen),
        ]).valid
    }

    /// 【重试】：限流中不发请求（返回 false）。
    @discardableResult
    public func retry() -> Bool {
        guard !block.active else { return false }
        if snapshot.phase == .error {
            userAction()
            let started = run(auto: false)
            publish()
            return started
        }
        if snapshot.loadMoreFailed {
            return loadMore()
        }
        return false
    }

    /// 加载更多：已到底、正在加载、没有结果页、限流中时不做（返回 false）。
    @discardableResult
    public func loadMore() -> Bool {
        guard !left, !block.active, !snapshot.endReached, !snapshot.loadingMore,
              let cursor = pager.nextCursor, snapshot.phase == .content || snapshot.phase == .empty,
              let platform = snapshot.platform
        else { return false }
        let query = SearchQuery.build(input(cursor: cursor))
        guard let text = query.queryString else { return false }
        let seq = beginRequest("loadMore")
        snapshot.loadingMore = true
        snapshot.loadMoreError = nil
        publish()
        requests.send(api, ApiCall(operationId: "searchProducts", query: text), seq: seq) { [weak self] result in
            self?.loadMoreSettled(result, seq: seq, platform: platform)
        }
        return true
    }

    /// 页面真正出栈（Router 的导航栈里已没有这一页）：作废当前请求并取消传输；之后迟到的响应一律丢弃。
    public func leave() {
        left = true
        restoreTarget = nil
        session.leave()
        requests.cancelAll()
        patchRequests.cancelAll()
        block.cancelTimer()
        deferredAutoRun = false
        observation?.cancel()
        observation = nil
    }

    /// 用购买结果更新列表里的那张卡（APP-06b，BR-PRICE-12：只换这一张；结果与推荐卡都找）。按 product_key 认卡（换了 link_id 也认得出）。
    public func updateItem(productKey: String, _ transform: ([String: Any]) -> [String: Any]) {
        guard !left, !productKey.isEmpty else { return }
        var changed = false
        func patch(_ items: inout [[String: Any]]) {
            for index in items.indices where items[index]["product_key"] as? String == productKey {
                items[index] = transform(items[index])
                changed = true
            }
        }
        patch(&snapshot.items)
        patch(&snapshot.fallbackItems)
        if changed {
            publish()
        }
    }

    /// 按这张卡的 product_key + item_ref 重取权威商品卡（APP-06b 共性第 7、9、17、26 条），到达时只替换这一张（`merge` 决定怎么落）。
    /// 离开页面、失败时什么都不做。
    public func refetchItem(
        productKey: String,
        itemRef: String?,
        merge: @escaping ([String: Any], [String: Any]) -> [String: Any]
    ) {
        guard !left, !productKey.isEmpty else { return }
        patchSeq += 1
        let query = itemRef.map { "item_ref=" + SearchQuery.encode($0) }
        let call = ApiCall(operationId: "getProduct", pathParams: ["product_key": productKey], query: query)
        patchRequests.send(api, call, seq: patchSeq) { [weak self] result in
            guard let self, !left, case let .success(data, _, _) = result, let fresh = JSON.parse(data) else { return }
            updateItem(productKey: productKey) { merge($0, fresh) }
        }
    }

    /// 配置变化（ConfigStore 订阅，含 304 确认）：重算 Tab。当前平台不再可搜时，作废并取消属于它的在途请求（搜索与翻页），
    /// 按可用平台回落；有关键词就在回落平台上重搜（限流中推迟到限流结束，共性 11）。当前平台仍可用时只更新 Tab。
    /// 没有关键词时（输入态）同样立即按可用平台更新阶段：全部关闭 → 无可搜索平台；恢复 → 回到输入态（共性 26）。
    /// 限流只挡发送，不挡状态更新（共性 19）。
    public func configChanged() {
        guard !left else { return }
        let before = snapshot.platform
        let beforeTabs = snapshot.tabs
        refreshTabs(wanted: before)
        if snapshot.platform == before {
            if snapshot.tabs != beforeTabs {
                publish()
            }
            return
        }
        if snapshot.keyword.isEmpty {
            _ = beginRequest("config")
            settleWithoutKeyword()
            publish()
            return
        }
        _ = run(auto: true)
        publish()
    }
}
