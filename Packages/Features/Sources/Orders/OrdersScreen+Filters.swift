import DesignSystem
import Generated
import OrderCore
import SwiftUI

/// 分组胶囊与筛选行（brief §2.1 第 6、7 条）：同款胶囊视觉高 32、左右 12、14 字；未选白底 + 1 `border.subtle`、选中 `brand.subtle` 底
/// （边同色）+ `brand.emphasis` 600；筛选胶囊另带 16 下箭头。命中区 = 视觉框上下各扩 6（≥ 44），只扩透明区、不撑高视觉。
extension OrdersScreen {
    /// 命中区比视觉 32 多出的上下扩展（各 6，合计 44）。
    static var chipHitInset: CGFloat {
        (CouliHitTarget.minimum - OrderLayout.chipHeight) / 2
    }

    var groupChips: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: CouliSpacing.s2) {
                    ForEach(OrderQuery.groups, id: \.self) { group in
                        let selected = snapshot.query.group == group
                        Button {
                            controller.setGroup(group)
                        } label: {
                            OrderChipLabel(selected: selected, probe: "orders.group.\(group)") {
                                Text(verbatim: texts.text(OrderKeys.groupPrefix + group))
                                    .couliFont(.footnote, weight: selected ? .couliSemibold : .regular)
                                    .foregroundColor(selected ? CouliColor.brandEmphasis : CouliColor.textPrimary)
                                    .fixedSize()
                            }
                        }
                        .buttonStyle(OrderChipButtonStyle())
                        .disabled(snapshot.blocked)
                        .couliProbe("orders.group.\(group).hit", role: "hit")
                        .accessibilityAddTraits(selected ? [.isSelected] : [])
                        .accessibilityIdentifier("orders.group.\(group)")
                        .id(group)
                    }
                }
            }
            .onChange(of: snapshot.query.group) { group in
                withAnimation { proxy.scrollTo(group, anchor: .center) }
            }
        }
    }

    var filterRow: some View {
        // 已选长筛选（平台 + 「2026 年 10 月」）在窄屏大字号下换行：眼睛也在同一排法里、贴行尾（共性第 11 条），胶囊可用整行宽，
        // 换行发生在胶囊之间、不在胶囊文字中间（「10」与「月」不拆开，评审 r1 S2-5）；眼睛放不下时整体换到下一行、仍贴右、命中区完整
        CouliFlowLayout(horizontalSpacing: CouliSpacing.s2, verticalSpacing: CouliSpacing.s1) {
            filterButton(
                label: snapshot.query.platform.map { texts.text("platform." + $0) } ?? texts
                    .text(OrderKeys.filterPlatform),
                sheet: .platform, focus: $platformFocused
            )
            filterButton(label: monthLabel, sheet: .month, focus: $monthFocused)
            AmountMaskButton(mask: mask, texts: texts)
                .couliProbe("orders.mask.hit", role: "hit")
                .fixedSize()
                .couliFlowPushTrailing(.always)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    var monthLabel: String {
        guard let month = snapshot.query.month, let parts = OrderFormat.monthParts(month) else {
            return texts.text(OrderKeys.filterMonth)
        }
        return texts.format(OrderKeys.monthItem, ["year": parts.year, "month": parts.month])
    }

    func filterButton(
        label: String, sheet: OrderFilterSheet, focus: AccessibilityFocusState<Bool>.Binding
    ) -> some View {
        let open = config.sheet == sheet
        let probe = "orders.filter.\(sheet.rawValue)"
        return Button {
            config.sheet = sheet
        } label: {
            OrderChipLabel(selected: false, probe: probe) {
                HStack(alignment: .center, spacing: CouliSpacing.s1) {
                    Text(verbatim: label)
                        .couliFont(.footnote)
                        .foregroundColor(CouliColor.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                        .layoutPriority(1)
                    CouliIconView(.chevronDown, size: CouliGuideMetric.iconInline, relativeTo: .footnote)
                        .foregroundColor(CouliColor.textSecondary)
                        .fixedSize()
                        .couliProbe(probe + ".chevron", role: "icon")
                }
            }
        }
        .buttonStyle(OrderChipButtonStyle())
        .disabled(snapshot.blocked)
        .couliProbe(probe + ".hit", role: "hit")
        .accessibilityFocused(focus)
        .accessibilityValue(Text(verbatim: texts.text(open ? OrderKeys.expanded : OrderKeys.collapsed)))
        .accessibilityIdentifier(probe)
    }
}

/// 胶囊外观 + 透明命中扩展：视觉框（最小高 32、左右 12、白底描边 / 选中浅强调底）上下各扩 6、最小宽 44 作为按钮的可点区。
struct OrderChipLabel<Content: View>: View {
    let selected: Bool
    let probe: String
    @ViewBuilder let content: Content

    var body: some View {
        content
            .padding(.horizontal, CouliSpacing.s3)
            .frame(minHeight: OrderLayout.chipHeight)
            .background(Capsule().fill(selected ? CouliColor.brandSubtle : CouliColor.backgroundSurface))
            .overlay(Capsule().strokeBorder(selected ? CouliColor.brandSubtle : CouliColor.borderSubtle, lineWidth: 1))
            .couliProbe(probe, role: "chip")
            .padding(.vertical, OrdersScreen.chipHitInset)
            .frame(minWidth: CouliHitTarget.minimum)
            .contentShape(Rectangle())
    }
}

/// 胶囊按钮的按下态：只降低不透明度（命中扩展区不画按下底色，视觉框不变）。
struct OrderChipButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.opacity(configuration.isPressed ? 0.6 : 1)
    }
}
