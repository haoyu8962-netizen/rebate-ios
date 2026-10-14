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

/// 【授权管理】入口行（「我的」Tab 与设置页各一行，经 Router 打开、保留守卫：游客先登录、基本模式先补同意；A22 同口径）。
/// 行的样式没有画板（「我的」页正文是后续任务 APP-12），这里用通用列表行。
struct AuthManageEntryRow: View {
    @EnvironmentObject private var router: Router

    var body: some View {
        Button {
            router.open(RouteRequest(route: AppTradeRoutes.authManage, from: .inApp))
        } label: {
            HStack(spacing: CouliSpacing.s3) {
                CouliIconView(.link)
                    .foregroundColor(CouliColor.textSecondary)
                    .accessibilityHidden(true)
                Text(verbatim: TradeDraftTexts.drafts["trade.auth_manage.entry"] ?? "")
                    .couliFont(.body)
                    .foregroundColor(CouliColor.textPrimary)
                Spacer(minLength: CouliSpacing.s2)
                CouliIconView(.chevron)
                    .foregroundColor(CouliColor.textSecondary)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, CouliSpacing.s4)
            .frame(maxWidth: .infinity, minHeight: CouliHitTarget.minimum)
            .contentShape(Rectangle())
        }
        .buttonStyle(CouliPlainButtonStyle(cornerRadius: CouliRadius.card))
        .couliCard(padding: 0)
        .accessibilityIdentifier("me.authManage")
    }
}

/// 「我的」Tab 的占位页（页面本身在 APP-12）：先放【授权管理】入口（共性第 14 条：AuthManage 要有正式入口）与【设置】。
struct MePlaceholderView: View {
    let destination: RouteDestination
    @EnvironmentObject private var router: Router

    var body: some View {
        ScrollView {
            VStack(spacing: CouliSpacing.s3) {
                // APP-09：钱包冒烟入口（「我的」页本身在 APP-12）
                WalletEntryRow()
                AuthManageEntryRow()
                Button {
                    router.open(RouteRequest(route: "Settings", from: .inApp))
                } label: {
                    HStack(spacing: CouliSpacing.s3) {
                        CouliIconView(.settings)
                            .foregroundColor(CouliColor.textSecondary)
                            .accessibilityHidden(true)
                        Text(verbatim: LoginDraftTexts.text("login.settings"))
                            .couliFont(.body)
                            .foregroundColor(CouliColor.textPrimary)
                        Spacer(minLength: CouliSpacing.s2)
                        CouliIconView(.chevron)
                            .foregroundColor(CouliColor.textSecondary)
                            .accessibilityHidden(true)
                    }
                    .padding(.horizontal, CouliSpacing.s4)
                    .frame(maxWidth: .infinity, minHeight: CouliHitTarget.minimum)
                    .contentShape(Rectangle())
                }
                .buttonStyle(CouliPlainButtonStyle(cornerRadius: CouliRadius.card))
                .couliCard(padding: 0)
                .accessibilityIdentifier("me.settings")
            }
            .padding(CouliSpacing.s4)
            .frame(maxWidth: 600)
            .frame(maxWidth: .infinity)
        }
        .background(CouliColor.backgroundCanvas.ignoresSafeArea())
        .accessibilityIdentifier("me.placeholder")
    }
}
