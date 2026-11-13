import DesignSystem
import SwiftUI
import WalletCore

/// 提现页的各区块。
extension WithdrawScreen {
    /// 待确认的上一笔：{amount} 取未决记录；{payout_account} 取服务端当前绑定的脱敏串，取不到时用 fallback 句。
    func pendingDesc(_ pending: PendingView, _ snapshot: WithdrawSnapshot) -> String {
        let object = WalletJSON.parse(Data(pending.summary.utf8)) as? [String: Any]
        let amount = object.flatMap { WalletJSON.int64($0["amount_fen"]) }.map(WalletMoney.text) ?? ""
        let account = snapshot.payout?.line(texts) ?? ""
        return texts.format("pending_confirm.withdraw.desc", ["amount": amount, "payout_account": account])
    }

    /// 放弃确认里附的上一笔明细（设计稿 WithdrawAbandonConfirm：上一笔金额、收款账号两行）；账号取不到时只列金额。
    func pendingDetail(_ flowState: FlowState, _ snapshot: WithdrawSnapshot) -> AbandonDetail {
        guard let pending = flowState.pending else { return .rows([]) }
        let object = WalletJSON.parse(Data(pending.summary.utf8)) as? [String: Any]
        let fen = object.flatMap { WalletJSON.int64($0["amount_fen"]) }
        var rows = [AbandonDetail.Row(
            label: texts.text("pending_confirm.withdraw.amount_label"), value: fen.map(WalletMoney.text) ?? "",
            spoken: fen.map(WalletMoney.spoken) ?? ""
        )]
        if let account = snapshot.payout?.line(texts) {
            rows.append(AbandonDetail.Row(label: texts.text("pending_confirm.payout_label"), value: account,
                                          spoken: WalletAnnounce.masked(account, texts: texts)))
        }
        return .rows(rows)
    }

    func pendingCard(_ pending: PendingView, _ snapshot: WithdrawSnapshot, _ flowState: FlowState,
                     _ actions: WithdrawActions, _ flowActions: FlowActions) -> some View {
        // 设计稿：【查看提现记录 ›】在卡内说明行的右侧
        PendingCard(
            texts: texts, pending: pending, desc: pendingDesc(pending, snapshot),
            abandonTitle: texts.text("pending_confirm.withdraw.abandon"),
            confirmTitle: texts.text("pending_confirm.withdraw.action"),
            note: texts.text("pending_confirm.withdraw.note"), notice: flowState.pendingNotice,
            blocked: gate.blocked, busy: flowState.pendingCardBusy, actionsEnabled: flowState.pendingActionsEnabled,
            actions: flowActions,
            abandonFocus: $abandonFocused,
            link: PendingCard.Link(title: texts.text("pending_confirm.withdraw.records"), action: actions.records)
        )
    }

    @ViewBuilder func notices(_ snapshot: WithdrawSnapshot, _ flowState: FlowState, _ actions: WithdrawActions,
                              _ flowActions: FlowActions) -> some View {
        writeNotices(flowState, flowActions, amountCardShown: snapshot.rules != nil)
        if let error = snapshot.readError {
            NoticeBar(
                text: error.message(texts), noticeId: error.id, retryTitle: texts.text("wallet.retry"),
                retryEnabled: !readGate.blocked, retry: actions.retry, identifier: "withdraw.readError"
            )
        }
        if let error = snapshot.payoutError {
            NoticeBar(
                text: error.message(texts), noticeId: error.id, retryTitle: texts.text("wallet.retry"),
                retryEnabled: !readGate.blocked, retry: actions.retry, identifier: "withdraw.payoutError"
            )
        }
        if snapshot.serverBlocked {
            NoticeBar(text: texts.text("error.30306"), noticeId: -30306, assertive: false, identifier: "withdraw.off")
        }
    }

    /// 写操作（提交、确认、放弃）的结局：错误条与被拦下的手动补办入口。与 rules 读取状态无关，加载中、读取失败时同样显示（共性第 76 条，
    /// iOS R2-02：确认得到 3xxxx / 20903、放弃 completed 原结果 3xxxx 时用户要看到上一笔的明确结局）。
    /// G-W13：金额类错误在金额卡显示时挪到金额框下（`fieldError`），这里不重复；金额卡不在（加载中、读取失败）时仍在这里，用户总能看到结局。
    @ViewBuilder func writeNotices(_ flowState: FlowState, _ flowActions: FlowActions,
                                   amountCardShown: Bool = false) -> some View {
        if let error = flowState.error, !(amountCardShown && WithdrawErrorPlacement.belowAmountBox(error.key)) {
            NoticeBar(text: error.message(texts), noticeId: error.id, identifier: "withdraw.flowError")
                .walletProbe("withdraw.flowError", role: "notice")
        }
        if let route = flowState.guideRoute {
            GuideEntry(texts: texts, route: route, action: flowActions.openGuide)
        }
        // 写请求已结束、身份暂时未知（RW-03）：不再转圈，给【重试】核对身份
        if flowState.awaitingIdentity {
            NoticeBar(
                text: texts.text("pending_confirm.retry_later"), noticeId: -1, retryTitle: texts.text("wallet.retry"),
                retry: flowActions.recheck, identifier: "withdraw.awaitingIdentity"
            )
        }
    }

    /// 余额卡（W37，设计稿 Withdraw：标签 14 → 34/700 等宽大数 → 次数 12）。文案仍是契约键 withdraw.balance_line，按 {amount} 拆开排版；
    /// 整卡一个读屏元素（A11yFocusWithdraw）。
    func header(_ display: WithdrawRulesDisplay) -> some View {
        let slot = "\u{1}"
        let parts = texts.format("withdraw.balance_line", ["amount": slot]).components(separatedBy: slot)
        let label = (parts.first ?? "").trimmingCharacters(in: .whitespaces)
        let suffix = parts.dropFirst().joined().trimmingCharacters(in: .whitespaces)
        let counts = texts.format("withdraw.remaining_counts", [
            "daily": "\(display.dailyRemaining)", "monthly": "\(display.monthlyRemaining)",
        ])
        return VStack(alignment: .leading, spacing: CouliSpacing.s2) {
            VStack(alignment: .leading, spacing: CouliSpacing.s1) {
                if !label.isEmpty {
                    RecordText(label, style: .footnote, color: CouliColor.textSecondary,
                               probe: "withdraw.balance.label")
                }
                HStack(alignment: .firstTextBaseline, spacing: CouliSpacing.s1) {
                    WalletAmount(text: WalletMoney.text(display.balanceFen), style: .display, weight: .couliBold,
                                 probe: "withdraw.balance.amount")
                        .foregroundColor(CouliColor.textPrimary)
                    if !suffix.isEmpty {
                        RecordText(suffix, style: .footnote, color: CouliColor.textSecondary)
                    }
                }
            }
            RecordText(counts, style: .caption, color: CouliColor.textSecondary, probe: "withdraw.balance.counts")
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .couliCard()
        .walletProbe("withdraw.balance", role: "card")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: texts.format(
            "withdraw.balance_line", ["amount": WalletMoney.spoken(display.balanceFen)]
        ) + PriceTerms.spokenPause + counts))
        .accessibilityIdentifier("withdraw.balance")
    }

    /// block 引导（W46，设计稿 WithdrawRealName；其余 block_code 套用同一版式，G28）：金额卡内的警告提示块，图标 + 原因句 + 文字下方描边按钮；
    /// 纯提示码无按钮；30309 有「提现规则」配置时出【查看提现规则】，去向同页底（G-W15，不改 WithdrawBlockGuide）。
    @ViewBuilder func guideCard(_ snapshot: WithdrawSnapshot, _ actions: WithdrawActions) -> some View {
        let guide = snapshot.guide
        if guide.actionRaw != WithdrawBlockGuide.none {
            WalletWarningBlock(iconProbe: "withdraw.guide.icon") {
                VStack(alignment: .leading, spacing: CouliSpacing.s2) {
                    RecordText(texts.text(guide.textKey), style: .footnote, weight: .couliMedium,
                               color: CouliColor.statusWarningText, probe: "withdraw.guide.text")
                        .accessibilityIdentifier("withdraw.guide")
                    if let button = guide.buttonKey {
                        CouliButton(texts.text(button), kind: .secondary, size: .compact,
                                    labelProbeID: "withdraw.guide.button.label", weight: .couliMedium,
                                    action: actions.guide)
                            .fixedSize(horizontal: false, vertical: true)
                            .walletProbe("withdraw.guide.button", role: "button")
                            .accessibilityIdentifier("withdraw.guide.button")
                    } else if guide.textKey == "error.30309", snapshot.helpTarget != nil {
                        CouliButton(texts.text("withdraw.guide.rules"), kind: .secondary, size: .compact,
                                    labelProbeID: "withdraw.guide.rules.label", weight: .couliMedium,
                                    action: actions.rules)
                            .fixedSize(horizontal: false, vertical: true)
                            .walletProbe("withdraw.guide.rules", role: "button")
                            .accessibilityIdentifier("withdraw.guide.rules")
                    }
                }
            }
            .walletProbe("withdraw.guide", role: "guide")
        }
    }

    func amountCard(_ snapshot: WithdrawSnapshot, _ display: WithdrawRulesDisplay, _ flowState: FlowState,
                    _ actions: WithdrawActions) -> some View {
        let editable = display.amountEditable && flowState.pending == nil && flowState.phase == .editing
        return VStack(alignment: .leading, spacing: CouliSpacing.s3) {
            RecordText(texts.text("withdraw.amount_label"), style: .footnote, color: CouliColor.textSecondary)
            // 设计稿：金额框占满一行余下宽度、【全部提现】在右；放不下（窄屏 + 大字号）时【全部提现】换到下一行
            ViewThatFits(in: .horizontal) {
                HStack(spacing: CouliSpacing.s2) {
                    amountField(display, flowState, editable: editable, actions)
                    allButton(display, editable: editable, actions)
                }
                VStack(alignment: .leading, spacing: CouliSpacing.s2) {
                    amountField(display, flowState, editable: editable, actions)
                    allButton(display, editable: editable, actions)
                }
            }
            fieldError(flowState)
            if let fen = display.maxLineFen {
                RecordText(texts.format("withdraw.max_line", ["amount": WalletMoney.text(fen)]), style: .caption,
                           color: CouliColor.textSecondary, monospacedDigits: true, probe: "withdraw.max")
                    .accessibilityIdentifier("withdraw.max")
            }
            if !display.quick.isEmpty {
                quickRow(display.quick, editable: editable, actions)
            }
            if snapshot.estimate != .hidden {
                RecordDivider()
                    .walletProbe("withdraw.divider", role: "divider")
            }
            estimateRow(snapshot.estimate)
            guideCard(snapshot, actions)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .couliCard()
        .walletProbe("withdraw.amountCard", role: "card")
    }

    func allButton(_ display: WithdrawRulesDisplay, editable: Bool, _ actions: WithdrawActions) -> some View {
        WithdrawLinkButton(title: texts.text("withdraw.all"), probe: "withdraw.all",
                           isEnabled: display.allEnabled && editable, action: actions.fillAll)
            .outlinedAtLargeText()
            .fixedSize()
            .accessibilityIdentifier("withdraw.all")
    }

    func amountField(_ display: WithdrawRulesDisplay, _ flowState: FlowState,
                     editable: Bool, _ actions: WithdrawActions) -> some View {
        WithdrawAmountBox(
            text: Binding(get: { controller.state.amountText }, set: actions.amount),
            placeholder: display.amountEditable ? nil : texts.text("withdraw.realname_placeholder"),
            label: texts.text("withdraw.amount_label"), editable: editable,
            muted: display.amountEditable && !editable, hasError: hasAmountError(flowState)
        )
    }

    func quickRow(_ quick: [Int64], editable: Bool, _ actions: WithdrawActions) -> some View {
        CouliFlowLayout(horizontalSpacing: CouliSpacing.s2, verticalSpacing: 0) {
            ForEach(quick, id: \.self) { fen in
                WithdrawQuickChip(
                    fen: fen,
                    spoken: texts.format("withdraw.spoken.amount", ["amount": WalletMoney.spoken(fen)]),
                    isEnabled: editable
                ) {
                    actions.quick(fen)
                }
            }
        }
    }

    /// 金额框要不要画红边：字段错误，或金额类提交错误（G-W13）。
    func hasAmountError(_ flowState: FlowState) -> Bool {
        flowState.fieldErrorKey != nil || amountError(flowState) != nil
    }

    /// 金额框下显示的提交错误（G-W13）：说的是提交时的金额，用户改了金额就不再显示（只管显示，`flow.error` 不动）。
    func amountError(_ flowState: FlowState) -> Notice? {
        guard let error = flowState.error, WithdrawErrorPlacement.belowAmountBox(error.key),
              error.id != staleAmountErrorId else { return nil }
        return error
    }

    /// 金额框下的错误（W49、W50）：字段错误（20001）与金额类提交错误（G-W13）同一位置，16 三角 + 14 红字；按事件编号播报一次。
    @ViewBuilder func fieldError(_ flowState: FlowState) -> some View {
        if let key = flowState.fieldErrorKey {
            fieldErrorRow(texts.text(key), event: flowState.fieldErrorId, focus: false)
        } else if let error = amountError(flowState) {
            fieldErrorRow(error.message(texts), event: error.id, focus: true)
        }
    }

    /// `focus`：字段错误由页面的 `onChange(fieldErrorId)` 移读屏焦点；金额类提交错误没有这个事件，在这里移一次。
    func fieldErrorRow(_ text: String, event: Int, focus: Bool) -> some View {
        HStack(alignment: .top, spacing: CouliSpacing.s1) {
            WalletErrorIcon(probe: "withdraw.fieldError.icon")
            RecordText(text, style: .footnote, color: CouliColor.statusErrorText, probe: "withdraw.fieldError.text")
                .accessibilityFocused($fieldErrorFocused)
                .accessibilityIdentifier("withdraw.fieldError")
        }
        .walletProbe("withdraw.fieldError", role: "error")
        .task(id: event) {
            // 从收款账号页、规则页返回时 task 会重跑：同一事件只播报、移焦点一次
            guard spokenFieldError != event else { return }
            spokenFieldError = event
            WalletAnnounce.post(text, assertive: true)
            if focus {
                fieldErrorFocused = true
            }
        }
    }

    @ViewBuilder func estimateRow(_ estimate: EstimateUi) -> some View {
        switch estimate {
        case .hidden:
            EmptyView()
        case .calculating:
            // 「计算中…」不播报，只读结果（A11yAnnounce）
            HStack(spacing: CouliSpacing.s2) {
                WalletSpinner(probe: "withdraw.calculating.spinner")
                RecordText(texts.text("withdraw.estimate.calculating"), style: .footnote,
                           color: CouliColor.textSecondary, probe: "withdraw.calculating")
            }
            .frame(minHeight: WithdrawMetric.estimateRowMinHeight)
            .walletProbe("withdraw.estimate.row", role: "row")
            .accessibilityHidden(true)
            .accessibilityIdentifier("withdraw.calculating")
        case let .shown(line, _):
            HStack(spacing: CouliSpacing.s1) {
                WithdrawEstimateText(line: estimateText(line), net: estimateNet(line))
                WalletIconButton(.help, base: CouliComponentMetric.iconInline - 2, relativeTo: .footnote,
                                 label: texts.text("wallet.help.fee_tax_label"), probe: "withdraw.estimate.help",
                                 focus: $feeHelpFocused) {
                    feeHelp = true
                }
            }
            .frame(minHeight: WithdrawMetric.estimateRowMinHeight)
            .walletProbe("withdraw.estimate.row", role: "row")
        }
    }

    func estimateNet(_ line: EstimateLine) -> String {
        switch line {
        case .hidden:
            ""
        case let .netOnly(net), let .full(net, _, _):
            WalletMoney.text(net)
        }
    }

    func estimateText(_ line: EstimateLine) -> String {
        switch line {
        case .hidden:
            ""
        case let .netOnly(net):
            texts.format(WithdrawRulesView.estimateNetOnlyKey, ["net": WalletMoney.text(net)])
        case let .full(net, fee, tax):
            texts.format(WithdrawRulesView.estimateKey, [
                "net": WalletMoney.text(net), "fee": WalletMoney.text(fee), "tax": WalletMoney.text(tax),
            ])
        }
    }
}
