@testable import DesignSystem
import Generated
import SnapshotTesting
import SwiftUI
import XCTest

/// 主要组件的快照基准图（iOS 26 模拟器一套，存在 __Snapshots__/ComponentSnapshotTests/，入库）。
/// 改了组件外观后：删掉对应基准图再跑一次测试即重新录制（第一次运行会失败并写出新图），核对后入库。
/// 宽度取设计稿画板宽 390；字号固定为默认档（large），另有一组辅助字号第 2 档（≈ 194%，最接近 200% 的档位）。
@MainActor
final class ComponentSnapshotTests: XCTestCase {
    private func snap(
        _ view: some View,
        size: DynamicTypeSize = .large,
        width: CGFloat = 390,
        named name: String? = nil,
        file: StaticString = #filePath,
        testName: String = #function,
        line: UInt = #line
    ) {
        let category: UIContentSizeCategory = size == .large ? .large : .accessibilityExtraExtraLarge
        let host = view
            .padding(CouliSpacing.s4)
            .frame(width: width)
            .background(CouliColor.backgroundCanvas)
            .environment(\.dynamicTypeSize, size)
            .environment(\.colorScheme, .light)
        assertSnapshot(
            of: host,
            as: .image(
                precision: 0.995,
                perceptualPrecision: 0.98,
                layout: .sizeThatFits,
                traits: UITraitCollection(preferredContentSizeCategory: category)
            ),
            named: name,
            file: file,
            testName: testName,
            line: line
        )
    }

    // MARK: 快照

    func testProductCardList() {
        snap(VStack(spacing: CouliSpacing.s3) {
            ProductCard(Samples.rangeCard) {}
            ProductCard(Samples.singleCard) {}
            ProductCard(Samples.noRebateCard) {}
            ProductCard(Samples.pddCard) {}
        })
    }

    func testProductCardStress() {
        snap(VStack(spacing: CouliSpacing.s3) {
            ProductCard(Samples.extremeCard) {}
            ProductCard(Samples.extremeCard, layout: .agent) {}
        })
    }

    func testProductCardStressLargeText() {
        snap(VStack(spacing: CouliSpacing.s3) {
            ProductCard(Samples.extremeCard) {}
            ProductCard(Samples.singleCard) {}
        }, size: .accessibility2)
    }

    /// 320 宽 + 辅助字号第 2 档（≈ 194%）+ 最长价格：主价、返利与按钮都不截断（放不下就换行）。
    func testLongestPriceNarrowLargeText() {
        snap(VStack(spacing: CouliSpacing.s3) {
            ProductCard(Samples.maxCouponCard) {}
            ProductCard(Samples.extremeCard) {}
        }, size: .accessibility2, width: 320)
    }

    /// 金额未知：不显示任何价格与返利金额；按钮不拼后缀。
    func testAmountUnknownCards() {
        snap(VStack(spacing: CouliSpacing.s3) {
            ProductCard(Samples.unknownCard) {}
            ProductCardGrid([Samples.unknownCard, Samples.singleCard])
            ProductDetailHeader(Samples.unknownCard)
        })
    }

    /// 金额隐藏：主卡、小数字行、数字格（含「其中…」）全部隐藏。
    func testWalletAmountHidden() {
        snap(VStack(spacing: CouliSpacing.s3) {
            WalletHeroCard(
                title: "可提现余额",
                amountFen: 1234,
                isHidden: true,
                toggleHiddenLabel: "显示金额",
                withdrawTitle: "提现",
                recordsTitle: "提现记录",
                onWithdraw: {},
                footer: {
                    HeroAmountRow(items: [
                        AmountGridItem(label: "冻结中", value: .amount(0)),
                        AmountGridItem(label: "已提现", value: .amount(500)),
                    ], amountHidden: true)
                }
            )
            AmountGrid(items: [
                AmountGridItem(
                    label: "预估收益",
                    value: .amount(5678),
                    note: AmountNote("其中已收货 ", amountFen: 3456),
                    isRebate: true
                ),
                AmountGridItem(label: "最早预计", value: .text("10 月结算")),
            ], amountHidden: true)
                .couliCard()
        })
    }

    func testProductGridAndDetail() {
        snap(VStack(spacing: CouliSpacing.s3) {
            ProductCardGrid([Samples.rangeCard, Samples.singleCard])
            ProductDetailHeader(Samples.rangeCard, fetchedAt: "10:00", shopName: "乳品生活旗舰店")
        })
    }

    func testPriceAndRebateTags() {
        let unknown = RebateTagModel.make(basis: "amount_unknown", minFen: nil, maxFen: nil, loginRequired: false)
        let login = RebateTagModel.make(basis: "login_required", minFen: nil, maxFen: nil, loginRequired: true)
        snap(VStack(alignment: .leading, spacing: CouliSpacing.s3) {
            PriceTag(Samples.rangeCard.price)
            PriceSubLine(Samples.rangeCard.price)
            PriceTag(Samples.singleCard.price, size: .compact)
            PriceSubLine(Samples.singleCard.price)
            PriceTag(Samples.pddCard.price)
            PriceTag(Samples.rangeCard.price, size: .large)
            RebateTag(Samples.rangeCard.rebate)
            RebateTag(Samples.singleCard.rebate)
            RebateTag(Samples.noRebateCard.rebate, placement: .detail)
            RebateTag(unknown)
            RebateTag(login)
            RebateTag(Samples.rangeCard.rebate, placement: .detail, isLarge: true)
            EstNetLine(Samples.rangeCard.estNet, rebate: Samples.rangeCard.rebate)
            CouliFlowLayout(horizontalSpacing: CouliSpacing.s2, verticalSpacing: CouliSpacing.s2) {
                PlatformBadge("淘宝", platformCode: "taobao")
                CouliTag("有券")
                CouliTag("预估中", style: .pending)
                CouliTag("已结算", style: .success)
                MatchBadge("符合条件", kind: .matched)
                MatchBadge("已放宽条件", kind: .relaxed)
                AiLabel("AI 生成")
            }
        })
    }

    func testButtons() {
        let single = Samples.singleCard.rebate
        snap(VStack(alignment: .leading, spacing: CouliSpacing.s3) {
            CouliFlowLayout(horizontalSpacing: CouliSpacing.s2, verticalSpacing: CouliSpacing.s2) {
                CouliButton("提现") {}
                CouliButton("提现", kind: .secondary) {}
                CouliButton("提现记录", kind: .text) {}
                CouliButton("提现", isEnabled: false) {}
            }
            BuyButton(base: "去购买", rebate: single, context: .list) {}
            BuyButton(base: "领券购买", rebate: Samples.rangeCard.rebate, context: .list) {}
            BuyButton(base: "去购买", rebate: single, amountHidden: true, context: .list) {}
            BuyButton(base: "去购买", rebate: single, context: .list, state: .disabled) {}
            BuyButton(base: "去购买", rebate: single, context: .list, state: .retryLater("网络不稳定，请重试")) {}
        })
    }

    func testWallet() {
        snap(VStack(spacing: CouliSpacing.s3) {
            WalletHeroCard(
                title: "可提现余额",
                amountFen: 1234,
                toggleHiddenLabel: "隐藏金额",
                withdrawTitle: "提现",
                recordsTitle: "提现记录",
                onWithdraw: {},
                footer: {
                    HeroAmountRow(items: [
                        AmountGridItem(label: "冻结中", value: .amount(0), helpLabel: "说明"),
                        AmountGridItem(label: "已提现", value: .amount(500)),
                    ])
                }
            )
            AmountGrid(items: [
                AmountGridItem(
                    label: "预估收益",
                    value: .amount(5678),
                    note: AmountNote("其中已收货 ", amountFen: 3456),
                    isRebate: true,
                    helpLabel: "说明"
                ),
                AmountGridItem(label: "最早预计", value: .text("10 月结算")),
            ])
            .couliCard()
            EntryGrid(title: "订单与钱包", items: [
                EntryGridItem(id: "a", title: "我的订单", icon: .orders),
                EntryGridItem(id: "b", title: "钱包", icon: .wallet),
                EntryGridItem(id: "c", title: "余额流水", icon: .ledger),
                EntryGridItem(id: "d", title: "找回订单", icon: .claim),
            ]) { _ in }
        })
    }

    func testWalletLargeText() {
        snap(VStack(spacing: CouliSpacing.s3) {
            WalletHeroCard(
                title: "可提现余额",
                amountFen: 123_456,
                toggleHiddenLabel: "隐藏金额",
                withdrawTitle: "提现",
                recordsTitle: "提现记录",
                onWithdraw: {},
                footer: {
                    HeroAmountRow(items: [
                        AmountGridItem(label: "冻结中", value: .amount(0)),
                        AmountGridItem(label: "已提现", value: .amount(500)),
                    ])
                }
            )
            AmountGrid(items: [
                AmountGridItem(label: "预估收益", value: .amount(5678), isRebate: true),
                AmountGridItem(label: "最早预计", value: .text("10 月结算")),
            ])
            .couliCard()
        }, size: .accessibility2)
    }

    func testStatesAndNavigation() {
        snap(VStack(spacing: CouliSpacing.s3) {
            NavBar(title: "钱包", backLabel: "返回")
            EmptyState(title: "没有找到符合条件的商品", message: "换个关键词，或放宽价格区间再试试")
            ProductCardSkeleton(accessibilityLabel: "加载中")
            Toast("已复制")
            DisclaimerFooter(lines: [.init("券后价按单件计算，不含运费及会员价等优惠，以下单页为准"), .init("以结算为准")])
            DisclaimerFooter(
                lines: [.init("券后价按单件计算，以下单页为准", icon: .info), .init("确认收货后随联盟月度结算入账", icon: .clock)],
                style: .boxed
            )
            TabBar(
                items: [
                    TabBarItem(id: "home", title: "首页", icon: .home),
                    TabBarItem(id: "agent", title: "AI 助手", icon: .chat),
                    TabBarItem(id: "orders", title: "订单", icon: .orders),
                    TabBarItem(id: "me", title: "我的", icon: .user),
                ],
                selectedID: "home"
            ) { _ in }
        })
    }

    func testDialogAndSheet() {
        snap(VStack(spacing: CouliSpacing.s4) {
            CouliDialog(
                title: "该商品当前暂无返利，继续购买？",
                message: "弹窗正文。",
                primary: CouliDialogAction("继续购买") {},
                secondary: CouliDialogAction("再想想") {}
            )
            CouliSheet(title: "授权说明", closeLabel: "关闭", onClose: {}, content: {
                Text(verbatim: "半屏正文").couliFont(.footnote)
            }, actions: {
                CouliButton("知道了", fillsWidth: true) {}
            })
        })
    }
}

/// 快照用样例（与组件目录页同一组设计稿数据）。
/// 快照共用的样例卡（RebateDisclaimerSnapshotTests 也用）。
enum Samples {
    static func card(
        platform: Platform = .taobao,
        platformName: String = "淘宝",
        title: String,
        priceFen: Int64,
        couponFen: Int64 = 0,
        presale: Bool = false,
        basis: RebateBasis,
        minFen: Int64? = nil,
        maxFen: Int64? = nil,
        estNetFen: Int64? = nil,
        buyBase: String,
        tags: [ProductCardTag] = [],
        notes: [String] = []
    ) -> ProductCardData {
        let rebate = RebateTagModel.make(
            basis: basis.rawValue, minFen: minFen, maxFen: maxFen, loginRequired: basis == .loginRequired
        )
        return ProductCardData(
            platformName: platformName,
            platformCode: platform.rawValue,
            title: title,
            tags: tags,
            price: PriceTagModel.make(
                platform: platform.rawValue,
                priceFen: priceFen,
                couponFen: couponFen,
                finalPriceFen: priceFen - couponFen,
                isPresale: presale
            ),
            rebate: rebate,
            estNet: EstNetModel.make(basis: basis.rawValue, minFen: minFen, estNetPriceFen: estNetFen),
            notes: notes,
            settlementNote: rebate.kind == .range ? PriceTerms.settlementNote : nil,
            buyBase: buyBase,
            disclaimer: "价格按单件计算，不含运费及会员价等优惠，以下单页为准",
            disclaimerButtonLabel: "口径说明"
        )
    }

    static var rangeCard: ProductCardData {
        card(
            title: "全脂纯牛奶 250ml × 24 盒 整箱装 早餐奶 学生奶 送礼礼盒款 生产日期新鲜",
            priceFen: 2345, couponFen: 1000,
            basis: .priceCompareRisk, minFen: 56, maxFen: 112, estNetFen: 1289,
            buyBase: "领券购买"
        )
    }

    static var singleCard: ProductCardData {
        card(
            platform: .jd, platformName: "京东",
            title: "快充数据线 编织线身 1.5m 双头通用 60W 快充 耐弯折",
            priceFen: 2990, basis: .normal, minFen: 45, maxFen: 45, estNetFen: 2945,
            buyBase: "去购买"
        )
    }

    static var noRebateCard: ProductCardData {
        card(
            platform: .jd, platformName: "京东",
            title: "抽纸 3 层 120 抽 × 24 包 家用整箱装",
            priceFen: 2990, basis: .noRebate, minFen: 0, maxFen: 0,
            buyBase: "去购买（无返利）"
        )
    }

    static var extremeCard: ProductCardData {
        card(
            title: "进口全自动意式咖啡机 家用商用两用 一体式研磨 双锅炉 恒温萃取 多种配置可选 预售 下单后 45 天发货",
            priceFen: 9_999_999, presale: true,
            basis: .priceCompareRisk, minFen: 8_888_888, maxFen: 9_999_999, estNetFen: 1_111_111,
            buyBase: "去购买",
            tags: [ProductCardTag("规格待确认", style: .info), ProductCardTag(PriceTerms.specNote)]
        )
    }

    static var maxCouponCard: ProductCardData {
        card(
            title: "进口全自动意式咖啡机 家用商用两用 一体式研磨 双锅炉 豪华礼盒装",
            priceFen: 10_099_999, couponFen: 100_000,
            basis: .normal, minFen: 9_999_999, maxFen: 9_999_999, estNetFen: 1_111_111,
            buyBase: "领券购买"
        )
    }

    static var unknownCard: ProductCardData {
        card(
            platform: .pdd, platformName: "拼多多",
            title: "拼多多直链商品（拿不到商品信息）",
            priceFen: 1990, basis: .amountUnknown,
            buyBase: "去购买"
        )
    }

    static var pddCard: ProductCardData {
        card(
            platform: .pdd, platformName: "拼多多",
            title: "拼团 家用大容量冰箱 十字对开门 风冷无霜 一级能效",
            priceFen: 1_099_999, couponFen: 100_000,
            basis: .normal, minFen: 9999, maxFen: 9999, estNetFen: 990_000,
            buyBase: "领券购买"
        )
    }
}
