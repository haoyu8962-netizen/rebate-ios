import DesignSystem
import MeCore
import SwiftUI

/// 「我的」余额卡（设计稿 Me、MeHidden、MeStates、MeDark，brief §2-5）：狸橙实底、内边距 20、行距 12。
/// 首行「可提现余额」14/500 + 眼睛 20（紧凑，命中 44 不撑高）→ 大数 34/700 +【提现】（白底、最小宽 96、视觉 48，放不下整块换行）→
/// 预估块（钟表 14 + 标签 14、22/600 数值、纵向 2）。
///
/// 页面私有件（G-M17）：DS `WalletHeroCard` 的读屏顺序是「标题 → 眼睛 → 金额」，本页要「金额 → 眼睛 →【提现】」，且要逐块测量；不给共用组件加一串
/// 只有本页用的参数，DS-02 与钱包基准不动。金额只取 `MeViewModel` 的两个服务端字段，不相加不推算；隐藏时文字与读屏都没有原金额。
/// 回调一律是渲染时取出的 `MeTabActions`。【提现】任何数据下都可点（G-M03 / 04 / 05）。
struct MeHeroCard: View {
    let view: MeViewModel
    let texts: MeTexts
    let actions: MeTabActions

    private var hidden: Bool {
        view.masked
    }

    private var titleText: String {
        texts.text("me.withdrawable")
    }

    private var estimateTitle: String {
        texts.text("me.estimated")
    }

    var body: some View {
        // 子项按读屏顺序声明（金额 → 眼睛 →【提现】→ 预估），由 MeHeroLayout 摆回画板位置
        MeHeroLayout(rowSpacing: CouliSpacing.s3) {
            amount
            titleGroup
            withdraw
            estimate
            // 首行视觉框的测量占位
            Color.clear
                .meProbe("me.hero.titleRow", role: "row")
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
        .meProbe("me.hero", role: "card")
    }

    private func display(_ fen: Int64?) -> String {
        guard !hidden, let fen else { return MeView.mask }
        return MeMoney.text(fen)
    }

    private func spoken(_ fen: Int64?) -> String {
        guard !hidden, let fen else { return texts.text("me.amount_hidden") }
        return MeMoney.spoken(fen)
    }

    private var amount: some View {
        MeAmount(display(view.withdrawableFen), style: .display, weight: .couliBold,
                 lineHeightMultiple: CouliComponentMetric.buttonMinHeight / CouliTextStyle.display.baseSize,
                 probe: "me.hero.amount")
            .dynamicTypeSize(...DynamicTypeSize.accessibility2)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: titleText + PriceTerms.spokenPause + spoken(view.withdrawableFen)))
    }

    /// 首行：标签 + 眼睛。标签不单读：大数一项读「可提现余额，金额」，否则读两遍、眼睛夹在中间。
    private var titleGroup: some View {
        HStack(spacing: CouliSpacing.s1) {
            MeText(titleText, style: .footnote, weight: .couliMedium, probe: "me.hero.title")
                .accessibilityRepresentation { EmptyView() }
            MeIconButton(hidden ? .eyeOff : .eye, base: CouliGuideMetric.iconMedium,
                         label: texts.text(hidden ? "amount_mask.show" : "amount_mask.hide"), onBrand: true,
                         probe: "me.hero.eye", action: actions.toggleMask)
        }
    }

    /// 主卡在深色下不变，卡内【提现】仍是白底（令牌 button.inverse）：`.inverse` 取随外观变化的颜色，这里固定浅色外观（同钱包主卡）。
    private var withdraw: some View {
        CouliButton(texts.text("me.withdraw"), kind: .inverse, labelProbeID: "me.hero.withdraw.label",
                    minWidth: CouliSpacing.s12 * 2, action: actions.withdraw)
            .fixedSize()
            .environment(\.colorScheme, .light)
            .meProbe("me.hero.withdraw", role: "button")
    }

    private var estimate: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: CouliSpacing.s1) {
                CouliIconView(.clock, size: CouliGuideMetric.iconSmall, relativeTo: .footnote)
                    .meProbe("me.estimate.clock", role: "icon")
                    .accessibilityHidden(true)
                MeText(estimateTitle, style: .footnote, probe: "me.estimate.label")
            }
            MeAmount(display(view.estimatedFen), style: .title, weight: .couliSemibold, probe: "me.estimate.value")
                .dynamicTypeSize(...DynamicTypeSize.accessibility2)
        }
        .meProbe("me.estimate", role: "block")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: estimateTitle + PriceTerms.spokenPause + spoken(view.estimatedFen)))
        .accessibilityIdentifier("me.estimated")
    }
}

/// 主卡的排法（子项顺序：0 大数、1 首行、2【提现】、3 预估块、4 首行视觉框占位）：首行 → `rowSpacing` → 大数 +【提现】
/// （放得下同行、【提现】贴右、上下居中；放不下【提现】换到下一行靠左）→ `rowSpacing` → 预估块。声明顺序就是读屏顺序。
struct MeHeroLayout: Layout {
    let rowSpacing: CGFloat

    private struct Plan {
        var title: CGSize
        var amount: CGSize
        var button: CGSize
        var estimate: CGSize
        var inline: Bool

        func rowHeight(_ spacing: CGFloat) -> CGFloat {
            inline ? max(amount.height, button.height) : amount.height + spacing + button.height
        }
    }

    private func plan(_ width: CGFloat, _ subviews: Subviews) -> Plan {
        let wide = ProposedViewSize(width: width, height: nil)
        func fit(_ view: LayoutSubview) -> CGSize {
            let size = view.sizeThatFits(.unspecified)
            guard size.width > width else { return size }
            var wrapped = view.sizeThatFits(wide)
            wrapped.width = min(wrapped.width, width)
            return wrapped
        }
        let amount = fit(subviews[0])
        let button = subviews[2].sizeThatFits(.unspecified)
        let inline = amount.width + rowSpacing + button.width <= width + 0.5
        return Plan(title: fit(subviews[1]), amount: amount, button: button, estimate: fit(subviews[3]), inline: inline)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache _: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        let plan = plan(width, subviews)
        let height = plan.title.height + plan.rowHeight(rowSpacing) + plan.estimate.height + rowSpacing * 2
        let natural = max(plan.title.width, plan.amount.width, plan.estimate.width)
        return CGSize(width: width.isFinite ? width : natural, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal _: ProposedViewSize, subviews: Subviews, cache _: inout ()) {
        let plan = plan(bounds.width, subviews)
        var top = bounds.minY
        subviews[1].place(at: CGPoint(x: bounds.minX, y: top), proposal: ProposedViewSize(plan.title))
        subviews[4].place(at: CGPoint(x: bounds.minX, y: top),
                          proposal: ProposedViewSize(width: bounds.width, height: plan.title.height))
        top += plan.title.height + rowSpacing
        let height = plan.rowHeight(rowSpacing)
        if plan.inline {
            subviews[0].place(at: CGPoint(x: bounds.minX, y: top + (height - plan.amount.height) / 2),
                              proposal: ProposedViewSize(plan.amount))
            subviews[2].place(
                at: CGPoint(x: bounds.maxX - plan.button.width, y: top + (height - plan.button.height) / 2),
                proposal: ProposedViewSize(plan.button)
            )
        } else {
            subviews[0].place(at: CGPoint(x: bounds.minX, y: top), proposal: ProposedViewSize(plan.amount))
            subviews[2].place(at: CGPoint(x: bounds.minX, y: top + plan.amount.height + rowSpacing),
                              proposal: ProposedViewSize(plan.button))
        }
        top += height + rowSpacing
        subviews[3].place(at: CGPoint(x: bounds.minX, y: top), proposal: ProposedViewSize(plan.estimate))
    }
}
