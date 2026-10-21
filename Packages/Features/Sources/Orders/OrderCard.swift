import DesignSystem
import OrderCore
import SwiftUI

/// 列表卡（设计稿 Orders 卡、A11yHitOrders）：来源 + 付款时间 → 商品图 + 标题 + 件数 → 订单号（自购带独立的【复制】）→ 金额格 → 状态行。
/// 整卡（除【复制】外）是一个打开详情的目标；【复制】是独立的第二个目标，点击不穿透（Button 优先于外层点按手势）。
/// 列表卡只显示状态文案（H09 同口径：月份、入账句等 hint 只在详情显示）。
struct OrderCard: View {
    let item: OrderSummary
    let texts: OrderTexts
    let hidden: Bool
    let now: Int64
    let onOpen: () -> Void
    let onCopy: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: CouliSpacing.s3) {
            top
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isButton)
                .accessibilityAction { onOpen() }
                .accessibilityIdentifier("order.card.open")
            OrderNumberRow(summary: item, texts: texts, onCopy: onCopy)
            VStack(alignment: .leading, spacing: CouliSpacing.s2) {
                OrderAmountBlock(summary: item, texts: texts, hidden: hidden)
                OrderStatusLine(summary: item, texts: texts, hidden: hidden)
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { onOpen() }
        }
        .couliCard()
        .contentShape(Rectangle())
        .onTapGesture(perform: onOpen)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("order.card.\(item.orderId)")
    }

    private var top: some View {
        let title = OrderTitleImage.view(item)
        return VStack(alignment: .leading, spacing: CouliSpacing.s2) {
            HStack(spacing: CouliSpacing.s2) {
                let name = texts.text("platform." + item.platform)
                if !name.isEmpty {
                    PlatformBadge(name, platformCode: item.platform)
                }
                if let paid = OrderFormat.paidMillis(item) {
                    Text(verbatim: CouliFormat.timeListPast(epochMillis: paid, nowEpochMillis: now))
                        .couliFont(.caption, monospacedDigits: true)
                        .foregroundColor(CouliColor.textSecondary)
                }
            }
            HStack(alignment: .top, spacing: CouliSpacing.s3) {
                OrderImage(url: title.imageUrl, texts: texts)
                VStack(alignment: .leading, spacing: CouliSpacing.s1) {
                    if let text = title.title ?? title.titleKey.map(texts.text) {
                        Text(verbatim: text)
                            .couliFont(.body)
                            .foregroundColor(CouliColor.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let quantity = item.quantity {
                        Text(verbatim: texts.format(OrderKeys.quantity, ["n": String(quantity)]))
                            .couliFont(.footnote)
                            .foregroundColor(CouliColor.textSecondary)
                    }
                }
                Spacer(minLength: 0)
            }
        }
    }
}
