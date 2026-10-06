import Generated

/// 价格、返利与时间的术语表：设计系统里唯一写这些中文字面量的地方。
///
/// 逐字照 08 原文（规划/08_业务规则/03_PRICE、12_TEXT）；数值规则不在这里复述。
/// TODO(N-11): 契约（contracts/texts.default.json）补键后改读 `DefaultTexts`，删掉这里的字面量。
/// 已有键的（`rebate_amount_unknown`、`rebate_login_to_view`、`spec_min_price_note`）直接读 `DefaultTexts`。
public enum PriceTerms {
    // MARK: 价格口径词（BR-PRICE-04、BR-PRICE-05）

    /// 有券主价口径词。
    public static let afterCoupon = "券后"
    /// 有券副行的券前价口径词（不用「原价」，不划线）。
    public static let beforeCoupon = "券前"
    /// 无券主价口径词。
    public static let salePrice = "售价"
    /// 副行里的券额词。
    public static let coupon = "券"
    /// 拼多多有券主价口径词。
    public static let pddAfterCoupon = "拼单券后"
    /// 拼多多有券副行的券前价口径词。
    public static let pddBeforeCoupon = "拼单券前"
    /// 拼多多无券主价口径词。
    public static let pddPrice = "拼单价"
    /// 副行分隔符（BR-PRICE-04 例：「券前 ¥39.9 · 券 ¥10」）。
    public static let separator = " · "
    /// 无券状态（GUIDE §7.2.1 副行「无券」）。
    public static let noCoupon = "无券"

    // MARK: 预售（BR-PRICE-22；BR-TEXT-12 细则 tag.presale、presale.price_note）

    /// 预售标签 `tag.presale`。
    public static let presale = "预售"
    /// 预售说明 `presale.price_note`。
    public static let presalePriceNote = "定金与尾款以下单页为准"

    // MARK: 返利（BR-PRICE-05、07、08、09；BR-TEXT-10）

    /// 返利短标签 `tag.rebate`（短标签只允许「预估返」）。
    public static let rebate = "预估返"
    /// 预估返后价（BR-PRICE-09）。
    public static let estNet = "预估返后"
    /// 无返利（BR-PRICE-08、BR-TEXT-10「区间 0 / 0」）。
    public static let noRebate = "暂无返利"
    /// 比价区间附带的结算说明（BR-PRICE-07「预估返 ¥a–¥b · 以结算为准」）。
    public static let settlementNote = "以结算为准"
    /// 区间连接符（U+2013，两侧无空格，BR-TEXT-10）。
    public static let rangeDash = "\u{2013}"
    /// 金额符号（BR-TEXT-10）。
    public static let yuanSign = "¥"
    /// 购买按钮后缀 `btn.buy.rebate_suffix`「· 预估返 {amount}」（BR-TEXT-14 表 C）。
    public static let buyRebateSuffixTemplate = " · 预估返 {amount}"

    /// 金额未知 `rebate_amount_unknown`（契约已有键）。
    public static var rebateAmountUnknown: String {
        DefaultTexts.text("rebate_amount_unknown") ?? ""
    }

    /// 登录查看返利 `rebate_login_to_view`（契约已有键）。
    public static var rebateLoginToView: String {
        DefaultTexts.text("rebate_login_to_view") ?? ""
    }

    /// 规格以下单页为准 `spec_min_price_note`（契约已有键）。
    public static var specNote: String {
        DefaultTexts.text("spec_min_price_note") ?? ""
    }

    /// 取价时间前缀（商品详情「取价 10:00」，BR-PRICE-11；设计稿 Product）。
    public static let priceFetchedAt = "取价"

    // MARK: 金额隐藏（BR-TEXT-10 细则「金额隐藏」：固定「****」，不显示「¥」、位数与正负号）

    /// 隐藏写法。
    public static let amountMask = "****"
    /// 被隐藏金额的读屏文本（adaptation-a11y-spec §9 待商量项，按「金额已隐藏」）。
    public static let spokenAmountHidden = "金额已隐藏"

    // MARK: 时间（BR-TEXT-11）

    public static let today = "今天"
    public static let yesterday = "昨天"

    // MARK: 读屏（adaptation-a11y-spec §9：金额读成完整句，如「券后 19.9 元」「1.23 元到 2.34 元」）

    /// 读屏金额单位。
    public static let spokenYuan = "元"
    /// 读屏区间连接词。
    public static let spokenRangeTo = "到"
    /// 读屏负号。
    public static let spokenMinus = "负"
    /// 读屏分句符。
    public static let spokenPause = "，"
}
