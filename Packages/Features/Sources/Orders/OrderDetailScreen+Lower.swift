import DesignSystem
import Generated
import OrderCore
import SwiftUI

/// 状态卡分隔线之下要画什么（纯视图整理，判定全部来自既有规则：`OrderStatusText`、`CreditPeriodText`、`WhyNoRebate`、
/// `PriceCompareEntry`、`OrderDetailActions`）。
struct OrderDetailLower {
    /// WAITING 的月份（「预计 {M} 月结算」灰胶囊，紧跟金额；没有月份不显示）。
    let creditMonth: String?
    /// DEPOSIT_PAID「尾款付清后计算返利」（紧跟金额，次文字）。
    let depositHint: String?
    /// 分隔线下的提示（PAID 入账句、售后 / 核对中、未知「请稍后查看」）；`muted` 为次文字色（未知状态，OrderDetailUnknown）。
    let hint: String?
    let hintMuted: Bool
    let why: WhyNoRebateView
    /// 原因说明（含扣回「已从余额扣除」）；nil = 只标题。
    let reasonDesc: String?
    let help: RouteTarget?
    let appealPending: Bool
    let split: OrderDetailActionSplit

    @MainActor
    init(detail: OrderDetail, actions: OrderActionsView, split: OrderDetailActionSplit, texts: OrderTexts,
         helpLinks: [String: Any]?, nowMs: Int64) {
        let summary = detail.summary
        let status = summary.displayStatus
        let statusView = OrderStatusText.view(status)
        let credit = CreditPeriodText.view(status, period: detail.expectedCreditPeriod, nowMs: nowMs)
        creditMonth = status == .waiting ? credit.monthText : nil
        depositHint = status == .depositPaid ? statusView.hintKey.map(texts.text)
            .flatMap { $0.isEmpty ? nil : $0 } : nil
        if status == .waiting || status == .depositPaid {
            hint = nil
        } else {
            hint = statusView.hintKey.map(texts.text).flatMap { $0.isEmpty ? nil : $0 }
        }
        hintMuted = status == .unknown
        why = WhyNoRebate.view(detail)
        reasonDesc = Self.desc(why, status: status, appealPending: detail.appealPending, texts: texts)
        help = PriceCompareEntry.view(detail, helpLinks: helpLinks, routes: Routes.all)
        appealPending = actions.appealPendingBlock
        self.split = split
    }

    /// 原因说明：PUNISH 只标题（G-O03，子原因无字段；扣回态仍保留「已从余额扣除」）；INVALID + BLACKLIST + 申诉中只标题
    /// （AppealPending-v2，由下方「申诉中」块代替；其他原因申诉中照常显示说明——Android b 评审 r1 S2-1）。
    @MainActor
    static func desc(_ why: WhyNoRebateView, status: DisplayStatus, appealPending: Bool, texts: OrderTexts) -> String? {
        let punish = why.reason == "PUNISH"
        let appealHidesDesc = status == .invalid && why.reason == "BLACKLIST" && appealPending
        let main = punish || appealHidesDesc ? nil : why.descKey.map(texts.text)
        let parts = [main, why.extraKey.map(texts.text)].compactMap(\.self).filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: texts.text(OrderKeys.descJoin))
    }

    /// 原因区（「为什么没返利？」/ 扣回标题）：INVALID / CLAWED_BACK 的已知原因。
    var showsReason: Bool {
        why.show && why.titleKey != nil && (why.headingKey != nil || why.extraKey != nil)
    }

    /// 差额 / 比价行：diff 类原因标题（G-O03 不推算金额）或 NO_REBATE 比价句。
    var showsDiff: Bool {
        why.show && !showsReason && (why.titleKey != nil || why.hintKey != nil)
    }

    /// 下方紧接可点的按钮（卡内按钮或未知状态动作）：其上的文字入口按命中区 44 占位，两个命中区不重叠。
    var buttonsBelow: Bool {
        !split.card.isEmpty || split.unknownLedger != nil
    }

    /// 「查看说明」下方直接是按钮（中间没有申诉中块）时占满命中区。
    var reservesHelpHit: Bool {
        buttonsBelow && !appealPending
    }

    var hasContent: Bool {
        hint != nil || showsReason || showsDiff || help != nil || appealPending || !split.card.isEmpty
            || split.unknownLedger != nil
    }
}

extension OrderDetailScreen {
    /// 分隔线下（brief §2.4-2）：提示 → 原因区 →（查看说明）→ 申诉中块 → 卡内按钮；未知状态：「请稍后查看」+ 描边【刷新】+「查看流水」。
    func lowerSection(_ lower: OrderDetailLower, blocked: Bool) -> some View {
        VStack(alignment: .leading, spacing: CouliSpacing.s3) {
            if let hint = lower.hint {
                OrderProbedText(hint, style: .footnote, probeID: "orderDetail.hint")
                    .foregroundColor(lower.hintMuted ? CouliColor.textSecondary : CouliColor.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("orderDetail.hint")
            }
            if lower.showsReason {
                reasonBlock(lower)
            }
            if lower.showsDiff {
                diffRow(lower)
            } else if let help = lower.help {
                helpLink(help, reserve: lower.reservesHelpHit)
            }
            if lower.appealPending {
                appealBlock(reserve: lower.buttonsBelow)
            }
            if !lower.split.card.isEmpty {
                cardButtons(lower.split.card)
            }
            if let ledger = lower.split.unknownLedger {
                unknownActions(ledger, blocked: blocked)
            }
        }
    }

    func reasonBlock(_ lower: OrderDetailLower) -> some View {
        VStack(alignment: .leading, spacing: CouliSpacing.s1) {
            if let heading = lower.why.headingKey {
                OrderProbedText(texts.text(heading), style: .footnote, weight: .couliSemibold,
                                probeID: "orderDetail.reason.heading")
                    .foregroundColor(CouliColor.textPrimary)
                    .accessibilityAddTraits(.isHeader)
            }
            if let title = lower.why.titleKey {
                OrderProbedText(texts.text(title), style: .footnote, probeID: "orderDetail.reason.title")
                    .foregroundColor(CouliColor.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("orderDetail.reasonTitle")
            }
            if let desc = lower.reasonDesc {
                OrderProbedText(desc, style: .footnote, probeID: "orderDetail.reason.desc")
                    .foregroundColor(CouliColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("orderDetail.reasonDesc")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("orderDetail.reason")
        .couliProbe("orderDetail.reason", role: "reason")
    }

    /// 差额 / 比价行：diff 类只显示原因标题（次文字，G-O03）；NO_REBATE 比价句（主文字）。「查看说明 ›」放得下在行尾，否则换到下一行行首。
    func diffRow(_ lower: OrderDetailLower) -> some View {
        let text = lower.why.titleKey.map(texts.text) ?? lower.why.hintKey.map(texts.text) ?? ""
        let muted = lower.why.titleKey != nil
        let label = OrderProbedText(text, style: .footnote, probeID: "orderDetail.diff")
            .foregroundColor(muted ? CouliColor.textSecondary : CouliColor.textPrimary)
            .accessibilityIdentifier(muted ? "orderDetail.reasonTitle" : "orderDetail.priceCompareHint")
        return ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: CouliSpacing.s2) {
                label.fixedSize()
                Spacer(minLength: CouliSpacing.s2)
                if let help = lower.help {
                    helpLink(help, reserve: lower.reservesHelpHit).fixedSize()
                }
            }
            VStack(alignment: .leading, spacing: 0) {
                label.fixedSize(horizontal: false, vertical: true)
                if let help = lower.help {
                    helpLink(help, reserve: lower.reservesHelpHit)
                }
            }
        }
    }

    /// 「查看说明 ›」：不占按钮位（BR-TEXT-03）。
    func helpLink(_ help: RouteTarget, reserve: Bool) -> some View {
        OrderDetailLink(
            title: texts.text(OrderKeys.viewHelp),
            probe: "orderDetail.viewHelp",
            reservesHitSpace: reserve
        ) {
            config.onOpen(help)
        }
        .accessibilityIdentifier("orderDetail.viewHelp")
    }

    /// 「申诉中」块（appeal_pending=true）：灰胶囊「申诉中」（钟表 14）→ 说明（不带提交时间，G-O03）→「查看申诉进度 ›」（Appeal，不带参数）。
    func appealBlock(reserve: Bool) -> some View {
        VStack(alignment: .leading, spacing: CouliSpacing.s2) {
            OrderDetailMutedPill(
                text: texts.text(OrderKeys.appealTitle),
                probe: "orderDetail.appeal.pill",
                icon: .clock
            )
            OrderProbedText(texts.text(OrderKeys.appealDesc), style: .footnote, probeID: "orderDetail.appeal.desc")
                .foregroundColor(CouliColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            OrderDetailLink(title: texts.text(OrderKeys.appealProgress), probe: "orderDetail.appealProgress",
                            reservesHitSpace: reserve) {
                config.onOpen(RouteTarget(route: "Appeal", params: [:]))
            }
            .accessibilityIdentifier("orderDetail.appealProgress")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("orderDetail.appeal")
        .couliProbe("orderDetail.appeal", role: "appeal")
    }

    /// 卡内按钮（G-O06）：左对齐、并排（放不下换行）；一个时描边，两个时首个实心 + 第二个描边。
    func cardButtons(_ buttons: [OrderActionButton]) -> some View {
        CouliFlowLayout(horizontalSpacing: CouliSpacing.s3, verticalSpacing: CouliSpacing.s2) {
            ForEach(Array(buttons.enumerated()), id: \.offset) { index, button in
                OrderDetailCardButton(
                    title: texts.text(button.labelKey), filled: buttons.count > 1 && index == 0,
                    probe: "orderDetail.action.\(button.actionRaw)"
                ) {
                    perform(button)
                }
                .accessibilityIdentifier("orderDetail.action.\(button.actionRaw)")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 未知状态（G-O08，OrderDetailUnknown）：不显示任何写动作；描边【刷新】（现有刷新，遵守 42901、在途时置灰，一次点击一次 getOrder）
    /// +「查看流水」文字链（规则层给出的 ledger → Ledger）。
    func unknownActions(_ ledger: OrderActionButton, blocked: Bool) -> some View {
        HStack(alignment: .center, spacing: CouliSpacing.s3) {
            OrderDetailCardButton(title: texts.text(OrderKeys.refresh), filled: false, probe: "orderDetail.refresh",
                                  enabled: !blocked) {
                controller.refresh()
            }
            .accessibilityIdentifier("orderDetail.refresh")
            OrderDetailLink(title: texts.text(ledger.labelKey), probe: "orderDetail.ledgerLink", chevron: false) {
                perform(ledger)
            }
            .fixedSize()
            .accessibilityIdentifier("orderDetail.ledgerLink")
        }
    }
}
