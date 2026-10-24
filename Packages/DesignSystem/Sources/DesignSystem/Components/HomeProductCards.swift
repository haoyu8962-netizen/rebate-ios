import SwiftUI
import UIKit

// MARK: - 首页商品卡（APP-11v：Main-v3 / HomeGuest-v3 的横滑卡、网格卡、信息流卡）

/// 首页商品卡的三种排法。
public enum HomeProductCardStyle: String, Sendable, CaseIterable {
    /// 今日精选横滑卡：图 + 价格行 + 副行 + 窄卡返利块；不显示标题与来源（读屏名仍含平台 + 标题 + 价格 + 返利）。
    case scroll
    /// 区段白卡内的网格卡（不再各自套卡）：图 + 来源标题 + 优惠标签 + 价格 + 返利块。
    case grid
    /// 信息流：每件一张独立白卡，内容同网格卡。
    case feed
}

/// 首页商品卡（GUIDE §6「窄卡返利标签」；APP-11v）。与搜索页、详情页的卡是不同组件：首页紧凑变体。
///
/// - 金额（主价、券前、券额、返利区间两端）都是不可拆的一段：不截断、不缩字，放不下由调用方加宽卡（横滑）或整组改单列（网格 / 信息流），
///   宽度需要量见 `HomeProductCardMetrics.requiredWidth`。金额随系统字号按正文曲线缩放。
/// - 口径 i（BR-PRICE-03 单卡 i）：有返利块时在返利块首行，暂无返利时在价格行右侧；视觉图形 16，命中区 44 另行叠在图形上，
///   不撑高首行（视觉行约 18）。i 是独立按钮，不被整卡点击抢走；整卡（不含 i 与展开的说明）合为一个读屏按钮。
public struct HomeProductCard<ImageContent: View>: View {
    private let data: ProductCardData
    private let style: HomeProductCardStyle
    private let index: Int
    private let width: CGFloat?
    private let spokenLabel: String
    private let onOpen: (() -> Void)?
    private let image: ImageContent
    @State private var expanded = false

    /// - Parameters:
    ///   - index: 本区段内的序号（可访问标识 `home.product.<style>.<index>`）。
    ///   - width: 横滑卡的固定宽度；nil 时铺满所在列。
    ///   - spokenLabel: 整卡读屏名（调用方按规则拼好：平台、标题、价格、返利）。
    ///   - onOpen: 点整卡（nil 时不可点）。
    public init(_ data: ProductCardData, style: HomeProductCardStyle, index: Int, width: CGFloat? = nil,
                spokenLabel: String, onOpen: (() -> Void)?, @ViewBuilder image: () -> ImageContent) {
        self.data = data
        self.style = style
        self.index = index
        self.width = width
        self.spokenLabel = spokenLabel
        self.onOpen = onOpen
        self.image = image()
    }

    private var suffix: String {
        "\(style.rawValue).\(index)"
    }

    private var cardID: String {
        "home.product.\(suffix)"
    }

    private var placement: ProductGridCard<EmptyView>.DisclaimerPlacement {
        ProductGridCard<EmptyView>.disclaimerPlacement(data)
    }

    /// 文字区左右缩进（信息流卡图片贴卡内边距 8，文字再缩 4，Main-v3）。
    private var textInset: CGFloat {
        style == .feed ? CouliSpacing.s1 : 0
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: CouliSpacing.s2) {
            content
                .frame(maxHeight: .infinity, alignment: .top)
            if expanded, placement != .hidden {
                Text(verbatim: data.disclaimer)
                    .couliFont(.caption)
                    .foregroundColor(CouliColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, textInset)
                    .accessibilityIdentifier("home.info.content.\(suffix)")
            }
        }
        .padding(style == .feed ? CouliSpacing.s2 : 0)
        // 同一行的卡等高（行容器按最高的卡定高），返利块贴卡底（Main-v3 margin-top: auto）
        .frame(maxHeight: .infinity, alignment: .top)
        .frame(width: width, alignment: .topLeading)
        .frame(maxWidth: width == nil ? .infinity : nil, alignment: .topLeading)
        .background {
            if style == .feed {
                RoundedRectangle(cornerRadius: CouliRadius.card, style: .continuous)
                    .fill(CouliColor.backgroundSurface)
                    .couliShadow(.card)
            }
        }
        .overlayPreferenceValue(HomeInfoAnchorKey.self) { anchor in
            GeometryReader { proxy in
                if let anchor, placement != .hidden {
                    // 以图形为中心，但整块命中区收在卡内（超出卡边的部分在横滑容器里点不到）
                    let rect = proxy[anchor]
                    let half = CouliHitTarget.minimum / 2
                    infoButton.position(
                        x: min(max(rect.midX, half), proxy.size.width - half),
                        y: min(max(rect.midY, half), proxy.size.height - half)
                    )
                }
            }
        }
        .couliProbe(cardID, role: "product-card", card: cardID)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: CouliSpacing.s2) {
            HomeProductImageFrame(height: style == .scroll ? 104 : 132) { image }
            VStack(alignment: .leading, spacing: CouliSpacing.s2) {
                if style != .scroll {
                    BadgedTitle(platform: data.platformName, platformCode: data.platformCode, title: data.title,
                                style: .footnote, lineLimit: 2)
                    if !data.allTags.isEmpty {
                        TagRow(tags: data.allTags)
                    }
                }
                priceBlock
            }
            .padding(.horizontal, textInset)
            Spacer(minLength: 0)
            if ProductGridCard<EmptyView>.showsNarrowRebate(data) {
                rebateBlock(withInfo: placement == .inRebateRow)
                    .padding(.horizontal, textInset)
                    .padding(.bottom, textInset)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture { onOpen?() }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: spokenLabel))
        .accessibilityAddTraits(onOpen == nil ? [] : .isButton)
        .accessibilityIdentifier(cardID)
        .accessibilityAction { onOpen?() }
    }

    // MARK: 价格

    private var priceBlock: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !data.hidesPrice {
                HStack(alignment: .center, spacing: CouliSpacing.s1) {
                    CouliFlowLayout(horizontalSpacing: CouliSpacing.s1, verticalSpacing: 0) {
                        if !data.price.mainLabel.isEmpty {
                            Text(verbatim: data.price.mainLabel)
                                .couliFont(.caption)
                                .foregroundColor(CouliColor.textSecondary)
                                .fixedSize()
                                .couliLineBox(.caption)
                        }
                        CouliUnbreakableText(data.price.mainAmount, size: CouliTextStyle.body.baseSize,
                                             weight: .couliBold, probeID: "home.amount.main.\(suffix)",
                                             role: "amount-part", card: cardID)
                            .foregroundColor(CouliColor.priceText)
                    }
                    if placement == .besidePrice {
                        Spacer(minLength: 0)
                        infoGlyph
                    }
                }
            }
            ForEach(Array(HomeProductCardMetrics.subLines(data).enumerated()), id: \.offset) { line, text in
                subLine(text, line: line)
            }
        }
    }

    private func subLine(_ text: String, line: Int) -> some View {
        let segments = HomeProductCardMetrics.segments(text)
        return CouliFlowLayout(horizontalSpacing: CouliSpacing.s1, verticalSpacing: 0) {
            ForEach(Array(segments.enumerated()), id: \.offset) { offset, segment in
                if HomeProductCardMetrics.isAmount(segment) {
                    CouliUnbreakableText(segment, size: CouliTextStyle.caption.baseSize,
                                         probeID: "home.amount.sub.\(suffix).\(line).\(offset)",
                                         role: "amount-part", card: cardID)
                } else {
                    Text(verbatim: segment)
                        .couliFont(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                        .couliLineBox(.caption)
                }
            }
        }
        .foregroundColor(CouliColor.textSecondary)
    }

    // MARK: 返利块

    private func rebateBlock(withInfo: Bool) -> some View {
        let rebate = data.rebate.hidingAmount(data.amountHidden)
        let accent = rebate.usesRebateAccent
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: CouliSpacing.s1) {
                if accent {
                    CouliIconView(.clock, size: CouliGuideMetric.iconSmall, relativeTo: .caption)
                }
                Text(verbatim: rebate.label ?? rebate.text)
                    .couliFont(.caption)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: CouliSpacing.s1)
                if withInfo {
                    infoGlyph
                }
            }
            .frame(minHeight: 18)
            .couliProbe("home.rebate.row.\(suffix)", role: "rebate-row", card: cardID)
            if !rebate.amountParts.isEmpty {
                CouliFlowLayout(horizontalSpacing: 0, verticalSpacing: 0) {
                    ForEach(Array(rebate.amountParts.enumerated()), id: \.offset) { offset, part in
                        CouliUnbreakableText(part, size: CouliTextStyle.footnote.baseSize, weight: .couliSemibold,
                                             probeID: "home.amount.rebate.\(suffix).\(offset)",
                                             role: "amount-part", card: cardID)
                    }
                }
            }
        }
        .foregroundColor(accent ? CouliColor.rebateText : CouliColor.textSecondary)
        .padding(.vertical, CouliSpacing.s1)
        .padding(.horizontal, CouliSpacing.s2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: CouliRadius.small, style: .continuous)
                .fill(accent ? CouliColor.rebateBackground : CouliColor.backgroundMuted)
        )
    }

    // MARK: 口径 i

    /// i 的视觉图形（16）：只占自己的大小；命中区由 `infoButton` 叠在上面。
    private var infoGlyph: some View {
        CouliIconView(.info, size: CouliGuideMetric.iconInline, relativeTo: .caption)
            .anchorPreference(key: HomeInfoAnchorKey.self, value: .bounds) { $0 }
            .couliProbe("home.info.glyph.\(suffix)", role: "info-glyph", card: cardID)
    }

    /// i 的命中区：44 × 44，以图形为中心叠在整卡最上层（不参与布局，不撑高首行；扩出的部分落在卡内留白上）。
    private var infoButton: some View {
        Button {
            expanded.toggle()
        } label: {
            Color.clear
                .frame(width: CouliHitTarget.minimum, height: CouliHitTarget.minimum)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(verbatim: data.disclaimerButtonLabel))
        .accessibilityAddTraits(expanded ? .isSelected : [])
        .accessibilityIdentifier("home.info.\(suffix)")
        .couliProbe("home.info.\(suffix)", role: "independent-hit", card: cardID)
    }
}

private struct HomeInfoAnchorKey: PreferenceKey {
    static var defaultValue: Anchor<CGRect>? {
        nil
    }

    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = value ?? nextValue()
    }
}

/// 首页商品图框：占位底 + 图 + 1 描边，圆角 8，固定高（Main-v3：横滑 104、网格 / 信息流 132），宽铺满。装饰，读屏隐藏。
struct HomeProductImageFrame<Content: View>: View {
    let height: CGFloat
    @ViewBuilder let content: Content

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: CouliRadius.small, style: .continuous)
        shape
            .fill(CouliColor.backgroundPlaceholder)
            .overlay(content)
            .overlay(shape.strokeBorder(CouliColor.borderSubtle, lineWidth: CouliComponentMetric.controlBorderWidth))
            .clipShape(shape)
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .accessibilityHidden(true)
    }
}

// MARK: - 量宽

/// 首页商品卡的量宽与分段（纯函数；字号按系统字号缩放后的实际值，用与卡上相同的系统字体与等宽数字量）。
public enum HomeProductCardMetrics {
    /// 卡上显示的副行（券前 / 无券、说明、预售说明；首页卡不显示「预估返后」）。
    static func subLines(_ data: ProductCardData) -> [String] {
        data.subLines.map(\.text).filter { $0 != data.estNet }
    }

    /// 副行按「 · 」分成不可拆的段：「券前 ¥39.9」「· 券 ¥10」。
    static func segments(_ line: String) -> [String] {
        let parts = line.components(separatedBy: PriceTerms.separator)
        return parts.enumerated().map { index, part in
            index == 0 ? part : PriceTerms.separator.trimmingCharacters(in: .whitespaces) + " " + part
        }
    }

    /// 段里有金额（¥）。
    static func isAmount(_ segment: String) -> Bool {
        segment.contains(PriceTerms.yuanSign)
    }

    /// 一张卡在该字号下不截断金额所需的最小宽度（pt）：各金额段自然宽度加所在容器的左右留白，取最大值。
    @MainActor
    public static func requiredWidth(_ data: ProductCardData, style: HomeProductCardStyle,
                                     dynamicTypeSize: DynamicTypeSize) -> CGFloat {
        let traits = UITraitCollection(preferredContentSizeCategory: category(dynamicTypeSize))
        func width(_ text: String, _ base: CGFloat, _ weight: UIFont.Weight) -> CGFloat {
            let size = UIFontMetrics(forTextStyle: .body).scaledValue(for: base, compatibleWith: traits)
            let font = UIFont.monospacedDigitSystemFont(ofSize: size, weight: weight)
            return ceil((text as NSString).size(withAttributes: [.font: font]).width)
        }
        let inset: CGFloat = style == .feed ? (CouliSpacing.s2 + CouliSpacing.s1) * 2 : 0
        var widths: [CGFloat] = []
        if !data.hidesPrice {
            let glyph = ProductGridCard<EmptyView>.disclaimerPlacement(data) == .besidePrice
                ? CouliSpacing.s1 + UIFontMetrics(forTextStyle: .caption1)
                .scaledValue(for: CouliGuideMetric.iconInline, compatibleWith: traits) : 0
            widths.append(width(data.price.mainAmount, CouliTextStyle.body.baseSize, .bold) + glyph)
        }
        for line in subLines(data) {
            for segment in segments(line) where isAmount(segment) {
                widths.append(width(segment, CouliTextStyle.caption.baseSize, .regular))
            }
        }
        if ProductGridCard<EmptyView>.showsNarrowRebate(data) {
            let rebate = data.rebate.hidingAmount(data.amountHidden)
            for part in rebate.amountParts {
                widths.append(width(part, CouliTextStyle.footnote.baseSize, .semibold) + CouliSpacing.s2 * 2)
            }
            // 返利块首行（钟表 + 预估返 + i）也不拆字：放不下时同样加宽 / 改单列
            let caption = UIFontMetrics(forTextStyle: .caption1)
            let label = caption.scaledFont(for: UIFont.systemFont(ofSize: CouliTextStyle.caption.baseSize))
            let icons = caption.scaledValue(for: CouliGuideMetric.iconSmall, compatibleWith: traits)
                + caption.scaledValue(for: CouliGuideMetric.iconInline, compatibleWith: traits)
            let text = ceil(((rebate.label ?? rebate.text) as NSString).size(withAttributes: [
                .font: label.withSize(caption.scaledValue(for: CouliTextStyle.caption.baseSize,
                                                          compatibleWith: traits)),
            ]).width)
            widths.append(icons + text + CouliSpacing.s1 * 2 + CouliSpacing.s2 * 2)
        }
        return (widths.max() ?? 0) + inset + 1
    }

    /// SwiftUI 动态字号 → UIKit 字号档。
    public static func category(_ size: DynamicTypeSize) -> UIContentSizeCategory {
        categories[size] ?? .large
    }

    private static let categories: [DynamicTypeSize: UIContentSizeCategory] = [
        .xSmall: .extraSmall, .small: .small, .medium: .medium, .large: .large, .xLarge: .extraLarge,
        .xxLarge: .extraExtraLarge, .xxxLarge: .extraExtraExtraLarge, .accessibility1: .accessibilityMedium,
        .accessibility2: .accessibilityLarge, .accessibility3: .accessibilityExtraLarge,
        .accessibility4: .accessibilityExtraExtraLarge, .accessibility5: .accessibilityExtraExtraExtraLarge,
    ]

    /// 整卡读屏名（网格 / 信息流）：来源、标题、优惠标签、主价、副行、返利。
    public static func accessibilityLabel(_ data: ProductCardData) -> String {
        var parts = [data.platformName, data.title] + data.allTags.map(\.text)
        if !data.hidesPrice {
            parts.append(data.price.mainAccessibilityText)
        }
        parts += data.subLines.filter { $0.text != data.estNet }.map(\.spoken)
        if data.showsRebate {
            parts.append(data.rebate.hidingAmount(data.amountHidden).accessibilityText)
        }
        return parts.filter { !$0.isEmpty }.joined(separator: PriceTerms.spokenPause)
    }
}
