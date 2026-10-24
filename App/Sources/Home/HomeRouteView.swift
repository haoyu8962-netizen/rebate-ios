import Home
import Router
import SwiftUI

struct HomeRouteView: View {
    let destination: RouteDestination
    @EnvironmentObject private var home: AppHome
    /// 原生头部（RootView 组装；单测只装配首页路由时为 nil）。
    @Environment(\.homeNativeHeader) private var header

    var body: some View {
        // 正式首页根的标识（home.root）挂在首页 Tab 内容（搜索行 + 本列表）上：这里只有一个滚动列表，挂在这里会与列表的
        // home.list 合并成同一个无障碍节点（APP-11v）
        screen
            .onAppear { home.tabAppeared() }
    }

    private var screen: some View {
        HomeSduiScreen(controller: home.controller, grayscale: home.grayscale, header: header)
    }
}
