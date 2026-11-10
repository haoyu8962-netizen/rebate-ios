#if DEBUG
import DesignSystem
import Generated
import SwiftUI

/// 组件目录页标记。Release 制品扫描（tools/ci/release-scan.sh）查这个字符串，命中即阻断发布。
enum ComponentCatalogMarker {
    static let identifier = "COULI_DS_COMPONENT_CATALOG_7Q4XK2"
}

/// 截图用的启动参数：`-CouliCatalogPage <ComparePage 原名|Gallery> [-CouliCatalogSection <n>]`，
/// 启动后直接全屏打开该页（只在 Debug / Staging）。
enum CatalogLaunch {
    static var page: String? {
        UserDefaults.standard.string(forKey: "CouliCatalogPage")
    }

    static var section: Int {
        UserDefaults.standard.integer(forKey: "CouliCatalogSection")
    }

    /// `-CouliCatalogHidden 1`：对照页以「金额隐藏」状态打开（截图用）。
    static var amountHidden: Bool {
        UserDefaults.standard.bool(forKey: "CouliCatalogHidden")
    }
}

/// 组件目录（DS-01 §5）：从调试面板进入。主要状态一页摆开，对照页逐张对应设计画板。
struct ComponentCatalogView: View {
    var body: some View {
        List {
            Section {
                NavigationLink {
                    ComponentGallery()
                        .navigationTitle(Text(verbatim: "Gallery"))
                } label: {
                    Text(verbatim: "All components / states")
                }
                .accessibilityIdentifier("catalog.gallery")
            }
            Section {
                ForEach(ComparePage.allCases) { page in
                    NavigationLink {
                        ComparePageView(page: page)
                            .toolbar(.hidden, for: .navigationBar)
                    } label: {
                        Text(verbatim: page.rawValue)
                    }
                    .accessibilityIdentifier("catalog.compare.\(page.rawValue)")
                }
            } header: {
                Text(verbatim: "Design compare pages")
            }
        }
        .navigationTitle(Text(verbatim: "Component catalog"))
        .accessibilityIdentifier(ComponentCatalogMarker.identifier)
    }
}

/// 启动参数直达的全屏页。
struct CatalogLaunchView: View {
    let page: String
    let section: Int

    var body: some View {
        Group {
            if let compare = ComparePage(rawValue: page) {
                ComparePageView(page: compare, section: section)
            } else {
                NavigationStack {
                    ComponentGallery(section: section)
                }
            }
        }
        .accessibilityIdentifier(ComponentCatalogMarker.identifier)
    }
}

// MARK: - 全部组件与状态

struct ComponentGallery: View {
    var section: Int = 0
    @State private var toast: CouliToastMessage?
    @State private var showsDialog = false
    @State private var showsSheet = false
    @State private var showsNestedDialog = false
    // 弹层关闭后读屏焦点回到这些触发控件（R1-03）。
    @AccessibilityFocusState private var dialogTriggerFocused: Bool
    @AccessibilityFocusState private var sheetTriggerFocused: Bool
    @AccessibilityFocusState private var nestedTriggerFocused: Bool
    @State private var tab = ShellTab.home

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: CouliSpacing.s4) {
                    buttons.id(0)
                    buyButtons.id(1)
                    prices.id(2)
                    rebates.id(3)
                    badges.id(4)
                    cards.id(5)
                    wallet.id(6)
                    states.id(7)
                    navigation.id(8)
                }
                .padding(CouliSpacing.s4)
            }
            .onAppear {
                if section > 0 {
                    proxy.scrollTo(section, anchor: .top)
                }
            }
        }
        .background(CouliColor.backgroundCanvas.ignoresSafeArea())
        .couliToast($toast)
        .couliSheet(
            isPresented: showsSheet,
            dismissOnScrim: { showsSheet = false },
            restoreFocusTo: $sheetTriggerFocused,
            sheet: {
                CouliSheet(title: "授权说明", closeLabel: CatalogText.close, onClose: { showsSheet = false }, content: {
                    Text(verbatim: "半屏正文。点遮罩可关闭（普通半屏）。")
                        .couliFont(.footnote)
                }, actions: {
                    // 嵌套：半屏里再开弹窗，弹窗关闭后焦点回到这个按钮。
                    CouliButton("打开弹窗", kind: .secondary, fillsWidth: true) { showsNestedDialog = true }
                        .accessibilityFocused($nestedTriggerFocused)
                    CouliButton("知道了", fillsWidth: true) { showsSheet = false }
                })
            }
        )
        .couliDialog(isPresented: showsNestedDialog, restoreFocusTo: $nestedTriggerFocused) {
            CouliDialog(
                title: "嵌套弹窗",
                message: "关闭后读屏焦点回到半屏里的「打开弹窗」。",
                primary: CouliDialogAction("知道了") { showsNestedDialog = false }
            )
        }
        .couliDialog(isPresented: showsDialog, restoreFocusTo: $dialogTriggerFocused) {
            CouliDialog(
                title: "该商品当前暂无返利，继续购买？",
                message: "弹窗正文。遮罩不关闭，只能点按钮。",
                primary: CouliDialogAction("继续购买") { showsDialog = false },
                secondary: CouliDialogAction("再想想") { showsDialog = false }
            )
        }
    }

    private func title(_ text: String) -> some View {
        Text(verbatim: text)
            .couliFont(.footnote, weight: .couliSemibold)
            .foregroundColor(CouliColor.textSecondary)
            .padding(.top, CouliSpacing.s2)
    }

    private var buttons: some View {
        VStack(alignment: .leading, spacing: CouliSpacing.s3) {
            title("CouliButton")
            CouliFlowLayout(horizontalSpacing: CouliSpacing.s2, verticalSpacing: CouliSpacing.s2) {
                CouliButton("提现") {}
                CouliButton("提现", kind: .secondary) {}
                CouliButton("提现记录", kind: .text) {}
                CouliButton("提交中…", isLoading: true) {}
                CouliButton("提现", isEnabled: false) {}
            }
            CouliButton("通栏主按钮", fillsWidth: true) {}
        }
    }

    private var buyButtons: some View {
        VStack(alignment: .leading, spacing: CouliSpacing.s2) {
            title("BuyButton")
            let single = CatalogSample.stressSingle.rebate
            CouliFlowLayout(horizontalSpacing: CouliSpacing.s2, verticalSpacing: CouliSpacing.s2) {
                BuyButton(base: CatalogText.buyCoupon, rebate: single, context: .list) {}
                BuyButton(base: CatalogText.buyCoupon, rebate: CatalogSample.stressRange.rebate, context: .list) {}
                BuyButton(base: CatalogText.buyNoRebate, rebate: CatalogSample.stressNoRebate.rebate, context: .list) {}
                BuyButton(base: CatalogText.buy, rebate: CatalogSample.amountUnknown.rebate, context: .detail) {}
                BuyButton(base: CatalogText.buy, rebate: CatalogSample.loginRequired.rebate, context: .list) {}
                BuyButton(base: CatalogText.buy, rebate: single, amountHidden: true, context: .list) {}
                BuyButton(base: CatalogText.buy, rebate: single, context: .linkLanding) {}
                BuyButton(base: CatalogText.buy, rebate: single, context: .list, state: .loading) {}
                BuyButton(base: CatalogText.buy, rebate: single, context: .list, state: .disabled) {}
                BuyButton(
                    base: CatalogText.buy,
                    rebate: single,
                    context: .list,
                    state: .retryLater(CatalogText.retryLater)
                ) {}
            }
            BuyButton(base: CatalogText.buyCoupon, rebate: single, context: .detail, size: .regular,
                      fillsWidth: true) {}
        }
    }

    private var prices: some View {
        VStack(alignment: .leading, spacing: CouliSpacing.s3) {
            title("PriceTag · PriceSubLine · EstNetLine")
            ForEach(
                [CatalogSample.searchMilk, CatalogSample.stressSingle, CatalogSample.stressPdd,
                 CatalogSample.card(platform: .pdd, title: "", priceFen: 1990, basis: .normal, minFen: 10, maxFen: 10),
                 CatalogSample.searchMilkPresale, CatalogSample.stressMax],
                id: \.title
            ) { data in
                VStack(alignment: .leading, spacing: CouliSpacing.s1) {
                    CouliFlowLayout(horizontalSpacing: CouliSpacing.s2, verticalSpacing: CouliSpacing.s1) {
                        PriceTag(data.price)
                        if let presale = data.price.presaleLabel {
                            CouliTag(presale)
                        }
                    }
                    PriceSubLine(data.price)
                    EstNetLine(
                        data.estNet,
                        accessibilityText: data.estNetAccessibility,
                        rebate: data.rebate,
                        amountHidden: data.amountHidden
                    )
                }
            }
            PriceTag(CatalogSample.detailMilk.price, size: .large)
        }
    }

    private var rebates: some View {
        VStack(alignment: .leading, spacing: CouliSpacing.s2) {
            title("RebateTag（列表里「暂无返利」隐藏；详情照常显示）")
            CouliFlowLayout(horizontalSpacing: CouliSpacing.s2, verticalSpacing: CouliSpacing.s2) {
                RebateTag(CatalogSample.stressSingle.rebate)
                RebateTag(CatalogSample.stressRange.rebate)
                RebateTag(CatalogSample.stressMax.rebate)
                RebateTag(CatalogSample.stressNoRebate.rebate, placement: .detail)
                RebateTag(CatalogSample.amountUnknown.rebate)
                RebateTag(CatalogSample.loginRequired.rebate)
            }
            RebateTag(CatalogSample.detailMilk.rebate, placement: .detail, isLarge: true)
            title("DisclaimerFooter")
            DisclaimerFooter(lines: [.init(CatalogText.priceBasis), .init(PriceTerms.settlementNote)])
            DisclaimerFooter(
                lines: [.init(CatalogText.priceBasis, icon: .info), .init(CatalogText.settleMonthly, icon: .clock)],
                style: .boxed
            )
        }
    }

    private var badges: some View {
        VStack(alignment: .leading, spacing: CouliSpacing.s2) {
            title("PlatformBadge · CouliTag · MatchBadge · AiLabel")
            CouliFlowLayout(horizontalSpacing: CouliSpacing.s2, verticalSpacing: CouliSpacing.s2) {
                PlatformBadge(CatalogText.taobao, platformCode: Platform.taobao.rawValue)
                PlatformBadge(CatalogText.jd, platformCode: Platform.jd.rawValue)
                PlatformBadge(CatalogText.pdd, platformCode: Platform.pdd.rawValue)
                CouliTag(CatalogText.couponTag)
                CouliTag(PriceTerms.presale)
                CouliTag(PriceTerms.specNote)
                CouliTag(DefaultTexts.text("order_status_group.estimating") ?? "", style: .pending)
                CouliTag(DefaultTexts.text("order_status_group.credited") ?? "", style: .success)
                MatchBadge(DefaultTexts.text("agent.match.matched") ?? "", kind: .matched)
                MatchBadge(DefaultTexts.text("agent.match.relaxed") ?? "", kind: .relaxed)
                MatchBadge(DefaultTexts.text("agent.match.spec_unconfirmed") ?? "", kind: .specUnconfirmed)
                AiLabel("AI 生成")
            }
        }
    }

    private var cards: some View {
        VStack(alignment: .leading, spacing: CouliSpacing.s3) {
            title("ProductCard（列表 / AI / 网格 / 详情大卡）")
            ProductCard(CatalogSample.searchMilk) {}
            ProductCard(CatalogSample.emptyTissue, layout: .agent) {}
            ProductCard(CatalogSample.amountUnknown) {}
            ProductCard(CatalogSample.loginRequired) {}
            ProductCard(CatalogSample.card(
                platform: .taobao, title: "金额隐藏", priceFen: 2990, basis: .normal, minFen: 45, maxFen: 45,
                estNetFen: 2945, amountHidden: true
            )) {}
            ProductCardGrid([CatalogSample.gridCoffee, CatalogSample.gridShelf])
            // 网格卡暂无返利 / 金额隐藏：返利区不显示，价格口径 i 仍在价格行右侧。
            ProductCardGrid([
                CatalogSample.stressNoRebate,
                CatalogSample.card(
                    platform: .taobao, title: "金额隐藏", priceFen: 2990, basis: .normal, minFen: 45, maxFen: 45,
                    estNetFen: 2945, amountHidden: true
                ),
            ])
            ProductDetailHeader(CatalogSample.detailMilk, fetchedAt: "10:00", shopName: "乳品生活旗舰店")
        }
    }

    private var wallet: some View {
        VStack(alignment: .leading, spacing: CouliSpacing.s3) {
            title("WalletHeroCard · AmountGrid · EntryGrid")
            WalletHeroCard(title: "可提现余额", amountFen: 1234, withdrawTitle: "提现") {}
            // 金额隐藏：同一区域所有金额（含「其中…」）一律隐藏，读屏读「金额已隐藏」。
            WalletHeroCard(
                title: "可提现余额",
                amountFen: 1234,
                isHidden: true,
                toggleHiddenLabel: DefaultTexts.text("amount_mask.show"),
                withdrawTitle: "提现",
                onWithdraw: {},
                footer: {
                    HeroAmountRow(items: [
                        AmountGridItem(label: "冻结中", value: .amount(0)),
                        AmountGridItem(label: "已提现", value: .amount(500), note: AmountNote("其中今日 ", amountFen: 100)),
                    ], amountHidden: true)
                }
            )
            AmountGrid(items: [
                AmountGridItem(label: "预估返", value: .amount(269), isRebate: true),
                AmountGridItem(label: "实付金额", value: .amount(2990)),
            ], valueStyle: .body)
                .couliCard()
            // 零返利 / 暂无返利：常规文字色，不用返利橙、不带钟表（GUIDE §7.1）。
            AmountGrid(items: [
                AmountGridItem(label: "预估返", value: .range(minFen: 0, maxFen: 0), isRebate: true),
                AmountGridItem(label: "预估返", value: .amount(0), isRebate: true),
            ], valueStyle: .body)
                .couliCard()
            // 区间金额（订单数字格）：只在破折号处折行；隐藏时「****」、读屏「金额已隐藏」。
            AmountGrid(items: [
                AmountGridItem(label: "预估返", value: .range(minFen: 8_888_888, maxFen: 9_999_999), isRebate: true),
                AmountGridItem(label: "实付金额", value: .amount(12_345_678)),
            ], valueStyle: .body)
                .couliCard()
            AmountGrid(items: [
                AmountGridItem(label: "预估返", value: .range(minFen: 123, maxFen: 234), isRebate: true),
                AmountGridItem(label: "实付金额", value: .amount(2990)),
            ], valueStyle: .body, amountHidden: true)
                .couliCard()
            EntryGrid(title: "订单与钱包", items: [
                EntryGridItem(id: "orders", title: "我的订单", icon: .orders),
                EntryGridItem(id: "wallet", title: "钱包", icon: .wallet),
                EntryGridItem(id: "ledger", title: "余额流水", icon: .ledger),
                EntryGridItem(id: "claim", title: "找回订单", icon: .claim),
            ]) { _ in }
        }
    }
}

// 状态与导航两组（拆出 struct 主体以满足 type_body_length）。
extension ComponentGallery {
    private var states: some View {
        VStack(alignment: .leading, spacing: CouliSpacing.s3) {
            title("EmptyState · ErrorState · Skeleton · Toast · Dialog · Sheet")
            EmptyState(title: "没有找到符合条件的商品", message: "换个关键词，或放宽价格区间再试试")
                .couliCard()
            ErrorState(
                title: DefaultTexts.text("h5.load_failed") ?? "",
                retryTitle: DefaultTexts.text("external_page.retry") ?? ""
            ) {}
                .couliCard()
            ProductCardSkeleton(accessibilityLabel: "加载中")
            Toast(DefaultTexts.text("share_page.copy_tpwd.done") ?? "")
            CouliFlowLayout(horizontalSpacing: CouliSpacing.s2, verticalSpacing: CouliSpacing.s2) {
                // 连点同一个按钮 = 同文再提示；两个按钮交替 = 显示期间换内容；两种都重新播报（R1-05）。
                CouliButton("Toast", kind: .secondary) {
                    toast = CouliToastMessage(DefaultTexts.text("withdraw_detail.copied") ?? "")
                }
                CouliButton("Toast 2", kind: .secondary) {
                    toast = CouliToastMessage(DefaultTexts.text("share_page.copy_tpwd.done") ?? "")
                }
                CouliButton("Dialog", kind: .secondary) { showsDialog = true }
                    .accessibilityFocused($dialogTriggerFocused)
                CouliButton("Sheet", kind: .secondary) { showsSheet = true }
                    .accessibilityFocused($sheetTriggerFocused)
            }
        }
    }

    private var navigation: some View {
        VStack(alignment: .leading, spacing: CouliSpacing.s3) {
            title("NavBar · 标签栏（系统）")
            NavBar(title: "钱包", backLabel: CatalogText.back)
                .background(CouliColor.backgroundSurface)
            // 底栏是系统 TabView 的标签栏（D10-826），样例与外壳同一配置（TabShellView.Page / 品牌色 tint / iOS 26 滚动收起），
            // 不另画一套；占位页不进 Feature
            TabView(selection: $tab) {
                ForEach(ShellTab.allCases, id: \.self) { item in
                    CouliColor.backgroundSurface
                        .modifier(TabShellView<EmptyView>.Page(tab: item))
                }
            }
            .tint(CouliColor.brandPrimary)
            .modifier(ShellTabBarMinimize())
            .frame(height: 120)
        }
    }
}
#endif
