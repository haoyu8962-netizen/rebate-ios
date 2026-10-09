import CouliNetwork
import Foundation

/// SearchController 的请求与结算（拆出来的内部实现）。
extension SearchController {
    /// 用户主动操作（搜索、换 Tab / 排序 / 筛选、重试）：开始新的一轮，清掉自动回落的排除与推迟（共性 18）。
    func userAction() {
        roundDisabled = []
        deferredAutoRun = false
        restoreTarget = nil
    }

    func loadMoreSettled(_ result: ApiResult, seq: Int64, platform: String) {
        guard !left, session.accept(seq) else { return }
        snapshot.loadingMore = false
        let envelope = SearchResults.envelope(result)
        if envelope != nil, Self.isSearchDisabled(result) {
            // 共性 7：与首屏同一处理——刷新配置、隐藏该平台、作废其请求、回落；不给重试。
            searchDisabled(SearchResultState.map(envelope ?? [:]), requested: platform)
            return
        }
        guard case .success = result, let envelope else {
            // TODO(N-27)：翻页失败的保留 / 重试策略未规定：保留已展示的结果；底部先给错误文案（带 trace6），再给【重试】。
            let view = envelope.map(SearchResultState.map) ?? SearchResults.transportError(result)
            snapshot.loadMoreError = SearchResultView(
                stateRaw: SearchStateRaw.error, textKey: view.textKey, code: view.code,
                platform: view.platform ?? platform, traceId: view.traceId
            )
            restoreTarget = nil
            startBlock(result)
            publish()
            return
        }
        pager.append(envelope)
        applyPager(seq)
    }

    func firstPageSettled(_ result: ApiResult, seq: Int64, platform: String) {
        guard !left, session.accept(seq) else { return }
        let envelope = SearchResults.envelope(result)
        let view = envelope.map(SearchResultState.map) ?? SearchResults.transportError(result)
        if envelope != nil, Self.isSearchDisabled(result) {
            searchDisabled(view, requested: platform)
            return
        }
        guard case .success = result, let envelope else {
            snapshot.phase = .error
            snapshot.error = view
            snapshot.shownSeq = seq
            startBlock(result)
            publish()
            return
        }
        pager.append(envelope)
        applyPager(seq)
    }

    static func isSearchDisabled(_ result: ApiResult) -> Bool {
        guard case let .failure(code, _, data, _, _, _) = result, code == 50304 else { return false }
        return JSON.string(JSON.parse(data)?["reason"]) == "search_disabled"
    }

    var currentLayers: [String: Any] {
        config?.searchStatusLayers() ?? staticLayers?() ?? [:]
    }

    /// 重算 Tab 与选中平台。自动选择（想要的平台不可用时）跳过本轮返回过 search_disabled 的平台（共性 18）。
    func refreshTabs(wanted: String?) {
        restoreReopened()
        snapshot.tabs = SearchTabs.resolve(currentLayers).filter { disabled[$0] == nil }
        if let wanted, snapshot.tabs.contains(wanted) {
            snapshot.platform = wanted
        } else {
            snapshot.platform = snapshot.tabs.first { !roundDisabled.contains($0) }
        }
    }

    /// 共性 8、10：因 search_disabled 隐藏的平台，在分界之后被服务端确认（200 或 304）的配置里明确为 on 时恢复。
    /// 分界之前或同一次在途拉取的配置、取值不是 on（off、缺省、未知值）都继续隐藏。没有配置源时不恢复。
    func restoreReopened() {
        guard let config, !disabled.isEmpty else { return }
        let applied = config.appliedFetchId
        let confirmed = config.confirmedSearchStatus ?? [:]
        for (platform, mark) in disabled where applied > mark && (confirmed[platform] as? String) == "on" {
            disabled[platform] = nil
        }
    }

    /// 42901：按 ErrorEffect.disableMillis 禁用，到期恢复并通知页面；期间推迟的自动回落在到期后发出（共性 11）。
    func startBlock(_ result: ApiResult) {
        let millis = SearchResults.disableMillis(result)
        guard millis > 0 else { return }
        snapshot.blocked = true
        block.start(millis) { [weak self] in
            guard let self, !left else { return }
            snapshot.blocked = false
            if deferredAutoRun {
                deferredAutoRun = false
                _ = run(auto: true)
            }
            publish()
        }
    }

    /// 50304 + search_disabled（error-codes：不显示重试，刷新配置并隐藏该平台 Tab；BR-PROD-10）：本页移除该平台、请求
    /// 配置刷新、按可用平台回落；有回落平台就在那里重搜（本轮不再自动选它，共性 18），没有就进入「无可搜索平台」。
    /// 提示保留到用户下一次换条件。TODO(APP-07)：提示里「粘贴商品链接查返利」的入口随剪贴板识别接入。
    func searchDisabled(_ view: SearchResultView, requested: String) {
        let platform = view.platform ?? requested
        roundDisabled.insert(platform)
        if let config {
            // 分界在刷新之前取：之后发出的拉取编号都大于它（重复收到时以最新的分界为准）。
            disabled[platform] = config.issuedFetchId
            config.requestFresh()
        } else {
            disabled[platform] = UInt64.max
        }
        snapshot.notice = SearchResultView(
            stateRaw: view.stateRaw, textKey: view.textKey, code: view.code, platform: platform, traceId: view.traceId
        )
        refreshTabs(wanted: nil)
        _ = run(auto: true)
        publish()
    }

    /// 已有关键词时按当前条件重搜；还没搜过只记下条件。
    func rerun() {
        if !snapshot.keyword.isEmpty {
            _ = run(auto: false)
        }
        publish()
    }

    /// 搜第一页。条件不合法返回 false（不发请求、不改界面）。发送入口统一检查限流（共性 11）：用户操作在入口已拒绝；
    /// 自动回落在限流中只作废旧请求、显示加载态，等限流结束再发。
    func run(auto: Bool) -> Bool {
        guard !left, auto || !block.active else { return false }
        guard let platform = snapshot.platform else {
            // 没有可搜索的平台：不发请求；旧请求照样作废。
            _ = beginRequest("search")
            resetResults(phase: .unavailable)
            return true
        }
        let query = SearchQuery.build(input(cursor: nil))
        guard let text = query.queryString else { return false }
        let seq = beginRequest("search")
        pager = SearchPager()
        snapshot.queryRound += 1
        // TODO(N-27)：begin 时是否清除已展示的旧结果未规定；这里清掉并显示加载态，避免新条件下仍显示旧条件的结果。
        resetResults(phase: .loading)
        if block.active {
            guard auto else { return false }
            deferredAutoRun = true
            return true
        }
        requests.send(api, ApiCall(operationId: "searchProducts", query: text), seq: seq) { [weak self] result in
            self?.firstPageSettled(result, seq: seq, platform: platform)
        }
        return true
    }

    func resetResults(phase: SearchPhase) {
        snapshot.phase = phase
        snapshot.items = []
        snapshot.fallbackItems = []
        snapshot.endReached = true
        snapshot.loadingMore = false
        snapshot.loadMoreError = nil
        snapshot.error = nil
        snapshot.stale = false
    }

    func applyPager(_ seq: Int64) {
        snapshot.items = pager.items
        snapshot.fallbackItems = pager.fallbackItems
        snapshot.endReached = pager.endReached
        snapshot.phase = pager.stateRaw == SearchStateRaw.content ? .content : .empty
        snapshot.stale = (snapshot.items + snapshot.fallbackItems).contains(where: ProductDetailState.stale)
        snapshot.error = nil
        snapshot.loadMoreError = nil
        snapshot.shownSeq = seq
        publish()
        continueRestore()
    }

    /// 恢复页面时（共性 20）：滚动锚点所在的卡片还没加载到、还有下一页就接着翻；够数或到底就结束。
    func continueRestore() {
        guard let target = restoreTarget else { return }
        if snapshot.items.count >= target || snapshot.endReached || !loadMore() {
            restoreTarget = nil
        }
    }

    func input(cursor: String?) -> [String: Any] {
        var value: [String: Any] = [
            "keyword": snapshot.keyword,
            "platform": snapshot.platform ?? "",
            "sort": snapshot.sort,
            "filters": Self.filterObject(
                hasCoupon: snapshot.hasCoupon, minFen: snapshot.priceMinFen, maxFen: snapshot.priceMaxFen
            ),
        ]
        if let cursor {
            value["cursor"] = cursor
        }
        return value
    }

    static func filterObject(hasCoupon: Bool, minFen: Int64?, maxFen: Int64?) -> [String: Any] {
        var filters: [String: Any] = [:]
        if hasCoupon {
            filters["has_coupon"] = true
        }
        if let minFen {
            filters["price_min_fen"] = NSNumber(value: minFen)
        }
        if let maxFen {
            filters["price_max_fen"] = NSNumber(value: maxFen)
        }
        return filters
    }

    /// 新请求开始：旧序号立即失效，并作废、取消旧请求的传输。
    func beginRequest(_ kind: String) -> Int64 {
        let seq = session.begin(kind: kind)
        requests.cancelAll()
        deferredAutoRun = false
        return seq
    }

    func publish() {
        // 整体赋值触发 @Published（结构体内部修改已经触发过，这里保证每次结算后页面一定刷新）。
        let current = snapshot
        snapshot = current
    }
}
