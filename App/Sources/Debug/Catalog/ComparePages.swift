#if DEBUG
import DesignSystem
import Generated
import SwiftUI

/// 对照页：按设计画板的同一内容与状态拼出来，逐张截图比对（DS-01 §5）。
/// 搜索头部、价格走势折叠行、个人信息卡不是本任务的组件，这里用令牌简单拼出占位，只为对齐版面。
enum ComparePage: String, CaseIterable, Identifiable {
    case search = "Search"
    case productCardStress = "ProductCardStress"
    case product = "Product"
    case wallet = "Wallet"
    case me = "Me"
    case searchEmpty = "SearchEmpty"

    var id: String {
        rawValue
    }
}

struct ComparePageView: View {
    let page: ComparePage
    /// 截图用：滚动到第几段（0 起）。
    var section: Int = 0

    var body: some View {
        switch page {
        case .search: SearchCompare(section: section)
        case .productCardStress: StressCompare(section: section)
        case .product: ProductCompare()
        case .wallet: WalletCompare()
        case .me: MeCompare(section: section)
        case .searchEmpty: SearchEmptyCompare(section: section)
        }
    }
}

// MARK: - 共用

struct PageScroll<Content: View>: View {
    let section: Int
    let content: Content

    init(section: Int, @ViewBuilder content: () -> Content) {
        self.section = section
        self.content = content()
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: CouliSpacing.s3) {
                    content
                }
                .padding(.horizontal, CouliSpacing.s4)
                .padding(.vertical, CouliSpacing.s4)
            }
            .onAppear {
                // 0 不滚；1–9 让该锚点贴顶；10 起让该锚点贴底（截长卡的下半部分）。
                if section > 0 {
                    proxy.scrollTo(section, anchor: section >= 10 ? .bottom : .top)
                }
            }
        }
        .background(CouliColor.backgroundCanvas.ignoresSafeArea())
    }
}

struct Anchor: View {
    let id: Int

    var body: some View {
        Color.clear.frame(height: 0).id(id)
    }
}

/// 搜索页头部（APP-06 的页面内容，这里只按画板拼出外观）。
private struct SearchHeaderMock: View {
    let query: String
    /// 价格筛选（券后区间，分）；nil 为未选。金额由格式化组件同时出显示与读屏文字。
    var priceRange: (minFen: Int64, maxFen: Int64)?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: CouliSpacing.s2) {
                CouliIconView(.back).couliHitTarget().accessibilityLabel(Text(verbatim: CatalogText.back))
                HStack(spacing: CouliSpacing.s2) {
                    CouliIconView(.search).foregroundColor(CouliColor.textSecondary)
                    Text(verbatim: query).couliFont(.body).lineLimit(1)
                    Spacer(minLength: 0)
                    CouliIconView(.close, size: CouliSpacing.s4)
                        .foregroundColor(CouliColor.textSecondary)
                        .padding(CouliSpacing.s1)
                        .background(Circle().fill(CouliColor.backgroundMuted))
                        .couliHitTarget()
                }
                .padding(.leading, CouliSpacing.s3)
                .frame(minHeight: CouliHitTarget.minimum)
                .overlay(RoundedRectangle(cornerRadius: CouliRadius.button).strokeBorder(CouliColor.borderControl))
                Text(verbatim: "搜索")
                    .couliFont(.body, weight: .couliSemibold)
                    .foregroundColor(CouliColor.textInverse)
                    .padding(.horizontal, CouliSpacing.s3)
                    .frame(minHeight: CouliHitTarget.minimum)
                    .background(RoundedRectangle(cornerRadius: CouliRadius.button).fill(CouliColor.brandPrimary))
            }
            .padding(.leading, CouliSpacing.s1)
            .padding(.trailing, CouliSpacing.s4)
            .padding(.bottom, CouliSpacing.s2)
            ScrollView(.horizontal, showsIndicators: false) { HStack(spacing: CouliSpacing.s6) {
                ForEach([CatalogText.taobao, CatalogText.jd, CatalogText.pdd], id: \.self) { name in
                    let selected = name == CatalogText.taobao
                    Text(verbatim: name)
                        .couliFont(.body, weight: selected ? .couliSemibold : .regular)
                        .foregroundColor(selected ? CouliColor.brandEmphasis : CouliColor.textSecondary)
                        .frame(minHeight: CouliHitTarget.minimum)
                        .overlay(alignment: .bottom) {
                            Rectangle().fill(selected ? CouliColor.brandPrimary : .clear).frame(height: 2)
                        }
                }
            }
            .padding(.horizontal, CouliSpacing.s4)
            }
            Rectangle().fill(CouliColor.borderSubtle).frame(height: 1)
            ScrollView(.horizontal, showsIndicators: false) { HStack(spacing: CouliSpacing.s5) {
                ForEach(["综合", "销量", "券后价从低到高", "返利从高到低"], id: \.self) { name in
                    Text(verbatim: name)
                        .couliFont(.footnote, weight: name == "综合" ? .couliSemibold : .regular)
                        .foregroundColor(name == "综合" ? CouliColor.textPrimary : CouliColor.textSecondary)
                        .frame(minHeight: CouliHitTarget.minimum)
                        .fixedSize()
                }
            }
            .padding(.horizontal, CouliSpacing.s4)
            }
            ScrollView(.horizontal, showsIndicators: false) { HStack(spacing: CouliSpacing.s2) {
                chip("只看有券", selected: false)
                if let priceRange {
                    chip(
                        PriceTerms.afterCoupon + " " + CouliFormat.money(fen: priceRange.minFen)
                            + PriceTerms.rangeDash + CouliFormat.money(fen: priceRange.maxFen),
                        selected: true,
                        spoken: PriceTerms.afterCoupon + " " + CouliFormat.moneySpoken(fen: priceRange.minFen)
                            + PriceTerms.spokenRangeTo + " " + CouliFormat.moneySpoken(fen: priceRange.maxFen)
                    )
                } else {
                    chip("价格区间", selected: false)
                }
            }
            .padding(.horizontal, CouliSpacing.s4)
            }
            .padding(.bottom, CouliSpacing.s2)
        }
        .background(CouliColor.backgroundSurface)
        .overlay(alignment: .bottom) { Rectangle().fill(CouliColor.borderSubtle).frame(height: 1) }
    }

    private func chip(_ text: String, selected: Bool, spoken: String? = nil) -> some View {
        HStack(spacing: CouliSpacing.s1) {
            Text(verbatim: text).couliFont(.caption, weight: selected ? .couliSemibold : .regular)
            if text != "只看有券" {
                CouliIconView(.chevronDown, size: CouliSpacing.s4, relativeTo: .caption)
            }
        }
        .foregroundColor(selected ? CouliColor.brandEmphasis : CouliColor.textPrimary)
        .padding(.horizontal, CouliSpacing.s3)
        .frame(minHeight: CouliSpacing.s8)
        .background(Capsule().fill(selected ? CouliColor.brandSubtle : CouliColor.backgroundSurface))
        .overlay(Capsule().strokeBorder(selected ? .clear : CouliColor.borderSubtle))
        .frame(minHeight: CouliHitTarget.minimum)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: spoken ?? text))
    }
}

// MARK: - Search

private struct SearchCompare: View {
    let section: Int

    var body: some View {
        VStack(spacing: 0) {
            SearchHeaderMock(query: "纯牛奶")
            PageScroll(section: section) {
                ProductCard(CatalogSample.searchMilk) {}
                ProductCard(CatalogSample.searchMilkSpec) {}
                Anchor(id: 1)
                ProductCard(CatalogSample.searchMilkPresale) {}
                // 列表里有无券卡 → 用 price_basis.general（BR-PRICE-03 细则 2026-10-06）。
                DisclaimerFooter(lines: [
                    .init(CatalogText.priceBasisGeneral),
                    .init(PriceTerms.settlementNote),
                ])
            }
        }
    }
}

// MARK: - ProductCardStress

private struct StressCompare: View {
    let section: Int

    var body: some View {
        VStack(spacing: 0) {
            SearchHeaderMock(query: "纯牛奶")
            PageScroll(section: section) {
                heading("按钮四种情况（GUIDE §7.2.1；商品与金额为样例）")
                heading("① 单一金额：按钮带「· 预估返 ¥x」")
                ProductCard(CatalogSample.stressSingle) {}
                heading("② 区间（淘宝比价）：按钮只写动词，区间留在返利标签里")
                ProductCard(CatalogSample.stressRange) {}
                Anchor(id: 1)
                heading("③ 无返利：不显示返利标签与预估返后，按钮「去购买（无返利）」")
                ProductCard(CatalogSample.stressNoRebate) {}
                heading("④ 降级：320 宽屏（卡片内容宽 264）")
                ProductCard(CatalogSample.stressNarrow) {}
                    .frame(width: 288)
                Anchor(id: 12)
                Anchor(id: 2)
                heading("列表卡（搜索、AI 结果同款）：有券、多标签、超长标题")
                ProductCard(CatalogSample.stressLongTitle) {}
                heading("预售、无券")
                ProductCard(CatalogSample.stressPresaleNoCoupon) {}
                Anchor(id: 3)
                heading("无券、长规格（京东）")
                ProductCard(CatalogSample.stressJdSpec) {}
                heading("拼多多有券、大金额")
                ProductCard(CatalogSample.stressPdd) {}
                Anchor(id: 4)
                heading("首页网格卡：大金额、预售与无券")
                ProductCardGrid([CatalogSample.gridCoffee, CatalogSample.gridShelf])
                Anchor(id: 5)
                heading("合法最大长度：列表卡")
                ProductCard(CatalogSample.stressMax) {}
                Anchor(id: 15)
                heading("列表商品卡极值（搜索卡，主价 22px）")
                ProductCard(CatalogSample.stressExtreme) {}
                Anchor(id: 16)
                Anchor(id: 6)
                heading("列表商品卡极值（AI 结果卡，主价 17px）")
                ProductCard(CatalogSample.stressExtreme, layout: .agent) {}
                heading("合法最大长度：首页网格卡")
                ProductCardGrid([CatalogSample.gridMaxRange, CatalogSample.gridMaxSingle])
                DisclaimerFooter(lines: [.init(CatalogText.priceBasisGeneral), .init(PriceTerms.settlementNote)])
            }
        }
    }

    private func heading(_ text: String) -> some View {
        Text(verbatim: text)
            .couliFont(.footnote, weight: .couliSemibold)
            .foregroundColor(CouliColor.textPrimary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Product

private struct ProductCompare: View {
    var body: some View {
        VStack(spacing: 0) {
            NavBar(title: "商品详情", backLabel: CatalogText.back)
            ScrollView {
                VStack(spacing: CouliSpacing.s3) {
                    RoundedRectangle(cornerRadius: CouliRadius.card)
                        .fill(CouliColor.backgroundPlaceholder)
                        .overlay(RoundedRectangle(cornerRadius: CouliRadius.card).strokeBorder(CouliColor.borderSubtle))
                        .aspectRatio(358.0 / 264.0, contentMode: .fit)
                        .accessibilityElement()
                        .accessibilityLabel(Text(verbatim: "商品图：全脂纯牛奶 250ml × 24 盒"))
                    ProductDetailHeader(CatalogSample.detailMilk, fetchedAt: "10:00", shopName: "乳品生活旗舰店")
                    HStack(spacing: CouliSpacing.s3) {
                        CouliIconView(.trend)
                        Text(verbatim: "近 30 天券后价").couliFont(.body, weight: .couliMedium)
                        Spacer()
                        CouliIconView(.chevronDown).foregroundColor(CouliColor.textSecondary)
                    }
                    .foregroundColor(CouliColor.textPrimary)
                    .frame(minHeight: CouliHitTarget.minimum)
                    .couliCard(padding: CouliSpacing.s4)
                    DisclaimerFooter(
                        lines: [
                            .init(CatalogText.priceBasis, icon: .info),
                            .init(CatalogText.settleMonthly, icon: .clock),
                        ],
                        style: .boxed
                    )
                }
                .padding(CouliSpacing.s4)
            }
            HStack(spacing: CouliSpacing.s2) {
                bottomIcon(.chat, "问问 AI")
                bottomIcon(.star, "收藏")
                BuyButton(
                    base: CatalogText.buyCoupon,
                    rebate: CatalogSample.detailMilk.rebate,
                    context: .detail,
                    size: .regular,
                    fillsWidth: true
                ) {}
            }
            .padding(.top, CouliSpacing.s3)
            .padding(.horizontal, CouliSpacing.s4)
            .padding(.leading, -CouliSpacing.s1)
            .background(
                CouliColor.backgroundSurface.ignoresSafeArea(edges: .bottom)
                    .overlay(alignment: .top) { Rectangle().fill(CouliColor.borderSubtle).frame(height: 1) }
            )
        }
        .background(CouliColor.backgroundCanvas.ignoresSafeArea())
    }

    private func bottomIcon(_ icon: CouliIcon, _ title: String) -> some View {
        VStack(spacing: CouliSpacing.s1 / 2) {
            CouliIconView(icon)
            Text(verbatim: title).couliFont(.caption)
        }
        .foregroundColor(CouliColor.textSecondary)
        .frame(minWidth: CouliComponentMetric.buttonMinHeight, minHeight: CouliComponentMetric.buttonMinHeight)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }
}

// MARK: - SearchEmpty

private struct SearchEmptyCompare: View {
    let section: Int

    var body: some View {
        VStack(spacing: 0) {
            SearchHeaderMock(query: "手冲咖啡滤纸 V60 02 型 100 张", priceRange: (1000, 2000))
            PageScroll(section: section) {
                EmptyState(
                    icon: .search,
                    title: "没有找到符合条件的商品",
                    message: "换个关键词，或放宽价格区间再试试"
                )
                VStack(alignment: .leading, spacing: CouliSpacing.s1) {
                    Text(verbatim: "看看淘宝的其他商品")
                        .couliFont(.footnote, weight: .couliSemibold)
                        .foregroundColor(CouliColor.textPrimary)
                    Text(verbatim: "淘宝推荐商品，不受当前关键词和价格区间限制")
                        .couliFont(.caption)
                        .foregroundColor(CouliColor.textSecondary)
                }
                .padding(.horizontal, CouliSpacing.s1)
                Anchor(id: 1)
                ProductCard(CatalogSample.emptyTissue) {}
                ProductCard(CatalogSample.emptyRice) {}
                DisclaimerFooter(lines: [.init(CatalogText.priceBasisGeneral), .init(CatalogText.rebateSettleNote)])
            }
        }
    }
}
#endif
