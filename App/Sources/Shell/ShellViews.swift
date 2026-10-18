import DesignSystem
import Generated
import Router
import SwiftUI

/// 一级 Tab（首页 / AI 助手 / 订单 / 我的）。每个 Tab 的根页面经路由注册表按路由名取得（不 import Feature 内部类型）。
enum ShellTab: String, CaseIterable {
    case home
    case agent
    case orders
    case me

    /// Tab 根页面的路由名（routes.json）。
    var route: String {
        switch self {
        case .home: RoutePolicy.home
        case .agent: "AgentChat"
        case .orders: "OrderList"
        case .me: "Me"
        }
    }

    var item: TabBarItem {
        switch self {
        case .home: TabBarItem(id: rawValue, title: ShellDraftTexts.tabHome, icon: .home)
        case .agent: TabBarItem(id: rawValue, title: ShellDraftTexts.tabAgent, icon: .chat)
        case .orders: TabBarItem(id: rawValue, title: ShellDraftTexts.tabOrders, icon: .orders)
        case .me: TabBarItem(id: rawValue, title: ShellDraftTexts.tabMe, icon: .user)
        }
    }

    /// 基本模式下能直接切过去的 Tab：只有首页（BR-ID-02、BR-ID-11 基本模式可达页面；由守卫判定，这里只作说明与单测对照）。
    /// 其余三个照设计稿照常显示，点击时守卫要求补同意，重新弹首启弹窗（decisions-v2-launch §5；BR-ID-02）。
    var reachableInBasicMode: Bool {
        RoutePolicy.basicModeRoutes.contains(route)
    }

    /// Router 的 Tab 根目的地 → 选中的 Tab（R1-05）。不是 Tab 根路由时回到首页。
    init(rootRoute route: String?) {
        self = Self.allCases.first { $0.route == route } ?? .home
    }
}

/// Tab 外壳：内容 + 底部 TabBar（DesignSystem）。基本模式时首页 Tab 是基本模式页。
/// 选中哪个 Tab、Tab 根页面以什么目的地（含只读标记）渲染，一律跟随 `Router.tabRoot`（R1-05）：
/// Tab 点击经 `onSelect` 过守卫（AppRouting.selectTab → Router.selectTab，放行时由 Router 切 Tab），
/// 深链、待办恢复打开 Tab 根路由时同样由 Router 切 Tab；外壳自己不保存选中状态。
struct TabShellView<Home: View>: View {
    /// Router 当前的 Tab 根目的地。
    let root: RouteDestination
    let onSelect: (ShellTab) -> Void
    @ViewBuilder let home: (RouteDestination) -> Home
    @State private var retainedHome = RouteDestination(route: RoutePolicy.home)

    private var selected: ShellTab {
        ShellTab(rootRoute: root.route)
    }

    var body: some View {
        VStack(spacing: 0) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            TabBar(items: ShellTab.allCases.map(\.item), selectedID: selected.rawValue) { item in
                guard let tab = ShellTab(rawValue: item.id) else { return }
                onSelect(tab)
            }
            .accessibilityIdentifier("shell.tabBar")
        }
        .background(CouliColor.backgroundCanvas.ignoresSafeArea())
    }

    /// 首页常驻（切走 Tab 再回来沿用 ScrollView 的位置、不重建首页视图）。用系统分页容器承载各 Tab 根页面：未选中的页面由系统
    /// 移出显示层级，读屏与界面自动化都够不到、也接不到点击；切回时原实例连同滚动位置恢复（APP-11 补修：常驻首页读屏可达）。
    /// 选中哪个 Tab 仍只跟随 Router（绑定只读），系统自带的标签栏隐藏，外壳照旧画设计系统的 TabBar。
    private var content: some View {
        TabView(selection: Binding(get: { selected }, set: { _ in })) {
            home(selected == .home ? root : retainedHome)
                .tag(ShellTab.home)
                .toolbar(.hidden, for: .tabBar)
            ForEach(ShellTab.allCases.filter { $0 != .home }, id: \.self) { tab in
                Group {
                    if selected == tab {
                        RouteViewRegistry.view(for: root)
                    } else {
                        Color.clear
                    }
                }
                .tag(tab)
                .toolbar(.hidden, for: .tabBar)
            }
        }
        .onAppear {
            if selected == .home {
                retainedHome = root
            }
        }
        .onChange(of: root) { value in
            if value.route == RoutePolicy.home {
                retainedHome = value
            }
        }
    }
}

/// 基本模式页（设计稿 BasicMode）：搜索框 +【设置】，顶部提示条 `privacy.basic_mode.notice` +【开启完整功能】，
/// 下面是首页内容（首页卡片由 APP-11 实现，这里是路由注册表的首页占位）。
struct BasicModeHomeView: View {
    let onSearch: () -> Void
    let onSettings: () -> Void
    let onEnableFull: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            topBar
            notice
                .padding(.horizontal, CouliSpacing.s4)
                .padding(.top, CouliSpacing.s1)
            RouteViewRegistry.view(for: RouteDestination(route: RoutePolicy.home, readonly: true))
        }
        .background(CouliColor.backgroundCanvas.ignoresSafeArea())
    }

    private var topBar: some View {
        HStack(spacing: CouliSpacing.s2) {
            Button(action: onSearch) {
                HStack(spacing: CouliSpacing.s2) {
                    CouliIconView(.search, size: 20)
                    Text(verbatim: ShellDraftTexts.basicSearchPlaceholder)
                        .couliFont(.body)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .foregroundColor(CouliColor.textSecondary)
                .padding(.vertical, CouliSpacing.s2)
                .padding(.horizontal, CouliSpacing.s3)
                .frame(minHeight: CouliHitTarget.minimum)
                .background(
                    RoundedRectangle(cornerRadius: CouliRadius.button, style: .continuous)
                        .fill(CouliColor.backgroundSurface)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: CouliRadius.button, style: .continuous)
                        .stroke(CouliColor.borderControl, lineWidth: 1)
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("basic.search")
            Button(action: onSettings) {
                CouliIconView(.settings)
                    .foregroundColor(CouliColor.textPrimary)
                    .couliHitTarget()
            }
            .buttonStyle(CouliPlainButtonStyle(cornerRadius: CouliRadius.small))
            .accessibilityLabel(Text(verbatim: ShellDraftTexts.settingsLabel))
            .accessibilityIdentifier("basic.settings")
        }
        .padding(.horizontal, CouliSpacing.s4)
        .padding(.vertical, CouliSpacing.s2)
    }

    private var notice: some View {
        VStack(alignment: .leading, spacing: CouliSpacing.s3) {
            HStack(alignment: .top, spacing: CouliSpacing.s2) {
                CouliIconView(.info, size: 20, relativeTo: .footnote)
                    .foregroundColor(CouliColor.brandEmphasis)
                Text(verbatim: DefaultTexts.text("privacy.basic_mode.notice") ?? "")
                    .couliFont(.footnote)
                    .foregroundColor(CouliColor.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("basic.notice")
            }
            CouliButton(
                DefaultTexts.text("privacy.basic_mode.enable") ?? "",
                kind: .primary,
                size: .compact,
                fillsWidth: true,
                action: onEnableFull
            )
            .accessibilityIdentifier("basic.enableFull")
        }
        .padding(CouliSpacing.s4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: CouliRadius.card, style: .continuous)
                .fill(CouliColor.brandSubtle)
        )
    }
}

/// 首启弹窗背后的启动底（设计稿 LaunchPrivacy / LaunchSecondNotice 的底层）：页面底色 + 品牌图形占位。
/// 系统启动屏（Info.plist UILaunchScreen）用同一底色，过渡时不闪。
struct LaunchBackdropView: View {
    /// 品牌图形占位上的字（设计稿画法）。TODO: 正式品牌图形由设计提供后换成图片资源。
    static let brandTileText = "凑狸"

    var body: some View {
        ZStack {
            CouliColor.backgroundCanvas
                .ignoresSafeArea()
            Text(verbatim: Self.brandTileText)
                .font(.system(size: 22, weight: .bold))
                .tracking(2)
                .foregroundColor(CouliColor.textInverse)
                .frame(width: 88, height: 88)
                .background(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .fill(CouliColor.brandPrimary)
                )
                .dynamicTypeSize(.large)
                .accessibilityHidden(true)
        }
        .accessibilityIdentifier("launch.backdrop")
    }
}

/// 首页顶部的搜索入口（APP-06a；与基本模式页同一写法）。TODO(APP-11)：首页实现后并入首页顶栏。
struct HomeSearchEntry: View {
    let onSearch: () -> Void

    var body: some View {
        Button(action: onSearch) {
            HStack(spacing: CouliSpacing.s2) {
                CouliIconView(.search, size: 20)
                Text(verbatim: ShellDraftTexts.basicSearchPlaceholder)
                    .couliFont(.body)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .foregroundColor(CouliColor.textSecondary)
            .padding(.vertical, CouliSpacing.s2)
            .padding(.horizontal, CouliSpacing.s3)
            .frame(minHeight: CouliHitTarget.minimum)
            .background(
                RoundedRectangle(cornerRadius: CouliRadius.button, style: .continuous)
                    .fill(CouliColor.backgroundSurface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: CouliRadius.button, style: .continuous)
                    .stroke(CouliColor.borderControl, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("home.search")
    }
}
