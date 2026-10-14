import Foundation
import OrderCore

/// 一个可隐藏的金额（`fen` 始终是服务端值；`masked` 时显示「****」，不带 ¥、位数、正负号）。
public struct MaskableAmount: Equatable, Sendable {
    /// BR-TEXT-10 细则「金额隐藏」的遮罩（与 APP-08 amount_mask.mask 同文）。
    public static let mask = "****"

    public let fen: Int64
    public let masked: Bool

    public var maskedText: String? {
        masked ? Self.mask : nil
    }
}

/// 风控暂停提示条（G10）：`textKey` 为 wallet.draft.risk_paused（查不到原因文案）或 wallet.draft.risk_paused_reason（带 `reasonText`）。
public struct RiskBanner: Equatable, Sendable {
    public let show: Bool
    public let textKey: String?
    public let reasonText: String?
}

/// 钱包页的显示结论（BR-FUND-18、BR-TEXT-01、03 §10.2 WalletHeroCard / AmountGrid）。金额只取服务端字段：
/// - 主卡「可提现余额」= withdrawable_fen；待抵扣 negative_fen>0 另起一行，冻结中、待抵扣不进大数字；
/// - 「预估收益」= estimated_total_fen（客户端不相加）；其下三项分开：已收货（为 0 照常显示）、「最早预计 {月份} 结算」（next_credit_period
///   非 null）与「入账核对中」（credit_overdue）、「其中 {x} 暂缓入账」（>0）；不出现「待入账」「累计」；
/// - 【提现】（G11 编排者更正）：withdraw_enabled=false（附 error.30306）、待抵扣置灰；风控冻结不置灰（BR-WDR-05 细则），能不能提由
///   Withdraw 页的 rules 决定。
public struct WalletSummaryDisplay: Equatable, Sendable {
    public let hero: MaskableAmount
    public let negativeLine: MaskableAmount?
    public let frozen: MaskableAmount
    public let withdrawn: MaskableAmount
    public let estimated: MaskableAmount
    public let receivedLine: MaskableAmount
    public let earliestMonth: String?
    public let overdueNote: Bool
    public let pausedLine: MaskableAmount?
    public let riskBanner: RiskBanner
    public let withdrawEnabled: Bool
    public let withdrawReasonKey: String?
}

public enum WalletSummaryView {
    public static let riskPausedKey = "wallet.draft.risk_paused"
    public static let riskPausedReasonKey = "wallet.draft.risk_paused_reason"
    public static let featureOffKey = "error.30306"

    public static func of(
        _ summary: WalletSummary, masked: Bool, nowMs: Int64, texts: WalletTexts = WalletDraftTexts()
    ) -> WalletSummaryDisplay {
        func amount(_ fen: Int64) -> MaskableAmount {
            MaskableAmount(fen: fen, masked: masked)
        }
        let banner: RiskBanner
        if let risk = summary.riskPausedReason {
            // 原因文案查 risk_msg.<reason>（契约还没有这些键，G10）；查不到只显示「提现已暂停」，不显示原因码原文
            let key = "risk_msg.\(risk)"
            banner = texts.has(key)
                ? RiskBanner(show: true, textKey: riskPausedReasonKey, reasonText: texts.text(key))
                : RiskBanner(show: true, textKey: riskPausedKey, reasonText: nil)
        } else {
            banner = RiskBanner(show: false, textKey: nil, reasonText: nil)
        }
        // 风控冻结不置灰（G11 编排者更正）：可点，进提现页由 rules 的 30303 account_frozen 提示、不能提交
        let enabled = summary.withdrawEnabled && summary.negativeFen <= 0
        return WalletSummaryDisplay(
            hero: amount(summary.withdrawableFen),
            negativeLine: summary.negativeFen > 0 ? amount(summary.negativeFen) : nil,
            frozen: amount(summary.frozenFen),
            withdrawn: amount(summary.withdrawnFen),
            estimated: amount(summary.estimatedTotalFen),
            receivedLine: amount(summary.pendingCreditFen),
            earliestMonth: CreditPeriodText.monthText(summary.nextCreditPeriod, nowMs: nowMs),
            overdueNote: summary.creditOverdue,
            pausedLine: summary.pendingCreditPausedFen > 0 ? amount(summary.pendingCreditPausedFen) : nil,
            riskBanner: banner,
            withdrawEnabled: enabled,
            withdrawReasonKey: summary.withdrawEnabled ? nil : featureOffKey
        )
    }
}

/// 收益看板入口（G20，F-WDR-14，M-公开）：同时满足才显示——Config features.flags["earnings.dashboard.visible"] 为 true，且 Earnings 路由在
/// 本端本版本可用（routes.json since 非 null 且不高于当前版本）。现在三端 since 都为 null，入口一律不显示。
public enum EarningsEntry {
    public static let flagKey = "earnings.dashboard.visible"

    public static func visible(flag: Bool?, routeSince: String?, appVersion: String) -> Bool {
        guard flag == true, let routeSince else { return false }
        return versionAtLeast(appVersion, routeSince)
    }

    /// 按点分隔的十进制整数逐段比较，缺的段按 0；任一方解析不了按 false（保守）。
    static func versionAtLeast(_ version: String, _ minimum: String) -> Bool {
        func parse(_ text: String) -> [Int]? {
            let parts = text.split(separator: ".", omittingEmptySubsequences: false)
            let numbers = parts.compactMap { part -> Int? in
                guard !part.isEmpty, part.allSatisfy(\.isASCII) else { return nil }
                return Int(part)
            }
            return numbers.count == parts.count && !numbers.isEmpty ? numbers : nil
        }
        guard let lhs = parse(version), let rhs = parse(minimum) else { return false }
        for index in 0..<max(lhs.count, rhs.count) {
            let left = index < lhs.count ? lhs[index] : 0
            let right = index < rhs.count ? rhs[index] : 0
            if left != right {
                return left > right
            }
        }
        return true
    }
}

/// 资金与实名四页（Withdraw、PayoutAccount、LaborAgreement、RealName）不接受任何路由参数（BR-WDR-01 细则，AC-S1-81 ⑫）：全部丢弃、照常
/// 打开，记 route_params_dropped（只有路由名与个数）。其余路由的参数原样（由 Router 按 routes.json 校验）。
public enum FundRouteParams {
    public static let event = "route_params_dropped"
    public static let routes: Set<String> = [
        WalletRoutes.withdraw, WalletRoutes.payoutAccount, WalletRoutes.laborAgreement, WalletRoutes.realName,
    ]

    public struct Filtered: Equatable, Sendable {
        public let dropped: Int
        public let event: String?
        public let keepsParams: Bool
    }

    public static func filtered(route: String, paramCount: Int) -> Filtered {
        guard routes.contains(route) else { return Filtered(dropped: 0, event: nil, keepsParams: true) }
        return Filtered(dropped: paramCount, event: paramCount > 0 ? event : nil, keepsParams: false)
    }
}

/// 钱包类页面用到的路由名（routes.json；跨功能跳转只经 Router）。路由表里没有 StepUp、WithdrawDetail、PayoutAccountEdit。
public enum WalletRoutes {
    public static let wallet = "Wallet"
    public static let withdraw = "Withdraw"
    public static let withdrawRecords = "WithdrawRecords"
    public static let ledger = "Ledger"
    public static let earnings = "Earnings"
    public static let realName = "RealName"
    public static let payoutAccount = "PayoutAccount"
    public static let laborAgreement = "LaborAgreement"
    public static let help = "Help"
    public static let riskNotice = "RiskNotice"
    public static let bindPhone = "BindPhone"
    public static let orderList = "OrderList"
    public static let login = "Login"
    public static let withdrawalId = "withdrawal_id"

    /// 本任务接管页面的路由。
    public static let pages = [wallet, withdraw, withdrawRecords, payoutAccount, realName, laborAgreement]
    /// 钱包类页面会打开的全部路由（OrdersWiringTests 同口径逐个核对在 routes.json 里）。
    public static let all = pages + [ledger, earnings, help, riskNotice, bindPhone, orderList, login]
}
