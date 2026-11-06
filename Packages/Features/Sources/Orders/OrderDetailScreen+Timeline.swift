import DesignSystem
import Generated
import OrderCore
import SwiftUI

/// 时间线节点的画法（纯视图，按画板）：已发生 / 当前 / 未发生。
enum OrderTimelineNodeKind {
    case done
    case current
    case future

    /// 当前节点只在状态本身落在时间线某节点上时标（Android b 决策 2 同口径）：WAITING 为「预计 {M} 月结算」行，PAID / DEPOSIT_PAID /
    /// 已结算 / 部分扣回 / 已扣回 / 已失效为最后一个已发生节点；售后处理中、入账核对中、本单无返利、未知状态不标。
    static func current(_ status: DisplayStatus, _ rows: [TimelineRow]) -> Int? {
        let marked: Set<DisplayStatus> = [
            .paid, .depositPaid, .waiting, .credited, .creditedPartClawed, .clawedBack, .invalid,
        ]
        guard marked.contains(status) else { return nil }
        if let month = rows.firstIndex(where: { $0.monthText != nil }) {
            return month
        }
        return rows.lastIndex { !$0.grey }
    }
}

extension OrderDetailScreen {
    // MARK: - 时间线

    /// 时间线卡（brief §2.4-4）：左侧 16 宽轨道——已发生 8 实心（次文字色）、未发生 8 空心（`border.control` 描边）、当前节点加外环
    /// 且名称 600（CREDITED 用成功色）；节点间 1 竖线（`border.subtle`）；节点名 14、时间 12 次文字。节点与 G16 月份规则不变。
    @ViewBuilder func timelineCard(_ detail: OrderDetail) -> some View {
        let status = detail.summary.displayStatus
        let rows = OrderTimelineView.rows(status, detail.timeline, nowMs: config.now())
        if !rows.isEmpty {
            let current = OrderTimelineNodeKind.current(status, rows)
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                    let kind: OrderTimelineNodeKind = index == current ? .current : (row.grey ? .future : .done)
                    timelineRow(row, index: index, kind: kind, last: index == rows.count - 1,
                                settled: status == .credited)
                }
            }
            .couliCard()
            .accessibilityElement(children: .contain)
            .accessibilityLabel(Text(verbatim: texts.text(OrderKeys.timeline)))
            .accessibilityIdentifier("orderDetail.timeline")
            .couliProbe("orderDetail.timeline", role: "card")
        }
    }

    func timelineLabel(_ row: TimelineRow) -> String {
        switch row.node {
        case .depositPaid, .finalPaid:
            // 「付定金 {time}」「付尾款 {time}」：只取名称（同一个键的 fallback），时间单独一行（OrderDetailPresale-v2）
            texts.format(row.labelKey, [:]).trimmingCharacters(in: .whitespaces)
        case .creditExpected:
            row.monthText.map { texts.format(OrderKeys.creditExpectedMonth, ["credit_period": $0]) }
                ?? texts.text(row.labelKey)
        default:
            texts.text(row.labelKey)
        }
    }

    func timelineRow(_ row: TimelineRow, index: Int, kind: OrderTimelineNodeKind, last: Bool,
                     settled: Bool) -> some View {
        let dotArea = (CouliTextStyle.footnote.baseSize * CouliTextStyle.footnote.lineHeightMultiple).rounded()
        let labelColor: Color = switch kind {
        case .current: settled ? CouliColor.statusSuccessText : CouliColor.textPrimary
        case .future: CouliColor.textSecondary
        case .done: CouliColor.textPrimary
        }
        return HStack(alignment: .top, spacing: CouliSpacing.s3) {
            timelineDot(kind, settled: settled, probe: "orderDetail.timeline.dot.\(index)")
                .frame(width: CouliSpacing.s4, height: dotArea)
            VStack(alignment: .leading, spacing: 0) {
                Text(verbatim: timelineLabel(row))
                    .couliFont(.footnote, weight: kind == .current ? .couliSemibold : .regular)
                    .foregroundColor(labelColor)
                    .fixedSize(horizontal: false, vertical: true)
                    .couliLineBox(.footnote)
                if let time = row.time {
                    Text(verbatim: time)
                        .couliFont(.caption, monospacedDigits: true)
                        .foregroundColor(CouliColor.textSecondary)
                        .couliLineBox(.caption)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, last ? 0 : CouliSpacing.s4)
        }
        .overlay(alignment: .topLeading) {
            if !last {
                // 节点间 1 竖线：从本节点圆点下方到本行底（下一节点之前）
                Rectangle()
                    .fill(CouliColor.borderSubtle)
                    .frame(width: CouliComponentMetric.controlBorderWidth)
                    .frame(maxHeight: .infinity)
                    .couliProbe("orderDetail.timeline.line.\(index)", role: "line")
                    .padding(.top, dotArea / 2 + CouliSpacing.s2)
                    .padding(.leading, (CouliSpacing.s4 - CouliComponentMetric.controlBorderWidth) / 2)
                    .accessibilityHidden(true)
            }
        }
        .accessibilityElement(children: .combine)
        // 未发生的节点读出「未发生」状态
        .accessibilityValue(Text(verbatim: row.grey ? texts.text(OrderKeys.notHappened) : ""))
        .accessibilityIdentifier("orderDetail.timeline.\(row.node.rawValue)")
    }

    @ViewBuilder func timelineDot(_ kind: OrderTimelineNodeKind, settled: Bool, probe: String) -> some View {
        let size = CouliSpacing.s2
        switch kind {
        case .current:
            ZStack {
                Circle().fill(settled ? CouliColor.statusSuccessBackground : CouliColor.backgroundMuted)
                    .frame(width: CouliSpacing.s4, height: CouliSpacing.s4)
                Circle().fill(settled ? CouliColor.statusSuccessText : CouliColor.textPrimary)
                    .frame(width: size, height: size)
                    .couliProbe(probe, role: "dot")
            }
            .accessibilityHidden(true)
        case .done:
            Circle().fill(CouliColor.textSecondary)
                .frame(width: size, height: size)
                .couliProbe(probe, role: "dot")
                .accessibilityHidden(true)
        case .future:
            Circle().fill(CouliColor.backgroundSurface)
                .overlay(Circle().strokeBorder(
                    CouliColor.borderControl,
                    lineWidth: CouliComponentMetric.controlBorderWidth
                ))
                .frame(width: size, height: size)
                .couliProbe(probe, role: "dot")
                .accessibilityHidden(true)
        }
    }

    // MARK: - 问问 AI

    /// 【问问 AI】整行卡（brief §2.4-5，时间线之后；G-I02）：白卡、32 方块图标底（`brand.subtle`、圆角 8、对话图标 20 强调色）+
    /// 「问问 AI」17/500 + 行尾 ›；整行一个目标（≥ 44）。去向由 App 给（AgentChat 带 context.order_id、不自动发送）。
    func askAIRow(_ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(alignment: .center, spacing: CouliSpacing.s3) {
                ZStack {
                    RoundedRectangle(cornerRadius: CouliRadius.small, style: .continuous)
                        .fill(CouliColor.brandSubtle)
                    CouliIconView(.chat, size: CouliComponentMetric.iconMedium)
                        .foregroundColor(CouliColor.brandEmphasis)
                }
                .frame(width: CouliSpacing.s8, height: CouliSpacing.s8)
                .couliProbe("orderDetail.askAI.icon", role: "icon")
                OrderProbedText(texts.text(OrderKeys.askAI), style: .body, weight: .couliMedium,
                                probeID: "orderDetail.askAI.label")
                    .foregroundColor(CouliColor.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: CouliSpacing.s2)
                CouliIconView(.chevron, size: CouliComponentMetric.iconMedium)
                    .foregroundColor(CouliColor.textSecondary)
            }
            .padding(.horizontal, CouliSpacing.s4)
            .padding(.vertical, CouliSpacing.s3)
            .frame(minHeight: CouliHitTarget.minimum)
            .couliCard(padding: 0)
            .contentShape(Rectangle())
        }
        .buttonStyle(OrderChipButtonStyle())
        .accessibilityLabel(Text(verbatim: texts.text(OrderKeys.askAI)))
        .accessibilityIdentifier("orderDetail.askAI")
        .couliProbe("orderDetail.askAI", role: "row")
    }

    // MARK: - 底部固定栏

    /// 底部固定栏（G-O06）：只放状态固有的【去提现】；白底铺满整宽（含底部安全区）+ 顶部 1 分隔线，内部内容限宽 600 居中，
    /// 内边距 上 12 / 左右 16 / 下 max(安全区, 16)；通栏主按钮高 48。底栏按钮一律实心主按钮（评审 r1 S2-1）：G-O06 把主次外观
    /// 交给视图分区（卡内按数量定主次），规则层的 primary 只表示顺序；已结算又下发 reason.action 时（规则给 [contact_cs*, withdraw]）
    /// 卡内一个描边、底栏仍是实心，与 Android 一致。按钮集合、顺序、去向不变。
    func bottomBar(_ buttons: [OrderActionButton]) -> some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(CouliColor.borderSubtle)
                .frame(height: CouliComponentMetric.controlBorderWidth)
                .accessibilityHidden(true)
            HStack(spacing: CouliSpacing.s3) {
                ForEach(Array(buttons.enumerated()), id: \.offset) { _, button in
                    CouliButton(
                        texts.text(button.labelKey), kind: .primary, fillsWidth: true
                    ) {
                        perform(button)
                    }
                    .couliProbe("orderDetail.action.\(button.actionRaw)", role: "button")
                    .accessibilityIdentifier("orderDetail.action.\(button.actionRaw)")
                }
            }
            .padding(.horizontal, CouliSpacing.s4)
            .padding(.top, CouliSpacing.s3)
            .padding(.bottom, max(CouliSpacing.s4 - bottomInset, 0))
            .frame(maxWidth: OrderLayout.maxContentWidth)
        }
        .frame(maxWidth: .infinity)
        .background(
            GeometryReader { proxy in
                CouliColor.backgroundSurface
                    .onAppear { bottomInset = proxy.safeAreaInsets.bottom }
                    .onChange(of: proxy.safeAreaInsets.bottom) { bottomInset = $0 }
            }
            .couliProbe("orderDetail.bottomBar", role: "bar")
            .ignoresSafeArea(edges: .bottom)
        )
    }
}
