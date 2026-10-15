import DesignSystem
import Generated
import OrderCore
import SwiftUI

extension OrderDetailScreen {
    // MARK: - 时间线

    @ViewBuilder func timelineCard(_ detail: OrderDetail) -> some View {
        let rows = OrderTimelineView.rows(detail.summary.displayStatus, detail.timeline, nowMs: config.now())
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: CouliSpacing.s3) {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    timelineRow(row)
                }
            }
            .couliCard()
            .accessibilityElement(children: .contain)
            .accessibilityLabel(Text(verbatim: texts.text(OrderKeys.timeline)))
            .accessibilityIdentifier("orderDetail.timeline")
        }
    }

    func timelineRow(_ row: TimelineRow) -> some View {
        let label: String = switch row.node {
        case .depositPaid, .finalPaid:
            // 「付定金 {time}」「付尾款 {time}」：没有时间时用同一个键的 fallback（只显示「付定金」）
            texts.format(row.labelKey, ["time": row.time ?? ""])
        case .creditExpected:
            row.monthText.map { texts.format(OrderKeys.creditExpectedMonth, ["credit_period": $0]) }
                ?? texts.text(row.labelKey)
        default:
            texts.text(row.labelKey)
        }
        let showsTime = row.time != nil && row.node != .depositPaid && row.node != .finalPaid
        return HStack(alignment: .top, spacing: CouliSpacing.s3) {
            Circle()
                .strokeBorder(row.grey ? CouliColor.textSecondary : CouliColor.brandPrimary, lineWidth: 1.5)
                .background(Circle().fill(row.grey ? Color.clear : CouliColor.brandPrimary))
                .frame(width: 10, height: 10)
                .padding(.top, CouliSpacing.s1)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: label)
                    .couliFont(.body)
                    .foregroundColor(row.grey ? CouliColor.textSecondary : CouliColor.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                if showsTime, let time = row.time {
                    Text(verbatim: time)
                        .couliFont(.footnote, monospacedDigits: true)
                        .foregroundColor(CouliColor.textSecondary)
                }
            }
        }
        .accessibilityElement(children: .combine)
        // 未发生的节点读出「未发生」状态
        .accessibilityValue(Text(verbatim: row.grey ? texts.text(OrderKeys.notHappened) : ""))
        .accessibilityIdentifier("orderDetail.timeline.\(row.node.rawValue)")
    }

    // MARK: - 底部按钮

    func bottomBar(_ buttons: [OrderActionButton]) -> some View {
        HStack(spacing: CouliSpacing.s3) {
            ForEach(Array(buttons.enumerated()), id: \.offset) { _, button in
                CouliButton(
                    texts.text(button.labelKey), kind: button.primary ? .primary : .secondary, fillsWidth: true
                ) {
                    if button.actionRaw == "contact_cs", config.onContactService() {
                        return
                    }
                    config.onOpen(RouteTarget(route: button.route, params: [:]))
                }
                .accessibilityIdentifier("orderDetail.action.\(button.actionRaw)")
            }
        }
        .padding(.horizontal, CouliSpacing.s4)
        .padding(.vertical, CouliSpacing.s3)
        .frame(maxWidth: OrderLayout.maxContentWidth)
        .frame(maxWidth: .infinity)
        .background(CouliColor.backgroundSurface.ignoresSafeArea(edges: .bottom))
    }
}
