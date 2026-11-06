import SwiftUI

// MARK: - PriceTag

/// PriceTag 字号档。
public enum PriceTagSize: Sendable {
    /// 搜索列表卡：主价 22/700（title）。
    case list
    /// AI 卡、网格卡：主价 17/700（body）。
    case compact
    /// 商品详情：主价 34/700（display）。
    case large

    var style: CouliTextStyle {
        switch self {
        case .list: .title
        case .compact: .body
        case .large: .display
        }
    }

    var labelStyle: CouliTextStyle {
        self == .large ? .body : .caption
    }
}

/// 主价：口径词（12 灰棕）+ 金额（墨棕 700、等宽数字）。不用删除线、不用橙红（GUIDE §2）。
/// 副行（券前 · 券 / 无券）用 `PriceSubLine`，由调用方按卡片结构摆放。
public struct PriceTag: View {
    private let content: PriceTagContent
    private let size: PriceTagSize

    public init(_ content: PriceTagContent, size: PriceTagSize = .list) {
        self.content = content
        self.size = size
    }

    private var label: some View {
        Text(verbatim: content.mainLabel)
            .couliFont(size.labelStyle)
            .foregroundColor(CouliColor.textSecondary)
            .fixedSize()
    }

    private var amount: some View {
        Text(verbatim: content.mainAmount)
            .couliFont(size.style, weight: .couliBold, monospacedDigits: true)
            .foregroundColor(CouliColor.priceText)
            .fixedSize()
    }

    public var body: some View {
        // 口径词与主价按基线对齐；放不下时口径词在上、主价在下（不缩字号、不截断）。
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: CouliSpacing.s1) {
                label
                amount
            }
            VStack(alignment: .leading, spacing: 0) {
                label
                amount
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: content.mainAccessibilityText))
    }
}

/// 价格副行：「券前 ¥x · 券 ¥y」或「无券」（caption、灰棕、等宽数字、不划线）。
public struct PriceSubLine: View {
    private let content: PriceTagContent
    private let style: CouliTextStyle

    public init(_ content: PriceTagContent, style: CouliTextStyle = .caption) {
        self.content = content
        self.style = style
    }

    public var body: some View {
        // 主价没有口径词 = 券前价与券额待补齐（APP-06b）：不写副行。
        if !content.mainLabel.isEmpty {
            SegmentedLine(
                text: content.subLine ?? PriceTerms.noCoupon,
                spoken: content.subLineAccessibilityText ?? PriceTerms.noCoupon,
                style: style
            )
        }
    }
}

// MARK: - RebateTag

/// RebateTag 所在场景。
public enum RebateTagPlacement: Sendable {
    /// 列表卡：「暂无返利」隐藏（BR-TEXT-10）。
    case list
    /// 详情、粘贴出卡：「暂无返利」照常显示（BR-PRICE-08）。
    case detail
}

/// 返利标签（GUIDE §7.1）：返利浅底 + 深橙字 + 钟表图形；金额 600、等宽数字；区间只在破折号处折行。
/// 暂无返利用中性色（不用橙）；金额未知、登录查看只显示文字。
public struct RebateTag: View {
    private let content: RebateTagContent
    private let placement: RebateTagPlacement
    private let isLarge: Bool

    public init(_ content: RebateTagContent, placement: RebateTagPlacement = .list, isLarge: Bool = false) {
        self.content = content
        self.placement = placement
        self.isLarge = isLarge
    }

    public var body: some View {
        if content.kind == .none, placement == .list {
            EmptyView()
        } else {
            tag
        }
    }

    private var labelStyle: CouliTextStyle {
        isLarge ? .body : .caption
    }

    private var amountStyle: CouliTextStyle {
        isLarge ? .title : .caption
    }

    /// 中性配色：暂无返利、异常数据降级、¥0（GUIDE §7.1「无返利 / 返利 ¥0 不用橙」）。
    private var isNeutral: Bool {
        !content.usesRebateAccent
    }

    private var tag: some View {
        CouliFlowLayout(horizontalSpacing: CouliSpacing.s1, verticalSpacing: 0) {
            HStack(spacing: CouliSpacing.s1) {
                if !isNeutral {
                    CouliIconView(
                        .clock,
                        size: isLarge ? CouliComponentMetric.iconMedium : CouliComponentMetric.iconSmall,
                        relativeTo: isLarge ? .body : .caption
                    )
                }
                Text(verbatim: content.label ?? content.text)
                    .couliFont(labelStyle, weight: isLarge ? .couliMedium : .regular)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !content.amountParts.isEmpty {
                // 金额段之间不留空：区间只在破折号处折行。
                CouliFlowLayout(horizontalSpacing: 0, verticalSpacing: 0) {
                    ForEach(Array(content.amountParts.enumerated()), id: \.offset) { _, part in
                        // 单段金额比整行还宽时在小数点前折行（不截断）。
                        BreakableText(part, style: amountStyle, weight: isLarge ? .couliBold : .couliSemibold)
                    }
                }
            }
        }
        .foregroundColor(isNeutral ? CouliColor.textSecondary : CouliColor.rebateText)
        .padding(.horizontal, isLarge ? CouliSpacing.s4 : CouliSpacing.s2)
        .padding(.vertical, isLarge ? CouliSpacing.s2 : CouliPendingTokenMetric.tagPaddingVertical)
        .frame(minHeight: CouliComponentMetric.tagMinHeight)
        .background(
            RoundedRectangle(cornerRadius: isLarge ? CouliRadius.button : CouliRadius.button, style: .continuous)
                .fill(isNeutral ? CouliColor.backgroundMuted : CouliColor.rebateBackground)
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: content.accessibilityText))
    }
}

// MARK: - EstNetLine

/// 「预估返后 ¥x」一行（caption、灰棕、等宽数字；价格类不用橙）。
/// 显示与否由同一张卡的 `RebateTagContent` 决定（编排者裁定，三端一致）：只有 RebateTag 判定为可显示金额
/// （kind amount / range）且金额未隐藏时才显示；RebateTag 因异常数据判为「暂无返利」时预估返后也不显示。
public struct EstNetLine: View {
    private let text: String?
    private let accessibilityText: String?
    private let style: CouliTextStyle

    /// - Parameters:
    ///   - text: `EstNetModel.make` 的结果。
    ///   - rebate: 同一张卡的返利标签内容。
    ///   - amountHidden: 金额隐藏开关；打开时不显示。
    public init(
        _ text: String?,
        accessibilityText: String? = nil,
        rebate: RebateTagContent,
        amountHidden: Bool = false,
        style: CouliTextStyle = .caption
    ) {
        self.text = Self.visibleText(text, rebate: rebate, amountHidden: amountHidden)
        self.accessibilityText = accessibilityText
        self.style = style
    }

    /// 组件层的显示判定：RebateTag 可显示金额且金额未隐藏时返回 `text`，否则 nil。
    public static func visibleText(_ text: String?, rebate: RebateTagContent, amountHidden: Bool) -> String? {
        guard rebate.showsAmount, !amountHidden else {
            return nil
        }
        return text
    }

    public var body: some View {
        if let text {
            Text(verbatim: text)
                .couliFont(style, monospacedDigits: true)
                .foregroundColor(CouliColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel(Text(verbatim: accessibilityText ?? text))
        }
    }
}

// MARK: - DisclaimerFooter

/// 口径说明（BR-PRICE-03）。文案（price_basis、price_basis.general、结算说明…）由调用方按卡片下发的键给。
public struct DisclaimerFooter: View {
    /// 一行说明及其图标。
    public struct Line: Sendable, Hashable {
        public let text: String
        public let icon: CouliIcon?

        public init(_ text: String, icon: CouliIcon? = nil) {
            self.text = text
            self.icon = icon
        }
    }

    public enum Style: Sendable {
        /// 列表每屏底部一次：首行带信息图标，其余行缩进对齐（Search 稿）。
        case list
        /// 详情页常驻全文：中性浅底块，每行带自己的图标（Product 稿）。
        case boxed
    }

    private let lines: [Line]
    private let style: Style

    public init(lines: [Line], style: Style = .list) {
        self.lines = lines
        self.style = style
    }

    public var body: some View {
        switch style {
        case .list:
            HStack(alignment: .top, spacing: CouliSpacing.s2) {
                CouliIconView(.info, size: CouliComponentMetric.iconInline, relativeTo: .caption)
                VStack(alignment: .leading, spacing: CouliSpacing.s1) {
                    ForEach(lines, id: \.self) { line in
                        Text(verbatim: line.text)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }
            .couliFont(.caption)
            .foregroundColor(CouliColor.textSecondary)
            .padding(.horizontal, CouliSpacing.s1)
            .padding(.top, CouliSpacing.s1)
            .accessibilityElement(children: .combine)
        case .boxed:
            VStack(alignment: .leading, spacing: CouliSpacing.s3) {
                ForEach(lines, id: \.self) { line in
                    HStack(alignment: .top, spacing: CouliSpacing.s2) {
                        CouliIconView(line.icon ?? .info, size: CouliComponentMetric.iconInline, relativeTo: .footnote)
                        Text(verbatim: line.text)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            .couliFont(.footnote)
            .foregroundColor(CouliColor.textSecondary)
            .padding(CouliSpacing.s4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: CouliRadius.card, style: .continuous)
                    .fill(CouliColor.backgroundMuted)
            )
        }
    }
}

/// 卡片上的口径 i 图标（44×44 命中区）：点开在卡内展开全文，再点收起（BR-PRICE-03「单卡 i 图标」）。
public struct DisclaimerInfoButton: View {
    @Binding private var isExpanded: Bool
    private let accessibilityLabel: String

    /// - Parameter accessibilityLabel: 读屏名称（如「口径说明」），由调用方从字典给。
    public init(isExpanded: Binding<Bool>, accessibilityLabel: String) {
        _isExpanded = isExpanded
        self.accessibilityLabel = accessibilityLabel
    }

    public var body: some View {
        Button {
            isExpanded.toggle()
        } label: {
            CouliIconView(.info, size: CouliComponentMetric.iconInline, relativeTo: .caption)
                .foregroundColor(CouliColor.textSecondary)
                .couliHitTarget()
        }
        .buttonStyle(CouliPlainButtonStyle(cornerRadius: CouliRadius.small))
        .accessibilityLabel(Text(verbatim: accessibilityLabel))
        .accessibilityValue(Text(verbatim: ""))
        .accessibilityAddTraits(isExpanded ? .isSelected : [])
    }
}

/// 副行：按「 · 」分段，段与段之间优先换行（「券前 ¥39.9」「· 券 ¥10」各自成块）；单段比整行还宽时段内在空格处折行，不截断。
struct SegmentedLine: View {
    let text: String
    let spoken: String
    let style: CouliTextStyle

    private var segments: [String] {
        let parts = text.components(separatedBy: PriceTerms.separator)
        return parts.enumerated().map { index, part in
            index == 0 ? part : PriceTerms.separator.trimmingCharacters(in: .whitespaces) + " " + part
        }
    }

    var body: some View {
        CouliFlowLayout(horizontalSpacing: CouliSpacing.s1, verticalSpacing: 0) {
            ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                BreakableText(segment, style: style)
            }
        }
        .foregroundColor(CouliColor.textSecondary)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: spoken))
    }
}
