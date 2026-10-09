import Foundation
import Generated

/// 卡片映射的结果：DesignSystem 卡片数据 + 详情大卡另外要的取价时间、店铺、降级提示。
public struct ProductCardMapping: Sendable {
    public var data: ProductCardData
    /// 口径说明逐行（disclaimer_keys 顺序；SearchDisclaimerNote 弹层与详情页说明框用）。
    public var disclaimerLines: [String]
    /// 取价时间（BR-TEXT-11 列表过去时间：「今天 10:00」）；价格不可用或没有 quoted_at 为 nil。
    public var quotedAt: String?
    /// 缓存 / 商品池降级报价（BR-PRICE-11：stale=true 或 age_sec > 300）。
    public var stale: Bool
    public var shopName: String?
}

/// 卡片映射用到的文案键（三端同名）。平台名、口径按钮名、价格不可用提示不在契约字典里，由调用方的草稿表给（TODO(N-27)）。
public enum ProductCardKeys {
    public static func platform(_ platform: String) -> String {
        "platform." + platform
    }

    public static let disclaimerButton = "card.disclaimer_button"
    /// 价格不可用（BR-PRICE-01「暂时查不到该商品价格」）。
    public static let priceUnavailable = "card.price_unavailable"
    /// 价格不可用、平台维护中时的按钮（「稍后再试」，BR-TEXT-14 表 B 50301.maintenance「购买按钮置灰『稍后再试』」）。
    public static let retryLater = "card.retry_later"
    /// 平台返利未开放时的按钮（契约字典 error.50301.not_launched =「{platform_name}返利即将开放」，即 platform_coming_soon）。
    public static let platformComingSoon = "error.50301.not_launched"
}

/// 接口的 ProductCard（openapi searchProducts / getProduct 的 JSON 对象）→ ProductCardData。只做格式化，不做计算
/// （BR-PRICE-17）：价格、返利、预估返后都用服务端字段经 PriceTagModel / RebateTagModel / EstNetModel。
/// - 价格三字段原样保留「未知」，不补 0（BR-PRICE-01；APP-06a 共性 1）：价格不可用时隐藏全部金额、显示提示、按钮「稍后再试」禁用。
/// - 购买按钮动词：服务端 cta.text_key 经 texts（BR-TEXT-12、TRADE-21）。
/// - 优惠标签：benefit_tags 原样（「预售」由 is_presale 放置，不重复）。
/// - 口径说明：disclaimer_keys 按数组顺序经 texts 取文字；含 rebate_compare 时底行带「以结算为准」。
public enum ProductCardMapper {
    public static func map(
        _ card: [String: Any],
        texts: (String) -> String,
        buyEnabled: Bool = true,
        nowMillis: Int64 = Int64(Date().timeIntervalSince1970 * 1000)
    ) -> ProductCardMapping {
        let platform = card["platform"] as? String ?? ""
        let basis = rebateBasis(card)
        let unavailable = priceUnavailable(card)
        let price = priceTag(card, platform: platform, unavailable: unavailable)
        let minFen = int64(card["rebate_min_fen"])
        let rebate = RebateTagModel.make(basis: basis, minFen: minFen, maxFen: int64(card["rebate_max_fen"]),
                                         loginRequired: false)
        let estFen = int64(card["est_net_price_fen"])
        let keys = (card["disclaimer_keys"] as? [Any])?.compactMap { $0 as? String } ?? []
        let lines = keys.map(texts).filter { !$0.isEmpty }
        let ctaKey = (card["cta"] as? [String: Any])?["text_key"] as? String ?? ""
        let buyBase = ctaKey.isEmpty ? "" : texts(ctaKey)
        let buyState = buttonState(unavailable: unavailable, buyEnabled: buyEnabled, buyBase: buyBase, texts: texts)
        let tags = (card["benefit_tags"] as? [Any])?.compactMap { $0 as? String }
            .filter { !$0.isEmpty && $0 != PriceTerms.presale }.map { ProductCardTag($0) } ?? []
        let data = ProductCardData(
            platformName: texts(ProductCardKeys.platform(platform)),
            title: card["title"] as? String ?? "",
            tags: tags,
            price: price,
            rebate: rebate,
            estNet: unavailable ? nil : EstNetModel.make(basis: basis, minFen: minFen, estNetPriceFen: estFen),
            estNetAccessibility: unavailable ? nil
                : EstNetModel.accessibilityText(basis: basis, minFen: minFen, estNetPriceFen: estFen),
            notes: [],
            settlementNote: !unavailable && (keys.contains("rebate_compare") || rebate.kind == .range)
                ? PriceTerms.settlementNote : nil,
            buyBase: buyBase,
            disclaimer: lines.joined(separator: "\n"),
            disclaimerButtonLabel: texts(ProductCardKeys.disclaimerButton),
            priceUnavailableText: unavailable ? texts(ProductCardKeys.priceUnavailable) : nil,
            buyState: buyState
        )
        var quoted: String?
        if !unavailable, let text = card["quoted_at"] as? String, let millis = epochMillis(text) {
            quoted = CouliFormat.timeListPast(epochMillis: millis, nowEpochMillis: nowMillis)
        }
        let shop = card["shop_name"] as? String
        return ProductCardMapping(
            data: data, disclaimerLines: lines, quotedAt: quoted, stale: stale(card),
            shopName: (shop?.isEmpty ?? true) ? nil : shop
        )
    }

    private static func priceTag(_ card: [String: Any], platform: String, unavailable: Bool) -> PriceTagContent {
        let presale = bool(card["is_presale"]) == true
        if !unavailable, let priceFen = int64(card["price_fen"]), let couponFen = int64(card["coupon_fen"]),
           let finalFen = int64(card["final_price_fen"]) {
            return PriceTagModel.make(
                platform: platform, priceFen: priceFen, couponFen: couponFen, finalPriceFen: finalFen,
                isPresale: presale
            )
        }
        // 新券后价已知、口径与券前价待补齐（APP-06b 共性第 34、37 条）：只显示已知的新价，不带口径词、不写「无券」。
        if !unavailable, pricePending(card), let finalFen = int64(card["final_price_fen"]) {
            return PriceTagContent(
                mainLabel: "", mainAmount: CouliFormat.money(fen: finalFen), subLine: nil, noCoupon: false,
                presaleLabel: presale ? PriceTerms.presale : nil,
                mainAccessibilityText: CouliFormat.moneySpoken(fen: finalFen), subLineAccessibilityText: nil
            )
        }
        // 没有可展示的价格：PriceTag 不出现（hidesPrice），这里不带任何金额。
        return PriceTagContent(
            mainLabel: "", mainAmount: "", subLine: nil, noCoupon: false,
            presaleLabel: presale ? PriceTerms.presale : nil, mainAccessibilityText: "", subLineAccessibilityText: nil
        )
    }

    /// 按平台购买状态（`features.platform_status.<platform>` 原始取值，契约 PlatformPurchaseStatus；APP-06a R2-01）调整
    /// 购买按钮：maintenance → 置灰「稍后再试」；not_launched → 置灰「{platform_name}返利即将开放」（BR-TEXT-14 表 B，
    /// 03 §7.4：点击前的卡片状态取配置）。on、缺失或不认识的取值不改（点击时以 open 的 50301 为准，TODO(N-27)）。
    public static func purchaseButtonState(
        _ state: BuyButtonState,
        statusRaw: String?,
        platformName: String,
        texts: (String) -> String
    ) -> BuyButtonState {
        switch statusRaw {
        case "maintenance":
            .retryLater(texts(ProductCardKeys.retryLater))
        case "not_launched":
            .retryLater(
                texts(ProductCardKeys.platformComingSoon).replacingOccurrences(
                    of: "{platform_name}",
                    with: platformName
                )
            )
        default:
            state
        }
    }

    /// 详情口径说明框是否带入账说明句（共性 15、34，BR-TEXT-04、F-PROD-05）：按入账规则——这张卡可返利、价格可用时显示。
    /// 隐藏条件原文是入账开关 credit.enabled.<platform>=off；TODO(N-27)：该开关在 getProduct / 配置里还没有字段，暂按卡片
    /// 是否可返利判断（rule-gaps 已登记）。平台购买开关（platform_status，含 not_launched）只管金额与按钮，不能替代入账开关，
    /// 这里不看 `rebateNotLaunched`（R3F-04）。
    public static func showsSettleNote(_ data: ProductCardData, priceUnavailable: Bool) -> Bool {
        data.rebate.kind != .none && !priceUnavailable
    }

    /// 平台购买状态接入卡片展示（列表卡与详情大卡同一映射，R2-01 + R3-02）：按钮按 `purchaseButtonState`；明确的
    /// not_launched 另外隐藏返利金额与预估返后（设计稿 ProductCardDegrade ①：保留价格，替代返利的位置不显示任何返利金额）。
    /// maintenance 只改按钮（返利照常显示）；on、缺失或不认识的取值不改。
    public static func applyPurchaseStatus(
        _ data: ProductCardData, statusRaw: String?, texts: (String) -> String
    ) -> ProductCardData {
        var data = data
        data.buyState = purchaseButtonState(
            data.buyState, statusRaw: statusRaw, platformName: data.platformName, texts: texts
        )
        if statusRaw == "not_launched" {
            data.rebateNotLaunched = true
            data.estNet = nil
            data.estNetAccessibility = nil
            data.settlementNote = nil
        }
        return data
    }

    private static func buttonState(
        unavailable: Bool, buyEnabled: Bool, buyBase: String, texts: (String) -> String
    ) -> BuyButtonState {
        if unavailable {
            return .retryLater(texts(ProductCardKeys.retryLater))
        }
        return buyEnabled && !buyBase.isEmpty ? .normal : .disabled
    }

    /// 价格不可用（BR-PRICE-01、AC-S1-09）：availability=price_unavailable，或价格三字段任一缺失（rebate_basis=
    /// amount_unknown 的拼多多直链卡除外：BR-PRICE-08 规定它本来就不显示价格）。与 ProductSearch.ProductDetailState 同一判定。
    public static func priceUnavailable(_ card: [String: Any]) -> Bool {
        if card["availability"] as? String == Availability.priceUnavailable.rawValue {
            return true
        }
        if card["rebate_basis"] as? String == RebateBasis.amountUnknown.rawValue {
            return false
        }
        if pricePending(card), int64(card["final_price_fen"]) != nil {
            return false
        }
        return ["price_fen", "coupon_fen", "final_price_fen"].contains { int64(card[$0]) == nil }
    }

    /// 客户端临时展示状态（APP-06b 共性第 16 条，Core Trade 的 CardPatch.provisionalKey）：open 响应把返利由 0 变为正数、却不带口径时
    /// 置上，按服务端区间显示（不落入「暂无返利」），重取的权威卡补上口径后去掉。
    public static let provisionalRebateKey = "client_provisional_rebate"

    /// 客户端「价格待补齐」状态（APP-06b 共性第 34 条，Core Trade 的 CardPatch.pricePendingKey）。
    public static let pricePendingKey = "client_price_pending"

    public static func pricePending(_ card: [String: Any]) -> Bool {
        bool(card[pricePendingKey]) == true
    }

    /// 返利口径：临时展示状态且口径未知时按区间（normal）显示，其余原样。
    static func rebateBasis(_ card: [String: Any]) -> String {
        if let basis = card["rebate_basis"] as? String {
            return basis
        }
        return bool(card[provisionalRebateKey]) == true ? RebateBasis.normal.rawValue : ""
    }

    /// BR-PRICE-11：stale=true，或 age_sec > 300（正好 300 不提示）。
    public static func stale(_ card: [String: Any]) -> Bool {
        if bool(card["stale"]) == true {
            return true
        }
        return (int64(card["age_sec"]) ?? 0) > 300
    }

    static func int64(_ value: Any?) -> Int64? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let integral = number.int64Value
        return NSNumber(value: integral) == number ? integral : nil
    }

    static func bool(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }

    static func epochMillis(_ iso: String) -> Int64? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        if let date = formatter.date(from: iso) {
            return Int64(date.timeIntervalSince1970 * 1000)
        }
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: iso).map { Int64($0.timeIntervalSince1970 * 1000) }
    }
}
