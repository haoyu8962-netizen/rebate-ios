import Foundation

extension Router {
    /// 打开结论：推送兜底的 Messages 不带原请求的参数；资金与实名页面丢弃全部参数（03 §4.4）。
    func showOpened(_ decision: GuardDecision, for request: RouteRequest) {
        guard let route = decision.route else { return }
        // 资金与实名页面带参数打开：参数已丢弃，通知 App 记 route_params_dropped（只有路由名与个数，AC-S1-81 ⑫；APP-09 iOS I07）
        if route == request.route, RoutePolicy.paramsDroppedRoutes.contains(route), !request.paramValues.isEmpty {
            onParamsDropped?(route, request.paramValues.count)
        }
        show(RouteDestination(
            route: route,
            params: route == request.route ? EntryGuard.effectiveParams(request) : [:],
            readonly: decision.kind == .openReadonly
        ))
    }
}
