import DesignSystem
import SwiftUI
import WalletCore

/// 主卡、预估收益卡、入口宫格与问号说明。
extension WalletScreen {
    func hero(_ view: WalletSummaryDisplay, _ snapshot: WalletSnapshot, _ actions: WalletActions) -> some View {
        let hidden = mask.hidden
        return WalletHeroCard(
            title: texts.text("wallet.withdrawable"), amountFen: view.hero.fen, isHidden: hidden,
            toggleHiddenLabel: texts.text(hidden ? "amount_mask.show" : "amount_mask.hide"),
            withdrawTitle: texts.text("wallet.withdraw"), withdrawEnabled: snapshot.withdrawEnabled,
            recordsTitle: texts.text("wallet.records"), onToggleHidden: actions.toggleMask,
            onWithdraw: actions.withdraw, onRecords: actions.records
        ) {
            VStack(alignment: .leading, spacing: CouliSpacing.s3) {
                HeroAmountRow(
                    items: [
                        AmountGridItem(
                            label: texts.text("wallet.frozen"), value: .amount(view.frozen.fen),
                            helpLabel: texts.text("wallet.help.frozen_label")
                        ),
                        AmountGridItem(label: texts.text("wallet.withdrawn"), value: .amount(view.withdrawn.fen)),
                    ],
                    amountHidden: hidden
                ) { _ in help = "frozen" }
                if let reason = view.withdrawReasonKey {
                    Text(verbatim: texts.text(reason))
                        .couliFont(.footnote, weight: .couliSemibold)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("wallet.disabledReason")
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("wallet.hero")
    }

    /// 待抵扣（设计稿 WalletNegative：主卡下方的浅黄条，三角 +「待抵扣 {x}，后续返利将优先抵扣」；待抵扣不进大数字）。
    func negativeStrip(_ fen: Int64) -> some View {
        HStack(alignment: .top, spacing: CouliSpacing.s2) {
            CouliIconView(.alert, size: CouliGuideMetric.iconInline, relativeTo: .footnote)
                .accessibilityHidden(true)
            noteLine(texts.format("wallet.negative", ["amount": Self.slot]), fen: fen, hidden: mask.hidden)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .foregroundColor(CouliColor.statusWarningText)
        .padding(CouliSpacing.s3)
        .background(RoundedRectangle(cornerRadius: CouliRadius.card).fill(CouliColor.statusWarningText.opacity(0.1)))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("wallet.negative")
    }

    /// 模板里金额位置的占位（不可见字符；金额由 AmountNote 按隐藏开关渲染，不经文案字典格式化）。
    static let slot = "\u{1}"

    /// 带一个金额的说明行。
    func noteLine(_ template: String, fen: Int64, hidden: Bool) -> some View {
        let parts = template.components(separatedBy: Self.slot)
        let note = AmountNote(parts.first ?? "", amountFen: fen, suffix: parts.dropFirst().joined())
        return Text(verbatim: note.display(hidden: hidden))
            .couliFont(.footnote, weight: .couliSemibold, monospacedDigits: true)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityLabel(Text(verbatim: note.spoken(hidden: hidden)))
    }

    func estimatedCard(_ view: WalletSummaryDisplay) -> some View {
        let hidden = mask.hidden
        let received = AmountNote(
            texts.format("wallet.received", ["amount": Self.slot]).components(separatedBy: Self.slot).first ?? "",
            amountFen: view.receivedLine.fen
        )
        let grid = AmountGrid(
            items: [
                AmountGridItem(
                    label: texts.text("wallet.estimated"), value: .amount(view.estimated.fen), note: received,
                    isRebate: true, helpLabel: texts.text("wallet.help.estimated_label")
                ),
            ],
            amountHidden: hidden
        ) { _ in help = "estimated" }
            .accessibilityIdentifier("wallet.estimated")
        return VStack(alignment: .leading, spacing: CouliSpacing.s2) {
            // 设计稿 Wallet：左「预估收益」、右「最早预计 / {M} 月结算」两列；大字号（AX 档）纵排（AdaptLargeTextWallet）
            if let month = view.earliestMonth {
                if dynamicTypeSize >= .accessibility1 {
                    grid
                    earliest(month)
                } else {
                    HStack(alignment: .top, spacing: CouliSpacing.s3) {
                        grid.frame(maxWidth: .infinity, alignment: .leading)
                        earliest(month).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            } else {
                grid
            }
            if view.overdueNote {
                Text(verbatim: texts.text("wallet.overdue"))
                    .couliFont(.footnote)
                    .foregroundColor(CouliColor.textSecondary)
                    .accessibilityIdentifier("wallet.overdue")
            }
            if let paused = view.pausedLine {
                pausedChip(paused.fen, hidden: hidden)
            }
            Text(verbatim: texts.text("wallet.estimate_note"))
                .couliFont(.footnote)
                .foregroundColor(CouliColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .couliCard()
    }

    /// 「其中 {x} 暂缓入账」+ 问号（设计稿：浅底胶囊条）。
    func pausedChip(_ fen: Int64, hidden: Bool) -> some View {
        HStack(spacing: CouliSpacing.s1) {
            noteLine(texts.format("wallet.paused", ["amount": Self.slot]), fen: fen, hidden: hidden)
                .foregroundColor(CouliColor.textSecondary)
            WalletHelpButton(label: texts.text("wallet.help.pending_paused_label")) { help = "pending_paused" }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, CouliSpacing.s3)
        .padding(.vertical, CouliSpacing.s1)
        .background(
            RoundedRectangle(cornerRadius: CouliRadius.small, style: .continuous)
                .fill(CouliColor.backgroundMuted)
        )
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("wallet.paused")
    }

    /// 「最早预计」+「{M} 月结算」（同年 / 跨年写法由 WalletSummaryView 给出）。
    func earliest(_ month: String) -> some View {
        VStack(alignment: .leading, spacing: CouliSpacing.s1) {
            Text(verbatim: texts.text("wallet.earliest_label"))
                .couliFont(.footnote)
                .foregroundColor(CouliColor.textSecondary)
            Text(verbatim: texts.format("wallet.earliest", ["month": month]))
                .couliFont(.title, weight: .couliBold)
                .foregroundColor(CouliColor.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("wallet.earliest")
    }

    func entries(_ actions: WalletActions) -> some View {
        var items = [
            EntryGridItem(id: WalletRoutes.orderList, title: texts.text("wallet.entry.orders"), icon: .orders),
            EntryGridItem(id: WalletRoutes.ledger, title: texts.text("wallet.entry.ledger"), icon: .ledger),
        ]
        if controller.earningsVisible {
            items.append(EntryGridItem(
                id: WalletRoutes.earnings, title: texts.text("wallet.entry.earnings"), icon: .trend
            ))
        }
        // EntryGrid 自带卡片底（不再套一层 couliCard）
        return EntryGrid(items: items, columns: items.count) { actions.entry($0.id) }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("wallet.entries")
    }

    func helpSheet(_ topic: String) -> some View {
        WalletHelpSheet(
            title: texts.text("wallet.help.\(topic)_title"), text: texts.text("wallet.help.\(topic)"), texts: texts,
            close: { help = nil }
        )
    }
}
