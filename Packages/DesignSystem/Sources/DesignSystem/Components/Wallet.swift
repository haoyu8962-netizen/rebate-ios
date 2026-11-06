import SwiftUI

// MARK: - 金额值（可隐藏）

/// 数字格 / 主卡里的一个值：金额（分）、金额区间（分）或纯文字。金额与区间由组件统一格式化，金额隐藏时统一换成
/// 隐藏写法、读屏读「金额已隐藏」，调用方拿不到绕过隐藏的口子（BR-TEXT-10 细则「金额隐藏」）。
/// `.text` 只放不含金额的文字（如「10 月结算」）；含金额一律用 `.amount` / `.range`。
public enum AmountValue: Sendable, Hashable {
    case amount(Int64)
    /// 返利区间（订单数字格「预估返」等）：显示「¥a–¥b」、读「a 元到 b 元」，只在破折号处折行。
    /// min = max > 0 按单值；异常数据（min > max 不排序、端点为负、上限为 0）按 rule-gaps.md 统一裁定显示「暂无返利」。
    case range(minFen: Int64, maxFen: Int64)
    case text(String)

    /// 不可拆分的显示段：单值一段；区间两段「¥a」「–¥b」（段间不留空，只在破折号处折行）；隐藏时一段「****」。
    func displayParts(hidden: Bool) -> [String] {
        switch self {
        case let .amount(fen):
            return [hidden ? PriceTerms.amountMask : CouliFormat.money(fen: fen)]
        case let .range(minFen, maxFen):
            if hidden {
                return [PriceTerms.amountMask]
            }
            guard let (low, high) = CouliFormat.normalizedRange(minFen, maxFen) else {
                return [PriceTerms.noRebate]
            }
            if low == high {
                return [CouliFormat.money(fen: low)]
            }
            return [CouliFormat.money(fen: low), PriceTerms.rangeDash + CouliFormat.money(fen: high)]
        case let .text(text):
            return [text]
        }
    }

    func display(hidden: Bool) -> String {
        displayParts(hidden: hidden).joined()
    }

    /// 是否是可显示的正金额：单值 > 0；区间合法（同 `CouliFormat.normalizedRange`）且上限 > 0。
    /// 0、负数、异常区间（显示「暂无返利」）与纯文字都不是。返利强调色只给这种值（GUIDE §7.1「无返利 / 返利 ¥0 不用橙」）。
    var isPositiveAmount: Bool {
        switch self {
        case let .amount(fen):
            fen > 0
        case let .range(minFen, maxFen):
            CouliFormat.normalizedRange(minFen, maxFen) != nil
        case .text:
            false
        }
    }

    func spoken(hidden: Bool) -> String {
        switch self {
        case let .amount(fen):
            return hidden ? PriceTerms.spokenAmountHidden : CouliFormat.moneySpoken(fen: fen)
        case let .range(minFen, maxFen):
            if hidden {
                return PriceTerms.spokenAmountHidden
            }
            return CouliFormat.rebateRangeSpoken(minFen: minFen, maxFen: maxFen) ?? PriceTerms.noRebate
        case let .text(text):
            return text
        }
    }
}

/// 数值下方的补充小字，可带一个金额（如「其中已收货 ¥34.56」）。
public struct AmountNote: Sendable, Hashable {
    public let prefix: String
    public let amountFen: Int64?
    public let suffix: String

    public init(_ prefix: String, amountFen: Int64? = nil, suffix: String = "") {
        self.prefix = prefix
        self.amountFen = amountFen
        self.suffix = suffix
    }

    /// 显示文字；金额隐藏时金额段换成隐藏写法。
    public func display(hidden: Bool) -> String {
        guard let amountFen else {
            return prefix + suffix
        }
        return prefix + AmountValue.amount(amountFen).display(hidden: hidden) + suffix
    }

    /// 读屏文字；金额隐藏时不读真实金额。
    public func spoken(hidden: Bool) -> String {
        guard let amountFen else {
            return prefix + suffix
        }
        return prefix + AmountValue.amount(amountFen).spoken(hidden: hidden) + suffix
    }
}

// MARK: - AmountGrid

/// 数字格的一格。
public struct AmountGridItem: Sendable, Hashable {
    public let label: String
    public let value: AmountValue
    /// 数值下方的补充小字（金额随隐藏开关一起隐藏）。
    public let note: AmountNote?
    /// 返利类金额（预估返、预估收益等）：排序上返利在上；有正金额时标签、金额、钟表用返利强调色（GUIDE §7.1）。
    /// 无返利、¥0、异常区间（「暂无返利」）、纯文字不用强调色，见 `usesRebateAccent(amountHidden:)`。
    public let isRebate: Bool
    /// 问号说明按钮的读屏名称；nil 时不显示问号。
    public let helpLabel: String?

    public init(
        label: String,
        value: AmountValue,
        note: AmountNote? = nil,
        isRebate: Bool = false,
        helpLabel: String? = nil
    ) {
        self.label = label
        self.value = value
        self.note = note
        self.isRebate = isRebate
        self.helpLabel = helpLabel
    }

    /// 是否用返利强调色（标签、金额、钟表三者同步，GUIDE §7.1）。
    /// - 金额可见：返利类且值是正金额才用；「无返利 / 返利 ¥0 / 暂无返利 / 异常数据」用常规文字色。
    /// - 金额隐藏：金额 / 区间只按类别（返利类就用），不按真实金额——否则「****」的颜色会泄露返利是不是 0。
    /// - 纯文字（`.text`，不随隐藏变化）：一律不用。
    public func usesRebateAccent(amountHidden: Bool) -> Bool {
        guard isRebate else {
            return false
        }
        if case .text = value {
            return false
        }
        return amountHidden || value.isPositiveAmount
    }

    func accessibilityText(hidden: Bool) -> String {
        var parts = [label, value.spoken(hidden: hidden)]
        if let note {
            parts.append(note.spoken(hidden: hidden))
        }
        return parts.joined(separator: PriceTerms.spokenPause)
    }
}

/// 数字格（两列对齐，GUIDE §7.2）：上标签（14，可带问号）下数值（等宽数字）。
/// 放大规则（adaptation-a11y-spec §2）：两列放得下就并排；任一列放不下一个不可拆分的金额段时改上下排（返利在上）；
/// 辅助字号档（≈200% 起）一律上下排。超过 200% 时封顶在辅助字号第 2 档（03 §10.4），长按用大内容查看器。
/// `amountHidden` 打开时格内所有金额（含补充小字里的金额）一律隐藏。
public struct AmountGrid: View {
    private let items: [AmountGridItem]
    private let valueStyle: CouliTextStyle
    private let amountHidden: Bool
    private let onHelp: (AmountGridItem) -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    public init(
        items: [AmountGridItem],
        valueStyle: CouliTextStyle = .title,
        amountHidden: Bool = false,
        onHelp: @escaping (AmountGridItem) -> Void = { _ in }
    ) {
        self.items = items
        self.valueStyle = valueStyle
        self.amountHidden = amountHidden
        self.onHelp = onHelp
    }

    public var body: some View {
        // 两列放得下每列最宽的不可拆分金额段就并排（区间在本列内、破折号处折行）；否则上下排、返利在上。
        // 辅助字号档（≈200% 起）一律上下排。
        AmountGridLayout(
            columnSpacing: CouliSpacing.s4,
            rowSpacing: CouliSpacing.s3,
            forceStacked: dynamicTypeSize >= .accessibility1
        ) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                cell(item)
                    .layoutValue(key: AmountGridRole.self, value: .cell(stackFirst: item.isRebate))
                // 量宽用的隐形探针：本格最宽的不可拆分金额段。
                AmountText.widestPartProbe(item.value.displayParts(hidden: amountHidden), style: valueStyle)
                    .layoutValue(key: AmountGridRole.self, value: .probe(cell: index))
            }
        }
        .dynamicTypeSize(...DynamicTypeSize.accessibility2)
    }

    private func cell(_ item: AmountGridItem) -> some View {
        let rebateAccent = item.usesRebateAccent(amountHidden: amountHidden)
        return VStack(alignment: .leading, spacing: CouliSpacing.s1) {
            HStack(spacing: CouliSpacing.s1) {
                if rebateAccent {
                    CouliIconView(.clock, size: CouliComponentMetric.iconInline, relativeTo: .caption)
                }
                Text(verbatim: item.label)
                    .couliFont(.footnote)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel(Text(verbatim: item.accessibilityText(hidden: amountHidden)))
                if let helpLabel = item.helpLabel {
                    HelpButton(label: helpLabel) { onHelp(item) }
                }
            }
            .foregroundColor(rebateAccent ? CouliColor.rebateText : CouliColor.textSecondary)
            AmountText(item.value, hidden: amountHidden, style: valueStyle, weight: .couliBold)
                .foregroundColor(rebateAccent ? CouliColor.rebateText : CouliColor.textPrimary)
                .accessibilityShowsLargeContentViewer()
                .accessibilityHidden(true)
            if let note = item.note {
                Text(verbatim: note.display(hidden: amountHidden))
                    .couliFont(.footnote, monospacedDigits: true)
                    .foregroundColor(CouliColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityHidden(true)
            }
        }
        .accessibilityElement(children: .contain)
    }
}

// MARK: - WalletHeroCard

/// 狸橙实底主卡（GUIDE §7.1、§7.2「钱包主卡」）：白色大字金额、白底【提现】、「提现记录 ›」入口；不做渐变。
/// 卡内白字不小于 14（footnote）。冻结中、待抵扣不进大数字（由调用方放进 `footer`）。
/// 金额隐藏时大数字显示隐藏写法、读屏读「金额已隐藏」；`footer` 里的金额用 `HeroAmountRow` 传同一个 `isHidden`。
public struct WalletHeroCard<Footer: View>: View {
    private let title: String
    private let amountFen: Int64
    private let isHidden: Bool
    private let toggleHiddenLabel: String?
    private let withdrawTitle: String
    private let withdrawEnabled: Bool
    private let recordsTitle: String?
    private let onToggleHidden: () -> Void
    private let onWithdraw: () -> Void
    private let onRecords: () -> Void
    private let footer: Footer

    /// - Parameters:
    ///   - toggleHiddenLabel: 眼睛按钮读屏名称（amount_mask.hide / show）；nil 时不显示眼睛。
    ///   - recordsTitle: 「提现记录」；nil 时不显示。
    ///   - withdrawEnabled: 【提现】是否可点（APP-09 G11：withdraw_enabled=false、待抵扣、旧数据时置灰；缺省可点）。
    public init(
        title: String,
        amountFen: Int64,
        isHidden: Bool = false,
        toggleHiddenLabel: String? = nil,
        withdrawTitle: String,
        withdrawEnabled: Bool = true,
        recordsTitle: String? = nil,
        onToggleHidden: @escaping () -> Void = {},
        onWithdraw: @escaping () -> Void,
        onRecords: @escaping () -> Void = {},
        @ViewBuilder footer: () -> Footer
    ) {
        self.title = title
        self.amountFen = amountFen
        self.isHidden = isHidden
        self.toggleHiddenLabel = toggleHiddenLabel
        self.withdrawTitle = withdrawTitle
        self.withdrawEnabled = withdrawEnabled
        self.recordsTitle = recordsTitle
        self.onToggleHidden = onToggleHidden
        self.onWithdraw = onWithdraw
        self.onRecords = onRecords
        self.footer = footer()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: CouliSpacing.s4) {
            CouliFlowLayout(horizontalSpacing: CouliSpacing.s3, verticalSpacing: CouliSpacing.s1) {
                HStack(spacing: CouliSpacing.s1) {
                    Text(verbatim: title)
                        .couliFont(.footnote, weight: .couliSemibold)
                        .fixedSize(horizontal: false, vertical: true)
                    if let toggleHiddenLabel {
                        Button(action: onToggleHidden) {
                            CouliIconView(isHidden ? .eyeOff : .eye, relativeTo: .footnote)
                                .couliHitTarget()
                        }
                        .buttonStyle(CouliPlainButtonStyle(cornerRadius: CouliRadius.small, onBrand: true))
                        .padding(.vertical, -CouliSpacing.s3)
                        .accessibilityLabel(Text(verbatim: toggleHiddenLabel))
                    }
                }
                if let recordsTitle {
                    Button(action: onRecords) {
                        HStack(spacing: CouliSpacing.s1) {
                            Text(verbatim: recordsTitle)
                                .couliFont(.footnote, weight: .couliSemibold)
                            CouliIconView(.chevron, size: CouliComponentMetric.iconInline, relativeTo: .footnote)
                        }
                        .frame(minHeight: CouliHitTarget.minimum)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(CouliPlainButtonStyle(cornerRadius: CouliRadius.small, onBrand: true))
                    .padding(.vertical, -CouliSpacing.s3)
                    .accessibilityLabel(Text(verbatim: recordsTitle))
                    .couliFlowPushTrailing(.inlineOnly)
                }
            }
            CouliFlowLayout(horizontalSpacing: CouliSpacing.s4, verticalSpacing: CouliSpacing.s3) {
                AmountText(.amount(amountFen), hidden: isHidden, style: .display, weight: .couliBold)
                    .accessibilityLabel(Text(verbatim: title + PriceTerms.spokenPause
                            + AmountValue.amount(amountFen).spoken(hidden: isHidden)))
                CouliButton(withdrawTitle, kind: .inverse, isEnabled: withdrawEnabled, action: onWithdraw)
                    .fixedSize()
                    .couliFlowPushTrailing(.inlineOnly)
            }
            footer
        }
        .foregroundColor(CouliColor.token("rebate.solid.text"))
        .padding(CouliSpacing.s5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: CouliRadius.card, style: .continuous)
                .fill(CouliColor.token("rebate.solid.background"))
        )
    }
}

public extension WalletHeroCard where Footer == EmptyView {
    init(
        title: String,
        amountFen: Int64,
        isHidden: Bool = false,
        withdrawTitle: String,
        onWithdraw: @escaping () -> Void
    ) {
        self.init(
            title: title,
            amountFen: amountFen,
            isHidden: isHidden,
            withdrawTitle: withdrawTitle,
            onWithdraw: onWithdraw,
            footer: { EmptyView() }
        )
    }
}

/// 主卡内的小数字行（冻结中 / 已提现等）：白字 14 起，两列，200% 时上下排；随 `amountHidden` 一起隐藏。
public struct HeroAmountRow: View {
    private let items: [AmountGridItem]
    private let amountHidden: Bool
    private let valueStyle: CouliTextStyle
    private let onHelp: (AmountGridItem) -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    public init(
        items: [AmountGridItem],
        amountHidden: Bool = false,
        valueStyle: CouliTextStyle = .body,
        onHelp: @escaping (AmountGridItem) -> Void = { _ in }
    ) {
        self.items = items
        self.amountHidden = amountHidden
        self.valueStyle = valueStyle
        self.onHelp = onHelp
    }

    public var body: some View {
        let layout = dynamicTypeSize >= .accessibility1
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: CouliSpacing.s3))
            : AnyLayout(HStackLayout(alignment: .top, spacing: CouliSpacing.s4))
        layout {
            ForEach(items, id: \.self) { item in
                VStack(alignment: .leading, spacing: CouliSpacing.s1) {
                    HStack(spacing: CouliSpacing.s1) {
                        // 狸橙实底上一律白字；钟表与 AmountGrid 同一判定（无返利 / ¥0 不带返利图形）。
                        if item.usesRebateAccent(amountHidden: amountHidden) {
                            CouliIconView(.clock, size: CouliComponentMetric.iconInline, relativeTo: .footnote)
                        }
                        Text(verbatim: item.label)
                            .couliFont(.footnote, weight: .couliMedium)
                            .accessibilityLabel(Text(verbatim: item.accessibilityText(hidden: amountHidden)))
                        if let helpLabel = item.helpLabel {
                            HelpButton(label: helpLabel) { onHelp(item) }
                        }
                    }
                    // 有无问号的两列标签行同高，数值对齐。
                    .frame(minHeight: CouliComponentMetric.iconInline + CouliSpacing.s2, alignment: .leading)
                    AmountText(item.value, hidden: amountHidden, style: valueStyle, weight: .couliBold)
                        .accessibilityHidden(true)
                    if let note = item.note {
                        Text(verbatim: note.display(hidden: amountHidden))
                            .couliFont(.footnote, weight: .couliSemibold, monospacedDigits: true)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityHidden(true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .contain)
            }
        }
        .dynamicTypeSize(...DynamicTypeSize.accessibility2)
    }
}
