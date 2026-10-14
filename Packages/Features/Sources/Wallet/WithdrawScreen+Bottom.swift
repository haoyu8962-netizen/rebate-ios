import DesignSystem
import SwiftUI
import WalletCore

/// 收款账号行、时效、规则链接与底部【提交】。
extension WithdrawScreen {
    /// 收款账号卡、时效条（浅底 + 信息图标）、「提交后不能自行撤销」（设计稿 Withdraw）。【提现规则】在底部【提交】下方。
    func infoCard(_ snapshot: WithdrawSnapshot, _ display: WithdrawRulesDisplay, _ actions: WithdrawActions)
        -> some View {
        VStack(alignment: .leading, spacing: CouliSpacing.s3) {
            if let payout = snapshot.payout, let line = payout.line(texts) {
                Button(action: actions.payout) {
                    HStack(spacing: CouliSpacing.s2) {
                        WalletInfoRow(
                            label: texts.text("withdraw.payout_label"), value: line,
                            spokenValue: WalletAnnounce.masked(line, texts: texts)
                        )
                        CouliIconView(.chevron, size: CouliGuideMetric.iconInline, relativeTo: .footnote)
                            .foregroundColor(CouliColor.textSecondary)
                            .accessibilityHidden(true)
                    }
                    .frame(minHeight: CouliHitTarget.minimum)
                    .contentShape(Rectangle())
                }
                .buttonStyle(CouliPlainButtonStyle(cornerRadius: CouliRadius.small))
                .couliCard()
                .accessibilityIdentifier("withdraw.payout")
            }
            HStack(alignment: .top, spacing: CouliSpacing.s2) {
                CouliIconView(.info, size: CouliGuideMetric.iconInline, relativeTo: .footnote)
                    .foregroundColor(CouliColor.textSecondary)
                    .accessibilityHidden(true)
                Text(verbatim: display.slaText)
                    .couliFont(.footnote)
                    .foregroundColor(CouliColor.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(CouliSpacing.s3)
            .background(
                RoundedRectangle(cornerRadius: CouliRadius.card, style: .continuous).fill(CouliColor.backgroundMuted)
            )
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("withdraw.sla")
            Text(verbatim: texts.text("withdraw.irrevocable"))
                .couliFont(.footnote)
                .foregroundColor(CouliColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, CouliSpacing.s1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 底部【提交】：排在页面内容之后（待确认卡的警告先读）；提交中 loading 不可用；随键盘上移。
    func submitBar(_ snapshot: WithdrawSnapshot, _ flowState: FlowState, _ actions: WithdrawActions) -> some View {
        let display = snapshot.display(slaDefault: texts)
        let enabled = (display?.submitEnabled ?? false) && flowState.canSubmit && !snapshot.serverBlocked
            && !snapshot.successPending && !gate.blocked
        let submitting = flowState.phase == .submitting
        return VStack(spacing: CouliSpacing.s2) {
            CouliButton(
                texts.text(submitting ? "withdraw.submitting" : "withdraw.submit"), isLoading: submitting,
                isEnabled: enabled, fillsWidth: true, action: actions.submit
            )
            .accessibilityFocused($submitFocused)
            .accessibilityIdentifier("withdraw.submit")
            // 【提现规则】只在 help_links.withdraw_rules 已配置且目标合法时显示（G26）
            if snapshot.helpTarget != nil {
                CouliButton(texts.text("withdraw.rules_link"), kind: .text, size: .compact, action: actions.rules)
                    .accessibilityIdentifier("withdraw.rulesLink")
            }
        }
        .padding(CouliSpacing.s4)
        .frame(maxWidth: WalletLayout.maxContentWidth)
        .frame(maxWidth: .infinity)
        .background(CouliColor.backgroundSurface.ignoresSafeArea(edges: .bottom))
    }

    /// 「预计到账」问号说明（WithdrawNoteNet；正文用 BR-TEXT-14 的 wallet.help.fee_tax，brief 指定）。
    var feeSheet: some View {
        WalletHelpSheet(
            title: texts.text("wallet.help.fee_tax_title"), text: texts.text("wallet.help.fee_tax"), texts: texts,
            close: { feeHelp = false }
        )
    }
}
