import DesignSystem
import Generated
import OrderCore
import SwiftUI

extension OrderDetailScreen {
    // MARK: - 提示条

    func staleBanner(_ at: Int64, blocked: Bool) -> some View {
        VStack(alignment: .leading, spacing: CouliSpacing.s2) {
            HStack(alignment: .top, spacing: CouliSpacing.s2) {
                CouliIconView(.info, size: CouliGuideMetric.iconInline, relativeTo: .footnote)
                    .foregroundColor(CouliColor.statusWarningText)
                Text(verbatim: texts.format(
                    OrderKeys.staleData,
                    ["time": CouliFormat.timeListPast(epochMillis: at, nowEpochMillis: config.now())]
                ))
                .couliFont(.footnote)
                .foregroundColor(CouliColor.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.updatesFrequently)
            }
            // 缓存态的刷新入口（共性第 26 条；读屏用户无法下拉）：遵守共享 42901 禁用期
            CouliButton(texts.text(OrderKeys.retry), kind: .secondary, size: .compact, isEnabled: !blocked) {
                controller.refresh()
            }
            .accessibilityIdentifier("orderDetail.staleRetry")
        }
        .padding(CouliSpacing.s3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: CouliRadius.small).fill(CouliColor.backgroundMuted))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("orderDetail.stale")
    }

    // MARK: - 状态与金额

    func statusCard(_ detail: OrderDetail) -> some View {
        let summary = detail.summary
        let status = OrderStatusText.view(summary.displayStatus)
        let credit = CreditPeriodText.view(
            summary.displayStatus,
            period: detail.expectedCreditPeriod,
            nowMs: config.now()
        )
        // 状态说明：WAITING 只有月份非空时出「预计 {M} 月结算」；PAID 入账句；其余按映射表的 hint（INVALID / CLAWED_BACK 在原因区）
        let hint: String? = if summary.displayStatus == .waiting {
            credit.monthText.map { texts.format(CreditPeriodText.waitingKey, ["credit_period": $0]) }
        } else {
            status.hintKey.map(texts.text)
        }
        return VStack(alignment: .leading, spacing: CouliSpacing.s3) {
            HStack(alignment: .top, spacing: CouliSpacing.s2) {
                Text(verbatim: OrderStatusLine.label(summary, texts: texts, hidden: mask.hidden))
                    .couliFont(.title, weight: .couliBold)
                    .foregroundColor(CouliColor.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("orderDetail.status")
                Spacer(minLength: CouliSpacing.s2)
                AmountMaskButton(mask: mask, texts: texts)
                    .fixedSize()
            }
            OrderAmountBlock(summary: summary, texts: texts, hidden: mask.hidden, valueStyle: .heading)
            if let hint, !hint.isEmpty {
                Text(verbatim: hint)
                    .couliFont(.footnote)
                    .foregroundColor(CouliColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("orderDetail.hint")
            }
        }
        .couliCard()
        .accessibilityElement(children: .contain)
    }

    // MARK: - 原因区

    @ViewBuilder func reasonCard(_ detail: OrderDetail) -> some View {
        let why = WhyNoRebate.view(detail)
        let help = PriceCompareEntry.view(detail, helpLinks: config.helpLinks(), routes: Routes.all)
        if why.show {
            VStack(alignment: .leading, spacing: CouliSpacing.s2) {
                if let heading = why.headingKey {
                    Text(verbatim: texts.text(heading))
                        .couliFont(.footnote)
                        .foregroundColor(CouliColor.textSecondary)
                        .accessibilityAddTraits(.isHeader)
                }
                if let title = why.titleKey {
                    Text(verbatim: texts.text(title))
                        .couliFont(.body, weight: .couliSemibold)
                        .foregroundColor(CouliColor.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("orderDetail.reasonTitle")
                }
                let desc = [why.descKey.map(texts.text), why.extraKey.map(texts.text)].compactMap(\.self)
                    .filter { !$0.isEmpty }
                if !desc.isEmpty {
                    Text(verbatim: desc.joined(separator: texts.text(OrderKeys.descJoin)))
                        .couliFont(.footnote)
                        .foregroundColor(CouliColor.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("orderDetail.reasonDesc")
                }
                if let hint = why.hintKey {
                    Text(verbatim: texts.text(hint))
                        .couliFont(.footnote)
                        .foregroundColor(CouliColor.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("orderDetail.priceCompareHint")
                }
                if let help {
                    // 「查看说明」：行尾文字入口，不占按钮位（BR-TEXT-03）
                    CouliButton(texts.text(OrderKeys.viewHelp), kind: .text, size: .compact) {
                        config.onOpen(help)
                    }
                    .accessibilityIdentifier("orderDetail.viewHelp")
                }
            }
            .couliCard()
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("orderDetail.reason")
        }
    }

    var appealBlock: some View {
        VStack(alignment: .leading, spacing: CouliSpacing.s2) {
            CouliTag(texts.text(OrderKeys.appealTitle))
            Text(verbatim: texts.text(OrderKeys.appealDesc))
                .couliFont(.footnote)
                .foregroundColor(CouliColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            CouliButton(texts.text(OrderKeys.appealProgress), kind: .text, size: .compact) {
                config.onOpen(RouteTarget(route: "Appeal", params: [:]))
            }
            .accessibilityIdentifier("orderDetail.appealProgress")
        }
        .couliCard()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("orderDetail.appeal")
    }

    // MARK: - 商品

    func productCard(_ detail: OrderDetail) -> some View {
        let summary = detail.summary
        let title = OrderTitleImage.view(summary)
        let view = ViewProductEntry.view(detail)
        // 渲染这一刻固定【复制】票据（执行器、会话、详情版本、单号；共性第 41 条）
        let ticket = controller.copyTicket()
        return VStack(alignment: .leading, spacing: CouliSpacing.s3) {
            HStack(alignment: .center, spacing: CouliSpacing.s2) {
                let name = texts.text("platform." + summary.platform)
                if !name.isEmpty {
                    PlatformBadge(name, platformCode: summary.platform)
                }
                Spacer(minLength: 0)
                if let view {
                    // 「查看商品」（F-ORD-16）：不占按钮名额；只带 platform、product_key
                    CouliButton(texts.text(OrderKeys.viewProduct), kind: .text, size: .compact) {
                        config.onOpen(view)
                    }
                    .accessibilityIdentifier("orderDetail.viewProduct")
                    .fixedSize()
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
                    if let quantity = summary.quantity {
                        Text(verbatim: texts.format(OrderKeys.quantity, ["n": String(quantity)]))
                            .couliFont(.footnote)
                            .foregroundColor(CouliColor.textSecondary)
                    }
                }
                Spacer(minLength: 0)
            }
            .accessibilityElement(children: .combine)
            OrderNumberRow(summary: summary, texts: texts) { controller.copyOrderNo(ticket, rendered: $0) }
        }
        .couliCard()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("orderDetail.product")
    }
}
