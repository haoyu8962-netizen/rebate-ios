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
        writeNotices(snapshot, flowState, flowActions)
    }

    /// 表单此刻在页面上（30307 / 30308 才有字段可挂）。
    func formShown(_ snapshot: PayoutSnapshot, _ flowState: FlowState) -> Bool {
        snapshot.phase == .content && snapshot.editing && flowState.pending == nil
    }

    /// 挂在字段下的提交错误（G-W13）：说的是提交时的内容，用户改了就不再显示。
    func submitError(_ flowState: FlowState, _ form: PayoutForm) -> (field: String, notice: Notice)? {
        guard let error = flowState.error, error.id != staleSubmitErrorId,
              let field = PayoutErrorPlacement.field(error.key, method: form.method) else { return nil }
        return (field, error)
    }

    /// 字段下的错误没有 `fieldErrorId` 事件，定位、播报走这里（同一套 `FieldErrorCue`，只定位一次）。
    func cueSubmitError() {
        let form = controller.state.form
        guard formShown(controller.state, flow.state), let placed = submitError(flow.state, form) else { return }
        errorCue.arm(event: "S\(placed.notice.id)", errors: [placed.field],
                     order: FieldErrorCue.payoutOrder(method: form.method))
    }

    /// 改了错误所指的字段（或换了收款方式）：这条错误不再按当前内容显示。
    func retireSubmitError(from old: PayoutForm, to form: PayoutForm) {
        guard let placed = submitError(flow.state, old) else { return }
        let path: KeyPath<PayoutForm, String> = switch placed.field {
        case PayoutAccountForm.payeeName: \.payeeName
        case PayoutAccountForm.cardNo: \.cardNo
        default: \.alipayLogonId
        }
        let accountGone = old.method != form.method && placed.field != PayoutAccountForm.payeeName
        if old[keyPath: path] != form[keyPath: path] || accountGone {
            staleSubmitErrorId = placed.notice.id
        }
    }

    /// 写操作（保存、确认、放弃）的结局：错误条与被拦下的手动补办入口；与账号读取状态无关（共性第 76 条，iOS R2-02）。
    /// 白名单内的错误在表单显示时挂到字段下（`submitError`），表单不在时仍在这里，用户总能看到结局。
    @ViewBuilder func writeNotices(_ snapshot: PayoutSnapshot, _ flowState: FlowState,
                                   _ flowActions: FlowActions) -> some View {
        let method = snapshot.form.method
        if let error = flowState.error,
           !(formShown(snapshot, flowState) && PayoutErrorPlacement.field(error.key, method: method) != nil) {
            NoticeBar(text: error.message(texts), noticeId: error.id, identifier: "payout.flowError",
                      tone: PayoutErrorPlacement.tone(error.key))
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
                    RecordText(texts.text("payout.current"), style: .footnote, color: CouliColor.textSecondary,
                               probe: "payout.bound.currentLabel")
                        .accessibilityAddTraits(.isHeader)
                    Spacer(minLength: CouliSpacing.s2)
                    if account.known {
                        Text(verbatim: texts.text(method))
                            .couliFont(.caption)
                            .foregroundColor(CouliColor.textSecondary)
                            .padding(.horizontal, CouliSpacing.s2)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(CouliColor.backgroundMuted))
                            .couliTextNaturalProbe("payout.bound.methodTag", role: "tag", text: texts.text(method),
                                                   style: .caption)
                    }
                }
                RecordText(big, style: .title, weight: .couliSemibold, color: CouliColor.textPrimary,
                           monospacedDigits: true, probe: "payout.bound.account")
                    .accessibilityLabel(Text(verbatim: texts.text("withdraw.payout_label") + PriceTerms.spokenPause
                            + WalletAnnounce.masked(line, texts: texts)))
                    .accessibilityIdentifier("payout.bound")
                RecordDivider()
                    .walletProbe("payout.bound.divider", role: "divider")
                VStack(spacing: CouliSpacing.s2) {
                    WalletInfoRow(label: texts.text("payout.payee_label"), value: account.maskedPayee ?? "",
                                  spokenValue: WalletAnnounce.masked(account.maskedPayee ?? "", texts: texts),
                                  probe: "payout.bound.payee")
                    if let left = account.changeRemaining {
                        WalletInfoRow(label: texts.text("payout.remaining_label"),
                                      value: texts.format("payout.remaining", ["n": "\(left)"]),
                                      probe: "payout.bound.remaining")
                    }
                }
                if account.known, !snapshot.editing || flowState.pending != nil {
                    changeButton(exhausted: account.changeRemaining == 0, snapshot, flowState, actions)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .couliCard()
            .walletProbe("payout.boundCard", role: "card")
            WalletInfoStrip(text: texts.text("payout.bound_note"), probe: "payout.note")
        }
    }

    /// G-W21：次数用完只在原条件上追加置灰（字段缺失不置灰），读屏读出原因。
    func changeButton(exhausted: Bool, _ snapshot: PayoutSnapshot, _ flowState: FlowState,
                      _ actions: PayoutActions) -> some View {
        CouliButton(texts.text("payout.change"), kind: .secondary, isEnabled: snapshot.loadError == nil
            && flowState.pending == nil && !exhausted, fillsWidth: true, weight: .couliMedium,
            mutedWhenDisabled: true, action: actions.change)
            .couliButtonLabelProbe("payout.change.label")
            .walletProbe("payout.change", role: "button")
            .accessibilityValue(Text(verbatim: exhausted ? texts.text("payout.remaining_label")
                    + texts.format("payout.remaining", ["n": "0"]) : ""))
            .accessibilityIdentifier("payout.change")
    }

    func saveBar(_ flowState: FlowState, _ actions: PayoutActions) -> some View {
        let saving = flowState.phase == .submitting && !flowState.awaitingIdentity
        return CouliButton(
            texts.text(saving ? "payout.saving" : "payout.save"), isLoading: saving,
            isEnabled: flowState.canSubmit && !gate.blocked, fillsWidth: true, action: actions.save
        )
        .accessibilityFocused($saveFocused)
        .walletProbe("payout.save", role: "button")
        .accessibilityIdentifier("payout.save")
        .padding([.top, .bottom], CouliSpacing.s3)
        .padding(.horizontal, CouliSpacing.s4)
        .frame(maxWidth: WalletLayout.maxContentWidth)
        .frame(maxWidth: .infinity)
    }
}
