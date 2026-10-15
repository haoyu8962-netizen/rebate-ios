import DesignSystem
import MeCore
import SwiftUI

/// 「我的」页的引导条、身份卡、余额卡与宫格（设计稿 Me、MeHidden、MeMinor）。
extension MeTabBody {
    func guideBar(_ actions: MeTabActions) -> some View {
        HStack(spacing: 0) {
            Button(action: actions.openGuide) {
                HStack(spacing: CouliSpacing.s2) {
                    CouliIconView(.bell, size: CouliGuideMetric.iconMedium, relativeTo: .footnote)
                        .foregroundColor(CouliColor.statusWarningText)
                        .accessibilityHidden(true)
                    Text(verbatim: texts.text("perm.push.guide_bar"))
                        .couliFont(.footnote)
                        .foregroundColor(CouliColor.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.leading, CouliSpacing.s3)
                .padding(.vertical, CouliSpacing.s2)
                .frame(minHeight: CouliHitTarget.minimum)
                .contentShape(Rectangle())
            }
            .buttonStyle(CouliPlainButtonStyle(cornerRadius: CouliRadius.button))
            .accessibilityIdentifier("me.guideBar.open")
            Button(action: actions.closeGuide) {
                CouliIconView(.close, size: CouliGuideMetric.iconInline, relativeTo: .footnote)
                    .foregroundColor(CouliColor.textSecondary)
                    .couliHitTarget()
            }
            .buttonStyle(CouliPlainButtonStyle(cornerRadius: CouliRadius.small))
            .accessibilityLabel(Text(verbatim: texts.text("me.guide_bar.close")))
            .accessibilityIdentifier("me.guideBar.close")
        }
        .background(
            RoundedRectangle(cornerRadius: CouliRadius.button, style: .continuous)
                .fill(CouliColor.statusWarningText.opacity(0.1))
        )
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("me.guideBar")
    }

    func identityCard(_ me: MeProfile, _ view: MeViewModel, _ actions: MeTabActions) -> some View {
        HStack(alignment: .center, spacing: CouliSpacing.s4) {
            avatar
            VStack(alignment: .leading, spacing: CouliSpacing.s1) {
                Text(verbatim: me.nickname)
                    .couliFont(.title, weight: .couliSemibold)
                    .foregroundColor(CouliColor.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("me.nickname")
                // G05：invite_code 为 null 时整块不显示（不显示原因）
                if let code = view.inviteCode {
                    HStack(spacing: CouliSpacing.s1) {
                        Text(verbatim: texts.text("me.invite_code") + " " + code)
                            .couliFont(.footnote)
                            .foregroundColor(CouliColor.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("me.inviteCode")
                        Button(action: actions.copyInvite) {
                            CouliIconView(.copy, size: CouliGuideMetric.iconInline, relativeTo: .footnote)
                                .foregroundColor(CouliColor.brandPrimary)
                                .couliHitTarget()
                        }
                        .buttonStyle(CouliPlainButtonStyle(cornerRadius: CouliRadius.small))
                        .padding(.vertical, -CouliSpacing.s3)
                        .accessibilityLabel(Text(verbatim: texts.text("me.copy") + texts.text("me.invite_code")))
                        .accessibilityIdentifier("me.copyInvite")
                    }
                }
                if let key = view.inviterTextKey {
                    Text(verbatim: texts.text(key))
                        .couliFont(.footnote)
                        .foregroundColor(CouliColor.textSecondary)
                        .accessibilityIdentifier("me.inviter")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .couliCard(padding: CouliSpacing.s5)
        .background(MeSectionTops.reader("me.section.identity"))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("me.identity")
    }

    func balanceCard(_ view: MeViewModel, _ actions: MeTabActions) -> some View {
        let withdrawable = view.withdrawableFen ?? 0
        let estimated = view.estimatedFen ?? 0
        let hidden = view.masked
        return WalletHeroCard(
            title: texts.text("me.withdrawable"), amountFen: withdrawable, isHidden: hidden,
            toggleHiddenLabel: texts.text(hidden ? "amount_mask.show" : "amount_mask.hide"),
            withdrawTitle: texts.text("me.withdraw"), onToggleHidden: actions.toggleMask, onWithdraw: actions.withdraw
        ) {
            VStack(alignment: .leading, spacing: CouliSpacing.s1) {
                HStack(spacing: CouliSpacing.s1) {
                    CouliIconView(.clock, size: CouliGuideMetric.iconInline, relativeTo: .footnote)
                        .accessibilityHidden(true)
                    Text(verbatim: texts.text("me.estimated"))
                        .couliFont(.footnote, weight: .couliSemibold)
                }
                Text(verbatim: hidden ? MeView.mask : MeMoney.text(estimated))
                    .couliFont(.title, weight: .couliBold, monospacedDigits: true)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: texts.text("me.estimated") + PriceTerms.spokenPause
                    + (hidden ? texts.text("me.amount_hidden") : MeMoney.spoken(estimated))))
            .accessibilityIdentifier("me.estimated")
        }
        .background(MeSectionTops.reader("me.section.balance"))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("me.balance")
    }

    func grid(_ view: MeViewModel, _ actions: MeTabActions) -> some View {
        let groups = [MeView.groupOrders, MeView.groupPromo, MeView.groupMore]
        return ForEach(groups, id: \.self) { group in
            let cells = view.grid.filter { $0.group == group }
            let items = cells.compactMap { cell -> EntryGridItem? in
                guard let key = MeDraftTexts.gridKey(cell.item) else { return nil }
                return EntryGridItem(id: cell.item, title: texts.text(key), icon: Self.icon(key),
                                     accessibilityIdentifier: MeDraftTexts.gridIdentifier(cell.item))
            }
            if !items.isEmpty {
                EntryGrid(title: texts.text("me.group.\(group)"), items: items, eager: true) { item in
                    if let cell = cells.first(where: { $0.item == item.id }) {
                        actions.tap(cell)
                    }
                }
                .id("me.section.\(group)")
                .background(MeSectionTops.reader("me.section.\(group)"))
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("me.grid.\(group)")
            }
        }
    }

    static func icon(_ key: String) -> CouliIcon {
        switch key {
        case "me.grid.orders": .orders
        case "me.grid.wallet": .wallet
        case "me.grid.ledger": .ledger
        case "me.grid.find_order": .claim
        case "me.grid.invite": .invite
        case "me.grid.earnings": .trend
        case "me.grid.help": .help
        case "me.grid.cs": .headset
        case "me.grid.auth": .link
        default: .settings
        }
    }
}
