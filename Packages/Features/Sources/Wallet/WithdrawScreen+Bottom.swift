import DesignSystem
import SwiftUI
import WalletCore

/// 收款账号行、时效、规则链接与底部【提交】。
extension WithdrawScreen {
    /// 收款账号卡、时效条（INFO：浅底 + 信息图标）、「提交后不能自行撤销」（设计稿 Withdraw）。【提现规则】在底部【提交】下方。
    /// 不能提现时这三块隐藏（W47 / G-W14）：只看 can_withdraw，不看 submitEnabled（空金额时照常显示）；待确认卡、引导框不受影响。
    @ViewBuilder func infoCard(_ snapshot: WithdrawSnapshot, _ display: WithdrawRulesDisplay,
                               _ actions: WithdrawActions) -> some View {
        if snapshot.rules?.canWithdraw != false {
            VStack(alignment: .leading, spacing: CouliSpacing.s3) {
                if let payout = snapshot.payout, let line = payout.line(texts) {
                    WithdrawPayoutRow(
                        label: texts.text("withdraw.payout_label"), value: line,
                        spoken: WalletAnnounce.masked(line, texts: texts), action: actions.payout
                    )
                }
                HStack(alignment: .top, spacing: CouliSpacing.s2) {
                    CouliIconView(.info, size: CouliComponentMetric.iconMedium, relativeTo: .footnote)
                        .foregroundColor(CouliColor.textSecondary)
                        .walletProbe("withdraw.sla.icon", role: "icon")
                        .accessibilityHidden(true)
                    RecordText(display.slaText, style: .footnote, color: CouliColor.textPrimary,
                               probe: "withdraw.sla.text")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(CouliSpacing.s3)
                .background(
                    RoundedRectangle(cornerRadius: CouliRadius.button, style: .continuous)
                        .fill(CouliColor.backgroundMuted)
                )
                .walletProbe("withdraw.sla", role: "note")
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("withdraw.sla")
                RecordText(texts.text("withdraw.irrevocable"), style: .caption, color: CouliColor.textSecondary,
                           probe: "withdraw.irrevocable")
                    .padding(.horizontal, CouliSpacing.s1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// 底部【提交】：排在页面内容之后（待确认卡的警告先读）；提交中 loading 不可用；随键盘上移。
    func submitBar(_ snapshot: WithdrawSnapshot, _ flowState: FlowState, _ actions: WithdrawActions) -> some View {
        let display = snapshot.display(slaDefault: texts)
        let enabled = (display?.submitEnabled ?? false) && flowState.canSubmit && !snapshot.serverBlocked
            && !snapshot.successPending && !gate.blocked
        let submitting = flowState.phase == .submitting && !flowState.awaitingIdentity
        return VStack(spacing: CouliSpacing.s1) {
            CouliButton(
                texts.text(submitting ? "withdraw.submitting" : "withdraw.submit"), isLoading: submitting,
                isEnabled: enabled, fillsWidth: true, action: actions.submit
            )
            .couliButtonLabelProbe("withdraw.submit.label")
            .accessibilityFocused($submitFocused)
            .walletProbe("withdraw.submit", role: "button")
            .accessibilityIdentifier("withdraw.submit")
            // 【提现规则】只在 help_links.withdraw_rules 已配置且目标合法时显示（G26）；视觉是一行字，命中 44 按布局占位，不压【提交】（W53）
            if snapshot.helpTarget != nil {
                WithdrawLinkButton(title: texts.text("withdraw.rules_link"), probe: "withdraw.rulesLink",
                                   weight: .regular, inset: CouliSpacing.s3, action: actions.rules)
                    .accessibilityIdentifier("withdraw.rulesLink")
            }
        }
        .padding(.top, CouliSpacing.s3)
        .padding(.horizontal, CouliSpacing.s4)
        .padding(.bottom, snapshot.helpTarget == nil ? CouliSpacing.s3 : 0)
        .frame(maxWidth: WalletLayout.maxContentWidth)
        .frame(maxWidth: .infinity)
        // 无底色（W53、W55）：透出页面画布
        .walletProbe("withdraw.bottom", role: "bar")
    }

    /// 「预计到账」问号说明（W45，WithdrawNoteNet；正文用 BR-TEXT-14 的 wallet.help.fee_tax，G-W27）。
    var feeSheet: some View {
        WalletHelpSheet(
            title: texts.text("wallet.help.fee_tax_title"), text: texts.text("wallet.help.fee_tax"), texts: texts,
            bodyStyle: .footnote, okKind: .secondary, close: { feeHelp = false }
        )
    }
}
