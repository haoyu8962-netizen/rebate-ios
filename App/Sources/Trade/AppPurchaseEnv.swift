import CouliNetwork
import Foundation
import Trade

/// 一个发起页的购买环境（PurchaseEnv）。
@MainActor
final class AppPurchaseEnv: PurchaseEnv {
    private weak var trade: AppTrade?
    private let update: @MainActor (TradeObject, @escaping (TradeObject) -> TradeObject) -> Void
    /// 购买派生的补齐：目标卡、尝试的固定归属（r3f NEW-03）、合并。
    typealias Refetch = @MainActor (
        TradeObject, RequestOwnership?, @escaping (TradeObject, TradeObject) -> TradeObject
    ) -> Void
    private let refetch: Refetch
    /// 执行器（弱引用即可；只为调试时能从环境找到它）。
    weak var retain: OpenPurchaseController?

    init(
        trade: AppTrade,
        updateCard: @escaping @MainActor (TradeObject, @escaping (TradeObject) -> TradeObject) -> Void,
        refetchCard: @escaping Refetch
    ) {
        self.trade = trade
        update = updateCard
        refetch = refetchCard
    }

    func loggedIn() -> Bool {
        trade?.loggedIn ?? false
    }

    func basicMode() -> Bool {
        trade?.basicMode ?? true
    }

    func requestConsent() {
        trade?.requestConsent()
    }

    func platformStatus(_ platform: String) -> String? {
        trade?.platformStatus(platform)
    }

    func markPlatformStatus(_ platform: String, status: String) {
        trade?.overrides.mark(platform, status: status)
    }

    func updateCard(_ target: TradeObject, transform: @escaping (TradeObject) -> TradeObject) {
        update(target, transform)
    }

    func open(route: String, params: [String: String]) {
        trade?.open(route: route, params: params)
    }

    func refetchCard(
        _ target: TradeObject, request: RequestOwnership?, merge: @escaping (TradeObject, TradeObject) -> TradeObject
    ) {
        refetch(target, request, merge)
    }

    func helpLink(_ key: String) -> (route: String, params: [String: String])? {
        trade?.helpLink(key)
    }
}
