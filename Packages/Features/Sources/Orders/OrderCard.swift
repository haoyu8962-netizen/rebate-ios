import DesignSystem
import OrderCore
import SwiftUI

/// 列表卡（设计稿 Orders-v2 / OrdersShare-v2，brief §2.2）：头行 来源徽标 + 付款时间（右对齐）→ 64 商品图 + 右列（标题 14/500 单行省略 →
/// 件数 → 订单号 +【复制】紧随）→ 分隔线 → 两列金额格（17/600，左实付右返利）→ 状态胶囊。列表不显示月份 / 入账句（G-O02）。
/// 整卡（除【复制】外）是一个打开详情的目标、读屏一项（平台、商品名、件数、单号、金额、状态）；【复制】是独立的第二个目标，点击不穿透。
struct OrderCard: View {
    let item: OrderSummary
    let texts: OrderTexts
    let hidden: Bool
    let now: Int64
    let onOpen: () -> Void
    let onCopy: (String) -> Void

    private var probe: String {
        "order.card.\(item.orderId)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: CouliSpacing.s3) {
            // 可见文字都不单独进读屏（由整卡一项读出）；只有【复制】是第二项
            header.accessibilityHidden(true)
            product
            Rectangle()
                .fill(CouliColor.borderSubtle)
                .frame(height: 1)
                .couliProbe(probe + ".divider", role: "divider")
                .accessibilityHidden(true)
            OrderListAmounts(summary: item, texts: texts, hidden: hidden, probe: probe + ".amount")
                .accessibilityHidden(true)
            OrderStatusPill(summary: item, texts: texts, hidden: hidden, probe: probe + ".status")
                .accessibilityHidden(true)
        }
        .couliCard()
        .background(summaryElement)
        .contentShape(Rectangle())
        .onTapGesture(perform: onOpen)
        .couliProbe(probe, role: "card")
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(probe)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: CouliSpacing.s2) {
            let name = texts.text("platform." + item.platform)
            if !name.isEmpty {
                PlatformBadge(name, platformCode: item.platform)
                    .couliProbe(probe + ".badge", role: "badge")
            }
            Spacer(minLength: CouliSpacing.s2)
            if let paid = OrderFormat.paidMillis(item) {
                OrderProbedText(CouliFormat.timeListPast(epochMillis: paid, nowEpochMillis: now), style: .caption,
                                monospacedDigits: true, probeID: probe + ".time")
                    .foregroundColor(CouliColor.textSecondary)
            }
        }
    }

    private var product: some View {
        let title = OrderTitleImage.view(item)
        return HStack(alignment: .top, spacing: CouliSpacing.s3) {
            OrderImage(url: title.imageUrl, texts: texts, otherProduct: item.isOtherProduct, probe: probe)
            VStack(alignment: .leading, spacing: CouliSpacing.s1) {
                if let text = title.title ?? title.titleKey.map(texts.text) {
                    OrderProbedText(text, style: .footnote, weight: .couliMedium, probeID: probe + ".title")
                        .foregroundColor(item.isOtherProduct ? CouliColor.textSecondary : CouliColor.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .accessibilityHidden(true)
                }
                if let quantity = item.quantity {
                    Text(verbatim: texts.format(OrderKeys.quantity, ["n": String(quantity)]))
                        .couliFont(.caption)
                        .foregroundColor(CouliColor.textSecondary)
                        .couliProbe(probe + ".quantity", role: "text")
                        .accessibilityHidden(true)
                }
                OrderListNumber(summary: item, texts: texts, probe: probe, onCopy: onCopy)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// 整卡读屏一项：平台、商品名、件数、单号（脱敏号的「*」读作星号）、金额（隐藏时读「金额已隐藏」）、状态。
    private var summaryElement: some View {
        Color.clear
            .accessibilityElement()
            .accessibilityLabel(Text(verbatim: OrderCardSpeech.label(item, texts: texts, hidden: hidden)))
            .accessibilityAddTraits(.isStaticText)
            .accessibilitySortPriority(1)
            .accessibilityAction { onOpen() }
            .accessibilityIdentifier(OrderNumberDisplay.view(item).copyable ? "order.number" : "order.maskedNumber")
    }
}
