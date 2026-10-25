import SwiftUI
import UIKit

// 商品详情页主体的小件（APP-06v-a）：金额段与字号测量、主价行排法、返利大标签、状态胶囊、口径块。
// 测量编号（product.*）只在有测量接收方时上报（Release 没有接收方）。

// MARK: - 金额段

/// 详情金额排版的可用宽度（价格大卡内容宽；返利标签内再减去标签左右内边距）。nil = 还没量到，不封顶。
extension EnvironmentValues {
    @Entry var productAmountWidth: CGFloat?
}

/// 详情金额的字号测量（与 `CouliUnbreakableText` / `couliFont` 同一字体：系统字体、等宽数字、按 Dynamic Type 缩放）。
enum ProductDetailFit {
    /// 放不下时依次退到的字号档（nil = 跟随系统，不封顶）。
    static let caps: [DynamicTypeSize?] = [nil, .accessibility1, .xxxLarge, .large]

    static func uiStyle(_ style: CouliTextStyle) -> UIFont.TextStyle {
        switch style {
        case .caption: .caption1
        case .footnote: .footnote
        case .body: .body
        case .title: .title2
        case .heading: .title1
        case .display: .largeTitle
        }
    }

    static func uiWeight(_ weight: Font.Weight) -> UIFont.Weight {
        switch weight {
        case .bold: .bold
        case .semibold: .semibold
        case .medium: .medium
        default: .regular
        }
    }

    static func size(_ style: CouliTextStyle, at dynamicType: DynamicTypeSize) -> CGFloat {
        let traits = UITraitCollection(preferredContentSizeCategory: UIContentSizeCategory(dynamicType))
        return UIFontMetrics(forTextStyle: uiStyle(style)).scaledValue(for: style.baseSize, compatibleWith: traits)
    }

    /// 单行自然宽（不取整；与 `CouliUnbreakableText` 同一字体）。
    static func width(_ text: String, style: CouliTextStyle, weight: Font.Weight, monospacedDigits: Bool = true,
                      at dynamicType: DynamicTypeSize) -> CGFloat {
        let size = size(style, at: dynamicType)
        let font = monospacedDigits ? UIFont.monospacedDigitSystemFont(ofSize: size, weight: uiWeight(weight))
            : UIFont.systemFont(ofSize: size, weight: uiWeight(weight))
        return (text as NSString).size(withAttributes: [.font: font]).width
    }

    /// 两边按同一像素网格取整后比较（文字框向上取整到物理像素，可用宽向下取整），没有对称误差。
    static func fits(_ width: CGFloat, in available: CGFloat, scale: CGFloat) -> Bool {
        let grid = max(scale, 1)
        return (width * grid).rounded(.up) <= (available * grid).rounded(.down)
    }

    /// 第一个放得下的档（都放不下取最后一档 = 默认字号）；没有可用宽度时不封顶。
    /// `available` 必须来自不受内容撑宽的外层（页面视口 / 内容列宽），不能取被金额撑开的卡片宽（评审 r1 S1-1）。
    static func cap(_ text: String, style: CouliTextStyle, weight: Font.Weight, current: DynamicTypeSize,
                    room: (width: CGFloat, scale: CGFloat)?) -> DynamicTypeSize? {
        guard let room else { return nil }
        for cap in caps {
            let effective = cap.map { min($0, current) } ?? current
            if fits(width(text, style: style, weight: weight, at: effective), in: room.width, scale: room.scale) {
                return cap
            }
        }
        return .large
    }

    static func effective(_ cap: DynamicTypeSize?, current: DynamicTypeSize) -> DynamicTypeSize {
        cap.map { min($0, current) } ?? current
    }
}

/// 详情页的一段不可拆金额（主价、券前、券额、返利两端、预估返后）：单行、不截断、字号随系统放大。
/// 极端长金额在窄屏大字号下整段比可用宽还宽时，依次退到辅助字号第 1 档、超大档、默认档（不小于默认字号，不截断、不越出卡片；
/// 03 §10.4「放不下时换行、改纵向排列」之外的最后防线）。常规金额不受影响。
struct ProductDetailAmount: View {
    let text: String
    let style: CouliTextStyle
    let weight: Font.Weight
    let probeID: String?
    @Environment(\.dynamicTypeSize) private var dynamicType
    @Environment(\.productAmountWidth) private var available
    @Environment(\.displayScale) private var scale

    var body: some View {
        let cap = ProductDetailFit.cap(text, style: style, weight: weight, current: dynamicType,
                                       room: available.map { ($0, scale) })
        let natural = ProductDetailFit.width(text, style: style, weight: weight,
                                             at: ProductDetailFit.effective(cap, current: dynamicType))
        CouliUnbreakableText(
            text, size: style.baseSize, weight: weight, relativeTo: style.relativeTo, probeID: probeID,
            role: "amount-part", lineHeightMultiple: style.lineHeightMultiple, naturalWidth: natural
        )
        .dynamicTypeSize(...(cap ?? .accessibility5))
        // 封顶档变化时换一个实例重新上报测量（同一实例尺寸随环境变化时，背景里的几何读取不一定再报一次）
        .id(cap.map { "\($0)" } ?? "uncapped")
    }
}

/// 「口径词 + 金额」一段（「券前 ¥56.78」「· 券 ¥10」「预估返后 ¥45.55」）：放不下时只在词与金额之间折行，金额整段不拆。
struct ProductDetailLabeledAmount: View {
    let label: String
    let amount: String
    let style: CouliTextStyle
    let probeID: String

    var body: some View {
        CouliFlowLayout(horizontalSpacing: CouliSpacing.s1, verticalSpacing: 0) {
            if !label.isEmpty {
                Text(verbatim: label)
                    .couliFont(style)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ProductDetailAmount(text: amount, style: style, weight: .regular, probeID: probeID)
        }
    }

    /// 「券前 ¥56.78」→（「券前」，「¥56.78」）：最后一个空格前是口径词。没有空格时整段当金额。
    static func split(_ segment: String) -> (label: String, amount: String) {
        guard let space = segment.range(of: " ", options: .backwards) else {
            return ("", segment)
        }
        return (String(segment[..<space.lowerBound]), String(segment[space.upperBound...]))
    }
}

// MARK: - 主价行、返利标签、胶囊、口径块

/// 主价行排法：「口径词 + 主价」放得下时同一行、按首行基线对齐；放不下时口径词在上、主价在下（左对齐）。
struct ProductPriceRowLayout: Layout {
    let spacing: CGFloat

    private func inline(_ subviews: Subviews, width: CGFloat?) -> Bool {
        guard subviews.count == 2, let width else { return true }
        let total = subviews.map { $0.sizeThatFits(.unspecified).width }.reduce(0, +) + spacing
        return total <= width + 0.5
    }

    private func baseline(_ subview: LayoutSubview) -> CGFloat {
        subview.dimensions(in: .unspecified)[VerticalAlignment.firstTextBaseline]
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache _: inout ()) -> CGSize {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        if inline(subviews, width: proposal.width) {
            let ascent = subviews.map(baseline).max() ?? 0
            let descent = zip(subviews, sizes).map { $1.height - baseline($0) }.max() ?? 0
            let width = sizes.map(\.width).reduce(0, +) + spacing * CGFloat(max(sizes.count - 1, 0))
            return CGSize(width: width, height: ascent + descent)
        }
        return CGSize(width: sizes.map(\.width).max() ?? 0, height: sizes.map(\.height).reduce(0, +))
    }

    func placeSubviews(in bounds: CGRect, proposal _: ProposedViewSize, subviews: Subviews, cache _: inout ()) {
        if inline(subviews, width: bounds.width) {
            let ascent = subviews.map(baseline).max() ?? 0
            var cursor = bounds.minX
            for subview in subviews {
                let size = subview.sizeThatFits(.unspecified)
                subview.place(at: CGPoint(x: cursor, y: bounds.minY + ascent - baseline(subview)), anchor: .topLeading,
                              proposal: ProposedViewSize(size))
                cursor += size.width + spacing
            }
        } else {
            var top = bounds.minY
            for subview in subviews {
                let size = subview.sizeThatFits(.unspecified)
                subview.place(
                    at: CGPoint(x: bounds.minX, y: top),
                    anchor: .topLeading,
                    proposal: ProposedViewSize(size)
                )
                top += size.height
            }
        }
    }
}

/// 详情返利大标签（画板：返利浅底圆角 12、内边距 4 / 12；钟表 16 +「预估返」14/500 + 金额 22/600，区间只在破折号处折行）。
/// 暂无返利用中性色；金额未知、登录查看只显示文字（返利配色）。
struct ProductDetailRebateTag: View {
    let content: RebateTagContent
    @Environment(\.productAmountWidth) private var available

    var body: some View {
        let accent = content.usesRebateAccent
        CouliFlowLayout(horizontalSpacing: CouliSpacing.s1, verticalSpacing: 0) {
            HStack(spacing: CouliSpacing.s1) {
                if accent {
                    CouliIconView(.clock, size: CouliSpacing.s4, relativeTo: .footnote)
                }
                Text(verbatim: content.label ?? content.text)
                    .couliFont(.footnote, weight: .couliMedium)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !content.amountParts.isEmpty {
                CouliFlowLayout(horizontalSpacing: 0, verticalSpacing: 0) {
                    ForEach(Array(content.amountParts.enumerated()), id: \.offset) { index, part in
                        ProductDetailAmount(
                            text: part, style: .title, weight: .couliSemibold,
                            probeID: index == 0 ? "product.amount.rebate.min" : "product.amount.rebate.max"
                        )
                    }
                }
                .environment(\.productAmountWidth, available.map { $0 - CouliSpacing.s3 * 2 })
            }
        }
        .foregroundColor(accent ? CouliColor.rebateText : CouliColor.textSecondary)
        .padding(.horizontal, CouliSpacing.s3)
        .padding(.vertical, CouliSpacing.s1)
        .frame(minHeight: CouliSpacing.s8)
        .background(
            RoundedRectangle(cornerRadius: CouliRadius.button, style: .continuous)
                .fill(accent ? CouliColor.rebateBackground : CouliColor.backgroundMuted)
        )
        .couliProbe("product.rebateTag", role: "rebate-tag")
    }
}

/// 状态灰胶囊（画板「商品已下架」「这次被判为比价，没有返利」：高 32、左右 12、14 次文字、次要底、全圆角）。
public struct ProductStatusCapsule: View {
    private let text: String

    public init(_ text: String) {
        self.text = text
    }

    public var body: some View {
        Text(verbatim: text)
            .couliFont(.footnote)
            .foregroundColor(CouliColor.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, CouliSpacing.s3)
            .padding(.vertical, CouliSpacing.s1)
            .frame(minHeight: CouliSpacing.s8)
            .background(Capsule(style: .continuous).fill(CouliColor.backgroundMuted))
    }
}

// MARK: - 口径块

/// 详情口径块（BR-PRICE-03 详情常驻全文；画板：次要底圆角 16、内边距 12 / 16、行距 8；每行 16 图标 + 12 次文字）。
/// 图标由调用方按行给：口径句 i，入账说明钟表（§2.5）。
public struct ProductDetailDisclaimer: View {
    private let lines: [DisclaimerFooter.Line]
    @ScaledMetric(relativeTo: .caption) private var lineHeight: CGFloat = CouliTextStyle.caption.baseSize
        * CouliTextStyle.caption.lineHeightMultiple

    public init(lines: [DisclaimerFooter.Line]) {
        self.lines = lines
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: CouliSpacing.s2) {
            ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                HStack(alignment: .top, spacing: CouliSpacing.s2) {
                    CouliIconView(line.icon ?? .info, size: CouliGuideMetric.iconInline, relativeTo: .caption)
                        .couliProbe("product.disclaimer.icon.\(index)", role: "icon")
                        .frame(minHeight: lineHeight)
                    Text(verbatim: line.text)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .accessibilityElement(children: .combine)
            }
        }
        .couliFont(.caption)
        .foregroundColor(CouliColor.textSecondary)
        .padding(.horizontal, CouliSpacing.s4)
        .padding(.vertical, CouliSpacing.s3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: CouliRadius.card, style: .continuous)
                .fill(CouliColor.backgroundMuted)
        )
        .couliProbe("product.disclaimer", role: "block")
    }
}
