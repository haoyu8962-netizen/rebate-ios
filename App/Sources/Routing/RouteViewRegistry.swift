import DesignSystem
import Generated
import Router
import SwiftUI

/// 路由名 → 页面。Router 不 import 任何 Feature（03 §3.1 依赖方向）；由 App 在这里把路由名映射到各 Feature 暴露的入口视图。
/// 本任务各 Feature 还没有页面，未登记的路由一律显示占位页。
@MainActor
enum RouteViewRegistry {
    typealias Builder = @MainActor (RouteDestination) -> AnyView

    /// TODO(APP-05…APP-12): 各 Feature 实现页面后在这里登记（如 "Search": { AnyView(SearchScreen(...)) }）。
    /// APP-04：两类 WebView 容器（Features/Web，App 侧接线在 App/Sources/Web）。
    static let builders: [String: Builder] = [
        RoutePolicy.webPage: { AnyView(WebPageRouteView(destination: $0)) },
        RoutePolicy.externalPage: { AnyView(ExternalPageRouteView(destination: $0)) },
        // APP-05a：短信登录页（Features/Login）与设置占位页上的【退出登录】。
        RoutePolicy.login: { AnyView(LoginRouteView(destination: $0)) },
        "Settings": { AnyView(SettingsPlaceholderView(destination: $0)) },
    ]

    @ViewBuilder
    static func view(for destination: RouteDestination) -> some View {
        if let route = destination.route {
            if route == RoutePolicy.forceUpdate {
                // 强更页是 App 外壳的一部分（APP-02c），不属于任何 Feature。
                ForceUpdateScreen()
            } else if let builder = builders[route] {
                builder(destination)
            } else {
                RoutePlaceholderView(destination: destination)
            }
        } else {
            UpgradePromptView()
        }
    }
}

/// 占位页：显示路由名与参数（开发用英文字样，页面实现后替换）。
private struct RoutePlaceholderView: View {
    let destination: RouteDestination

    var body: some View {
        VStack(spacing: CouliSpacing.s3) {
            Text(verbatim: destination.route ?? "")
                .couliFont(.title)
                .foregroundColor(CouliColor.textPrimary)
                .accessibilityIdentifier("route.placeholder.name")
            if destination.readonly {
                Text(verbatim: "read-only")
                    .couliFont(.footnote)
                    .foregroundColor(CouliColor.textSecondary)
            }
            if destination.fromForceUpdatePage {
                // 从强更页进入（APP-02c）。登录页（APP-05a LoginRouteView）读这个标记按受限登录显示。
                Text(verbatim: "from force update")
                    .couliFont(.footnote)
                    .foregroundColor(CouliColor.textSecondary)
                    .accessibilityIdentifier("route.placeholder.restricted")
            }
            ForEach(destination.params.keys.sorted(), id: \.self) { key in
                Text(verbatim: "\(key) = \(describe(destination.params[key]))")
                    .couliFont(.footnote)
                    .foregroundColor(CouliColor.textSecondary)
            }
        }
        .padding(CouliSpacing.s6)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(CouliColor.backgroundCanvas.ignoresSafeArea())
    }

    private func describe(_ value: JSONValue?) -> String {
        switch value {
        case let .string(text): text
        case let .some(other): "\(other)"
        case .none: ""
        }
    }
}

/// 升级提示页（未知路由、since 未发布或高于本端版本）。routes.json 没有它的路由名（rule-gaps G03）。
/// TODO(N-14): 契约补升级提示的路由名与文案键后替换；暂用强更页的「去更新」文案。
private struct UpgradePromptView: View {
    var body: some View {
        VStack(spacing: CouliSpacing.s4) {
            Text(verbatim: DefaultTexts.text("app_update.go_store") ?? "")
                .couliFont(.title)
                .foregroundColor(CouliColor.textPrimary)
        }
        .padding(CouliSpacing.s6)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(CouliColor.backgroundCanvas.ignoresSafeArea())
        .accessibilityIdentifier("route.upgradePrompt")
    }
}
