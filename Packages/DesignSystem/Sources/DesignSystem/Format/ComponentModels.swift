import Generated

// 组件模型：纯函数，决定 PriceTag / RebateTag / EstNetLine / BuyButton 显示的文字（三端同名）。
// 规则只引编号：BR-PRICE-04、05、07、08、09、22，BR-TEXT-10，BR-TEXT-14 表 C btn.buy.rebate_suffix。

// MARK: - PriceTag

/// PriceTag 的显示内容。
public struct PriceTagContent: Sendable, Equatable {
    /// 主价口径词：券后 / 售价 / 拼单券后 / 拼单价。
    public let mainLabel: String
    /// 主价（BR-TEXT-10 格式）。
    public let mainAmount: String
    /// 副行「券前 ¥x · 券 ¥y」；无券时 nil。
    public let subLine: String?
    /// 无券状态（组件显示「无券」）。
    public let noCoupon: Bool
    /// 预售标签；非预售 nil。
    public let presaleLabel: String?
    /// 主价读屏文本：「券后 29.9 元」。
    public let mainAccessibilityText: String
    /// 副行读屏文本：「券前 39.9 元，券 10 元」；无券时 nil。
    public let subLineAccessibilityText: String?

    public init(
        mainLabel: String,
        mainAmount: String,
        subLine: String?,
        noCoupon: Bool,
        presaleLabel: String?,
        mainAccessibilityText: String,
        subLineAccessibilityText: String?
    ) {
        self.mainLabel = mainLabel
        self.mainAmount = mainAmount
        self.subLine = subLine
        self.noCoupon = noCoupon
        self.presaleLabel = presaleLabel
        self.mainAccessibilityText = mainAccessibilityText
        self.subLineAccessibilityText = subLineAccessibilityText
    }
}

public enum PriceTagModel {
    /// 有券：主价「券后 ¥final」，副行「券前 ¥price · 券 ¥coupon」；无券：「售价 ¥final」、无副行、无券状态；
    /// 拼多多加「拼单」（无券为「拼单价」）。预售加「预售」标签，按总价显示（BR-PRICE-22）。
    /// 规则空白（rule-gaps.md）：负价、负券额、未知平台未定义。保守处理：券额 ≤ 0 一律按无券；
    /// 只有 `pdd` 加「拼单」，其他（含未知）平台按普通写法；金额原样格式化，不做纠正。
    public static func make(
        platform: String,
        priceFen: Int64,
        couponFen: Int64,
        finalPriceFen: Int64,
        isPresale: Bool
    ) -> PriceTagContent {
        let isPdd = Platform(rawValue: platform) == .pdd
        let presale = isPresale ? PriceTerms.presale : nil
        let mainAmount = CouliFormat.money(fen: finalPriceFen)
        guard couponFen > 0 else {
            let label = isPdd ? PriceTerms.pddPrice : PriceTerms.salePrice
            return PriceTagContent(
                mainLabel: label,
                mainAmount: mainAmount,
                subLine: nil,
                noCoupon: true,
                presaleLabel: presale,
                mainAccessibilityText: label + " " + CouliFormat.moneySpoken(fen: finalPriceFen),
                subLineAccessibilityText: nil
            )
        }
        let label = isPdd ? PriceTerms.pddAfterCoupon : PriceTerms.afterCoupon
        let before = isPdd ? PriceTerms.pddBeforeCoupon : PriceTerms.beforeCoupon
        let subLine = before + " " + CouliFormat.money(fen: priceFen)
            + PriceTerms.separator + PriceTerms.coupon + " " + CouliFormat.money(fen: couponFen)
        let spokenSub = before + " " + CouliFormat.moneySpoken(fen: priceFen)
            + PriceTerms.spokenPause + PriceTerms.coupon + " " + CouliFormat.moneySpoken(fen: couponFen)
        return PriceTagContent(
            mainLabel: label,
            mainAmount: mainAmount,
            subLine: subLine,
            noCoupon: false,
            presaleLabel: presale,
            mainAccessibilityText: label + " " + CouliFormat.moneySpoken(fen: finalPriceFen),
            subLineAccessibilityText: spokenSub
        )
    }
}

// MARK: - RebateTag

/// 返利标签的种类。字符串值就是向量里的 kind。
public enum RebateTagKind: String, Sendable, CaseIterable {
    /// 单一金额「预估返 ¥x」。
    case amount
    /// 区间「预估返 ¥a–¥b」。
    case range
    /// 暂无返利（列表里隐藏）。
    case none
    /// 金额未知「可返利，金额以订单为准」。
    case unknown
    /// 登录查看返利。
    case login
}

/// RebateTag 的显示内容。
public struct RebateTagContent: Sendable, Equatable {
    public let kind: RebateTagKind
    /// 完整文字（「预估返 ¥2.69」「预估返 ¥1.35–¥2.69」「暂无返利」…）。
    public let text: String
    /// 标签词（amount / range 为「预估返」，其他为 nil）。
    public let label: String?
    /// 金额的不可拆分段：单值一段，区间两段「¥a」「–¥b」（只在破折号处折行，GUIDE §7.2.1）。
    public let amountParts: [String]
    /// 单一金额的格式化结果（BuyButton 后缀用同一结果）；不是单值时 nil。
    public let singleAmount: String?
    /// 读屏文本：「预估返 1.35 元到 2.69 元」。
    public let accessibilityText: String

    /// 向量与跨端约定用的字符串种类。
    public var kindRaw: String {
        kind.rawValue
    }

    /// 是否显示金额（amount、range）。
    public var showsAmount: Bool {
        kind == .amount || kind == .range
    }

    /// 是否用返利强调色（返利浅底 + 深橙字 + 钟表，GUIDE §7.1）。
    /// 「暂无返利」（含按统一裁定降级的异常数据）与金额为 ¥0 的内容（模型不产出，防调用方手工构造）用中性色：
    /// GUIDE §7.1「无返利 / 返利 ¥0 不用橙」。金额未知、登录查看是返利提示文字，沿用返利配色。
    public var usesRebateAccent: Bool {
        switch kind {
        case .none:
            return false
        case .amount, .range:
            let zero = CouliFormat.money(fen: 0)
            return amountParts.contains { part in
                (part.hasPrefix(PriceTerms.rangeDash) ? String(part.dropFirst()) : part) != zero
            }
        case .unknown, .login:
            return true
        }
    }

    /// 金额隐藏开关打开时的标签（F-IOS-06，DS-01 三端统一裁定）：有金额的（amount、range）显示「预估返 ****」、
    /// 读屏「预估返，金额已隐藏」，不再整个隐藏；不带金额的种类原样返回。
    /// 配色按类别（返利强调色），不按真实金额——否则「****」的颜色会泄露返利是不是 0（与钱包金额隐藏同一做法）。
    public func hidingAmount(_ hidden: Bool) -> RebateTagContent {
        guard hidden, showsAmount else {
            return self
        }
        let tagLabel = label ?? PriceTerms.rebate
        return RebateTagContent(
            kind: kind,
            text: tagLabel + " " + PriceTerms.amountMask,
            label: tagLabel,
            amountParts: [PriceTerms.amountMask],
            singleAmount: nil,
            accessibilityText: tagLabel + "，" + PriceTerms.spokenAmountHidden
        )
    }

    public init(
        kind: RebateTagKind,
        text: String,
        label: String?,
        amountParts: [String],
        singleAmount: String?,
        accessibilityText: String
    ) {
        self.kind = kind
        self.text = text
        self.label = label
        self.amountParts = amountParts
        self.singleAmount = singleAmount
        self.accessibilityText = accessibilityText
    }
}

public enum RebateTagModel {
    /// 按 rebate_basis 决定返利标签（BR-PRICE-07、08，BR-TEXT-10）。
    ///
    /// 规则空白按 rule-gaps.md「编排者统一裁定」（三端一致）：
    /// - loginRequired 优先于 basis（不显示任何金额）；
    /// - normal 却 min ≠ max：按区间显示（不只显示上限）；
    /// - no_rebate 却金额 > 0：仍显示「暂无返利」（以 basis 为准，不显示金额）；
    /// - 异常数据一律「暂无返利」（kind none）：normal / price_compare_risk 缺一端、端点为负、
    ///   min > max（不排序）、上限为 0、未知 basis；「可返利，金额以订单为准」只给 amount_unknown。
    public static func make(basis: String, minFen: Int64?, maxFen: Int64?, loginRequired: Bool) -> RebateTagContent {
        let basisValue = RebateBasis(rawValue: basis) ?? .unknown
        if loginRequired || basisValue == .loginRequired {
            return textOnly(.login, PriceTerms.rebateLoginToView)
        }
        switch basisValue {
        case .amountUnknown:
            return textOnly(.unknown, PriceTerms.rebateAmountUnknown)
        case .normal, .priceCompareRisk:
            guard let minFen, let maxFen,
                  let (low, high) = CouliFormat.normalizedRange(minFen, maxFen)
            else {
                return textOnly(.none, PriceTerms.noRebate)
            }
            return amount(low: low, high: high)
        case .noRebate, .loginRequired, .unknown:
            return textOnly(.none, PriceTerms.noRebate)
        }
    }

    private static func amount(low: Int64, high: Int64) -> RebateTagContent {
        let label = PriceTerms.rebate
        if low == high {
            let value = CouliFormat.money(fen: low)
            return RebateTagContent(
                kind: .amount,
                text: label + " " + value,
                label: label,
                amountParts: [value],
                singleAmount: value,
                accessibilityText: label + " " + CouliFormat.moneySpoken(fen: low)
            )
        }
        let parts = [CouliFormat.money(fen: low), PriceTerms.rangeDash + CouliFormat.money(fen: high)]
        return RebateTagContent(
            kind: .range,
            text: label + " " + parts.joined(),
            label: label,
            amountParts: parts,
            singleAmount: nil,
            accessibilityText: label + " " + (CouliFormat.rebateRangeSpoken(minFen: low, maxFen: high) ?? "")
        )
    }

    private static func textOnly(_ kind: RebateTagKind, _ text: String) -> RebateTagContent {
        RebateTagContent(
            kind: kind,
            text: text,
            label: nil,
            amountParts: [],
            singleAmount: nil,
            accessibilityText: text
        )
    }
}

// MARK: - EstNetLine

public enum EstNetModel {
    /// 「预估返后 ¥x」（BR-PRICE-09）：只在可显示返利金额的 basis、返利下限 > 0、且下发了返后价时显示。
    /// 规则空白：下限 > 0 但 estNetPriceFen 为空、负返后价未定义。保守处理：为空不显示；负数照格式化（服务端下发为准）。
    public static func make(basis: String, minFen: Int64?, estNetPriceFen: Int64?) -> String? {
        guard let estNetPriceFen, isShown(basis: basis, minFen: minFen) else {
            return nil
        }
        return PriceTerms.estNet + " " + CouliFormat.money(fen: estNetPriceFen)
    }

    /// 读屏文本：「预估返后 27.21 元」。
    public static func accessibilityText(basis: String, minFen: Int64?, estNetPriceFen: Int64?) -> String? {
        guard let estNetPriceFen, isShown(basis: basis, minFen: minFen) else {
            return nil
        }
        return PriceTerms.estNet + " " + CouliFormat.moneySpoken(fen: estNetPriceFen)
    }

    private static func isShown(basis: String, minFen: Int64?) -> Bool {
        let basisValue = RebateBasis(rawValue: basis) ?? .unknown
        guard basisValue == .normal || basisValue == .priceCompareRisk, let minFen else {
            return false
        }
        return minFen > 0
    }
}

// MARK: - BuyButton

/// BuyButton 所在页面（决定是否拼返利后缀）。
public enum BuyButtonContext: String, Sendable, CaseIterable {
    case list
    case detail
    case agent
    case linkLanding = "link_landing"
    case share
}

public enum BuyButtonModel {
    /// 按 BR-TEXT-14 表 C `btn.buy.rebate_suffix`：单一金额、金额未隐藏、所在页面显示返利金额（list / detail / agent）
    /// 时在动词后拼「· 预估返 ¥x」，金额与 RebateTag 同一格式化结果；区间、无返利、金额未知、登录查看、
    /// LinkLanding 与分享页不拼。loading、禁用、「稍后再试」由 BuyButton 组件处理（不拼）。
    /// 未知 context 不拼（保守）。
    public static func text(base: String, rebate: RebateTagContent, amountHidden: Bool, context: String) -> String {
        guard let amount = suffixAmount(rebate: rebate, amountHidden: amountHidden, context: context) else {
            return base
        }
        return base + PriceTerms.buyRebateSuffixTemplate.replacingOccurrences(of: "{amount}", with: amount)
    }

    /// 读屏名称（adaptation-a11y-spec §9）：可见文字开头；区间按钮只显示动词时补上区间；金额隐藏时不读金额。
    /// 例：「领券购买，预估返 1.23 元到 2.34 元」「去购买，预估返 2.34 元」。
    public static func accessibilityLabel(
        base: String,
        rebate: RebateTagContent,
        amountHidden: Bool,
        context: String
    ) -> String {
        let showsAmountOnPage = !amountHidden && shownContexts.contains(BuyButtonContext(rawValue: context) ?? .share)
        guard showsAmountOnPage, rebate.showsAmount else {
            return base
        }
        return base + PriceTerms.spokenPause + rebate.accessibilityText
    }

    private static let shownContexts: Set<BuyButtonContext> = [.list, .detail, .agent]

    private static func suffixAmount(rebate: RebateTagContent, amountHidden: Bool, context: String) -> String? {
        guard !amountHidden,
              let contextValue = BuyButtonContext(rawValue: context),
              shownContexts.contains(contextValue),
              rebate.kind == .amount
        else {
            return nil
        }
        return rebate.singleAmount
    }
}
