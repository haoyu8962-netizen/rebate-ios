import SwiftUI

// MARK: - 网格卡

/// 首页网格卡（GUIDE §6「窄卡返利标签」：钟表 + 预估返 + 信息按钮一行，完整金额另起一行，只在破折号处折行）。
/// 价格口径 i 按钮只跟着价格走（BR-PRICE-03「单卡 i 图标」）：有返利标签时放在返利标签那一行；
/// 返利不显示（暂无返利、金额隐藏）时放在价格行右侧；卡上没有价格（金额未知）时才不显示。
public struct ProductGridCard<ImageContent: View>: View {
    private let data: ProductCardData
    private let image: ImageContent
    @State private var disclaimerExpanded = false

    public init(_ data: ProductCardData, @ViewBuilder image: () -> ImageContent) {
        self.data = data
        self.image = image()
    }

    /// i 按钮放在哪里（纯逻辑，单测覆盖）。
    enum DisclaimerPlacement: Equatable {
        /// 返利标签行内（设计稿写法）。
        case inRebateRow
        /// 价格行右侧（返利标签不显示时）。
        case besidePrice
        /// 不显示（卡上没有价格）。
        case hidden
    }

    static func showsNarrowRebate(_ data: ProductCardData) -> Bool {
        data.rebate.kind != .none && !data.amountHidden
    }

    static func disclaimerPlacement(_ data: ProductCardData) -> DisclaimerPlacement {
        guard ProductCardData.showsDisclaimerButton(data) else {
            return .hidden
        }
        return showsNarrowRebate(data) ? .inRebateRow : .besidePrice
    }

    public var body: some View {
        let placement = Self.disclaimerPlacement(data)
        VStack(alignment: .leading, spacing: CouliSpacing.s2) {
            ProductImageFrame(side: nil) { image }
            BadgedTitle(platform: data.platformName, title: data.title, style: .footnote, lineLimit: 2)
            if !data.allTags.isEmpty {
                TagRow(tags: data.allTags)
            }
            HStack(alignment: .top, spacing: CouliSpacing.s1) {
                priceBlock
                if placement == .besidePrice {
                    Spacer(minLength: 0)
                    infoButton
                        .padding(.vertical, -CouliSpacing.s2)
                        .padding(.trailing, -CouliSpacing.s3)
                }
            }
            if Self.showsNarrowRebate(data) {
                narrowRebate(withInfo: placement == .inRebateRow)
            }
            if disclaimerExpanded, placement != .hidden {
                Text(verbatim: data.disclaimer)
                    .couliFont(.caption)
                    .foregroundColor(CouliColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .couliCard(padding: CouliSpacing.s3)
    }

    private var priceBlock: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !data.hidesPrice {
                PriceTag(data.price, size: .compact)
            }
            ForEach(
                Array(data.subLines.filter { $0.text != data.estNet }.enumerated()),
                id: \.offset
            ) { _, line in
                SegmentedLine(text: line.text, spoken: line.spoken, style: .caption)
            }
        }
    }

    private var infoButton: some View {
        DisclaimerInfoButton(isExpanded: $disclaimerExpanded, accessibilityLabel: data.disclaimerButtonLabel)
    }

    private func narrowRebate(withInfo: Bool) -> some View {
        let accent = data.rebate.usesRebateAccent
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: CouliSpacing.s1) {
                if accent {
                    CouliIconView(.clock, size: CouliGuideMetric.iconSmall, relativeTo: .caption)
                }
                Text(verbatim: data.rebate.label ?? data.rebate.text)
                    .couliFont(.caption)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                if withInfo {
                    infoButton
                        .foregroundColor(accent ? CouliColor.rebateText : CouliColor.textSecondary)
                        .padding(.vertical, -CouliSpacing.s3)
                        .padding(.trailing, -CouliSpacing.s3)
                }
            }
            .accessibilityElement(children: .contain)
            if !data.rebate.amountParts.isEmpty {
                CouliFlowLayout(horizontalSpacing: 0, verticalSpacing: 0) {
                    ForEach(Array(data.rebate.amountParts.enumerated()), id: \.offset) { _, part in
                        BreakableText(part, style: .footnote, weight: .couliSemibold)
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(verbatim: data.rebate.accessibilityText))
            }
        }
        .foregroundColor(accent ? CouliColor.rebateText : CouliColor.textSecondary)
        .padding(.horizontal, CouliSpacing.s3)
        .padding(.vertical, CouliSpacing.s2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: CouliRadius.button, style: .continuous)
                .fill(accent ? CouliColor.rebateBackground : CouliColor.backgroundMuted)
        )
    }
}

/// 网格卡两列排布；辅助字号档（≈200% 起）改单列，金额整段不拆。
public struct ProductCardGrid: View {
    private let items: [ProductCardData]
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    public init(_ items: [ProductCardData]) {
        self.items = items
    }

    private var rows: [[ProductCardData]] {
        stride(from: 0, to: items.count, by: 2).map { Array(items[$0..<min($0 + 2, items.count)]) }
    }

    public var body: some View {
        if dynamicTypeSize >= .accessibility1 {
            single
        } else {
            VStack(spacing: CouliSpacing.s3) {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    HStack(alignment: .top, spacing: CouliSpacing.s3) {
                        ForEach(Array(row.enumerated()), id: \.offset) { _, item in
                            ProductGridCard(item) { EmptyView() }
                        }
                        if row.count == 1 {
                            Color.clear.frame(maxWidth: .infinity)
                        }
                    }
                }
            }
        }
    }

    private var single: some View {
        VStack(spacing: CouliSpacing.s3) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                ProductGridCard(item) { EmptyView() }
            }
        }
    }
}

// MARK: - 详情大卡

/// 商品详情头部大卡（GUIDE §7.2「商品详情」）：大号主价 → 副行 → 大号返利标签（+「以结算为准」）→
/// 预估返后与取价时间 → 优惠标签 → 分隔线 → 平台来源 + 标题 → 店铺。
public struct ProductDetailHeader: View {
    private let data: ProductCardData
    private let fetchedAt: String?
    private let shopName: String?

    /// - Parameters:
    ///   - fetchedAt: 取价时间（已按 BR-TEXT-11 格式化的时间，如 `CouliFormat.timeListPast` 去掉日期词后的「10:00」）。
    ///   - shopName: 店铺名。
    public init(_ data: ProductCardData, fetchedAt: String? = nil, shopName: String? = nil) {
        self.data = data
        self.fetchedAt = fetchedAt
        self.shopName = shopName
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: CouliSpacing.s3) {
            if !data.hidesPrice {
                VStack(alignment: .leading, spacing: CouliSpacing.s1) {
                    PriceTag(data.price, size: .large)
                    PriceSubLine(data.price, style: .footnote)
                }
            }
            if !data.amountHidden {
                CouliFlowLayout(horizontalSpacing: CouliSpacing.s4, verticalSpacing: CouliSpacing.s1) {
                    RebateTag(data.rebate, placement: .detail, isLarge: true)
                    if let note = data.settlementNote, data.rebate.kind == .range {
                        Text(verbatim: note)
                            .couliFont(.footnote)
                            .foregroundColor(CouliColor.textSecondary)
                            .fixedSize()
                    }
                }
            }
            metaRow
            let notes = (data.price.presaleLabel != nil ? [PriceTerms.presalePriceNote] : []) + data.notes
            ForEach(notes, id: \.self) { note in
                Text(verbatim: note)
                    .couliFont(.footnote)
                    .foregroundColor(CouliColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !data.allTags.isEmpty {
                TagRow(tags: data.allTags)
            }
            Rectangle()
                .fill(CouliColor.borderSubtle)
                .frame(height: CouliComponentMetric.controlBorderWidth)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: CouliSpacing.s1) {
                BadgedTitle(
                    platform: data.platformName,
                    title: data.title,
                    style: .body,
                    weight: .couliSemibold,
                    lineLimit: nil
                )
                if let shopName {
                    Text(verbatim: shopName)
                        .couliFont(.footnote)
                        .foregroundColor(CouliColor.textSecondary)
                }
            }
        }
        .couliCard()
    }

    @ViewBuilder private var metaRow: some View {
        let estNet = EstNetLine.visibleText(data.estNet, rebate: data.rebate, amountHidden: data.amountHidden)
        let fetched = fetchedAt.map { PriceTerms.priceFetchedAt + " " + $0 }
        if estNet != nil || fetched != nil {
            CouliFlowLayout(horizontalSpacing: CouliSpacing.s4, verticalSpacing: 0) {
                EstNetLine(
                    estNet,
                    accessibilityText: data.estNetAccessibility,
                    rebate: data.rebate,
                    amountHidden: data.amountHidden,
                    style: .footnote
                )
                if let fetched {
                    Text(verbatim: fetched)
                        .couliFont(.footnote, monospacedDigits: true)
                        .foregroundColor(CouliColor.textSecondary)
                        .fixedSize()
                }
            }
        }
    }
}
