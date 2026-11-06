import DesignSystem
import SwiftUI
import WalletCore

/// 钱包页主卡（设计稿 Wallet / WalletFrozen / WalletHidden，brief §2.1-3，W1–W3）：狸橙实底、纵向 16、内边距 20。
/// 首行「可提现余额」+ 眼睛 /「提现记录 ›」（视觉一行，44 命中区溢出不撑高）→ 白字大数 + 【提现】（白底，最小宽 96、视觉 48）→
/// 冻结中 / 已提现两格（标签 14、数值 17/600，冻结中带问号）。
///
/// 只给钱包页用（「我的」的余额卡仍用 DesignSystem `WalletHeroCard`，默认外观不变）：本页要逐块测量、首行紧凑、按钮最小宽，
/// 写成页面私有件，不给共用组件加一串只有本页用的参数。金额只取 `WalletSummaryDisplay` 的服务端字段，隐藏时一律「****」。
/// 回调一律是渲染时取出的 `WalletActions`（版本与身份固定，共性第 4、63 条）；置灰判定取执行器 `snapshot.withdrawEnabled`，不在这里算。
struct WalletHeroPanel: View {
    let view: WalletSummaryDisplay
    let hidden: Bool
    let withdrawEnabled: Bool
    /// 置灰时【提现】的读屏原因（字典文案；可点时 nil）。
    let disabledReason: String?
    let texts: WalletTexts
    let actions: WalletActions
    let onHelp: (String) -> Void
    @ScaledMetric(relativeTo: .footnote) private var rowLine: CGFloat = CouliTextStyle.footnote.baseSize
        * CouliTextStyle.footnote.lineHeightMultiple
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        // 子项按读屏顺序声明（眼睛 → 可提现金额 →【提现】→ 提现记录 → 冻结中 / 已提现，brief §4.2），由 WalletHeroLayout 摆回画板位置
        WalletHeroLayout(rowSpacing: CouliSpacing.s4, titleSpacing: CouliSpacing.s3) {
            titleGroup
            amountRow
            records
            footer
            // 首行视觉框（标签 + 眼睛 +「提现记录 ›」所在的行，不含命中区溢出）的测量占位
            Color.clear
                .walletProbe("wallet.hero.titleRow", role: "row")
                .accessibilityHidden(true)
        }
        .foregroundColor(CouliColor.token("rebate.solid.text"))
        .padding(CouliSpacing.s5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: CouliRadius.card, style: .continuous)
                .fill(CouliColor.token("rebate.solid.background"))
                .couliShadow(.card)
        )
        .walletProbe("wallet.hero", role: "card")
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("wallet.hero")
    }

    private var titleText: String {
        texts.text("wallet.withdrawable")
    }

    /// 首行左段：标签 + 眼睛。视觉行高 = 14 号一行（眼睛 20，命中区 44 溢出）。
    private var titleGroup: some View {
        HStack(spacing: CouliSpacing.s1) {
            // 读屏由大数一项读「可提现余额，金额」，标签本身不重复读
            WalletText(titleText, style: .footnote, weight: .couliMedium, probe: "wallet.hero.title")
                .accessibilityHidden(true)
            WalletIconButton(
                hidden ? .eyeOff : .eye, base: CouliComponentMetric.iconMedium,
                label: texts.text(hidden ? "amount_mask.show" : "amount_mask.hide"), onBrand: true,
                probe: "wallet.hero.eye", action: actions.toggleMask
            )
        }
    }

    /// 「提现记录 ›」：视觉 = 文字行（14 号行高 21），命中区上下补到 44（负外边距，不撑高首行）。
    private var records: some View {
        let title = texts.text("wallet.records")
        let extra = max(0, (CouliHitTarget.minimum - rowLine) / 2)
        return Button(action: actions.records) {
            HStack(spacing: 2) {
                Text(verbatim: title)
                    .couliFont(.footnote, weight: .couliMedium)
                CouliIconView(.chevron, size: CouliComponentMetric.iconInline, relativeTo: .footnote)
            }
            .frame(minHeight: rowLine)
            .walletProbe("wallet.hero.records", role: "link")
            .padding(.vertical, extra)
            .contentShape(Rectangle())
            .walletProbe("wallet.hero.records.hit", role: "hit")
        }
        .buttonStyle(CouliPlainButtonStyle(cornerRadius: CouliRadius.small, onBrand: true))
        .padding(.vertical, -extra)
        .accessibilityLabel(Text(verbatim: title))
    }

    /// 大数 + 【提现】：同行时【提现】贴右，放不下时【提现】换到下一行靠左（adaptation-a11y-spec §2）。
    private var amountRow: some View {
        CouliFlowLayout(horizontalSpacing: CouliSpacing.s3, verticalSpacing: CouliSpacing.s3) {
            WalletAmount(
                text: view.hero.maskedText ?? WalletMoney.text(view.hero.fen), style: .display, weight: .couliBold,
                lineHeightMultiple: CouliComponentMetric.buttonMinHeight / CouliTextStyle.display.baseSize,
                probe: "wallet.hero.amount"
            )
            .dynamicTypeSize(...DynamicTypeSize.accessibility2)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: titleText + PriceTerms.spokenPause + spoken(view.hero.fen)))
            withdrawButton
                .couliFlowPushTrailing(.inlineOnly)
        }
    }

    /// 【提现】（WalletDark 设计说明）：狸橙主卡在深色下不变，可点时卡内【提现】仍是白底 + #A83B1F 字，置灰为主按钮禁用样式
    /// （深色 #36312C 底 + #A39A90 字）。都由共用 `.inverse` 样式按令牌 button.inverse.* / button.primary.disabled.* 取值
    /// （DS-02-iOS-1 计划 ③），本页不再局部强制外观（原 F-IOS-50 写法）。
    private var withdrawButton: some View {
        CouliButton(
            texts.text("wallet.withdraw"), kind: .inverse, isEnabled: withdrawEnabled,
            labelProbeID: "wallet.hero.withdraw.label", minWidth: CouliSpacing.s12 * 2, action: actions.withdraw
        )
        .fixedSize()
        .walletProbe("wallet.hero.withdraw", role: "button")
        .accessibilityValue(Text(verbatim: disabledReason ?? ""))
    }

    /// 主卡底部两格：冻结中（带问号）/ 已提现；辅助字号档（≈ 200% 起）上下排。
    private var footer: some View {
        let frozen = cell(
            "wallet.hero.frozen", label: texts.text("wallet.frozen"), amount: view.frozen,
            help: texts.text("wallet.help.frozen_label")
        )
        let withdrawn = cell("wallet.hero.withdrawn", label: texts.text("wallet.withdrawn"), amount: view.withdrawn)
        return Group {
            if dynamicTypeSize >= .accessibility1 {
                VStack(alignment: .leading, spacing: CouliSpacing.s3) {
                    frozen
                    withdrawn
                }
            } else {
                HStack(alignment: .top, spacing: CouliSpacing.s3) {
                    frozen
                    withdrawn
                }
            }
        }
        .dynamicTypeSize(...DynamicTypeSize.accessibility2)
    }

    private func cell(_ id: String, label: String, amount: MaskableAmount, help: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: CouliSpacing.s1) {
                WalletText(label, style: .footnote, probe: id + ".label")
                    .accessibilityLabel(Text(verbatim: label + PriceTerms.spokenPause + spoken(amount.fen)))
                if let help {
                    WalletIconButton(.help, base: CouliComponentMetric.iconSmall, label: help, onBrand: true,
                                     probe: id + ".help") { onHelp("frozen") }
                }
            }
            .walletProbe(id + ".labelRow", role: "row")
            WalletAmount(text: amount.maskedText ?? WalletMoney.text(amount.fen), style: .body, probe: id + ".value")
                .accessibilityHidden(true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .walletProbe(id, role: "cell")
    }

    private func spoken(_ fen: Int64) -> String {
        hidden ? PriceTerms.spokenAmountHidden : WalletMoney.spoken(fen)
    }
}

/// 主卡的排法（子项顺序：0 首行左段、1 大数行、2「提现记录 ›」、3 底部两格、4 首行视觉框占位）：
/// 首行 = 左段 +「提现记录 ›」（放得下同行贴右、上下居中；放不下「提现记录 ›」换到下一行靠左，行距 `titleSpacing`，
/// 两者 44 命中区不重叠）→ `rowSpacing` → 大数行 → `rowSpacing` → 底部两格。声明顺序就是读屏顺序。
struct WalletHeroLayout: Layout {
    let rowSpacing: CGFloat
    let titleSpacing: CGFloat

    private struct Plan {
        var title: CGSize
        var records: CGSize
        var inline: Bool
        var rowHeight: CGFloat
        var amount: CGSize
        var footer: CGSize
    }

    private func plan(_ width: CGFloat, _ subviews: Subviews) -> Plan {
        func fit(_ view: LayoutSubview) -> CGSize {
            var size = view.sizeThatFits(.unspecified)
            if size.width > width {
                size = view.sizeThatFits(ProposedViewSize(width: width, height: nil))
                size.width = min(size.width, width)
            }
            return size
        }
        let title = fit(subviews[0])
        let records = fit(subviews[2])
        let inline = title.width + titleSpacing + records.width <= width + 0.5
        let rowHeight = inline ? max(title.height, records.height) : title.height + titleSpacing + records.height
        let amount = subviews[1].sizeThatFits(ProposedViewSize(width: width, height: nil))
        let footer = subviews[3].sizeThatFits(ProposedViewSize(width: width, height: nil))
        return Plan(title: title, records: records, inline: inline, rowHeight: rowHeight, amount: amount,
                    footer: footer)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache _: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        let plan = plan(width, subviews)
        let height = plan.rowHeight + rowSpacing + plan.amount.height + rowSpacing + plan.footer.height
        let natural = max(plan.inline ? plan.title.width + titleSpacing + plan.records.width : plan.title.width,
                          plan.amount.width, plan.footer.width)
        return CGSize(width: width.isFinite ? width : natural, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal _: ProposedViewSize, subviews: Subviews, cache _: inout ()) {
        let plan = plan(bounds.width, subviews)
        let top = bounds.minY
        if plan.inline {
            subviews[0].place(at: CGPoint(x: bounds.minX, y: top + (plan.rowHeight - plan.title.height) / 2),
                              proposal: ProposedViewSize(plan.title))
            subviews[2].place(at: CGPoint(x: bounds.maxX - plan.records.width,
                                          y: top + (plan.rowHeight - plan.records.height) / 2),
                              proposal: ProposedViewSize(plan.records))
        } else {
            subviews[0].place(at: CGPoint(x: bounds.minX, y: top), proposal: ProposedViewSize(plan.title))
            subviews[2].place(at: CGPoint(x: bounds.minX, y: top + plan.title.height + titleSpacing),
                              proposal: ProposedViewSize(plan.records))
        }
        subviews[4].place(at: CGPoint(x: bounds.minX, y: top),
                          proposal: ProposedViewSize(width: bounds.width, height: plan.rowHeight))
        let amountY = top + plan.rowHeight + rowSpacing
        subviews[1].place(at: CGPoint(x: bounds.minX, y: amountY),
                          proposal: ProposedViewSize(width: bounds.width, height: plan.amount.height))
        subviews[3].place(at: CGPoint(x: bounds.minX, y: amountY + plan.amount.height + rowSpacing),
                          proposal: ProposedViewSize(width: bounds.width, height: plan.footer.height))
    }
}
