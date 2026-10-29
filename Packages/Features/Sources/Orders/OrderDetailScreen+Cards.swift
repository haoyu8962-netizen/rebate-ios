import DesignSystem
import Generated
import OrderCore
import SwiftUI

extension OrderDetailScreen {
    // MARK: - 提示条

    /// 断网显示上次数据（共性第 26 条）：页顶警告浅底提示条（断网图标，同列表 OrdersStale-v2）+ 现有【重试】（读屏用户无法下拉）。
    func staleBanner(_ at: Int64, blocked: Bool) -> some View {
        let text = texts.format(
            OrderKeys.staleData, ["time": CouliFormat.timeListPast(epochMillis: at, nowEpochMillis: config.now())]
        )
        return VStack(alignment: .leading, spacing: CouliSpacing.s2) {
            HStack(alignment: .center, spacing: CouliSpacing.s2) {
                CouliIconView(.wifiOff, size: CouliGuideMetric.iconMedium, relativeTo: .footnote)
                Text(verbatim: text)
                    .couliFont(.footnote)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.updatesFrequently)
            }
            .foregroundColor(CouliColor.statusWarningText)
            // 缓存态的刷新入口：遵守共享 42901 禁用期
            CouliButton(texts.text(OrderKeys.retry), kind: .secondary, size: .compact, isEnabled: !blocked) {
                controller.refresh()
            }
            .accessibilityIdentifier("orderDetail.staleRetry")
        }
        .padding(CouliSpacing.s3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: CouliRadius.button, style: .continuous)
                .fill(CouliColor.statusWarningBackground)
        )
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("orderDetail.stale")
        .couliProbe("orderDetail.stale", role: "banner")
    }

    // MARK: - 状态卡

    /// 状态卡（brief §2.4-2）：标题行（状态图标 20 + 标题 17/600 heading + 眼睛）→ 两列金额（左返利右实付）→ WAITING 的月份灰胶囊 /
    /// DEPOSIT_PAID 提示紧跟金额 → 有下文时 1 分隔线 + 下文（其余提示、原因区、差额 / 比价行、申诉中块、卡内按钮、未知状态动作）。
    func statusCard(_ detail: OrderDetail, actions: OrderActionsView, split: OrderDetailActionSplit,
                    snapshot: OrderDetailSnapshot) -> some View {
        let summary = detail.summary
        let lower = OrderDetailLower(detail: detail, actions: actions, split: split, texts: texts,
                                     helpLinks: config.helpLinks(), nowMs: config.now())
        return VStack(alignment: .leading, spacing: CouliSpacing.s3) {
            statusTitleRow(summary)
            OrderDetailAmounts(summary: summary, texts: texts, hidden: mask.hidden)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("order.amounts")
            if let month = lower.creditMonth {
                OrderDetailMutedPill(text: texts.format(CreditPeriodText.waitingKey, ["credit_period": month]),
                                     probe: "orderDetail.creditPill")
                    .accessibilityIdentifier("orderDetail.hint")
            }
            if let hint = lower.depositHint {
                OrderProbedText(hint, style: .footnote, probeID: "orderDetail.hint")
                    .foregroundColor(CouliColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("orderDetail.hint")
            }
            if lower.hasContent {
                Rectangle()
                    .fill(CouliColor.borderSubtle)
                    .frame(height: CouliComponentMetric.controlBorderWidth)
                    .couliProbe("orderDetail.divider", role: "divider")
                    .accessibilityHidden(true)
                lowerSection(lower, blocked: snapshot.blocked || snapshot.refreshing)
            }
        }
        .couliCard()
        .accessibilityElement(children: .contain)
        .couliProbe("orderDetail.statusCard", role: "card")
    }

    /// 标题行：图标与色按状态（预估类钟表 + 次文字色；已结算对勾 + 成功色标题；INVALID / NO_REBATE / 未知 i；扣回三角）。
    func statusTitleRow(_ summary: OrderSummary) -> some View {
        let settled = OrderStatusIcon.settled(summary.displayStatus)
        return HStack(alignment: .center, spacing: CouliSpacing.s2) {
            CouliIconView(OrderStatusIcon.icon(summary.displayStatus), size: CouliGuideMetric.iconMedium)
                .foregroundColor(settled ? CouliColor.statusSuccessText : CouliColor.textSecondary)
                .couliProbe("orderDetail.status.icon", role: "icon")
            OrderProbedText(OrderStatusLine.label(summary, texts: texts, hidden: mask.hidden), style: .body,
                            weight: .couliSemibold, probeID: "orderDetail.status.title")
                .foregroundColor(settled ? CouliColor.statusSuccessText : CouliColor.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("orderDetail.status")
            Spacer(minLength: CouliSpacing.s2)
            // 眼睛：视觉 20、命中 44；命中区透明外扩（上下不撑高标题行、右侧伸进卡片内边距），图标与画板同位
            AmountMaskButton(mask: mask, texts: texts)
                .fixedSize()
                .padding(.vertical, -(CouliHitTarget.minimum - CouliGuideMetric.iconMedium) / 2)
                .padding(.trailing, -(CouliHitTarget.minimum - CouliGuideMetric.iconMedium) / 2)
        }
    }

    // MARK: - 商品

    /// 商品卡（brief §2.4-3）：头行 来源标签左 +「查看商品 ›」右（product_key 非空且非其他商品才有）；64 图 + 右列（标题 14/500 不省略
    /// → 件数 12 → 单号 +【复制】紧随，同列表排法）。分享单其他商品：占位底 + 文档图标、没有「查看商品」、脱敏单号无复制。
    func productCard(_ detail: OrderDetail) -> some View {
        let summary = detail.summary
        let title = OrderTitleImage.view(summary)
        let view = ViewProductEntry.view(detail)
        // 渲染这一刻固定【复制】票据（执行器、会话、详情版本、单号；共性第 41 条）
        let ticket = controller.copyTicket()
        let titleText = title.title ?? title.titleKey.map(texts.text)
        return VStack(alignment: .leading, spacing: CouliSpacing.s3) {
            HStack(alignment: .center, spacing: CouliSpacing.s2) {
                let name = texts.text("platform." + summary.platform)
                if !name.isEmpty {
                    PlatformBadge(name, platformCode: summary.platform)
                }
                Spacer(minLength: 0)
                if let view {
                    // 「查看商品」（F-ORD-16）：不占按钮名额；只带 platform、product_key
                    OrderDetailLink(title: texts.text(OrderKeys.viewProduct), probe: "orderDetail.viewProduct",
                                    alignment: .trailing, reservesHitSpace: false) {
                        config.onOpen(view)
                    }
                    .fixedSize()
                    .accessibilityIdentifier("orderDetail.viewProduct")
                }
            }
            productBody(summary, imageUrl: title.imageUrl, title: titleText, ticket: ticket)
        }
        .couliCard()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("orderDetail.product")
        .couliProbe("orderDetail.product", role: "card")
    }

    /// 商品块：64 图 + 右列（标题 14/500 不省略 → 件数 12 → 单号 +【复制】紧随，同列表排法）。
    func productBody(_ summary: OrderSummary, imageUrl: String?, title titleText: String?,
                     ticket: OrderDetailCopyTicket?) -> some View {
        HStack(alignment: .top, spacing: CouliSpacing.s3) {
            OrderImage(url: imageUrl, texts: texts, otherProduct: summary.isOtherProduct,
                       probe: "orderDetail.product")
            VStack(alignment: .leading, spacing: CouliSpacing.s1) {
                VStack(alignment: .leading, spacing: CouliSpacing.s1) {
                    if let titleText {
                        OrderProbedText(titleText, style: .footnote, weight: .couliMedium,
                                        probeID: "orderDetail.product.title")
                            .foregroundColor(CouliColor.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let quantity = summary.quantity {
                        Text(verbatim: texts.format(OrderKeys.quantity, ["n": String(quantity)]))
                            .couliFont(.caption)
                            .foregroundColor(CouliColor.textSecondary)
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(verbatim: productSpeech(summary, title: titleText)))
                OrderListNumber(summary: summary, texts: texts, probe: "orderDetail.product") {
                    controller.copyOrderNo(ticket, rendered: $0)
                }
            }
            Spacer(minLength: 0)
        }
    }

    /// 商品块读名：商品名、件数、单号（分享单脱敏号「*」读作「星号」）。
    func productSpeech(_ summary: OrderSummary, title: String?) -> String {
        var parts: [String] = []
        if let title {
            parts.append(title)
        }
        if let quantity = summary.quantity {
            parts.append(texts.format(OrderKeys.quantity, ["n": String(quantity)]))
        }
        if let number = OrderNumberDisplay.view(summary).text {
            let spoken = OrderNumberDisplay.spoken(number, star: texts.text(OrderKeys.starSpoken))
            parts.append(texts.format(OrderKeys.orderNo, ["no": spoken]))
        }
        return parts.joined(separator: PriceTerms.spokenPause)
    }
}
