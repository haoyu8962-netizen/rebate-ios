import DesignSystem
import SwiftUI
import WalletCore

/// 收款账号页的待确认卡、已绑账号卡、表单与【保存】。
extension PayoutAccountScreen {
    func payoutPending(_ pending: PendingView, _ flowState: FlowState, _ flowActions: FlowActions) -> some View {
        let summary = PayoutPendingSummary.decode(pending.summary)
        let method = summary?.method == WalletJSON.bankCard ? "" : texts.text("payout.channel.alipay") + " "
        let account = summary?.account.map { method + $0 } ?? ""
        let desc = texts.format("pending_confirm.payout_account.desc", ["payout_account": account])
        let extra = VStack(alignment: .leading, spacing: CouliSpacing.s1) {
            if let shown = summary?.account {
                WalletInfoRow(label: texts.text("pending_confirm.payout_account.account_label"), value: method + shown,
                              spokenValue: WalletAnnounce.masked(method + shown, texts: texts))
            }
            if let payee = summary?.payee {
                WalletInfoRow(label: texts.text("pending_confirm.payout_account.payee_label"), value: payee,
                              spokenValue: WalletAnnounce.masked(payee, texts: texts))
            }
            WalletInfoRow(
                label: texts.text("pending_confirm.payout_account.time_label"),
                value: CouliFormat.timeListPast(epochMillis: pending.createdAtMillis,
                                                nowEpochMillis: controller.displayNowMillis())
            )
        }
        return PendingCard(
            texts: texts, pending: pending, desc: desc, abandonTitle: texts.text("pending_confirm.abandon"),
            confirmTitle: texts.text("pending_confirm.payout_account.action"),
            note: texts.text("pending_confirm.payout_account.note"), notice: flowState.pendingNotice,
            blocked: gate.blocked, busy: flowState.pendingCardBusy, actionsEnabled: flowState.pendingActionsEnabled,
            actions: flowActions, extra: AnyView(extra)
        )
    }

    @ViewBuilder func pageNotices(_ snapshot: PayoutSnapshot, _ flowState: FlowState, _ actions: PayoutActions,
                                  _ flowActions: FlowActions) -> some View {
        if let error = snapshot.loadError {
            NoticeBar(
                text: error.message(texts), noticeId: error.id, retryTitle: texts.text("wallet.retry"),
                retryEnabled: !readGate.blocked, retry: actions.retry, identifier: "payout.refreshError"
            )
        }
        if let route = snapshot.guideRoute {
            GuideEntry(texts: texts, route: route, action: actions.openGuide)
        }
        writeNotices(flowState, flowActions)
    }

    /// 写操作（保存、确认、放弃）的结局：错误条与被拦下的手动补办入口；与账号读取状态无关（共性第 76 条，iOS R2-02）。
    @ViewBuilder func writeNotices(_ flowState: FlowState, _ flowActions: FlowActions) -> some View {
        if let error = flowState.error {
            NoticeBar(text: error.message(texts), noticeId: error.id, identifier: "payout.flowError")
                .accessibilityFocused($errorFocused)
        }
        if let route = flowState.guideRoute {
            GuideEntry(texts: texts, route: route, action: flowActions.openGuide)
        }
        // 写请求已结束、身份暂时未知（RW-03）：不再转圈，给【重试】核对身份
        if flowState.awaitingIdentity {
            NoticeBar(
                text: texts.text("pending_confirm.retry_later"), noticeId: -1, retryTitle: texts.text("wallet.retry"),
                retry: flowActions.recheck, identifier: "payout.awaitingIdentity"
            )
        }
    }

    func boundCard(_ account: PayoutAccountDisplay, _ snapshot: PayoutSnapshot, _ flowState: FlowState,
                   _ actions: PayoutActions) -> some View {
        let line = account.line(texts) ?? ""
        let method = account.methodRaw == WalletJSON.bankCard ? "payout.channel.bank_card" : "payout.channel.alipay"
        // 设计稿 PayoutAccountBound：标题行右侧方式胶囊、大号脱敏账号、分隔线、收款人与剩余次数、通栏【更换收款账号】；不能解绑说明在卡外浅底条
        let big = account.known && account.methodRaw == WalletJSON.alipay ? (account.maskedAccount ?? line) : line
        return VStack(alignment: .leading, spacing: CouliSpacing.s3) {
            VStack(alignment: .leading, spacing: CouliSpacing.s3) {
                HStack {
                    Text(verbatim: texts.text("payout.current"))
                        .couliFont(.footnote)
                        .foregroundColor(CouliColor.textSecondary)
                        .accessibilityAddTraits(.isHeader)
                    Spacer(minLength: CouliSpacing.s2)
                    if account.known {
                        Text(verbatim: texts.text(method))
                            .couliFont(.caption, weight: .couliSemibold)
                            .foregroundColor(CouliColor.textSecondary)
                            .padding(.horizontal, CouliSpacing.s2)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(CouliColor.backgroundMuted))
                    }
                }
                Text(verbatim: big)
                    .couliFont(.title, weight: .couliBold, monospacedDigits: true)
                    .foregroundColor(CouliColor.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel(Text(verbatim: texts.text("withdraw.payout_label") + PriceTerms.spokenPause
                            + WalletAnnounce.masked(line, texts: texts)))
                    .accessibilityIdentifier("payout.bound")
                Divider()
                WalletInfoRow(label: texts.text("payout.payee_label"), value: account.maskedPayee ?? "",
                              spokenValue: WalletAnnounce.masked(account.maskedPayee ?? "", texts: texts))
                if let left = account.changeRemaining {
                    WalletInfoRow(label: texts.text("payout.remaining_label"),
                                  value: texts.format("payout.remaining", ["n": "\(left)"]))
                }
                if account.known, !snapshot.editing || flowState.pending != nil {
                    CouliButton(texts.text("payout.change"), kind: .secondary, isEnabled: snapshot.loadError == nil
                        && flowState.pending == nil, fillsWidth: true, action: actions.change)
                        .accessibilityIdentifier("payout.change")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .couliCard()
            boundNote
        }
    }

    /// 「收款账号不能解绑…」浅底说明条（设计稿 PayoutAccountBound 在卡片之外）。
    var boundNote: some View {
        HStack(alignment: .top, spacing: CouliSpacing.s2) {
            CouliIconView(.info, size: CouliGuideMetric.iconInline, relativeTo: .footnote)
                .foregroundColor(CouliColor.textSecondary)
                .accessibilityHidden(true)
            Text(verbatim: texts.text("payout.bound_note"))
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
    }

    func saveBar(_ flowState: FlowState, _ actions: PayoutActions) -> some View {
        let saving = flowState.phase == .submitting && !flowState.awaitingIdentity
        return CouliButton(
            texts.text(saving ? "payout.saving" : "payout.save"), isLoading: saving,
            isEnabled: flowState.canSubmit && !gate.blocked, fillsWidth: true, action: actions.save
        )
        .accessibilityFocused($saveFocused)
        .accessibilityIdentifier("payout.save")
        .padding(CouliSpacing.s4)
        .frame(maxWidth: WalletLayout.maxContentWidth)
        .frame(maxWidth: .infinity)
        .background(CouliColor.backgroundSurface.ignoresSafeArea(edges: .bottom))
    }
}
