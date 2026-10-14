import Foundation

/// 提现单的显示结论（BR-TEXT-06、BR-WDR-25、BR-TEXT-07 / 08；G08）。
public struct WithdrawalDisplay: Equatable, Sendable {
    public let titleKey: String
    public let subLines: [TextLine]
    public let showChangeAccount: Bool
    /// withdraw_detail.net.expected / .actual；REJECTED、FAILED、未知状态为 nil（不显示到账行）。
    public let netKey: String?
    /// 认识的通道（alipay、bank_card）：才出【修改收款账号】等操作入口。
    public let knownChannel: Bool
}

/// 提现单的状态标题与副文案（G08）：只按契约里有的字段取。
/// - PENDING_REVIEW / APPROVED：review_mode=auto「预计几分钟内到账」，manual 或 null 用 Config withdraw.sla_text（没下发用 BR-TEXT-07 原文）；
///   另起一行「{amount} 已冻结」；
/// - PAYING：「处理中，结果会通知你」（读不到首次尝试时间，不按 T+2h 分支）；
/// - PAID_*：「已转入{通道} {脱敏串}，到账 {net}」，tax_fen>0 加「已代扣个税 {tax}」；
/// - REJECTED / FAILED：原因（只有规划原文写出的码才有键，未命中省略）+「{amount} 已退回可提现余额」；FAILED + fail_action=change_payout_account
///   句尾加「，可修改收款账号后重新提现」并出【修改收款账号】；
/// - 未知状态「处理中」，不出副文案；不认识的通道（含 wechat）只显示通道名与脱敏串，不出任何操作入口。
/// 不显示审核截止时间、超时句、到账时间行、hold_days 句（契约没有这些字段）。
public enum WithdrawalText {
    public static let auto = "auto"
    public static let changePayoutAccount = "change_payout_account"
    public static let netExpected = "withdraw_detail.net.expected"
    public static let netActual = "withdraw_detail.net.actual"
    static let knownStatuses: Set<String> = [
        "PENDING_REVIEW", "APPROVED", "PAYING", "PAID_API", "PAID_MANUAL", "REJECTED", "FAILED",
    ]
    static let rejectReasons: Set<String> = [
        "RISK_SUSPECT", "ORDER_ABNORMAL", "PAYEE_INFO_INVALID", "USER_REQUEST", "OTHER", "NEGATIVE_BALANCE",
    ]
    static let failReasons: Set<String> = ["PAYEE_NOT_EXIST", "PAYEE_USER_INFO_ERROR", "PAYEE_ACCOUNT_STATUS_ERROR"]

    public static func isPaid(_ status: String) -> Bool {
        status == "PAID_API" || status == "PAID_MANUAL"
    }

    public static func isReviewing(_ status: String) -> Bool {
        status == "PENDING_REVIEW" || status == "APPROVED"
    }

    public static func knownChannel(_ channel: String) -> Bool {
        channel == WalletJSON.alipay || channel == WalletJSON.bankCard
    }

    public static func of(_ item: Withdrawal, slaText: String?, texts: WalletTexts = WalletDraftTexts())
        -> WithdrawalDisplay {
        let status = item.status
        let known = knownChannel(item.payoutChannel)
        guard knownStatuses.contains(status) else {
            return WithdrawalDisplay(
                titleKey: "withdrawal_status.UNKNOWN.title", subLines: [], showChangeAccount: false, netKey: nil,
                knownChannel: known
            )
        }
        let title = "withdrawal_status.\(status).title"
        let netKey = isPaid(status) ? netActual : (isReviewing(status) || status == "PAYING" ? netExpected : nil)
        guard known else {
            let channel = TextLine("withdrawal.draft.channel", strings: channelStrings(item))
            return WithdrawalDisplay(
                titleKey: title, subLines: [channel], showChangeAccount: false, netKey: netKey, knownChannel: false
            )
        }
        let (lines, change) = subLines(item, slaText: slaText, texts: texts)
        return WithdrawalDisplay(
            titleKey: title, subLines: lines, showChangeAccount: change, netKey: netKey, knownChannel: true
        )
    }

    static func subLines(_ item: Withdrawal, slaText: String?, texts: WalletTexts) -> ([TextLine], Bool) {
        let status = item.status
        if isReviewing(status) {
            return (
                [sla(item.reviewMode, slaText, texts), TextLine(
                    "withdrawal.draft.frozen",
                    amounts: ["amount": item.amountFen]
                )],
                false
            )
        }
        if status == "PAYING" {
            return ([TextLine("withdrawal.draft.processing")], false)
        }
        if isPaid(status) {
            var lines = [TextLine(
                "withdrawal.draft.paid", amounts: ["net": item.netFen], strings: channelStrings(item)
            )]
            if item.taxFen > 0 {
                lines.append(TextLine("withdrawal.draft.tax", amounts: ["tax": item.taxFen]))
            }
            return (lines, false)
        }
        var lines: [TextLine] = []
        let returned = ["amount": item.amountFen]
        if status == "REJECTED" {
            if let code = item.reasonCode, rejectReasons.contains(code) {
                lines.append(TextLine("withdraw_reject_reason.\(code)"))
            }
            lines.append(TextLine("withdrawal.draft.returned", amounts: returned))
            return (lines, false)
        }
        if let code = item.reasonCode, failReasons.contains(code) {
            lines.append(TextLine("withdraw_fail_reason.\(code)"))
        }
        let change = item.failAction == changePayoutAccount
        lines.append(TextLine(
            change ? "withdrawal.draft.returned.change_account" : "withdrawal.draft.returned", amounts: returned
        ))
        return (lines, change)
    }

    static func sla(_ reviewMode: String?, _ slaText: String?, _ texts: WalletTexts) -> TextLine {
        if reviewMode == auto {
            return TextLine("withdraw.sla_text_auto")
        }
        let configured = slaText.flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
        return TextLine(
            "withdraw.sla_text",
            strings: ["text": configured ?? texts.text(WithdrawRulesView.slaDefaultKey)]
        )
    }

    static func channelStrings(_ item: Withdrawal) -> [String: String] {
        ["payout_channel_name": item.payoutChannelName, "masked_account": item.maskedAccount]
    }

    /// 原因片段与退回片段之间用分号连接（G08）；其余各占一行。
    public static func render(_ display: WithdrawalDisplay, texts: WalletTexts, money: (Int64) -> String) -> [String] {
        var out: [String] = []
        var reason: String?
        for line in display.subLines {
            let text = line.render(texts, money: money)
            if line.key.hasPrefix("withdraw_reject_reason.") || line.key.hasPrefix("withdraw_fail_reason.") {
                reason = text
            } else if line.key.hasPrefix("withdrawal.draft.returned"), let pending = reason {
                out.append(pending + texts.text("withdrawal.draft.join") + text)
                reason = nil
            } else {
                out.append(text)
            }
        }
        if let reason {
            out.append(reason)
        }
        return out
    }
}

/// 交易流水号行（BR-WDR-25 细则）：只有 PAID_API / PAID_MANUAL 且 channel_order_id 非 null 时显示，附【复制】，只在详情。
public enum TradeNoRow {
    public static func copyText(status: String, channelOrderId: String?) -> String? {
        guard let id = channelOrderId, !id.isEmpty, WithdrawalText.isPaid(status) else { return nil }
        return id
    }
}
