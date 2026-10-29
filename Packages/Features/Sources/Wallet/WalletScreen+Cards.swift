import DesignSystem
import SwiftUI
import WalletCore

/// 主卡、主卡下警告条、预估收益卡、入口宫格与问号说明（APP-09v-a，brief §2.1）。
extension WalletScreen {
    func hero(_ view: WalletSummaryDisplay, _ snapshot: WalletSnapshot, _ actions: WalletActions) -> some View {
        WalletHeroPanel(
            view: view, hidden: mask.hidden, withdrawEnabled: snapshot.withdrawEnabled,
            disabledReason: disabledReason(view, snapshot), texts: texts, actions: actions,
            onHelp: { help = $0 }
        )
    }

    /// 置灰【提现】读屏要带的原因（brief §4.2）：只是把已有判定的结果说出来，判定本身仍是执行器的 `withdrawEnabled`。
    func disabledReason(_ view: WalletSummaryDisplay, _ snapshot: WalletSnapshot) -> String? {
        guard !snapshot.withdrawEnabled else { return nil }
        if view.negativeLine != nil {
            return texts.text("error.30302")
        }
        if let key = view.withdrawReasonKey {
            return texts.text(key)
        }
        return staleText(snapshot)
    }

    /// 待抵扣（G-W06，WalletNegative-v2）：主卡下警告条，首行「待抵扣 ¥x」600、次行 error.30302；金额随隐藏开关。不可点、不播报。
    func negativeStrip(_ amount: MaskableAmount) -> some View {
        let template = texts.format("wallet.negative", ["amount": Self.slot]).components(separatedBy: Self.slot)
        let note = AmountNote(template.first ?? "", amountFen: amount.fen, suffix: template.dropFirst().joined())
        let hint = texts.text("error.30302")
        return WalletStrip(icon: .alert, probe: "wallet.negative") {
            WalletText(note.display(hidden: mask.hidden), style: .footnote, weight: .couliSemibold,
                       monospacedDigits: true, probe: "wallet.negative.line1")
            WalletText(hint, style: .footnote, probe: "wallet.negative.line2")
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: note.spoken(hidden: mask.hidden) + PriceTerms.spokenPause + hint))
        .accessibilityIdentifier("wallet.negative")
    }

    /// 30306（WalletStates ①）：主卡下警告条，单行 500。
    func disabledStrip(_ key: String) -> some View {
        let text = texts.text(key)
        return WalletStrip(icon: .alert, probe: "wallet.disabledReason") {
            WalletText(text, style: .footnote, weight: .couliMedium, probe: "wallet.disabledReason.text")
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("wallet.disabledReason")
    }

    /// 模板里金额位置的占位（不可见字符；金额由 AmountNote 按隐藏开关渲染，不经文案字典格式化）。
    static let slot = "\u{1}"

    /// 模板 + 一个金额（金额段随隐藏开关）。
    func note(_ key: String, fen: Int64) -> AmountNote {
        let parts = texts.format(key, ["amount": Self.slot]).components(separatedBy: Self.slot)
        return AmountNote(parts.first ?? "", amountFen: fen, suffix: parts.dropFirst().joined())
    }

    /// 预估区（W9–W12）：白卡两列——左「钟表 + 预估收益 + 问号」（返利色）、22/600 金额、「其中已收货 ¥x」12；右「最早预计 /
    /// {M} 月结算」或入账核对中时「结算进度 / 入账核对中」（G-W07），两者都没有就只有左列（不造）。下面暂缓条、口径说明。
    func estimatedCard(_ view: WalletSummaryDisplay) -> some View {
        VStack(alignment: .leading, spacing: CouliSpacing.s3) {
            WalletEstimateColumns(
                left: estimateLeft(view), right: estimateRight(view)
            )
            if let paused = view.pausedLine {
                pausedStrip(paused.fen)
            }
            Text(verbatim: texts.text("wallet.estimate_note"))
                .couliFont(.caption)
                .foregroundColor(CouliColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .couliCard()
        .walletProbe("wallet.estimate", role: "card")
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("wallet.estimated")
    }

    private func estimateLeft(_ view: WalletSummaryDisplay) -> some View {
        let hidden = mask.hidden
        let label = texts.text("wallet.estimated")
        // 返利强调色与 AmountGrid 同一判定（GUIDE §7.1：金额可见且为正才用；隐藏时按类别）
        let accent = AmountGridItem(label: label, value: .amount(view.estimated.fen), isRebate: true)
            .usesRebateAccent(amountHidden: hidden)
        let received = note("wallet.received", fen: view.receivedLine.fen)
        let value = view.estimated.maskedText ?? WalletMoney.text(view.estimated.fen)
        return VStack(alignment: .leading, spacing: CouliSpacing.s1) {
            HStack(spacing: CouliSpacing.s1) {
                if accent {
                    CouliIconView(.clock, size: CouliGuideMetric.iconSmall, relativeTo: .footnote)
                        .walletProbe("wallet.estimate.left.icon", role: "icon")
                }
                WalletText(label, style: .footnote, probe: "wallet.estimate.left.label")
                    .accessibilityLabel(Text(verbatim: label + PriceTerms.spokenPause
                            + (hidden ? PriceTerms.spokenAmountHidden : WalletMoney.spoken(view.estimated.fen))))
                WalletIconButton(
                    .help,
                    base: CouliGuideMetric.iconSmall,
                    label: texts.text("wallet.help.estimated_label"),
                    probe: "wallet.estimate.left.help"
                ) { help = "estimated" }
            }
            .couliLineBox(.footnote)
            .walletProbe("wallet.estimate.left.labelRow", role: "row")
            .foregroundColor(accent ? CouliColor.rebateText : CouliColor.textSecondary)
            WalletAmount(text: value, style: .title, probe: "wallet.estimate.left.value")
                .foregroundColor(accent ? CouliColor.rebateText : CouliColor.textPrimary)
                .accessibilityHidden(true)
            WalletText(received.display(hidden: hidden), style: .caption, monospacedDigits: true,
                       probe: "wallet.estimate.left.note")
                .foregroundColor(CouliColor.textSecondary)
                .accessibilityLabel(Text(verbatim: received.spoken(hidden: hidden)))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 右列：有月份写「最早预计 / {M} 月结算」；入账核对中写「结算进度 / 入账核对中」（G-W07）；都没有返回 nil（不造）。
    private func estimateRight(_ view: WalletSummaryDisplay) -> AnyView? {
        let pair: (String, String)? = if view.overdueNote {
            (texts.text("wallet.settle_progress"), texts.text("wallet.overdue"))
        } else if let month = view.earliestMonth {
            (texts.text("wallet.earliest_label"), texts.format("wallet.earliest", ["month": month]))
        } else {
            nil
        }
        guard let (label, value) = pair else { return nil }
        return AnyView(
            VStack(alignment: .leading, spacing: CouliSpacing.s1) {
                WalletText(label, style: .caption, probe: "wallet.estimate.right.label")
                    .foregroundColor(CouliColor.textSecondary)
                    .couliLineBox(.footnote)
                WalletText(value, style: .title, weight: .couliSemibold, probe: "wallet.estimate.right.value")
                    .foregroundColor(CouliColor.textPrimary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .walletProbe("wallet.estimate.right", role: "column")
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("wallet.earliest")
        )
    }

    /// 「其中 {x} 暂缓入账」+ 问号（浅底条：上下 8、左右 12、12 号字；问号 14，命中区 44 溢出不撑高）。
    func pausedStrip(_ fen: Int64) -> some View {
        let paused = note("wallet.paused", fen: fen)
        return HStack(spacing: CouliSpacing.s1) {
            WalletText(paused.display(hidden: mask.hidden), style: .caption, monospacedDigits: true,
                       probe: "wallet.paused.text")
                .accessibilityLabel(Text(verbatim: paused.spoken(hidden: mask.hidden)))
            WalletIconButton(.help, base: CouliGuideMetric.iconSmall,
                             label: texts.text("wallet.help.pending_paused_label"),
                             probe: "wallet.paused.help") { help = "pending_paused" }
            Spacer(minLength: 0)
        }
        .foregroundColor(CouliColor.textSecondary)
        .padding(.horizontal, CouliSpacing.s3)
        .padding(.vertical, CouliSpacing.s2)
        .background(
            RoundedRectangle(cornerRadius: CouliRadius.button, style: .continuous).fill(CouliColor.backgroundMuted)
        )
        .walletProbe("wallet.paused", role: "strip")
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("wallet.paused")
    }

    /// 入口行（W13 / W14）：列数 = 入口数、卡内边距 8；收益看板（开关可见时）用柱状图标。去向不变（经执行器 → Router）。
    func entries(_ actions: WalletActions) -> some View {
        var items = [
            EntryGridItem(id: WalletRoutes.orderList, title: texts.text("wallet.entry.orders"), icon: .orders),
            EntryGridItem(id: WalletRoutes.ledger, title: texts.text("wallet.entry.ledger"), icon: .ledger),
        ]
        if controller.earningsVisible {
            items.append(EntryGridItem(
                id: WalletRoutes.earnings, title: texts.text("wallet.entry.earnings"), icon: .barChart
            ))
        }
        // EntryGrid 自带卡片底（不再套一层 couliCard）
        return EntryGrid(
            items: items, columns: items.count, padding: CouliSpacing.s2, probeID: "wallet.entries",
            cellProbePrefix: "wallet.entry"
        ) { actions.entry($0.id) }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("wallet.entries")
    }

    /// 问号说明半屏（W15，WalletNote*）：正文 14/21、【知道了】描边次按钮。
    func helpSheet(_ topic: String) -> some View {
        WalletHelpSheet(
            title: texts.text("wallet.help.\(topic)_title"), text: texts.text("wallet.help.\(topic)"), texts: texts,
            bodyStyle: .footnote, okKind: .secondary, close: { help = nil }
        )
    }
}

/// 预估区两列：两列等宽（间距 12），辅助字号档（≈ 200% 起）或任一列放不下时上下排（预估在上）；没有右列时左列独占。
struct WalletEstimateColumns<Left: View>: View {
    let left: Left
    let right: AnyView?
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        Group {
            if let right {
                if dynamicTypeSize >= .accessibility1 {
                    VStack(alignment: .leading, spacing: CouliSpacing.s4) {
                        left
                        right
                    }
                } else {
                    HStack(alignment: .top, spacing: CouliSpacing.s3) {
                        left
                        right
                    }
                }
            } else {
                left
            }
        }
        .dynamicTypeSize(...DynamicTypeSize.accessibility2)
    }
}
