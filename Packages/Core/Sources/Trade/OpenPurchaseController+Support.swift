import CouliNetwork
import Foundation
import Generated

extension OpenPurchaseController {
    var busy: Bool {
        state.phase == .loading || state.dialog != nil || state.browserNotice
    }

    func grantPermit(_ attempt: PurchaseAttempt) {
        permit?.valid = false
        permit = Permit(attempt: attempt)
    }

    func revokePermit() {
        permit?.valid = false
        permit = nil
    }

    /// 续执行许可仍有效：是当前尝试的、没作废、页面没离开且在前台。
    func allowed(_ granted: Permit) -> Bool {
        granted.valid && permit === granted && granted.attempt === current && !left && foreground
    }

    func permitted(_ attempt: PurchaseAttempt) -> Bool {
        guard let permit, permit.attempt === attempt else { return false }
        return allowed(permit)
    }

    func whenForeground(_ kind: DeferredResume, _ action: @escaping () -> Void) {
        if foreground {
            action()
        } else {
            deferred[kind] = action
        }
    }

    /// 购买待办的参数。待办按发起页面与购买尝试归属（共性第 44 条）：`owner` 是本页执行器的标识，`attempt` 是登记它的那次点击编号
    /// （补同意的待办还没发请求，不带）。所有页面共用 Router 的同一份记录，清除、计时、消费前都先核对归属。
    func pendingParams(
        _ target: TradeObject, linkId: String, key: String?, kind: String, attempt: PurchaseAttempt?
    ) -> TradeObject {
        var fields: TradeObject = [
            "kind": kind, "link_id": linkId, "platform": TJSON.string(target["platform"]) ?? "",
            PurchasePendingKeys.owner: pageToken,
        ]
        if let attempt {
            fields[PurchasePendingKeys.attempt] = String(attempt.click)
        }
        if let productKey = TJSON.string(target["product_key"]) {
            fields["product_key"] = productKey
        }
        if let key {
            fields["idempotency_key"] = key
        }
        return fields
    }

    /// 本页登记的、仍有效的购买待办；`attempt` 给出时还须是那次尝试登记的，`kind` 给出时还须是那一类。别的页面登记的一律为 nil。
    func ownPending(_ attempt: PurchaseAttempt? = nil, kind: String? = nil) -> TradeObject? {
        guard let record = pending.peek(),
              TJSON.string(record[PurchasePendingKeys.owner]) == pageToken else { return nil }
        if let attempt, TJSON.string(record[PurchasePendingKeys.attempt]) != String(attempt.click) {
            return nil
        }
        if let kind, TJSON.string(record["kind"]) != kind {
            return nil
        }
        return record
    }

    /// 删除这次授权登记的待办（本页、那次尝试、授权类、同一 link_id）；别的页面或之后登记的不动（共性第 44 条）。
    func dropAuthPending(_ context: AuthContext) {
        if let record = ownPending(context.attempt, kind: PurchasePendingKeys.kindAuth),
           TJSON.string(record["link_id"]) == context.linkId {
            pending.clear()
        }
    }

    /// 授权完成后的延迟恢复仍属当前尝试：页面没离开、世代没变（期间没有新点击）、尝试仍是那次、没有在途请求或弹窗。
    func resumeStillMine(_ context: AuthContext, _ gen: Int) -> Bool {
        !left && authGen == gen && current === context.attempt && !busy
    }

    /// 只删除本页（以及给出的那次尝试）登记的购买待办；新页面登记的不动（共性第 44 条）。
    func clearOwnPending(_ attempt: PurchaseAttempt? = nil, kind: String? = nil) {
        guard ownPending(attempt, kind: kind) != nil else { return }
        pending.clear()
    }

    func showDialog(_ dialog: PurchaseDialog) {
        state.dialog = dialog
    }

    func hideDialog() {
        state.dialog = nil
    }

    func toast(_ key: String, traceId: String? = nil) {
        toastSeq += 1
        state.toast = PurchaseToast(key: key, traceId: traceId, id: toastSeq)
    }

    public func consumeToast() {
        state.toast = nil
    }

    func startBlock(_ millis: Int64) {
        state.rateLimited = true
        gate.start(millis) { [weak self] in
            guard let self, !left else { return }
            state.rateLimited = false
        }
    }

    /// 相似商品的搜索参数：同平台、原样标题（截前 60 字；排除同 product_key 待契约补参数，TODO(N-28) A04 同口径）。
    public static func similarParams(_ product: TradeObject) -> [String: String] {
        var params: [String: String] = [:]
        if let title = TJSON.string(product["title"]), !title.isEmpty {
            params["q"] = String(title.prefix(titleMax))
        }
        if let platform = TJSON.string(product["platform"]), !platform.isEmpty {
            params["platform"] = platform
        }
        return params
    }
}
