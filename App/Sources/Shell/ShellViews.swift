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

    /// 标签栏上的一项：文字取 ShellDraftTexts 的 Tab 文案，图标是 SF Symbols（凑狸自有图标到位前，N-11 / DSX-06）。
    var item: ShellTabItem {
        switch self {
        case .home: ShellTabItem(title: ShellDraftTexts.tabHome, systemImage: CouliIcon.home.rawValue)
        case .agent: ShellTabItem(title: ShellDraftTexts.tabAgent, systemImage: CouliIcon.chat.rawValue)
        case .orders: ShellTabItem(title: ShellDraftTexts.tabOrders, systemImage: CouliIcon.orders.rawValue)
        case .me: ShellTabItem(title: ShellDraftTexts.tabMe, systemImage: CouliIcon.user.rawValue)
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

/// 系统标签栏上一项的文字与图标（SF Symbols 名）。
struct ShellTabItem: Equatable {
    let title: String
    let systemImage: String
}

/// Tab 外壳：系统 TabView 的标签栏（D10-826；iOS 26 起系统呈现 Liquid Glass 悬浮样式，iOS 16–25 是经典样式）。
/// 基本模式时首页 Tab 是基本模式页。选中哪个 Tab、Tab 根页面以什么目的地（含只读标记）渲染，一律跟随 `Router.tabRoot`（R1-05）：
/// 选中绑定 get 读 Router，set 只调 `onSelect` 过守卫（AppRouting.selectTab → Router.selectTab，放行时由 Router 切 Tab；
/// 被拦时 Router 不切，绑定回到原值），深链、待办恢复打开 Tab 根路由时同样由 Router 切 Tab；外壳自己不保存选中状态。
/// 读屏（「标签，第 n 个，共 4 个」）、大字、长按放大都由系统标签栏提供，外壳不自写。
struct TabShellView<Home: View>: View {
    /// Router 当前的 Tab 根目的地。
    let root: RouteDestination
    let onSelect: (ShellTab) -> Void
    @ViewBuilder let home: (RouteDestination) -> Home
    @State private var retainedHome = RouteDestination(route: RoutePolicy.home)
    /// 每次点 Tab 加一：外壳随之重算，选中绑定把 Router 的当前 Tab 推回标签栏。系统标签栏在点击时先自己切到目标项、再经绑定问外壳；
    /// 被守卫拦下时 Router 不变，外壳若不重算，标签栏会停在目标项上（实测 iOS 26）。只触发重算，不动 TabView 的身份（方案 §1.2 退路）。
    @State private var taps = 0

    private var selected: ShellTab {
        ShellTab(rootRoute: root.route)
    }

    /// 首页常驻（切走 Tab 再回来沿用 ScrollView 的位置、不重建首页视图）：系统 TabView 承载各 Tab 根页面，未选中的页面由系统
    /// 移出显示层级，读屏与界面自动化都够不到、也接不到点击；切回时原实例连同滚动位置恢复（APP-11 补修：常驻首页读屏可达）。
    /// 不给 TabView 或页面加 `.id`（会重建首页、丢滚动位置）。
    var body: some View {
        TabView(selection: Binding(get: { selected }, set: { tab in
            onSelect(tab)
            taps &+= 1
        })) {
            home(selected == .home ? root : retainedHome)
                .modifier(Page(tab: .home))
            ForEach(ShellTab.allCases.filter { $0 != .home }, id: \.self) { tab in
                Group {
                    if selected == tab {
                        RouteViewRegistry.view(for: root)
                    } else {
                        Color.clear
                    }
                }
                .modifier(Page(tab: tab))
            }
        }
        // 品牌色只作用于标签栏的选中项（D10-831 ①）；页面内容在 Page 里还原系统默认 tint，全局 AccentColor 另开单
        .tint(CouliColor.brandPrimary)
        .modifier(ShellTabBarMinimize())
        .modifier(ShellSelectionResync(taps: taps))
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

    /// 一个 Tab 页：页面底色铺满（含标签栏下方，滚动内容从玻璃下透出；不另垫实色条、不设标签栏背景），内容 tint 还原系统默认，
    /// 系统标签项（文字 + SF Symbols 图标，选中态的实心变体由系统换）。组件目录页的标签栏样例用同一个配置。
    struct Page: ViewModifier {
        let tab: ShellTab

        func body(content: Content) -> some View {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(CouliColor.backgroundCanvas.ignoresSafeArea())
                // 页面内容还原系统默认 tint：App 没有 AccentColor 资源，系统默认就是系统蓝（.blue 随浅 / 深自适应）。
                // .tint(nil) 与 Color.accentColor 实测都取到外层的品牌色（方案 §5-1 退路）；全局 AccentColor 单里统一改
                .tint(.blue)
                .tabItem {
                    Label {
                        Text(verbatim: tab.item.title)
                    } icon: {
                        Image(systemName: tab.item.systemImage)
                    }
                }
                .tag(tab)
        }
    }
}

/// 外壳重算的依赖（点 Tab 的次数）。不改内容；只让外壳在每次点 Tab 后重算一遍，把 Router 的选中推回标签栏。
struct ShellSelectionResync: ViewModifier {
    let taps: Int

    func body(content: Content) -> some View {
        content
    }
}

/// iOS 26 起标签栏随内容下滑收起、回滑展开（D10-826 ②）；更早的系统没有这个行为，保持经典样式。
struct ShellTabBarMinimize: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.tabBarMinimizeBehavior(.onScrollDown)
        } else {
            content
        }
    }
}

/// 基本模式页（设计稿 BasicMode；首页底稿按 HomeGuest-v3，app-basic-mode.md）：吸顶的搜索入口 +【设置】，下面是首页列表
/// （基本模式提示条 + 游客价值卡作为列表头部，由 RootView 经 `homeNativeHeader` 交给首页路由）。搜索行、头部、SDUI 同一 600 列（03 §10.4）。
struct BasicModeHomeView: View {
    let onSearch: () -> Void
    let onSettings: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            topBar
            RouteViewRegistry.view(for: RouteDestination(route: RoutePolicy.home, readonly: true))
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("home.root")
        .background(CouliColor.backgroundCanvas.ignoresSafeArea())
    }

    private var topBar: some View {
        HStack(spacing: CouliSpacing.s2) {
            HomeSearchEntry(identifier: "basic.search", onSearch: onSearch)
                .frame(maxWidth: .infinity)
            Button(action: onSettings) {
                CouliIconView(.settings)
                    .foregroundColor(CouliColor.textPrimary)
                    .couliHitTarget()
            }
            .buttonStyle(CouliPlainButtonStyle(cornerRadius: CouliRadius.small))
            .accessibilityLabel(Text(verbatim: ShellDraftTexts.settingsLabel))
            .accessibilityIdentifier("basic.settings")
            .accessibilityShowsLargeContentViewer()
            .couliProbe("basic.settings", role: "independent-hit")
        }
        .frame(maxWidth: HomeSearchRow.maxColumn)
        .couliProbe("home.column.search", role: "column")
        .padding(.horizontal, CouliSpacing.s4)
        .padding(.vertical, CouliSpacing.s2)
        .frame(maxWidth: .infinity)
        // 与首页吸顶搜索行同一字号上限（AX3，正文约 235%；更大档按 03 §10.4 导航元素封顶 + 大内容查看器）
        .dynamicTypeSize(...HomeSearchRow.maxTypeSize)
        .fixedSize(horizontal: false, vertical: true)
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
