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
    func pendingDetail(_ flowState: FlowState, _ snapshot: WithdrawSnapshot) -> String {
        guard let pending = flowState.pending else { return "" }
        let object = WalletJSON.parse(Data(pending.summary.utf8)) as? [String: Any]
        let amount = object.flatMap { WalletJSON.int64($0["amount_fen"]) }.map(WalletMoney.text) ?? ""
        var lines = [texts.text("pending_confirm.withdraw.amount_label") + "  " + amount]
        if let account = snapshot.payout?.line(texts) {
            lines.append(texts.text("pending_confirm.payout_label") + "  " + account)
        }
        return lines.joined(separator: "\n")
    }

    func pendingCard(_ pending: PendingView, _ snapshot: WithdrawSnapshot, _ flowState: FlowState,
                     _ actions: WithdrawActions, _ flowActions: FlowActions) -> some View {
        // 设计稿：【查看提现记录 ›】在卡内说明行的右侧
        PendingCard(
            texts: texts, pending: pending, desc: pendingDesc(pending, snapshot),
            abandonTitle: texts.text("pending_confirm.withdraw.abandon"),
            confirmTitle: texts.text("pending_confirm.withdraw.action"),
            note: texts.text("pending_confirm.withdraw.note"), notice: flowState.pendingNotice,
            blocked: gate.blocked, actions: flowActions,
            link: PendingCard.Link(title: texts.text("pending_confirm.withdraw.records"), action: actions.records)
        )
    }

    @ViewBuilder func notices(_ snapshot: WithdrawSnapshot, _ flowState: FlowState, _ actions: WithdrawActions,
                              _ flowActions: FlowActions) -> some View {
        writeNotices(flowState, flowActions)
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
    @ViewBuilder func writeNotices(_ flowState: FlowState, _ flowActions: FlowActions) -> some View {
        if let error = flowState.error {
            NoticeBar(text: error.message(texts), noticeId: error.id, identifier: "withdraw.flowError")
        }
        if let route = flowState.guideRoute {
            GuideEntry(texts: texts, route: route, action: flowActions.openGuide)
        }
    }

    /// 页头（设计稿 Withdraw：「可提现余额」一行、大号金额一行、剩余次数一行）。文案仍是契约键 withdraw.balance_line，按 {amount} 拆开排版。
    func header(_ display: WithdrawRulesDisplay) -> some View {
        let slot = "\u{1}"
        let parts = texts.format("withdraw.balance_line", ["amount": slot]).components(separatedBy: slot)
        let label = (parts.first ?? "").trimmingCharacters(in: .whitespaces)
        let suffix = parts.dropFirst().joined().trimmingCharacters(in: .whitespaces)
        return VStack(alignment: .leading, spacing: CouliSpacing.s1) {
            VStack(alignment: .leading, spacing: CouliSpacing.s1) {
                if !label.isEmpty {
                    Text(verbatim: label)
                        .couliFont(.footnote)
                        .foregroundColor(CouliColor.textSecondary)
                }
                Text(verbatim: WalletMoney.text(display.balanceFen) + (suffix.isEmpty ? "" : " " + suffix))
                    .couliFont(.display, weight: .couliBold, monospacedDigits: true)
                    .foregroundColor(CouliColor.textPrimary)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: texts.format(
                "withdraw.balance_line", ["amount": WalletMoney.spoken(display.balanceFen)]
            )))
            .accessibilityIdentifier("withdraw.balance")
            Text(verbatim: texts.format("withdraw.remaining_counts", [
                "daily": "\(display.dailyRemaining)", "monthly": "\(display.monthlyRemaining)",
            ]))
            .couliFont(.footnote)
            .foregroundColor(CouliColor.textSecondary)
            .accessibilityIdentifier("withdraw.remaining")
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .couliCard()
    }

    /// block 引导（设计稿 WithdrawRealName；其余 block_code 套用同一版式，G28）：金额框下方的浅黄提示块，警示图标 + 原因句 + 引导按钮。
    @ViewBuilder func guideCard(_ snapshot: WithdrawSnapshot, _ actions: WithdrawActions) -> some View {
        let guide = snapshot.guide
        if guide.actionRaw != WithdrawBlockGuide.none {
            VStack(alignment: .leading, spacing: CouliSpacing.s3) {
                HStack(alignment: .top, spacing: CouliSpacing.s2) {
                    CouliIconView(.alert, size: CouliGuideMetric.iconInline, relativeTo: .footnote)
                        .foregroundColor(CouliColor.statusWarningText)
                        .accessibilityHidden(true)
                    Text(verbatim: texts.text(guide.textKey))
                        .couliFont(.footnote, weight: .couliSemibold)
                        .foregroundColor(CouliColor.statusWarningText)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("withdraw.guide")
                }
                if let button = guide.buttonKey {
                    CouliButton(texts.text(button), kind: .secondary, size: .compact, action: actions.guide)
                        .fixedSize()
                        .padding(.leading, CouliSpacing.s5)
                        .accessibilityIdentifier("withdraw.guide.button")
                }
            }
            .padding(CouliSpacing.s3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: CouliRadius.card, style: .continuous)
                    .fill(CouliColor.statusWarningText.opacity(0.1))
            )
        }
    }

    func amountCard(_ snapshot: WithdrawSnapshot, _ display: WithdrawRulesDisplay, _ flowState: FlowState,
                    _ actions: WithdrawActions) -> some View {
        let editable = display.amountEditable && flowState.pending == nil && flowState.phase == .editing
        return VStack(alignment: .leading, spacing: CouliSpacing.s3) {
            Text(verbatim: texts.text("withdraw.amount_label"))
                .couliFont(.footnote, weight: .couliSemibold)
                .foregroundColor(CouliColor.textSecondary)
            // 设计稿：金额框占满一行余下宽度、【全部提现】在右；放不下（窄屏 + 大字号）时【全部提现】换到下一行
            ViewThatFits(in: .horizontal) {
                HStack(spacing: CouliSpacing.s3) {
                    amountField(snapshot, display, editable: editable, actions)
                    allButton(display, editable: editable, actions)
                }
                VStack(alignment: .leading, spacing: CouliSpacing.s2) {
                    amountField(snapshot, display, editable: editable, actions)
                    allButton(display, editable: editable, actions)
                }
            }
            guideCard(snapshot, actions)
            if let fen = display.maxLineFen {
                Text(verbatim: texts.format("withdraw.max_line", ["amount": WalletMoney.text(fen)]))
                    .couliFont(.footnote)
                    .foregroundColor(CouliColor.textSecondary)
                    .accessibilityIdentifier("withdraw.max")
            }
            if !display.quick.isEmpty {
                quickRow(display.quick, editable: editable, actions)
            }
            fieldError(flowState)
            if snapshot.estimate != .hidden {
                Divider()
            }
            estimateRow(snapshot.estimate)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .couliCard()
    }

    func allButton(_ display: WithdrawRulesDisplay, editable: Bool, _ actions: WithdrawActions) -> some View {
        CouliButton(texts.text("withdraw.all"), kind: .text, size: .compact,
                    isEnabled: display.allEnabled && editable, action: actions.fillAll)
            .fixedSize()
            .accessibilityIdentifier("withdraw.all")
    }

    func amountField(_ snapshot: WithdrawSnapshot, _ display: WithdrawRulesDisplay, editable: Bool,
                     _ actions: WithdrawActions) -> some View {
        HStack(spacing: CouliSpacing.s1) {
            Text(verbatim: PriceTerms.yuanSign)
                .couliFont(.title, weight: .couliBold)
                .accessibilityHidden(true)
            TextField(
                display.amountEditable ? "" : texts.text("withdraw.realname_placeholder"),
                text: Binding(get: { snapshot.amountText }, set: actions.amount)
            )
            .keyboardType(.decimalPad)
            .couliFont(.title, weight: .couliBold, monospacedDigits: true)
            .disabled(!editable)
            .accessibilityLabel(Text(verbatim: texts.text("withdraw.amount_label")))
            .accessibilityIdentifier("withdraw.input")
        }
        .padding(.horizontal, CouliSpacing.s3)
        .frame(minWidth: 160, maxWidth: .infinity, minHeight: CouliHitTarget.minimum + CouliSpacing.s3)
        // 设计稿：带边框的金额框；不可输入（待确认、提交中、30304）时浅底
        .background(
            RoundedRectangle(cornerRadius: CouliRadius.button, style: .continuous)
                .fill(editable ? Color.clear : CouliColor.backgroundMuted)
        )
        .overlay(
            RoundedRectangle(cornerRadius: CouliRadius.button, style: .continuous).stroke(CouliColor.borderControl)
        )
    }

    func quickRow(_ quick: [Int64], editable: Bool, _ actions: WithdrawActions) -> some View {
        CouliFlowLayout(horizontalSpacing: CouliSpacing.s2, verticalSpacing: CouliSpacing.s2) {
            ForEach(quick, id: \.self) { fen in
                CouliButton(WalletMoney.text(fen), kind: .secondary, size: .compact, isEnabled: editable,
                            accessibilityLabel: texts.format(
                                "withdraw.spoken.amount",
                                ["amount": WalletMoney.spoken(fen)]
                            )) {
                    actions.quick(fen)
                }
                .accessibilityIdentifier("withdraw.quick.\(fen)")
            }
        }
    }

    @ViewBuilder func fieldError(_ flowState: FlowState) -> some View {
        if let key = flowState.fieldErrorKey {
            Text(verbatim: texts.text(key))
                .couliFont(.footnote)
                .foregroundColor(CouliColor.statusErrorText)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityFocused($fieldErrorFocused)
                .accessibilityIdentifier("withdraw.fieldError")
                .task(id: flowState.fieldErrorId) { WalletAnnounce.post(texts.text(key), assertive: true) }
        }
    }

    @ViewBuilder func estimateRow(_ estimate: EstimateUi) -> some View {
        switch estimate {
        case .hidden:
            EmptyView()
        case .calculating:
            // 「计算中…」不播报，只读结果（A11yAnnounce）
            Text(verbatim: texts.text("withdraw.estimate.calculating"))
                .couliFont(.footnote)
                .foregroundColor(CouliColor.textSecondary)
                .accessibilityHidden(true)
                .accessibilityIdentifier("withdraw.calculating")
        case let .shown(line, _):
            HStack(spacing: CouliSpacing.s1) {
                Text(verbatim: estimateText(line))
                    .couliFont(.footnote, monospacedDigits: true)
                    .foregroundColor(CouliColor.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("withdraw.estimate")
                WalletHelpButton(label: texts.text("wallet.help.fee_tax_label")) { feeHelp = true }
            }
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
