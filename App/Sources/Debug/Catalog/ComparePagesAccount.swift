#if DEBUG
import DesignSystem
import Generated
import SwiftUI

// 对照页：Wallet、Me（拆自 ComparePages.swift）。

// MARK: - Wallet

struct WalletCompare: View {
    @State private var hidden = CatalogLaunch.amountHidden

    var body: some View {
        VStack(spacing: 0) {
            NavBar(title: "钱包", backLabel: CatalogText.back)
            ScrollView {
                VStack(spacing: CouliSpacing.s3) {
                    WalletHeroCard(
                        title: "可提现余额",
                        amountFen: 1234,
                        isHidden: hidden,
                        toggleHiddenLabel: DefaultTexts.text(hidden ? "amount_mask.show" : "amount_mask.hide"),
                        withdrawTitle: "提现",
                        recordsTitle: "提现记录",
                        onToggleHidden: { hidden.toggle() },
                        onWithdraw: {},
                        footer: {
                            HeroAmountRow(items: [
                                AmountGridItem(
                                    label: "冻结中",
                                    value: .amount(0),
                                    helpLabel: CatalogText.walletHelp["frozen"]
                                ),
                                AmountGridItem(label: "已提现", value: .amount(500)),
                            ], amountHidden: hidden)
                        }
                    )
                    VStack(alignment: .leading, spacing: CouliSpacing.s4) {
                        AmountGrid(items: [
                            AmountGridItem(
                                label: "预估收益",
                                value: .amount(5678),
                                note: AmountNote("其中已收货 ", amountFen: 3456),
                                isRebate: true,
                                helpLabel: CatalogText.walletHelp["estimated"]
                            ),
                            AmountGridItem(label: "最早预计", value: .text("10 月结算")),
                        ], amountHidden: hidden)
                        HStack(spacing: CouliSpacing.s1) {
                            AmountNoteText(AmountNote("其中 ", amountFen: 456, suffix: " 暂缓入账"), hidden: hidden)
                            CouliIconView(.help, size: CouliGuideMetric.iconInline, relativeTo: .footnote)
                                .accessibilityHidden(true)
                            Spacer(minLength: 0)
                        }
                        .foregroundColor(CouliColor.textSecondary)
                        .padding(.horizontal, CouliSpacing.s3)
                        .frame(minHeight: CouliHitTarget.minimum)
                        .background(RoundedRectangle(cornerRadius: CouliRadius.button).fill(CouliColor.backgroundMuted))
                        Text(verbatim: "按联盟最新预估计算，以联盟结算金额为准")
                            .couliFont(.footnote)
                            .foregroundColor(CouliColor.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .couliCard()
                    EntryGrid(
                        items: [
                            EntryGridItem(id: "orders", title: "订单", icon: .orders),
                            EntryGridItem(id: "ledger", title: "余额流水", icon: .ledger),
                        ],
                        columns: 2
                    ) { _ in }
                }
                .padding(CouliSpacing.s4)
            }
        }
        .background(CouliColor.backgroundCanvas.ignoresSafeArea())
    }
}

// MARK: - Me

struct MeCompare: View {
    let section: Int

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(verbatim: "我的")
                    .couliFont(.heading, weight: .couliBold)
                    .foregroundColor(CouliColor.textPrimary)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                CouliIconView(.bell).couliHitTarget()
            }
            .padding(.horizontal, CouliSpacing.s4)
            PageScroll(section: section) {
                HStack(spacing: CouliSpacing.s4) {
                    Circle().fill(CouliColor.backgroundMuted)
                        .frame(width: CouliSpacing.s12 + CouliSpacing.s2, height: CouliSpacing.s12 + CouliSpacing.s2)
                        .overlay(CouliIconView(.user).foregroundColor(CouliColor.textSecondary))
                    VStack(alignment: .leading, spacing: CouliSpacing.s1) {
                        Text(verbatim: "凑狸用户").couliFont(.body, weight: .couliBold)
                        CouliFlowLayout(horizontalSpacing: CouliSpacing.s3, verticalSpacing: 0) {
                            Text(verbatim: "我的邀请码 K7M3QX").couliFont(.footnote)
                            Text(verbatim: "邀请人：已绑定").couliFont(.footnote)
                        }
                        .foregroundColor(CouliColor.textSecondary)
                    }
                }
                .couliCard()
                WalletHeroCard(
                    title: "可提现余额",
                    amountFen: 1234,
                    toggleHiddenLabel: DefaultTexts.text("amount_mask.hide"),
                    withdrawTitle: "提现",
                    onWithdraw: {},
                    footer: {
                        VStack(alignment: .leading, spacing: CouliSpacing.s1) {
                            HeroAmountRow(items: [
                                AmountGridItem(
                                    label: "预估收益",
                                    value: .amount(5678),
                                    note: AmountNote("其中已收货 ", amountFen: 3456),
                                    isRebate: true
                                ),
                            ], valueStyle: .title)
                            Text(verbatim: "最早预计 10 月结算").couliFont(.footnote, weight: .couliSemibold)
                        }
                    }
                )
                Anchor(id: 1)
                EntryGrid(title: "订单与钱包", items: [
                    EntryGridItem(id: "orders", title: "我的订单", icon: .orders),
                    EntryGridItem(id: "wallet", title: "钱包", icon: .wallet),
                    EntryGridItem(id: "ledger", title: "余额流水", icon: .ledger),
                    EntryGridItem(id: "claim", title: "找回订单", icon: .claim),
                ]) { _ in }
                EntryGrid(title: "推广与邀请", items: [
                    EntryGridItem(id: "invite", title: "邀请好友", icon: .invite),
                ]) { _ in }
                EntryGrid(title: "更多服务", items: [
                    EntryGridItem(id: "favorites", title: "收藏夹", icon: .heart),
                    EntryGridItem(id: "help", title: "帮助中心", icon: .help),
                    EntryGridItem(id: "cs", title: "联系客服", icon: .headset),
                    EntryGridItem(id: "auth", title: "授权管理", icon: .link),
                    EntryGridItem(id: "settings", title: "设置", icon: .settings),
                ]) { _ in }
            }
            TabBarMock(selected: "me")
        }
        .background(CouliColor.backgroundCanvas.ignoresSafeArea())
    }
}
#endif
