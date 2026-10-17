import CouliNetwork
import Foundation

/// 翻页、详情回填与轻提示（OrderListController 的一部分）。
public extension OrderListController {
    /// 末行出现：翻下一页（绑定查询轮次）。返回是否发出。
    @discardableResult
    func loadMore() -> Bool {
        guard !left, !gate.active, snapshot.canLoadMore, let cursor = snapshot.nextCursor,
              admitMore(ownerCheck) else { return false }
        var query = snapshot.query
        query.nextPage(cursor)
        guard query.sendsRequest() else { return false }
        let round = query.round
        snapshot.loadingMore = true
        let call = ApiCall(operationId: Self.operation, query: query.queryString())
        requests.send(api, call, gate: gate, owner: owner) { [weak self] result in
            guard let self, !left, snapshot.query.round == round, snapshot.loadingMore, admitMore(ownerCheck) else {
                return
            }
            settleNext(result)
        }
        return true
    }

    /// 翻页的身份核对：暂时未知 → 翻页在途标记复位、记待补做（身份确认后再翻这一页）；已换代 → 不放行。
    internal func admitMore(_ check: IdentityCheck) -> Bool {
        deferral.admit(check, slot: Slot.more, resume: { [weak self] in self?.loadMore() }, settle: {
            snapshot.loadingMore = false
        })
    }

    /// 翻页失败后的【重试】（stale 状态下是整页刷新）。
    @discardableResult
    func retryPage() -> Bool {
        if snapshot.phase == .stale {
            return refresh()
        }
        guard !gate.active, !left, snapshot.pageError != nil else { return false }
        snapshot.pageError = nil
        return loadMore()
    }

    internal func settleNext(_ result: ApiResult) {
        snapshot.loadingMore = false
        switch result {
        case let .success(data, traceId, _):
            guard let page = OrderJSON.listData(JSONPick.parse(data)) else {
                snapshot.pageError = OrderErrorView(
                    actionRaw: OrderErrorKind.pageError, textKey: "error.50001", showTrace6: true, keepItems: true,
                    traceId: traceId
                )
                return
            }
            let known = Set(snapshot.items.map(\.orderId))
            snapshot.items += page.items.filter { !known.contains($0.orderId) }
            snapshot.nextCursor = page.nextCursor
            if let date = page.earliestVisibleDate {
                snapshot.earliestVisibleDate = date
            }
        case let .localReject(reason) where reason == LocalRejectReason.callCancelled:
            break
        case let .localReject(reason) where reason == LocalRejectReason.sendBlocked:
            snapshot.pageError = OrderErrorView(
                actionRaw: OrderErrorKind.retryAfter, textKey: "error.42901", disableMs: gate.remainingMillis,
                keepItems: true
            )
        default:
            let view = OrderErrorAction.view(
                target: OrderErrorAction.listNext, result: result, hasCache: false, filtered: snapshot.query.filtered
            )
            if view.actionRaw == OrderErrorKind.retryAfter {
                gate.start(view.disableMs ?? ErrorActionMapper.defaultRetryAfterMillis)
            }
            snapshot.pageError = view
        }
    }

    // MARK: - 其他

    /// 详情返回（G17）：本次详情请求成功时，用详情响应里与 OrderSummary 同名的字段替换同 order_id 的那一行；其余行、筛选、搜索词不动，
    /// 不额外请求列表。列表不带入详情才有的 actual_fen / clawback_fen（A01 同口径，不让列表与契约口径不一致）。
    func replaceRow(with detail: OrderDetail) {
        guard !left, ownerCurrent,
              let index = snapshot.items.firstIndex(where: { $0.orderId == detail.summary.orderId }) else { return }
        var row = detail.summary
        row.actualFen = snapshot.items[index].actualFen
        row.clawbackFen = snapshot.items[index].clawbackFen
        snapshot.items[index] = row
    }

    func consumeToast() {
        snapshot.toast = nil
    }

    internal func toast(_ view: OrderErrorView) {
        toastSeq += 1
        snapshot.toast = OrderToast(key: view.textKey ?? OrderErrorAction.networkKey, error: view, id: toastSeq)
    }
}
