import SwiftUI

/// 商品卡上的一个优惠标签。
public struct ProductCardTag: Sendable, Hashable {
    public let text: String
    public let style: Style

    public enum Style: Sendable, Hashable {
        /// 有券、预售、规格以下单页为准等：白底描边。
        case outline
        /// 规格待确认、标题显示为…：中性底 + 信息图标。
        case info
    }

    public init(_ text: String, style: Style = .outline) {
        self.text = text
        self.style = style
    }
}

/// 商品卡的内容。文字类字段（平台名、标题、按钮动词、说明句）由调用方从字典与接口给；
/// 价格与返利用 `PriceTagModel` / `RebateTagModel` / `EstNetModel` 的结果。
public struct ProductCardData: Sendable {
    public var platformName: String
    public var title: String
    /// 优惠标签（预售标签由 `price.presaleLabel` 自动放在最前，不用重复给）。
    public var tags: [ProductCardTag]
    public var price: PriceTagContent
    public var rebate: RebateTagContent
    public var estNet: String?
    public var estNetAccessibility: String?
    /// 副行里的额外说明（如「规格以下单页为准」），排在券前 / 无券之后、预售说明之前（GUIDE §7.2.1）。
    public var notes: [String]
    /// 比价区间时的「以结算为准」（底行左侧）；单一金额时为 nil。
    public var settlementNote: String?
    /// 购买按钮动词（cta.text_key 的文案）。
    public var buyBase: String
    public var amountHidden: Bool
    /// i 图标展开的口径说明全文（disclaimer_keys 对应的文案）。
    public var disclaimer: String
    /// i 图标按钮的读屏名称。
    public var disclaimerButtonLabel: String
    /// 价格不可用的提示（BR-PRICE-01「暂时查不到该商品价格」；APP-06a 共性 1）。给了就隐藏全部金额（主价、副行、返利、
    /// 预估返后、口径 i），只显示这句；价格保持未知，不补 0。文案由调用方从字典给。
    public var priceUnavailableText: String?
    /// 购买按钮状态（价格不可用时为「稍后再试」禁用，已下架时禁用；其余 normal）。
    public var buyState: BuyButtonState
    /// 平台返利未开放（features.platform_status=not_launched，设计稿 ProductCardDegrade ①；APP-06a R3-02）：保留商品价格，
    /// 不显示任何返利金额——返利标签、预估返后、「以结算为准」及它们的读屏文字都不出现；按钮由调用方置灰。
    public var rebateNotLaunched: Bool

    public init(
        platformName: String,
        title: String,
        tags: [ProductCardTag] = [],
        price: PriceTagContent,
        rebate: RebateTagContent,
        estNet: String? = nil,
        estNetAccessibility: String? = nil,
        notes: [String] = [],
        settlementNote: String? = nil,
        buyBase: String,
        amountHidden: Bool = false,
        disclaimer: String,
        disclaimerButtonLabel: String,
        priceUnavailableText: String? = nil,
        buyState: BuyButtonState = .normal,
        rebateNotLaunched: Bool = false
    ) {
        self.platformName = platformName
        self.title = title
        self.tags = tags
        self.price = price
        self.rebate = rebate
        self.estNet = estNet
        self.estNetAccessibility = estNetAccessibility
        self.notes = notes
        self.settlementNote = settlementNote
        self.buyBase = buyBase
        self.amountHidden = amountHidden
        self.disclaimer = disclaimer
        self.disclaimerButtonLabel = disclaimerButtonLabel
        self.priceUnavailableText = priceUnavailableText
        self.buyState = buyState
        self.rebateNotLaunched = rebateNotLaunched
    }

    var allTags: [ProductCardTag] {
        (price.presaleLabel.map { [ProductCardTag($0)] } ?? []) + tags
    }

    /// 金额未知（amount_unknown）：不显示任何价格与返利金额，只显示「可返利，金额以订单为准」（BR-PRICE-08）。
    var hidesPrice: Bool {
        rebate.kind == .unknown || priceUnavailable
    }

    /// 价格不可用（BR-PRICE-01）：连返利标签也不显示（不显示任何金额）。
    var priceUnavailable: Bool {
        priceUnavailableText != nil
    }

    /// 返利标签是否显示：价格不可用（不显示任何金额）或平台返利未开放时不显示。
    var showsRebate: Bool {
        !priceUnavailable && !rebateNotLaunched
    }

    /// 价格口径 i 按钮（BR-PRICE-03「单卡 i 图标」）是否显示：跟着价格走，与返利标签是否显示无关
    /// （暂无返利、金额隐藏时照样保留）；卡上没有价格（金额未知）或没有说明全文时不显示。
    static func showsDisclaimerButton(_ data: ProductCardData) -> Bool {
        !data.hidesPrice && !data.disclaimer.isEmpty
    }

    var subLines: [(text: String, spoken: String)] {
        if let priceUnavailableText {
            return [(priceUnavailableText, priceUnavailableText)] + notes.map { ($0, $0) }
        }
        if hidesPrice {
            return notes.map { ($0, $0) }
        }
        // 主价没有口径词 = 券前价与券额待补齐（APP-06b）：不写副行（不能把券额未知写成「无券」）。
        var lines: [(String, String)] = price.mainLabel.isEmpty ? [] : [
            (price.subLine ?? PriceTerms.noCoupon, price.subLineAccessibilityText ?? PriceTerms.noCoupon),
        ]
        lines += notes.map { ($0, $0) }
        if price.presaleLabel != nil {
            lines.append((PriceTerms.presalePriceNote, PriceTerms.presalePriceNote))
        }
        if showsRebate, let estNet = EstNetLine.visibleText(estNet, rebate: rebate, amountHidden: amountHidden) {
            lines.append((estNet, estNetAccessibility ?? estNet))
        }
        return lines
    }
}
