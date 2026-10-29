import DesignSystem
import Generated
import OrderCore
import SwiftUI
import UIKit

// APP-08v-b 订单详情的小部件（brief §2.4）：两列金额（左返利、右实付，G-O07）、卡内按钮（视觉 40 + 透明命中扩展，G-O06）、
// 强调色文字入口（命中 44）、骨架。测量只在有接收方（Debug 测试宿主）时上报，Release 没有接收方、不多画任何视图。

/// 详情的两列金额格（brief §2.4-2；AdaptLargeTextOrderDetail）：**左返利类、右实付**（与列表相反，G-O07）；返利 28/700（返利色；
/// INVALID「¥0」与扣回「-¥8」墨棕），实付 22/600 墨棕，数值底对齐。只用服务端字段：金额为 null 的格只显示标签、不补 0、不推算；
/// DEPOSIT_PAID 只一格「已付定金」，NO_REBATE / 未知状态只一格实付（`OrderAmountCells` 不变）。两格各自放得进半宽就并排，
/// 否则或辅助字号档上下排、返利在上。隐藏开关只管返利类格（「****」，读「金额已隐藏」）；实付 / 定金不隐藏。
struct OrderDetailAmounts: View {
    let summary: OrderSummary
    let texts: OrderTexts
    let hidden: Bool
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: CouliTextStyle.heading.relativeTo) private var rebateSize = CouliTextStyle.heading
        .baseSize
    @ScaledMetric(relativeTo: CouliTextStyle.title.relativeTo) private var paidSize = CouliTextStyle.title.baseSize

    var body: some View {
        let view = OrderAmountCells.view(summary)
        OrderDetailAmountsLayout(
            columnSpacing: CouliSpacing.s4, rowSpacing: CouliSpacing.s3,
            forceStacked: dynamicTypeSize >= .accessibility1
        ) {
            if let right = view.right {
                cell(right, rebate: true)
            }
            cell(view.left, rebate: false)
        }
    }

    private func cell(_ cell: AmountCellView, rebate: Bool) -> some View {
        let text = OrderListAmountText.display(cell, hidden: hidden && rebate)
        let accent = rebate && text != nil && !cell.fixedZero && !cell.minus && (hidden || (cell.fen ?? 0) > 0)
        let label = texts.text(cell.labelKey)
        let style: CouliTextStyle = rebate ? .heading : .title
        let weight: Font.Weight = rebate ? .couliBold : .couliSemibold
        let size = rebate ? rebateSize : paidSize
        let spoken = rebate && hidden && cell.maskable && cell.fen != nil ? texts.text(OrderKeys.hiddenSpoken)
            : (text ?? "")
        return VStack(alignment: .leading, spacing: CouliSpacing.s1) {
            Text(verbatim: label)
                .couliFont(.caption)
                .foregroundColor(accent ? CouliColor.brandEmphasis : CouliColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if let text {
                CouliUnbreakableText(text, size: style.baseSize, weight: weight, relativeTo: style.relativeTo,
                                     probeID: rebate ? "orderDetail.amount.rebate" : "orderDetail.amount.paid",
                                     role: "amount", lineHeightMultiple: style.lineHeightMultiple,
                                     naturalWidth: Self.naturalWidth(
                                         text,
                                         size: size,
                                         weight: rebate ? .bold : .semibold
                                     ))
                                     .foregroundColor(accent ? CouliColor.brandEmphasis : CouliColor.textPrimary)
                                     .id(size)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: spoken.isEmpty ? label : label + PriceTerms.spokenPause + spoken))
    }

    /// 同一字体（系统字体、等宽数字）下金额段的单行宽度（APP-06v K6：隐藏副本在环境变化时不一定再报一次）。
    static func naturalWidth(_ text: String, size: CGFloat, weight: UIFont.Weight) -> CGFloat {
        let font = UIFont.monospacedDigitSystemFont(ofSize: size, weight: weight)
        return (text as NSString).size(withAttributes: [.font: font]).width
    }
}

/// 两列 / 上下排（子视图顺序即读屏与纵排顺序：返利格在前、实付格在后）：两格的理想宽都放得进半宽就并排、数值底对齐，
/// 否则上下排、返利在上。
struct OrderDetailAmountsLayout: Layout {
    let columnSpacing: CGFloat
    let rowSpacing: CGFloat
    let forceStacked: Bool

    private func sideBySide(_ subviews: Subviews, width: CGFloat?) -> Bool {
        guard subviews.count == 2, !forceStacked else { return false }
        guard let width, width.isFinite else { return true }
        let column = (width - columnSpacing) / 2
        return subviews.allSatisfy { $0.sizeThatFits(.unspecified).width <= column + 0.5 }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache _: inout ()) -> CGSize {
        if sideBySide(subviews, width: proposal.width) {
            let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
            let width = proposal.width ?? (sizes.map(\.width).reduce(0, +) + columnSpacing)
            return CGSize(width: width, height: sizes.map(\.height).max() ?? 0)
        }
        let row = ProposedViewSize(width: proposal.width, height: nil)
        let sizes = subviews.map { $0.sizeThatFits(row) }
        let height = sizes.map(\.height).reduce(0, +) + rowSpacing * CGFloat(max(sizes.count - 1, 0))
        return CGSize(width: proposal.width ?? (sizes.map(\.width).max() ?? 0), height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal _: ProposedViewSize, subviews: Subviews, cache _: inout ()) {
        if sideBySide(subviews, width: bounds.width) {
            let column = (bounds.width - columnSpacing) / 2
            let tallest = subviews.map { $0.sizeThatFits(.unspecified).height }.max() ?? 0
            for (index, subview) in subviews.enumerated() {
                let height = subview.sizeThatFits(.unspecified).height
                subview.place(at: CGPoint(x: bounds.minX + CGFloat(index) * (column + columnSpacing),
                                          y: bounds.minY + tallest - height),
                              proposal: ProposedViewSize(width: column, height: nil))
            }
            return
        }
        var originY = bounds.minY
        let row = ProposedViewSize(width: bounds.width, height: nil)
        for subview in subviews {
            subview.place(at: CGPoint(x: bounds.minX, y: originY), proposal: row)
            originY += subview.sizeThatFits(row).height + rowSpacing
        }
    }
}

/// 卡内按钮（G-O06：reason.action 按钮、扣回【查看流水】、未知状态【刷新】）：视觉高 40、圆角 12、14/600；一个时描边次按钮，
/// 两个时首个实心主按钮。命中区 = 视觉框上下各扩 2（≥ 44）、最小宽 44，只扩透明区、不撑高视觉（brief §9 风险 1）。
/// 不用共用 `CouliButton`（它的最小高 48 会撑高视觉 40；Android 决策 3 同做法），颜色取同一组按钮令牌。
struct OrderDetailCardButton: View {
    let title: String
    let filled: Bool
    let probe: String
    var enabled = true
    let action: () -> Void

    static let visualHeight = CouliSpacing.s10

    var body: some View {
        Button(action: action) {
            Text(verbatim: title)
                .couliFont(.footnote, weight: .couliSemibold)
                .foregroundColor(foreground)
                .fixedSize()
                .couliTextNaturalProbe(probe + ".label", role: "text", text: title, style: .footnote,
                                       weight: .couliSemibold)
                .padding(.horizontal, CouliSpacing.s4)
                // 大字号下按钮随文字增高、字与边框留出上下各 8（默认字号仍是视觉 40）
                .padding(.vertical, CouliSpacing.s2)
                .frame(minHeight: Self.visualHeight)
                .background(RoundedRectangle(cornerRadius: CouliRadius.button, style: .continuous).fill(background))
                .overlay(
                    RoundedRectangle(cornerRadius: CouliRadius.button, style: .continuous)
                        .strokeBorder(filled ? .clear : CouliColor.borderControl,
                                      lineWidth: CouliComponentMetric.controlBorderWidth)
                )
                .couliProbe(probe, role: "button")
                .padding(.vertical, (CouliHitTarget.minimum - Self.visualHeight) / 2)
                .frame(minWidth: CouliHitTarget.minimum)
                .contentShape(Rectangle())
        }
        .buttonStyle(OrderChipButtonStyle())
        .disabled(!enabled)
        .couliProbe(probe + ".hit", role: "hit")
    }

    private var foreground: Color {
        guard enabled else { return CouliColor.token("button.primary.disabled.text") }
        return filled ? CouliColor.token("button.primary.default.text") : CouliColor.textPrimary
    }

    private var background: Color {
        guard enabled else { return CouliColor.token("button.primary.disabled.background") }
        return filled ? CouliColor.token("button.primary.default.background") : CouliColor.backgroundSurface
    }
}

/// 强调色文字入口（「查看说明 ›」「查看申诉进度 ›」「查看商品 ›」「查看流水」）：14/600 `brand.emphasis`（可带 16 ›）；
/// 命中区 ≥ 44 × 44（视觉文字在命中区内，不加底色）。
struct OrderDetailLink: View {
    let title: String
    let probe: String
    var chevron = true
    var alignment: Alignment = .leading
    /// true：布局按命中区 44 占位（下方紧接另一个可点目标时，两个命中区由容器留出空间、互不重叠——Android b 评审 r1 S2-2）；
    /// false：布局只占文字行高，命中区上下透明外扩（附近没有别的可点目标时用，视觉间距与画板一致）。
    var reservesHitSpace = true
    let action: () -> Void
    @ScaledMetric(relativeTo: CouliTextStyle.footnote.relativeTo)
    private var lineHeight = CouliTextStyle.footnote.baseSize * CouliTextStyle.footnote.lineHeightMultiple

    var body: some View {
        Button(action: action) {
            HStack(alignment: .center, spacing: CouliSpacing.s0) {
                Text(verbatim: title)
                    .couliFont(.footnote, weight: .couliSemibold)
                    .fixedSize(horizontal: false, vertical: true)
                    .couliLineBox(.footnote)
                if chevron {
                    CouliIconView(.chevron, size: CouliGuideMetric.iconInline, relativeTo: .footnote)
                }
            }
            .foregroundColor(CouliColor.brandEmphasis)
            .couliProbe(probe + ".label", role: "label")
            .frame(minWidth: CouliHitTarget.minimum, minHeight: CouliHitTarget.minimum, alignment: alignment)
            .contentShape(Rectangle())
        }
        .buttonStyle(OrderChipButtonStyle())
        .couliProbe(probe, role: "hit")
        .padding(.vertical, reservesHitSpace ? 0 : -max((CouliHitTarget.minimum - lineHeight) / 2, 0))
        .accessibilityLabel(Text(verbatim: title))
    }
}

/// 灰胶囊（WAITING「预计 {M} 月结算」、「申诉中」）：高 22（最小高，随字号增高）、左右 8、`background.muted`、12 次文字，可带 14 图标。
struct OrderDetailMutedPill: View {
    let text: String
    let probe: String
    var icon: CouliIcon?

    var body: some View {
        HStack(alignment: .center, spacing: CouliSpacing.s1) {
            if let icon {
                CouliIconView(icon, size: CouliGuideMetric.iconSmall, relativeTo: .caption)
            }
            OrderProbedText(text, style: .caption, probeID: probe + ".label")
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundColor(CouliColor.textSecondary)
        .padding(.horizontal, CouliSpacing.s2)
        .frame(minHeight: CouliGuideMetric.tagMinHeight)
        .background(Capsule().fill(CouliColor.backgroundMuted))
        .couliProbe(probe, role: "pill", text: text)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: text))
    }
}

/// 详情加载骨架（brief §2.5）：按真实结构摆三块——状态卡（标题行 + 两列数字块）、商品卡（徽标 + 64 图 + 三行）、时间线 4 行。
struct OrderDetailSkeleton: View {
    var body: some View {
        VStack(alignment: .leading, spacing: CouliSpacing.s3) {
            VStack(alignment: .leading, spacing: CouliSpacing.s3) {
                HStack(spacing: CouliSpacing.s2) {
                    SkeletonBlock(width: 20, height: 20)
                    SkeletonBlock(width: 160, height: 20)
                }
                HStack(alignment: .bottom, spacing: CouliSpacing.s4) {
                    SkeletonBlock(width: 96, height: 36)
                    SkeletonBlock(width: 80, height: 28)
                }
            }
            .couliCard()
            .couliProbe("orderDetail.skeleton.status", role: "skeleton")
            VStack(alignment: .leading, spacing: CouliSpacing.s3) {
                SkeletonBlock(width: 60, height: 22)
                HStack(alignment: .top, spacing: CouliSpacing.s3) {
                    SkeletonBlock(width: OrderLayout.imageSize, height: OrderLayout.imageSize)
                    VStack(alignment: .leading, spacing: CouliSpacing.s2) {
                        SkeletonBlock(height: 16)
                        SkeletonBlock(width: 60, height: 12)
                        SkeletonBlock(width: 180, height: 12)
                    }
                }
            }
            .couliCard()
            VStack(alignment: .leading, spacing: CouliSpacing.s4) {
                ForEach(0..<4, id: \.self) { _ in
                    HStack(alignment: .top, spacing: CouliSpacing.s3) {
                        SkeletonBlock(width: 8, height: 8)
                        VStack(alignment: .leading, spacing: CouliSpacing.s1) {
                            SkeletonBlock(width: 72, height: 14)
                            SkeletonBlock(width: 120, height: 12)
                        }
                    }
                }
            }
            .couliCard()
        }
    }
}
