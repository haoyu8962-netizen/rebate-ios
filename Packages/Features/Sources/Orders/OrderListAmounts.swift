import DesignSystem
import Generated
import OrderCore
import SwiftUI
import UIKit

/// 列表卡的两列金额格（brief §2.2，`AmountGrid` 数字格写法：标签 12 在上、数值 17/600 在下）：左实付金额 / 已付定金（墨棕），右返利类
/// （预估返 / 实返 / 预估推广收益 / 推广收益：有金额时标签与金额用 `brand.emphasis`；INVALID「返利 ¥0」与扣回墨棕）。
/// 只用服务端字段：金额为 null 的格只显示标签、不补 0、不由别的字段推算（G-O02）；未知状态没有返利格。隐藏开关只管返利类格（「****」）。
/// 两格各自放得进半宽（列间距 16）就并排，否则或辅助字号档上下排、返利在上（adaptation-a11y-spec §2）。金额段单行不拆、不缩字。
struct OrderListAmounts: View {
    let summary: OrderSummary
    let texts: OrderTexts
    let hidden: Bool
    let probe: String
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    /// 金额实际字号（17 随系统字号缩放，与 CouliUnbreakableText 同一曲线）：用来按同一字体直接量单行自然宽（APP-06v K6 同做法：
    /// 隐藏副本在环境变化导致尺寸变时不一定再报一次）。
    @ScaledMetric(relativeTo: CouliTextStyle.body.relativeTo) private var amountSize = CouliTextStyle.body.baseSize

    var body: some View {
        let view = OrderAmountCells.view(summary)
        OrderAmountColumnsLayout(
            columnSpacing: CouliSpacing.s4, rowSpacing: CouliSpacing.s3,
            forceStacked: dynamicTypeSize >= .accessibility1
        ) {
            cell(view.left, rebate: false, probe: probe + ".left")
            if let right = view.right {
                cell(right, rebate: true, probe: probe + ".right")
            }
        }
    }

    private func cell(_ cell: AmountCellView, rebate: Bool, probe: String) -> some View {
        let text = OrderListAmountText.display(cell, hidden: hidden && rebate)
        let accent = rebate && text != nil && !cell.fixedZero && !cell.minus && (hidden || (cell.fen ?? 0) > 0)
        return VStack(alignment: .leading, spacing: CouliSpacing.s1) {
            Text(verbatim: texts.text(cell.labelKey))
                .couliFont(.caption)
                .foregroundColor(accent ? CouliColor.brandEmphasis : CouliColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .couliProbe(probe + ".label", role: "label")
            if let text {
                CouliUnbreakableText(text, size: CouliTextStyle.body.baseSize, weight: .couliSemibold,
                                     relativeTo: CouliTextStyle.body.relativeTo, probeID: probe, role: "amount",
                                     naturalWidth: naturalWidth(text))
                    .foregroundColor(accent ? CouliColor.brandEmphasis : CouliColor.textPrimary)
                    .id(amountSize)
            }
        }
    }
}

extension OrderListAmounts {
    /// 同一字体（系统字体、等宽数字、600）下金额段的单行宽度。
    func naturalWidth(_ text: String) -> CGFloat {
        let font = UIFont.monospacedDigitSystemFont(ofSize: amountSize, weight: .semibold)
        return (text as NSString).size(withAttributes: [.font: font]).width
    }
}

/// 金额格显示的字（只走 DesignSystem 的格式化，AGENTS 硬规则 3）。金额为 null 返回 nil（只显示标签）。
enum OrderListAmountText {
    static func display(_ cell: AmountCellView, hidden: Bool) -> String? {
        guard let fen = cell.fen else { return nil }
        if hidden, cell.maskable {
            return OrderAmountCells.mask
        }
        return CouliFormat.money(fen: cell.minus ? -fen : fen)
    }
}

/// 两列 / 上下排（第一个子视图实付格、第二个返利格）：两格的理想宽都放得进一列就并排（左实付右返利），否则上下排、返利在上。
struct OrderAmountColumnsLayout: Layout {
    let columnSpacing: CGFloat
    let rowSpacing: CGFloat
    let forceStacked: Bool

    private func sideBySide(_ subviews: Subviews, width: CGFloat?) -> Bool {
        guard subviews.count == 2, !forceStacked else { return false }
        guard let width, width.isFinite else { return true }
        let column = (width - columnSpacing) / 2
        return subviews.allSatisfy { $0.sizeThatFits(.unspecified).width <= column + 0.5 }
    }

    private func ordered(_ subviews: Subviews) -> [LayoutSubview] {
        subviews.count == 2 ? [subviews[1], subviews[0]] : Array(subviews)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache _: inout ()) -> CGSize {
        if sideBySide(subviews, width: proposal.width) {
            let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
            let width = proposal.width ?? (sizes.map(\.width).reduce(0, +) + columnSpacing)
            return CGSize(width: width, height: sizes.map(\.height).max() ?? 0)
        }
        let row = ProposedViewSize(width: proposal.width, height: nil)
        let sizes = ordered(subviews).map { $0.sizeThatFits(row) }
        let height = sizes.map(\.height).reduce(0, +) + rowSpacing * CGFloat(max(sizes.count - 1, 0))
        return CGSize(width: proposal.width ?? (sizes.map(\.width).max() ?? 0), height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal _: ProposedViewSize, subviews: Subviews, cache _: inout ()) {
        if sideBySide(subviews, width: bounds.width) {
            let column = (bounds.width - columnSpacing) / 2
            for (index, subview) in subviews.enumerated() {
                subview.place(at: CGPoint(x: bounds.minX + CGFloat(index) * (column + columnSpacing), y: bounds.minY),
                              proposal: ProposedViewSize(width: column, height: nil))
            }
            return
        }
        var originY = bounds.minY
        let row = ProposedViewSize(width: bounds.width, height: nil)
        for subview in ordered(subviews) {
            subview.place(at: CGPoint(x: bounds.minX, y: originY), proposal: row)
            originY += subview.sizeThatFits(row).height + rowSpacing
        }
    }
}

/// 整卡读屏一项的读名（brief §4.2）：平台、商品名、件数、单号、金额（返利隐藏时读「金额已隐藏」；null 的格不读）、状态。
@MainActor
enum OrderCardSpeech {
    static func label(_ item: OrderSummary, texts: OrderTexts, hidden: Bool) -> String {
        var parts: [String] = []
        let platform = texts.text("platform." + item.platform)
        if !platform.isEmpty {
            parts.append(platform)
        }
        let title = OrderTitleImage.view(item)
        if let text = title.title ?? title.titleKey.map(texts.text) {
            parts.append(text)
        }
        if let quantity = item.quantity {
            parts.append(texts.format(OrderKeys.quantity, ["n": String(quantity)]))
        }
        if let number = OrderNumberDisplay.view(item).text {
            let spoken = OrderNumberDisplay.spoken(number, star: texts.text(OrderKeys.starSpoken))
            parts.append(texts.format(OrderKeys.orderNo, ["no": spoken]))
        }
        let cells = OrderAmountCells.view(item)
        for (cell, rebate) in [(cells.left, false)] + (cells.right.map { [($0, true)] } ?? []) {
            guard cell.fen != nil else { continue }
            let value = rebate && hidden && cell.maskable ? texts.text(OrderKeys.hiddenSpoken)
                : OrderListAmountText.display(cell, hidden: false) ?? ""
            parts.append(texts.text(cell.labelKey) + " " + value)
        }
        parts.append(OrderStatusLine.label(item, texts: texts, hidden: hidden))
        return parts.joined(separator: PriceTerms.spokenPause)
    }
}
