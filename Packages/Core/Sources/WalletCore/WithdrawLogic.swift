import Foundation
import Generated

/// 提现金额输入（G18）：只接受半角数字与一个小数点，小数最多 2 位，整数部分最多 9 位；用字符串拆整数与小数部分做整数运算换算成分，不用浮点。
/// 空串、只有小数点、缺整数或小数部分（「.5」「5.」）、换算后为 0 → 不是合法金额（不发估算请求、【提交】置灰）。
public enum WithdrawAmountInput {
    static let valid = "^([0-9]{1,9})(\\.([0-9]{1,2}))?$"
    /// 正在编辑的文字（允许「12.」这类半截输入）。
    static let editing = "^[0-9]{0,9}(\\.[0-9]{0,2})?$"

    public static func parse(_ text: String) -> Int64? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard trimmed.range(of: valid, options: .regularExpression) != nil else { return nil }
        let parts = trimmed.split(separator: ".", omittingEmptySubsequences: false)
        guard let yuan = Int64(parts[0]) else { return nil }
        var cents: Int64 = 0
        if parts.count == 2 {
            let decimals = parts[1].count == 1 ? parts[1] + "0" : String(parts[1])
            cents = Int64(decimals) ?? 0
        }
        let fen = yuan * 100 + cents
        return fen > 0 ? fen : nil
    }

    /// 分 → 元的输入文字（【全部提现】与快捷档位）：去掉末尾的 0 和多余的小数点，不带「¥」（BR-TEXT-10 的写法）。
    public static func display(_ fen: Int64) -> String {
        let yuan = fen / 100
        let cent = fen % 100
        if cent == 0 {
            return "\(yuan)"
        }
        if cent % 10 == 0 {
            return "\(yuan).\(cent / 10)"
        }
        return cent < 10 ? "\(yuan).0\(cent)" : "\(yuan).\(cent)"
    }

    /// 输入框的过滤：新文字（粘贴先去首尾空白）只含半角数字与至多一个小数点、位数不超限时接受，否则整段不接受、保持原值（G18）。
    public static func accept(current: String, next: String) -> String {
        let trimmed = next.trimmingCharacters(in: .whitespaces)
        return trimmed.range(of: editing, options: .regularExpression) != nil ? trimmed : current
    }
}

/// 估算行（BR-WDR-04 细则）：隐藏，或 net_only / 带手续费与代扣个税的写法。金额都是服务端 est_*。
public enum EstimateLine: Equatable, Sendable {
    case hidden
    case netOnly(netFen: Int64)
    case full(netFen: Int64, feeFen: Int64, taxFen: Int64)

    public var netFen: Int64? {
        switch self {
        case .hidden: nil
        case let .netOnly(net): net
        case let .full(net, _, _): net
        }
    }
}

/// 提现页的显示结论（BR-WDR-04 细则「提现页的金额输入与提交后去向」）。客户端不判断余额够不够、最低额、步长、次数、费税、到账时间：
/// 能不能提只看 can_withdraw / block_code，【全部提现】只填 max_withdrawable_fen，估算只显示服务端 est_*，时效只按 Config 的 withdraw.sla_text
/// 或 BR-TEXT-07 原文（提交前不预判单据走向）。
public struct WithdrawRulesDisplay: Equatable, Sendable {
    public let balanceFen: Int64
    public let dailyRemaining: Int64
    public let monthlyRemaining: Int64
    public let maxLineFen: Int64?
    public let allEnabled: Bool
    public let allFen: Int64?
    public let quick: [Int64]
    public let estimate: EstimateLine
    public let slaText: String
    public let submitEnabled: Bool
    public let amountEditable: Bool
}

public enum WithdrawRulesView {
    public static let estimateKey = "withdraw.estimate"
    public static let estimateNetOnlyKey = "withdraw.estimate.net_only"
    public static let slaDefaultKey = "withdraw.sla_default"
    static let realnameBlock = 30304

    public static func of(
        _ rules: WithdrawRules, inputFen: Int64?, slaText: String?, texts: WalletTexts = WalletDraftTexts()
    ) -> WithdrawRulesDisplay {
        let can = rules.canWithdraw
        let allEnabled = can && rules.maxWithdrawableFen > 0
        let sla = slaText.flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
        return WithdrawRulesDisplay(
            balanceFen: rules.withdrawableFen,
            dailyRemaining: rules.dailyRemaining,
            monthlyRemaining: rules.monthlyRemaining,
            maxLineFen: can && rules.maxWithdrawableFen < rules.withdrawableFen ? rules.maxWithdrawableFen : nil,
            allEnabled: allEnabled,
            allFen: allEnabled ? rules.maxWithdrawableFen : nil,
            quick: can ? rules.quickAmountsFen : [],
            estimate: estimate(rules, inputFen: inputFen),
            slaText: sla ?? texts.text(slaDefaultKey),
            submitEnabled: can && inputFen != nil,
            // 只有未实名（30304）时金额框不可输入（照 WithdrawRealName 稿，G29）
            amountEditable: can || rules.blockCode != realnameBlock
        )
    }

    /// 估算：输入不合法、不能提、est_net_fen 为 null、费税有缺 → 隐藏；费税都为 0 → net_only。
    public static func estimate(_ rules: WithdrawRules, inputFen: Int64?) -> EstimateLine {
        guard inputFen != nil, rules.canWithdraw, let net = rules.estNetFen, let fee = rules.estFeeFen,
              let tax = rules.estTaxFen
        else { return .hidden }
        return fee == 0 && tax == 0 ? .netOnly(netFen: net) : .full(netFen: net, feeFen: fee, taxFen: tax)
    }
}

/// 估算响应的归属（BR-WDR-04 细则「估算响应的归属」）：四项都对得上才应用——① 账号与发请求时相同；② 仍是同一个 Withdraw 页面实例；
/// ③ 是这个实例最新的请求序号；④ 发请求时的金额等于当前输入换算出的金额（不带金额的请求不是估算）。
public enum WithdrawEstimateGate {
    public struct Request: Equatable, Sendable {
        public let account: String?
        public let pageInstance: String
        public let seq: Int64
        public let amountFen: Int64?

        public init(account: String?, pageInstance: String, seq: Int64, amountFen: Int64?) {
            self.account = account
            self.pageInstance = pageInstance
            self.seq = seq
            self.amountFen = amountFen
        }
    }

    public struct Current: Equatable, Sendable {
        public let account: String?
        public let pageInstance: String
        public let latestSeq: Int64
        public let inputFen: Int64?

        public init(account: String?, pageInstance: String, latestSeq: Int64, inputFen: Int64?) {
            self.account = account
            self.pageInstance = pageInstance
            self.latestSeq = latestSeq
            self.inputFen = inputFen
        }
    }

    public static func shouldApply(_ request: Request, _ current: Current) -> Bool {
        guard let amount = request.amountFen, let account = request.account else { return false }
        return account == current.account && request.pageInstance == current.pageInstance
            && request.seq == current.latestSeq && amount == current.inputFen
    }
}

/// 30303 的原因文案（G06、G07）：带占位符的子键取不到限制值，一律用 fallbacks；没有子键（payee_daily_count 等）回落 error.30303。
public enum WithdrawConditionText {
    public static let baseKey = "error.30303"

    public struct View: Equatable, Sendable {
        public let textKey: String
        public let useFallback: Bool
    }

    public static func view(_ reason: String?) -> View {
        guard let reason, let raw = DefaultTexts.text("\(baseKey).\(reason)") else {
            return View(textKey: baseKey, useFallback: true)
        }
        return View(textKey: "\(baseKey).\(reason)", useFallback: WalletDraftTexts.hasPlaceholder(raw))
    }
}

/// rules 的 block_code 引导表（G03、G04、G28、G29）：30304 → RealName；30305 / 30307 / 30308 → PayoutAccount；10004 →
/// LaborAgreement（rules
/// 不给 consent_type，一律按劳务协议）；30306 → 提现按钮置灰；30301 / 30302 / 30309 / 10006 / 44001 → 只提示；30303 按 `WithdrawConditionText`。
/// 表外的码只显示 error.<code>，键缺失时回落 error.30303，不引导、不显示码值。按钮由用户点了才打开前置页（G05，不自动跳）。
public enum WithdrawBlockGuide {
    public static let none = "none"
    public static let route = "route"
    public static let disable = "disable"
    public static let notice = "notice"

    public struct View: Equatable, Sendable {
        public let actionRaw: String
        public let route: String?
        public let textKey: String
        public let fallbackUsed: Bool?
        /// 引导按钮的文案键（只有 `route`）。
        public let buttonKey: String?

        init(_ action: String, route: String? = nil, textKey: String = "", fallbackUsed: Bool? = nil,
             buttonKey: String? = nil) {
            actionRaw = action
            self.route = route
            self.textKey = textKey
            self.fallbackUsed = fallbackUsed
            self.buttonKey = buttonKey
        }
    }

    public static func view(blockCode: Int?, blockReason: String?) -> View {
        guard let code = blockCode else { return View(none) }
        switch code {
        case 30304:
            return View(
                route,
                route: WalletRoutes.realName,
                textKey: "error.30304",
                buttonKey: "withdraw.guide.realname"
            )
        case 30305, 30307, 30308:
            return View(
                route,
                route: WalletRoutes.payoutAccount,
                textKey: "error.\(code)",
                buttonKey: "withdraw.guide.payout"
            )
        case 10004:
            return View(
                route,
                route: WalletRoutes.laborAgreement,
                textKey: "error.10004",
                buttonKey: "withdraw.guide.labor"
            )
        case 30306:
            return View(disable, textKey: "error.30306")
        case 30301, 30302, 30309, 10006, 44001:
            return View(notice, textKey: "error.\(code)")
        case 30303:
            let text = WithdrawConditionText.view(blockReason)
            return View(notice, textKey: text.textKey, fallbackUsed: text.useFallback)
        default:
            let key = "error.\(code)"
            return DefaultTexts.text(key) != nil
                ? View(notice, textKey: key, fallbackUsed: false)
                : View(notice, textKey: WithdrawConditionText.baseKey, fallbackUsed: true)
        }
    }
}

/// 帮助文章入口（G25、G26，照 APP-08 PriceCompareEntry）：help_links.<key> 已配置且目标路由与参数合法才给目标，未配置不显示。
public enum HelpLink {
    public static let withdrawRules = "withdraw_rules"

    public struct Target: Equatable, Sendable {
        public let route: String
        public let params: [String: String]
    }

    public static func target(_ helpLinks: [String: Any]?, key: String) -> Target? {
        guard let entry = helpLinks?[key] as? [String: Any], let route = entry["route"] as? String,
              route == WalletRoutes.help, let params = entry["params"] as? [String: Any],
              let article = params["article_id"] as? String, !article.isEmpty, params.count == 1,
              Routes.all[route] != nil
        else { return nil }
        return Target(route: route, params: ["article_id": article])
    }
}
