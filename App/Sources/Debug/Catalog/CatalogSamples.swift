#if DEBUG
import DesignSystem
import Foundation
import Generated

/// 组件目录页的样例数据（只在 Debug / Staging）。商品、金额取自设计画板（Search、ProductCardStress、Product、
/// Wallet、Me、SearchEmpty）与 couli-runs/design-hifi/sample-data.md；价格与返利文字一律经 DesignSystem 的模型生成。
/// 按钮动词、口径说明句等字典文案在契约补键前用这里的样例句（TODO(N-11)：改读 DefaultTexts）。
enum CatalogText {
    static let buyCoupon = "领券购买" // btn.buy.coupon
    static let buy = "去购买" // btn.buy
    static let buyNoRebate = "去购买（无返利）" // btn.buy.no_rebate
    static let retryLater = DefaultTexts.text("buy.timeout") ?? ""
    static let priceBasis = "券后价按单件计算，不含运费及会员价等优惠，以下单页为准" // price_basis
    static let priceBasisGeneral = "价格按单件计算，不含运费及会员价等优惠，以下单页为准" // price_basis.general
    static let settleMonthly = "确认收货后随联盟月度结算入账"
    static let rebateSettleNote = "预估返利以平台结算为准，未结算或订单失效时不返"
    static let disclaimerButton = "口径说明"
    static let back = "返回"
    static let close = "关闭"
    static let couponTag = "有券"
    static let taobao = "淘宝"
    static let jd = "京东"
    static let pdd = "拼多多"
    static let tabs = [
        TabBarItem(id: "home", title: "首页", icon: .home),
        TabBarItem(id: "agent", title: "AI 助手", icon: .chat),
        TabBarItem(id: "orders", title: "订单", icon: .orders),
        TabBarItem(id: "me", title: "我的", icon: .user),
    ]
    static let walletHelp = [
        "estimated": "还没结算的返利和推广收益的估计值，按联盟最新预估计算，以联盟结算金额为准，结算后计入可提现余额",
        "pending_paused": "部分订单暂时不能结算，处理完成后继续按联盟结算入账，如有疑问请联系客服",
        "frozen": "已申请提现、正在审核或打款的金额，这部分暂时不能再次提现",
    ]
}

enum CatalogSample {
    /// 用模型拼一张卡的数据。
    static func card(
        platform: Platform,
        title: String,
        priceFen: Int64,
        couponFen: Int64 = 0,
        presale: Bool = false,
        basis: RebateBasis,
        minFen: Int64? = nil,
        maxFen: Int64? = nil,
        estNetFen: Int64? = nil,
        buyBase: String? = nil,
        tags: [ProductCardTag] = [],
        notes: [String] = [],
        amountHidden: Bool = false
    ) -> ProductCardData {
        let price = PriceTagModel.make(
            platform: platform.rawValue,
            priceFen: priceFen,
            couponFen: couponFen,
            finalPriceFen: priceFen - couponFen,
            isPresale: presale
        )
        let rebate = RebateTagModel.make(
            basis: basis.rawValue,
            minFen: minFen,
            maxFen: maxFen,
            loginRequired: basis == .loginRequired
        )
        let verb = buyBase ?? (rebate.kind == .none ? CatalogText.buyNoRebate
            : couponFen > 0 ? CatalogText.buyCoupon : CatalogText.buy)
        return ProductCardData(
            platformName: name(platform),
            title: title,
            tags: tags,
            price: price,
            rebate: rebate,
            estNet: EstNetModel.make(basis: basis.rawValue, minFen: minFen, estNetPriceFen: estNetFen),
            estNetAccessibility: EstNetModel.accessibilityText(
                basis: basis.rawValue,
                minFen: minFen,
                estNetPriceFen: estNetFen
            ),
            notes: notes,
            settlementNote: rebate.kind == .range ? PriceTerms.settlementNote : nil,
            buyBase: verb,
            amountHidden: amountHidden,
            disclaimer: couponFen > 0 ? CatalogText.priceBasis : CatalogText.priceBasisGeneral,
            disclaimerButtonLabel: CatalogText.disclaimerButton
        )
    }

    static func name(_ platform: Platform) -> String {
        switch platform {
        case .jd: CatalogText.jd
        case .pdd: CatalogText.pdd
        default: CatalogText.taobao
        }
    }

    // MARK: Search 画板

    static let searchMilk = card(
        platform: .taobao,
        title: "全脂纯牛奶 250ml × 24 盒 整箱装 早餐奶 学生奶 送礼礼盒款 生产日期新鲜",
        priceFen: 2345, couponFen: 1000,
        basis: .priceCompareRisk, minFen: 56, maxFen: 112, estNetFen: 1289
    )
    static let searchMilkSpec = card(
        platform: .taobao,
        title: "纯牛奶 200ml × 12 盒 多规格可选",
        priceFen: 1234,
        basis: .priceCompareRisk, minFen: 0, maxFen: 99, estNetFen: 1234,
        notes: [PriceTerms.specNote]
    )
    static let searchMilkPresale = card(
        platform: .taobao,
        title: "有机纯牛奶 250ml × 24 盒 预售 下月发货",
        priceFen: 9999, presale: true,
        basis: .priceCompareRisk, minFen: 250, maxFen: 500, estNetFen: 9749
    )

    // MARK: ProductCardStress 画板

    static let stressSingle = card(
        platform: .jd,
        title: "快充数据线 编织线身 1.5m 双头通用 60W 快充 耐弯折",
        priceFen: 2990,
        basis: .normal, minFen: 45, maxFen: 45, estNetFen: 2945
    )
    static let stressRange = card(
        platform: .taobao,
        title: "全脂纯牛奶 250ml × 24 盒 整箱装 早餐奶",
        priceFen: 2345, couponFen: 1000,
        basis: .priceCompareRisk, minFen: 56, maxFen: 112, estNetFen: 1289,
        tags: [ProductCardTag(CatalogText.couponTag)]
    )
    static let stressNoRebate = card(
        platform: .jd,
        title: "抽纸 3 层 120 抽 × 24 包 家用整箱装",
        priceFen: 2990,
        basis: .noRebate, minFen: 0, maxFen: 0
    )
    static let stressNarrow = card(
        platform: .taobao,
        title: "进口全自动意式咖啡机 家用商用两用 一体式研磨 双锅炉 豪华礼盒装",
        priceFen: 1_334_567, couponFen: 100_000,
        basis: .normal, minFen: 12345, maxFen: 12345, estNetFen: 1_222_222,
        tags: [ProductCardTag(CatalogText.couponTag)]
    )
    static let stressLongTitle = card(
        platform: .taobao,
        title: "进口全自动意式咖啡机 家用商用两用 一体式研磨 双锅炉 恒温萃取 蒸汽打奶泡 触屏操作 自动清洗 1.8L 大容量水箱 豪华礼盒装（含磨豆机与奶缸套装）",
        priceFen: 1_334_567, couponFen: 100_000, presale: true,
        basis: .priceCompareRisk, minFen: 12345, maxFen: 24690, estNetFen: 1_222_222,
        tags: [ProductCardTag(PriceTerms.specNote)]
    )
    static let stressPresaleNoCoupon = card(
        platform: .taobao,
        title: "高端定制实木书柜 落地整墙 多层置物 胡桃木色 2.4m × 2.6m 全屋定制 免费上门测量 预售 下单后 45 天发货",
        priceFen: 2_345_678, presale: true,
        basis: .priceCompareRisk, minFen: 23456, maxFen: 46913, estNetFen: 2_322_222
    )
    static let stressJdSpec = card(
        platform: .jd,
        title: "笔记本电脑 16 英寸 2.5K 高刷屏 32GB 内存 1TB 固态 独立显卡 多种配置可选（颜色、内存、硬盘容量以下单页所选为准）",
        priceFen: 1_234_567,
        basis: .normal, minFen: 12345, maxFen: 12345,
        notes: [PriceTerms.specNote]
    )
    static let stressPdd = card(
        platform: .pdd,
        title: "拼团 家用大容量冰箱 十字对开门 风冷无霜 一级能效 变频 超薄嵌入式 约 500 升",
        priceFen: 1_099_999, couponFen: 100_000,
        basis: .normal, minFen: 9999, maxFen: 9999, estNetFen: 990_000
    )
    static let stressMax = card(
        platform: .taobao,
        title: "进口全自动意式咖啡机 家用商用两用 一体式研磨 双锅炉 恒温萃取 蒸汽打奶泡 触屏操作 自动清洗 1.8L 大容量水箱 豪华礼盒装（含磨豆机与奶缸套装）",
        priceFen: 10_099_999, couponFen: 100_000, presale: true,
        basis: .priceCompareRisk, minFen: 8_888_888, maxFen: 9_999_999, estNetFen: 1_111_111,
        tags: [ProductCardTag(PriceTerms.specNote)]
    )
    static let stressExtreme = card(
        platform: .taobao,
        title: "进口全自动意式咖啡机 家用商用两用 一体式研磨 双锅炉 恒温萃取 多种配置可选（颜色、容量以下单页所选为准） 预售 下单后 45 天发货",
        priceFen: 9_999_999, presale: true,
        basis: .priceCompareRisk, minFen: 8_888_888, maxFen: 9_999_999, estNetFen: 1_111_111,
        tags: [
            ProductCardTag(DefaultTexts.text("agent.match.spec_unconfirmed") ?? "", style: .info),
            ProductCardTag(PriceTerms.specNote),
        ]
    )
    static let gridCoffee = card(
        platform: .taobao,
        title: "进口全自动意式咖啡机 家用商用两用 一体式研磨 双锅炉 豪华礼盒装",
        priceFen: 1_334_567, couponFen: 100_000,
        basis: .priceCompareRisk, minFen: 12345, maxFen: 24690,
        tags: [ProductCardTag(CatalogText.couponTag)]
    )
    static let gridShelf = card(
        platform: .jd,
        title: "高端定制实木书柜 落地整墙 多层置物 胡桃木色 全屋定制 预售",
        priceFen: 2_345_678, presale: true,
        basis: .normal, minFen: 23456, maxFen: 23456
    )
    static let gridMaxRange = card(
        platform: .taobao,
        title: "进口全自动意式咖啡机 家用商用两用 一体式研磨 双锅炉 豪华礼盒装",
        priceFen: 10_099_999, couponFen: 100_000,
        basis: .priceCompareRisk, minFen: 8_888_888, maxFen: 9_999_999,
        tags: [ProductCardTag(CatalogText.couponTag)]
    )
    static let gridMaxSingle = card(
        platform: .jd,
        title: "高端定制实木书柜 落地整墙 多层置物 胡桃木色 全屋定制 预售",
        priceFen: 9_999_999, presale: true,
        basis: .normal, minFen: 9_999_999, maxFen: 9_999_999
    )

    // MARK: Product 画板

    static let detailMilk = card(
        platform: .taobao,
        title: "全脂纯牛奶 250ml × 24 盒 整箱装 早餐奶 学生奶",
        priceFen: 5678, couponFen: 1000,
        basis: .priceCompareRisk, minFen: 123, maxFen: 234, estNetFen: 4555,
        tags: [ProductCardTag(CatalogText.couponTag)]
    )

    // MARK: SearchEmpty 画板

    static let emptyTissue = card(
        platform: .taobao,
        title: "抽纸 3 层 120 抽 × 24 包 家用整箱装",
        priceFen: 1734, couponFen: 500,
        basis: .normal, minFen: 56, maxFen: 56, estNetFen: 1178
    )
    static let emptyRice = card(
        platform: .taobao,
        title: "东北长粒香大米 10kg 新米预售款",
        priceFen: 8800, presale: true,
        basis: .normal, minFen: 321, maxFen: 321, estNetFen: 8479
    )

    // MARK: 状态样例

    static let amountUnknown = card(
        platform: .pdd, title: "拼多多直链商品", priceFen: 0, basis: .amountUnknown
    )
    static let loginRequired = card(
        platform: .taobao, title: "游客卡商品", priceFen: 1990, couponFen: 300, basis: .loginRequired
    )
}
#endif
