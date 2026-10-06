import SwiftUI
import UIKit

/// 商品卡上的一个优惠标签。
public struct ProductCardTag: Sendable, Hashable {
    public let text: String
    public let style: Style

    public enum Style: Sendable, Hashable {
        /// 有券、预售、规格以下单页为准等：白底描边。
        case outline
        /// 规格待确认、标题显示为…：中性底 + 信息图标。
        case info
    }

    public init(_ text: String, style: Style = .outline) {
        self.text = text
        self.style = style
    }
}

/// 商品卡的内容。文字类字段（平台名、标题、按钮动词、说明句）由调用方从字典与接口给；
/// 价格与返利用 `PriceTagModel` / `RebateTagModel` / `EstNetModel` 的结果。
public struct ProductCardData: Sendable {
    public var platformName: String
    public var title: String
    /// 优惠标签（预售标签由 `price.presaleLabel` 自动放在最前，不用重复给）。
    public var tags: [ProductCardTag]
    public var price: PriceTagContent
    public var rebate: RebateTagContent
    public var estNet: String?
    public var estNetAccessibility: String?
    /// 副行里的额外说明（如「规格以下单页为准」），排在券前 / 无券之后、预售说明之前（GUIDE §7.2.1）。
    public var notes: [String]
    /// 比价区间时的「以结算为准」（底行左侧）；单一金额时为 nil。
    public var settlementNote: String?
    /// 购买按钮动词（cta.text_key 的文案）。
    public var buyBase: String
    public var amountHidden: Bool
    /// i 图标展开的口径说明全文（disclaimer_keys 对应的文案）。
    public var disclaimer: String
    /// i 图标按钮的读屏名称。
    public var disclaimerButtonLabel: String

    public init(
        platformName: String,
        title: String,
        tags: [ProductCardTag] = [],
        price: PriceTagContent,
        rebate: RebateTagContent,
        estNet: String? = nil,
        estNetAccessibility: String? = nil,
        notes: [String] = [],
        settlementNote: String? = nil,
        buyBase: String,
        amountHidden: Bool = false,
        disclaimer: String,
        disclaimerButtonLabel: String
    ) {
        self.platformName = platformName
        self.title = title
        self.tags = tags
        self.price = price
        self.rebate = rebate
        self.estNet = estNet
        self.estNetAccessibility = estNetAccessibility
        self.notes = notes
        self.settlementNote = settlementNote
        self.buyBase = buyBase
        self.amountHidden = amountHidden
        self.disclaimer = disclaimer
        self.disclaimerButtonLabel = disclaimerButtonLabel
    }

    var allTags: [ProductCardTag] {
        (price.presaleLabel.map { [ProductCardTag($0)] } ?? []) + tags
    }

    /// 金额未知（amount_unknown）：不显示任何价格与返利金额，只显示「可返利，金额以订单为准」（BR-PRICE-08）。
    var hidesPrice: Bool {
        rebate.kind == .unknown
    }

    /// 价格口径 i 按钮（BR-PRICE-03「单卡 i 图标」）是否显示：跟着价格走，与返利标签是否显示无关
    /// （暂无返利、金额隐藏时照样保留）；卡上没有价格（金额未知）或没有说明全文时不显示。
    static func showsDisclaimerButton(_ data: ProductCardData) -> Bool {
        !data.hidesPrice && !data.disclaimer.isEmpty
    }

    var subLines: [(text: String, spoken: String)] {
        if hidesPrice {
            return notes.map { ($0, $0) }
        }
        var lines: [(String, String)] = [
            (price.subLine ?? PriceTerms.noCoupon, price.subLineAccessibilityText ?? PriceTerms.noCoupon),
        ]
        lines += notes.map { ($0, $0) }
        if price.presaleLabel != nil {
            lines.append((PriceTerms.presalePriceNote, PriceTerms.presalePriceNote))
        }
        if let estNet = EstNetLine.visibleText(estNet, rebate: rebate, amountHidden: amountHidden) {
            lines.append((estNet, estNetAccessibility ?? estNet))
        }
        return lines
    }
}

/// 商品卡布局。
public enum ProductCardLayout: Sendable {
    /// 搜索结果列表卡（GUIDE §7.2.1 定稿写法，主价 22）。
    case list
    /// AI 结果卡（主价 17，口径按钮在右上角，底行只有按钮）。
    case agent
}

/// 列表商品卡（GUIDE §7.2.1）：左图右文；标题前 PlatformBadge；优惠标签行；价格行「口径词 + 主价 + RebateTag」，
/// 放不下时 RebateTag 整块换行；副行；底行左口径说明、右 BuyButton，放不下时按钮整块换行靠右。
/// 不缩字号、不截断金额（标题可两行截断）。
public struct ProductCard<ImageContent: View>: View {
    private let data: ProductCardData
    private let layout: ProductCardLayout
    private let image: ImageContent
    private let onBuy: () -> Void
    @State private var disclaimerExpanded = false
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    public init(
        _ data: ProductCardData,
        layout: ProductCardLayout = .list,
        onBuy: @escaping () -> Void,
        @ViewBuilder image: () -> ImageContent
    ) {
        self.data = data
        self.layout = layout
        self.onBuy = onBuy
        self.image = image()
    }

    /// 辅助字号档（≈200% 起）：价格区（标签、价格、返利、副行）移出右栏、占整卡宽，金额整段不拆。
    private var priceAreaFullWidth: Bool {
        dynamicTypeSize >= .accessibility1
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: CouliSpacing.s2) {
            ImageLeadingLayout(spacing: CouliSpacing.s3) {
                ProductImageFrame(side: CouliGuideMetric.listImage) { image }
                VStack(alignment: .leading, spacing: CouliSpacing.s1) {
                    BadgedTitle(platform: data.platformName, title: data.title, style: .footnote, lineLimit: 2)
                        .padding(
                            .trailing,
                            layout == .agent && ProductCardData.showsDisclaimerButton(data)
                                ? CouliSpacing.s6 + CouliSpacing.s1 : 0
                        )
                    if !priceAreaFullWidth {
                        priceArea
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if priceAreaFullWidth {
                priceArea
            }
            bottomRow
            if disclaimerExpanded, ProductCardData.showsDisclaimerButton(data) {
                Text(verbatim: data.disclaimer)
                    .couliFont(.caption)
                    .foregroundColor(CouliColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .couliCard(padding: CouliSpacing.s3)
        .overlay(alignment: .topTrailing) {
            if layout == .agent, ProductCardData.showsDisclaimerButton(data) {
                DisclaimerInfoButton(isExpanded: $disclaimerExpanded, accessibilityLabel: data.disclaimerButtonLabel)
                    .padding(CouliSpacing.s1)
            }
        }
    }

    private var priceArea: some View {
        VStack(alignment: .leading, spacing: CouliSpacing.s1) {
            if !data.allTags.isEmpty {
                TagRow(tags: data.allTags)
            }
            CouliFlowLayout(horizontalSpacing: CouliSpacing.s2, verticalSpacing: CouliSpacing.s1) {
                if !data.hidesPrice {
                    PriceTag(data.price, size: layout == .list ? .list : .compact)
                }
                if !data.amountHidden {
                    RebateTag(data.rebate, placement: .list)
                }
            }
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(data.subLines.enumerated()), id: \.offset) { _, line in
                    SegmentedLine(text: line.text, spoken: line.spoken, style: .caption)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var bottomRow: some View {
        CouliFlowLayout(horizontalSpacing: CouliSpacing.s2, verticalSpacing: CouliSpacing.s1) {
            if layout == .list {
                let note = data.amountHidden ? nil : data.settlementNote
                let showsInfo = ProductCardData.showsDisclaimerButton(data)
                if note != nil || showsInfo {
                    HStack(spacing: 0) {
                        if let note {
                            Text(verbatim: note)
                                .couliFont(.caption)
                                .foregroundColor(CouliColor.textSecondary)
                                .fixedSize()
                        }
                        if showsInfo {
                            DisclaimerInfoButton(
                                isExpanded: $disclaimerExpanded,
                                accessibilityLabel: data.disclaimerButtonLabel
                            )
                            // 视觉上贴近说明文字（设计稿 margin-left: -6），命中区不变。
                            .padding(.leading, -(CouliSpacing.s2 - CouliSpacing.s1 / 2))
                        }
                    }
                    // 让 44 高的按钮不撑开左侧视觉（设计稿 margin: -11px 0）。
                    .padding(.leading, note == nil ? -CouliSpacing.s3 : 0)
                }
            }
            BuyButton(base: data.buyBase, rebate: data.rebate, amountHidden: data.amountHidden, context: buyContext,
                      action: onBuy)
                // 按钮比整行还宽时文字在按钮内折行（不截断）。
                .fixedSize(horizontal: false, vertical: true)
                .couliFlowPushTrailing()
        }
        // 不加 minHeight 外框：外框在有高度提议时会把换行后的两行压回一行高（按钮与口径按钮本身已是 44 高）。
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var buyContext: BuyButtonContext {
        layout == .agent ? .agent : .list
    }
}

public extension ProductCard where ImageContent == EmptyView {
    /// 无图（占位底）。
    init(_ data: ProductCardData, layout: ProductCardLayout = .list, onBuy: @escaping () -> Void) {
        self.init(data, layout: layout, onBuy: onBuy) { EmptyView() }
    }
}

// MARK: - 共用小件

/// 商品图容器：占位底 + 装饰描边 + 小圆角；列表小图是装饰（读屏忽略，标题承载名称）。
struct ProductImageFrame<Content: View>: View {
    let side: CGFloat?
    @ViewBuilder let content: Content

    var body: some View {
        RoundedRectangle(cornerRadius: CouliRadius.small, style: .continuous)
            .fill(CouliColor.backgroundPlaceholder)
            .overlay(content)
            .overlay(
                RoundedRectangle(cornerRadius: CouliRadius.small, style: .continuous)
                    .strokeBorder(CouliColor.borderSubtle, lineWidth: CouliComponentMetric.controlBorderWidth)
            )
            .clipShape(RoundedRectangle(cornerRadius: CouliRadius.small, style: .continuous))
            .modifier(ImageSizing(side: side))
            .accessibilityHidden(true)
    }
}

private struct ImageSizing: ViewModifier {
    let side: CGFloat?

    func body(content: Content) -> some View {
        if let side {
            content.frame(width: side, height: side)
        } else {
            SquareLayout { content }
        }
    }
}

/// 左图右文：左边按理想尺寸，右边拿剩下的确切宽度，高取两者较高（不经过 HStack 的弹性协商，
/// 大字号时右栏高度与实际排版一致，不会与下方底行重叠）。
struct ImageLeadingLayout: Layout {
    let spacing: CGFloat

    private func sizes(_ width: CGFloat?, _ subviews: Subviews) -> (CGSize, CGSize) {
        guard subviews.count == 2 else {
            return (.zero, .zero)
        }
        let lead = subviews[0].sizeThatFits(.unspecified)
        let restWidth = width.map { max($0 - lead.width - spacing, 0) }
        let rest = subviews[1].sizeThatFits(ProposedViewSize(width: restWidth, height: nil))
        return (lead, CGSize(width: restWidth ?? rest.width, height: rest.height))
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache _: inout ()) -> CGSize {
        let (lead, rest) = sizes(proposal.width, subviews)
        return CGSize(width: lead.width + spacing + rest.width, height: max(lead.height, rest.height))
    }

    func placeSubviews(in bounds: CGRect, proposal _: ProposedViewSize, subviews: Subviews, cache _: inout ()) {
        let (lead, rest) = sizes(bounds.width, subviews)
        guard subviews.count == 2 else {
            return
        }
        subviews[0].place(at: bounds.origin, anchor: .topLeading, proposal: ProposedViewSize(lead))
        subviews[1].place(
            at: CGPoint(x: bounds.minX + lead.width + spacing, y: bounds.minY),
            anchor: .topLeading,
            proposal: ProposedViewSize(rest)
        )
    }
}

/// 网格卡图片：宽取提议宽度，高按设计稿 157×132 的比例（GUIDE §6；`aspectRatio` 在未定高度的提议下会塌成 0 高）。
private struct SquareLayout: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews _: Subviews, cache _: inout ()) -> CGSize {
        let side = proposal.width ?? CouliGuideMetric.listImage
        return CGSize(width: side, height: side * CouliGuideMetric.gridImageAspect)
    }

    func placeSubviews(in bounds: CGRect, proposal _: ProposedViewSize, subviews: Subviews, cache _: inout ()) {
        for subview in subviews {
            subview.place(at: bounds.origin, anchor: .topLeading, proposal: ProposedViewSize(bounds.size))
        }
    }
}

/// 优惠标签行：放不下就换行，不删标签。
struct TagRow: View {
    let tags: [ProductCardTag]

    var body: some View {
        CouliFlowLayout(horizontalSpacing: CouliSpacing.s1, verticalSpacing: CouliSpacing.s1) {
            ForEach(tags, id: \.self) { tag in
                CouliTag(tag.text, style: tag.style == .info ? .neutralInfo : .outline)
            }
        }
    }
}

/// 标题前放平台来源标签（行内，和标题同一段文字一起换行）。读屏合为一项、来源在前（adaptation-a11y-spec §8）。
public struct BadgedTitle: View {
    private let platform: String
    private let title: String
    private let style: CouliTextStyle
    private let weight: Font.Weight
    private let lineLimit: Int?
    @ScaledMetric private var fontSize: CGFloat
    @Environment(\.displayScale) private var displayScale
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    public init(
        platform: String,
        title: String,
        style: CouliTextStyle,
        weight: Font.Weight = .regular,
        lineLimit: Int?
    ) {
        self.platform = platform
        self.title = title
        self.style = style
        self.weight = weight
        self.lineLimit = lineLimit
        _fontSize = ScaledMetric(wrappedValue: style.baseSize, relativeTo: style.relativeTo)
    }

    public var body: some View {
        let badge = renderBadge()
        // 标签在这一行的行框内上下居中（设计稿 vertical-align: top，高 20 落在 21 的行高里）。
        let font = CouliFontMetrics.font(fontSize)
        let offset = (font.ascender + font.descender - badge.size.height) / 2
        (Text(Image(uiImage: badge)).baselineOffset(offset) + Text(verbatim: " " + title))
            .couliFont(style, weight: weight)
            .foregroundColor(CouliColor.textPrimary)
            .lineLimit(lineLimit)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: platform + PriceTerms.spokenPause + title))
            .accessibilityAddTraits(.isStaticText)
    }

    @MainActor
    private func renderBadge() -> UIImage {
        let renderer = ImageRenderer(
            content: PlatformBadge(platform).environment(\.dynamicTypeSize, dynamicTypeSize)
        )
        renderer.scale = displayScale
        return renderer.uiImage ?? UIImage()
    }
}
