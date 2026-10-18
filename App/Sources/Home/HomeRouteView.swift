import Home
import Router
import SwiftUI

struct HomeRouteView: View {
    let destination: RouteDestination
    @EnvironmentObject private var home: AppHome
    var body: some View {
        HomeSduiScreen(controller: home.controller, grayscale: home.grayscale)
            .onAppear { home.tabAppeared() }
            // 正式首页根（深链被拦后的验收接口）；.contain 保留子元素各自的标识，不覆盖
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("home.root")
    }
}
