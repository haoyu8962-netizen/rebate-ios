import DesignSystem
import Purchase
import Router
import SwiftUI

/// 路由 AuthManage（APP-06b；routes.json auth=login，entry in_app / push）：授权管理页（Features/Purchase 的 AuthManageScreen）。
/// 自己的顶栏，系统导航栏隐藏。进入页面不自动发起授权（共性第 14 条）。
struct AuthManageRouteView: View {
    let destination: RouteDestination
    @EnvironmentObject private var search: AppSearch

    var body: some View {
        if let trade = search.trade {
            AuthManageRouteContent(trade: trade, destination: destination)
                .toolbar(.hidden, for: .navigationBar)
                .navigationBarBackButtonHidden(true)
        }
    }
}

private struct AuthManageRouteContent: View {
    /// StateObject 的初始值只在页面第一次出现时求值：一个路由目的地只有一个执行器（出栈时由 AppTrade leave）。
    @StateObject private var config: AuthManagePageConfig

    init(trade: AppTrade, destination: RouteDestination) {
        _config = StateObject(wrappedValue: trade.authManagePage(destination))
    }

    var body: some View {
        AuthManageScreen(config: config)
    }
}
