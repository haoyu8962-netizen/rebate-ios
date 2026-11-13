import SwiftUI
import UIKit

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
    private let onDisclaimer: (() -> Void)?
    private let disclaimerFocus: AccessibilityFocusState<Bool>.Binding?
    /// 点整卡（读屏双击整卡）的出口；给了就把卡内文字合成一个整卡读屏按钮（FU-IOS-A11Y-04），只留口径 i 与购买两个独立按钮。
    private let onOpen: (() -> Void)?
    /// 整卡读屏名（nil = `ProductCardSpeech.list(data)`）；调用方要在前后加卡外的状态（下架、比价原因）时传。
    private let spokenLabel: String?
    /// false（APP-11v-b 识别卡单张，HomeClipboardCard-v3）：不画卡底与内边距，直接排在半屏里；默认 true，其余调用方不变。
    private let framed: Bool
    @State private var disclaimerExpanded = false
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// - Parameters:
    ///   - onDisclaimer: 给了就由调用方打开口径说明弹层（SearchDisclaimerNote），i 按钮不在卡内展开。
    ///   - disclaimerFocus: i 按钮的读屏焦点绑定（弹层关闭后焦点回到这里，`couliDialog(restoreFocusTo:)`）。
    ///   - onOpen: 整卡打开详情（缺省 nil：读屏结构不变，各段文字各自一项）。点卡的手势仍由调用方挂（与以前一样），这里只给读屏。
    ///   - spokenLabel: 整卡读屏名（只在 `onOpen` 给了时用；nil 按 `ProductCardSpeech.list`）。
    public init(
        _ data: ProductCardData,
        layout: ProductCardLayout = .list,
        onBuy: @escaping () -> Void,
        onDisclaimer: (() -> Void)? = nil,
        disclaimerFocus: AccessibilityFocusState<Bool>.Binding? = nil,
        onOpen: (() -> Void)? = nil,
        spokenLabel: String? = nil,
        framed: Bool = true,
        @ViewBuilder image: () -> ImageContent
    ) {
        self.data = data
        self.layout = layout
        self.onBuy = onBuy
        self.onDisclaimer = onDisclaimer
        self.disclaimerFocus = disclaimerFocus
        self.onOpen = onOpen
        self.spokenLabel = spokenLabel
        self.framed = framed
        self.image = image()
    }

    private var disclaimerBinding: Binding<Bool> {
        guard let onDisclaimer else { return $disclaimerExpanded }
        return Binding(get: { false }, set: { _ in onDisclaimer() })
    }

    /// 辅助字号档（≈200% 起）：价格区（标签、价格、返利、副行）移出右栏、占整卡宽，金额整段不拆。
    private var priceAreaFullWidth: Bool {
        dynamicTypeSize >= .accessibility1
    }

    /// 卡内文字合进整卡一项（只读看得见的内容，D10-1248 ⑦）。
    private var summarized: Bool {
        onOpen != nil
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: CouliSpacing.s2) {
            ImageLeadingLayout(spacing: CouliSpacing.s3) {
                ProductImageFrame(side: CouliComponentMetric.listImage) { image }
                VStack(alignment: .leading, spacing: CouliSpacing.s1) {
                    BadgedTitle(
                        platform: data.platformName, platformCode: data.platformCode, title: data.title,
                        style: .footnote, lineLimit: 2
                    )
                    .accessibilityHidden(summarized)
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
            if disclaimerExpanded, onDisclaimer == nil, ProductCardData.showsDisclaimerButton(data) {
                Text(verbatim: data.disclaimer)
                    .couliFont(.caption)
                    .foregroundColor(CouliColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .background(summaryElement)
        .modifier(ProductCardFrame(framed: framed))
        .overlay(alignment: .topTrailing) {
            if layout == .agent, ProductCardData.showsDisclaimerButton(data) {
                DisclaimerInfoButton(isExpanded: disclaimerBinding, accessibilityLabel: data.disclaimerButtonLabel)
                    .couliOptionalFocus(disclaimerFocus)
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
                // 金额隐藏时显示「预估返 ****」，不整个隐藏（F-IOS-06）。价格不可用、平台返利未开放时不显示返利。
                if data.showsRebate {
                    RebateTag(data.rebate.hidingAmount(data.amountHidden), placement: .list)
                }
            }
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(data.subLines.enumerated()), id: \.offset) { _, line in
                    SegmentedLine(text: line.text, spoken: line.spoken, style: .caption)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityHidden(summarized)
    }

    private var bottomRow: some View {
        CouliFlowLayout(horizontalSpacing: CouliSpacing.s2, verticalSpacing: CouliSpacing.s1) {
            if layout == .list {
                let note = data.amountHidden || !data.showsRebate ? nil : data.settlementNote
                let showsInfo = ProductCardData.showsDisclaimerButton(data)
                if note != nil || showsInfo {
                    HStack(spacing: 0) {
                        if let note {
                            Text(verbatim: note)
                                .couliFont(.caption)
                                .foregroundColor(CouliColor.textSecondary)
                                .fixedSize()
                                .accessibilityHidden(summarized)
                        }
                        if showsInfo {
                            DisclaimerInfoButton(
                                isExpanded: disclaimerBinding,
                                accessibilityLabel: data.disclaimerButtonLabel
                            )
                            .couliOptionalFocus(disclaimerFocus)
                            // 视觉上贴近说明文字（设计稿 margin-left: -6），命中区不变。
                            .padding(.leading, -(CouliSpacing.s2 - CouliSpacing.s1 / 2))
                        }
                    }
                    // 让 44 高的按钮不撑开左侧视觉（设计稿 margin: -11px 0）。
                    .padding(.leading, note == nil ? -CouliSpacing.s3 : 0)
                }
            }
            BuyButton(base: data.buyBase, rebate: data.rebate, amountHidden: data.amountHidden, context: buyContext,
                      state: data.buyState, action: onBuy)
                // 按钮比整行还宽时文字在按钮内折行（不截断）。
                .fixedSize(horizontal: false, vertical: true)
                .couliFlowPushTrailing()
        }
        // 不加 minHeight 外框：外框在有高度提议时会把换行后的两行压回一行高（按钮与口径按钮本身已是 44 高）。
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 整卡读屏一项（同订单卡写法）：读「平台，商品名，标签，价格，返利，副行，结算说明」、按钮角色、双击打开详情；排在卡内第一项。
    @ViewBuilder private var summaryElement: some View {
        if let onOpen {
            Color.clear
                .accessibilityElement()
                .accessibilityLabel(Text(verbatim: spokenLabel ?? ProductCardSpeech.list(data)))
                .accessibilityAddTraits(.isButton)
                .accessibilitySortPriority(1)
                .accessibilityAction { onOpen() }
                .accessibilityIdentifier("product.card.summary")
        }
    }

    private var buyContext: BuyButtonContext {
        layout == .agent ? .agent : .list
    }
}

public extension ProductCard where ImageContent == EmptyView {
    /// 无图（占位底）。
    init(
        _ data: ProductCardData,
        layout: ProductCardLayout = .list,
        onBuy: @escaping () -> Void,
        onDisclaimer: (() -> Void)? = nil,
        disclaimerFocus: AccessibilityFocusState<Bool>.Binding? = nil
    ) {
        self.init(data, layout: layout, onBuy: onBuy, onDisclaimer: onDisclaimer, disclaimerFocus: disclaimerFocus) {
            EmptyView()
        }
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
        let side = proposal.width ?? CouliComponentMetric.listImage
        return CGSize(width: side, height: side * CouliPendingTokenMetric.gridImageAspect)
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
/// `isHeader`：详情页的「平台 + 商品名」是页面标题（A11yFocusProduct 第 10 项「平台、商品名，标题」，03 §10.5），
/// 读屏角色为标题，可用标题转子定位；列表卡里的不是。
public struct BadgedTitle: View {
    private let platform: String
    private let platformCode: String?
    private let title: String
    private let style: CouliTextStyle
    private let weight: Font.Weight
    private let lineLimit: Int?
    private let isHeader: Bool
    private let color: Color
    @ScaledMetric private var fontSize: CGFloat
    @Environment(\.displayScale) private var displayScale
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.colorScheme) private var colorScheme

    public init(
        platform: String,
        platformCode: String? = nil,
        title: String,
        style: CouliTextStyle,
        weight: Font.Weight = .regular,
        lineLimit: Int?,
        isHeader: Bool = false,
        color: Color = CouliColor.textPrimary
    ) {
        self.color = color
        self.platform = platform
        self.platformCode = platformCode
        self.title = title
        self.style = style
        self.weight = weight
        self.lineLimit = lineLimit
        self.isHeader = isHeader
        _fontSize = ScaledMetric(wrappedValue: style.baseSize, relativeTo: style.relativeTo)
    }

    public var body: some View {
        let badge = renderBadge()
        // 标签在这一行的行框内上下居中（设计稿 vertical-align: top，高 20 落在 21 的行高里）。
        let font = CouliFontMetrics.font(fontSize)
        let offset = (font.ascender + font.descender - badge.size.height) / 2
        (Text(Image(uiImage: badge)).baselineOffset(offset) + Text(verbatim: " " + title))
            .couliFont(style, weight: weight)
            .foregroundColor(color)
            .lineLimit(lineLimit)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: Self.accessibilityText(platform: platform, title: title)))
            .accessibilityAddTraits(Self.accessibilityTraits(isHeader: isHeader))
    }

    /// 合并朗读的文字：来源在前（「淘宝，标题」）。
    static func accessibilityText(platform: String, title: String) -> String {
        platform + PriceTerms.spokenPause + title
    }

    /// 读屏角色：详情标题为标题（isHeader），其余为静态文字。
    static func accessibilityTraits(isHeader: Bool) -> AccessibilityTraits {
        isHeader ? [.isStaticText, .isHeader] : .isStaticText
    }

    @MainActor
    private func renderBadge() -> UIImage {
        let renderer = ImageRenderer(
            content: PlatformBadge(platform, platformCode: platformCode)
                .environment(\.dynamicTypeSize, dynamicTypeSize)
                .environment(\.colorScheme, colorScheme)
        )
        renderer.scale = displayScale
        return renderer.uiImage ?? UIImage()
    }
}

/// 列表卡的卡底（白底圆角 16 + 卡片阴影 + 内边距 12）；`framed == false` 时只占满宽度。
private struct ProductCardFrame: ViewModifier {
    let framed: Bool

    func body(content: Content) -> some View {
        if framed {
            content.couliCard(padding: CouliSpacing.s3)
        } else {
            content.frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
