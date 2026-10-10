import CouliNetwork
@testable import Trade

@MainActor
final class FakeSink: LinkJumpSink {
    var events: [TradeObject] = []
    /// 每条事件带的固定请求归属（r3g NEW-06；nil = 没带）。
    var owners: [RequestOwnership?] = []

    func report(_ fields: TradeObject) {
        report(fields, owner: nil)
    }

    func report(_ fields: TradeObject, owner: RequestOwnership?) {
        events.append(fields)
        owners.append(owner)
    }
}

/// 测试入口（APP-08 iOS r3g NEW-02）：按「此刻的当前弹窗 / 加载层 / 浏览器提示」执行，等同新渲染的回调立即执行。
/// 生产界面没有无票据的入口，一律经 PurchaseOverlay 渲染时捕获的票据调用。
@MainActor
extension OpenPurchaseController {
    func confirm() {
        confirm(state.dialogTicket)
    }

    func dismissDialog() {
        dismissDialog(state.dialogTicket)
    }

    func authorize() {
        authorize(state.dialogTicket)
    }

    func recheckAuth() {
        recheckAuth(state.dialogTicket)
    }

    func cancelLoading() {
        cancelLoading(state.loadingTicket)
    }

    func retryAfterTimeout() {
        retryAfterTimeout(state.loadingTicket)
    }

    func cancelBrowser() {
        cancelBrowser(state.browserTicket)
    }
}
