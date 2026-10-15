import DesignSystem
import Me
import MeCore
import Router
import SwiftUI

/// 路由 Me（「我的」Tab 根，APP-12）：Features/Me 的 MeTabScreen；执行器每一次进入一个（AppMe.tabHost）。
struct MeTabRouteView: View {
    let destination: RouteDestination
    @EnvironmentObject private var me: AppMe

    var body: some View {
        MeTabScreen(host: me.tabHost, mask: me.mask, scroll: me.scroll)
            .toolbar(.hidden, for: .navigationBar)
            .debugRouteMarker(destination)
    }
}

/// 设置、隐私中心、关于、封禁说明、申诉（APP-12）：一个导航实例只建一次执行器（AppMe 按 RouteDestination.id 缓存，出栈时作废）。系统导航栏
/// （行内标题、系统返回）；封禁版式与确认框显示期间隐藏返回。
struct MeRouteView: View {
    let destination: RouteDestination
    @EnvironmentObject private var me: AppMe

    var body: some View {
        Group {
            if let entry = me.entry(for: destination) {
                entry.screen()
            }
        }
        .debugRouteMarker(destination)
    }
}

/// 统一客服出口的半屏（系统 `.sheet` + presentationDetents，brief §3 iOS）与「撤回没有生效」提示（应用级，盖在当前可见界面上，鸿蒙 R2-04）。
struct MeOverlays: ViewModifier {
    @ObservedObject var cs: CustomerServiceEntry
    @ObservedObject var withdraw: MeWithdrawState
    let me: AppMe

    func body(content: Content) -> some View {
        content
            .sheet(item: Binding(get: { cs.sheet }, set: { value in
                if value == nil, let sheet = cs.sheet {
                    cs.dismiss(sheet.serial)
                }
            })) { sheet in
                CsSheetView(entry: cs, sheet: sheet, texts: me.deps.texts)
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
            }
            .couliDialog(isPresented: withdraw.failed != nil) {
                let id = withdraw.failed ?? 0
                let texts = me.deps.texts
                return CouliDialog(
                    title: texts.text("privacy_center.withdraw_failed"),
                    primary: CouliDialogAction(texts.text("me.retry")) { me.retryWithdrawCleanup(id) },
                    secondary: CouliDialogAction(texts.text("me.close")) { me.dismissWithdrawFailed(id) }
                )
            }
    }
}

extension View {
    /// 更早任务的 UI 测试按路由名找页面（`route.placeholder.name`、`route.placeholder.restricted`）：Debug / Staging 在正式页上挂一个看不见的
    /// 只读路由名标记（与 `clipboard.debug` 同做法）；Release 不编译。
    @ViewBuilder
    func debugRouteMarker(_ destination: RouteDestination) -> some View {
        #if DEBUG
        overlay(alignment: .topLeading) {
            VStack(spacing: 0) {
                Text(verbatim: destination.route ?? "")
                    .accessibilityIdentifier("route.placeholder.name")
                if destination.fromForceUpdatePage {
                    Text(verbatim: "from force update")
                        .accessibilityIdentifier("route.placeholder.restricted")
                }
            }
            .font(.system(size: 6))
            .foregroundColor(.clear)
            .allowsHitTesting(false)
        }
        #else
        self
        #endif
    }
}
