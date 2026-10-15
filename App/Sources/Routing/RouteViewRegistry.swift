import DesignSystem
import Generated
import Router
import SwiftUI

/// 路由名 → 页面。Router 不 import 任何 Feature（03 §3.1 依赖方向）；由 App 在这里把路由名映射到各 Feature 暴露的入口视图。
/// 未登记的路由一律显示占位页（协议页 Agreement 等，G21）。
@MainActor
enum RouteViewRegistry {
    typealias Builder = @MainActor (RouteDestination) -> AnyView

    /// 各 Feature 实现页面后在这里登记（如 "Search": { AnyView(SearchScreen(...)) }）。
    /// APP-04：两类 WebView 容器（Features/Web，App 侧接线在 App/Sources/Web）。
    static let builders: [String: Builder] = [
        RoutePolicy.webPage: { AnyView(WebPageRouteView(destination: $0)) },
        RoutePolicy.externalPage: { AnyView(ExternalPageRouteView(destination: $0)) },
        // APP-05a：短信登录页（Features/Login）。
        RoutePolicy.login: { AnyView(LoginRouteView(destination: $0)) },
        // APP-05b：绑手机页（Features/Login；首次绑定、并号确认、待确认）。
        RoutePolicy.bindPhone: { AnyView(BindPhoneRouteView(destination: $0)) },
        // APP-12：「我的」Tab 根、设置、隐私中心、关于、封禁说明与申诉（Features/Me）；消息中心、邀请好友是 H5（G04、G21）。
        "Me": { AnyView(MeTabRouteView(destination: $0)) },
        "Settings": { AnyView(MeRouteView(destination: $0)) },
        "PrivacyCenter": { AnyView(MeRouteView(destination: $0)) },
        "About": { AnyView(MeRouteView(destination: $0)) },
        "RiskNotice": { AnyView(MeRouteView(destination: $0)) },
        "Appeal": { AnyView(MeRouteView(destination: $0)) },
        "Messages": { AnyView(H5RouteView(destination: $0)) },
        "InviteShare": { AnyView(H5RouteView(destination: $0)) },
        // APP-06a：搜索（Features/Search）与商品详情（Features/Product）。
        "Search": { AnyView(SearchRouteView(destination: $0)) },
        "ProductDetail": { AnyView(ProductDetailRouteView(destination: $0)) },
        // APP-06b：授权管理（Features/Purchase）。
        "AuthManage": { AnyView(AuthManageRouteView(destination: $0)) },
        // APP-08：订单列表（订单 Tab 根）与详情（Features/Orders）；订单页的 H5 入口（找回、流水、帮助）接可信容器。
        "OrderList": { AnyView(OrderListRouteView(destination: $0)) },
        "OrderDetail": { AnyView(OrderDetailRouteView(destination: $0)) },
        "FindOrder": { AnyView(H5RouteView(destination: $0)) },
        "Ledger": { AnyView(H5RouteView(destination: $0)) },
        "Help": { AnyView(H5RouteView(destination: $0)) },
        // APP-09：钱包、提现、提现记录、收款账号、实名、劳务协议（Features/Wallet）；收益看板是 H5（since 三端为 null，G20）。
        "Wallet": { AnyView(WalletRouteView(destination: $0)) },
        "Withdraw": { AnyView(WalletRouteView(destination: $0)) },
        "WithdrawRecords": { AnyView(WalletRouteView(destination: $0)) },
        "PayoutAccount": { AnyView(WalletRouteView(destination: $0)) },
        "RealName": { AnyView(WalletRouteView(destination: $0)) },
        "LaborAgreement": { AnyView(WalletRouteView(destination: $0)) },
        "Earnings": { AnyView(H5RouteView(destination: $0)) },
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
