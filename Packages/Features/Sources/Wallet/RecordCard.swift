import DesignSystem
import SwiftUI
import WalletCore

/// 一张提现单卡片（整卡展开 / 收起，读屏名「展开详情 / 收起详情」）。展开后的明细与交易流水号来自同一份详情（共性第 28、34 条）。
struct RecordCard: View {
    let item: Withdrawal
    let detail: Withdrawal?
    let expanded: Bool
    let texts: WalletTexts
    let slaText: String?
    let now: Int64
    let actions: RecordsActions

    var body: some View {
        let display = WithdrawalText.of(item, slaText: slaText, texts: texts)
        VStack(alignment: .leading, spacing: CouliSpacing.s2) {
            Button {
                actions.toggle(item.withdrawalId)
            } label: {
                summary(display)
                    .contentShape(Rectangle())
            }
            .buttonStyle(CouliPlainButtonStyle(cornerRadius: CouliRadius.small))
            .accessibilityHint(Text(verbatim: texts
                    .text(expanded ? "withdraw_records.collapse" : "withdraw_records.expand")))
            .accessibilityIdentifier("record.\(item.withdrawalId)")
            if expanded {
                details(display)
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("record.detail.\(item.withdrawalId)")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, CouliSpacing.s1)
    }

    /// 状态胶囊（设计稿 WithdrawRecords：审核中 / 打款中 / 处理中为中性带钟表，已到账为成功色带勾，未通过 / 打款未成功为警示色带三角）。
    func statusPill(_ titleKey: String) -> some View {
        let status = item.status
        let tone: (icon: CouliIcon, color: Color) = switch status {
        case "PAID_API", "PAID_MANUAL": (.check, CouliColor.statusSuccessText)
        case "REJECTED", "FAILED": (.alert, CouliColor.statusWarningText)
        default: (.clock, CouliColor.textSecondary)
        }
        return HStack(spacing: CouliSpacing.s1) {
            CouliIconView(tone.icon, size: CouliGuideMetric.iconInline, relativeTo: .caption)
                .accessibilityHidden(true)
            Text(verbatim: texts.text(titleKey))
                .couliFont(.caption, weight: .couliSemibold)
        }
        .foregroundColor(tone.color)
        .padding(.horizontal, CouliSpacing.s2)
        .padding(.vertical, 2)
        .background(Capsule().fill(tone.color.opacity(0.12)))
    }

    func summary(_ display: WithdrawalDisplay) -> some View {
        let account = item.payoutChannelName + " " + item.maskedAccount
        let date = CouliFormat.timeListPast(epochMillis: item.createdAtMillis, nowEpochMillis: now)
        let lines = WithdrawalText.render(display, texts: texts, money: WalletMoney.text)
        return VStack(alignment: .leading, spacing: CouliSpacing.s1) {
            CouliFlowLayout(horizontalSpacing: CouliSpacing.s3, verticalSpacing: CouliSpacing.s1) {
                Text(verbatim: texts.format("withdraw_records.item", ["amount": WalletMoney.text(item.amountFen)]))
                    .couliFont(.body, weight: .couliSemibold, monospacedDigits: true)
                    .foregroundColor(CouliColor.textPrimary)
                HStack(spacing: CouliSpacing.s2) {
                    statusPill(display.titleKey)
                    CouliIconView(.chevronDown, size: CouliGuideMetric.iconInline, relativeTo: .footnote)
                        .foregroundColor(CouliColor.textSecondary)
                        .rotationEffect(.degrees(expanded ? 180 : 0))
                        .accessibilityHidden(true)
                }
                .accessibilityElement(children: .combine)
                .couliFlowPushTrailing(.inlineOnly)
            }
            Text(verbatim: texts.format("withdraw_records.channel_line", ["date": date, "account": account]))
                .couliFont(.footnote)
                .foregroundColor(CouliColor.textSecondary)
                .accessibilityLabel(Text(verbatim: WalletAnnounce.masked(
                    texts.format("withdraw_records.channel_line", ["date": date, "account": account]), texts: texts
                )))
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                Text(verbatim: line)
                    .couliFont(.footnote)
                    .foregroundColor(CouliColor.textSecondary)
                    .accessibilityLabel(Text(verbatim: WalletAnnounce.masked(line, texts: texts)))
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder func details(_ display: WithdrawalDisplay) -> some View {
        let source = detail ?? item
        let account = source.payoutChannelName + " " + source.maskedAccount
        VStack(alignment: .leading, spacing: CouliSpacing.s2) {
            Divider()
            WalletInfoRow(label: texts.text("withdraw_detail.amount"), value: WalletMoney.text(source.amountFen))
            WalletInfoRow(label: texts.text("withdraw_detail.fee"), value: WalletMoney.text(source.feeFen))
            if source.taxFen > 0 {
                WalletInfoRow(label: texts.text("withdraw_detail.tax"), value: WalletMoney.text(source.taxFen))
            }
            if let netKey = display.netKey {
                let label = texts.text(netKey == WithdrawalText.netActual
                    ? "withdraw_detail.net_label.actual" : "withdraw_detail.net_label.expected")
                WalletInfoRow(label: label, value: WalletMoney.text(source.netFen))
            }
            WalletInfoRow(label: texts.text("withdraw_detail.payout"), value: account,
                          spokenValue: WalletAnnounce.masked(account, texts: texts))
            // 明细里的申请时间用完整写法「YYYY-MM-DD HH:mm」（设计稿 WithdrawRecordsPending；列表行仍用 BR-TEXT-11 的相对写法）
            WalletInfoRow(label: texts.text("withdraw_detail.created"),
                          value: CouliFormat.timeMinute(epochMillis: source.createdAtMillis))
            tradeNo(source)
            actionsRow(source, display)
        }
    }

    @ViewBuilder func tradeNo(_ source: Withdrawal) -> some View {
        if let text = TradeNoRow.copyText(status: source.status, channelOrderId: source.channelOrderId),
           source.isDetail {
            HStack(spacing: CouliSpacing.s2) {
                WalletInfoRow(label: texts.text("withdraw_detail.trade_no"), value: text)
                    .accessibilityIdentifier("record.tradeNo")
                CouliButton(texts.text("withdraw_detail.copy"), kind: .text, size: .compact) {
                    actions.copy(source.withdrawalId, text)
                }
                .fixedSize()
                .accessibilityIdentifier("record.copy")
            }
        }
    }

    @ViewBuilder func actionsRow(_ source: Withdrawal, _ display: WithdrawalDisplay) -> some View {
        if WithdrawalText.isReviewing(source.status) {
            Text(verbatim: texts.text("withdraw.irrevocable"))
                .couliFont(.footnote)
                .foregroundColor(CouliColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            CouliButton(texts.text("withdraw_detail.cs"), kind: .text, size: .compact, action: actions.contact)
                .accessibilityIdentifier("record.cs")
        } else if source.status == "FAILED" || source.status == "REJECTED" {
            if display.showChangeAccount, display.knownChannel {
                CouliButton(texts.text("withdraw_detail.change_account"), kind: .secondary, size: .compact) {
                    actions.changeAccount(source.withdrawalId)
                }
                .accessibilityIdentifier("record.changeAccount")
            }
            Text(verbatim: texts.text("withdraw_detail.doubt"))
                .couliFont(.footnote)
                .foregroundColor(CouliColor.textSecondary)
            CouliButton(texts.text("withdraw_detail.cs"), kind: .text, size: .compact, action: actions.contact)
                .accessibilityIdentifier("record.cs")
        }
    }
}
