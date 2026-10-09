@testable import DesignSystem
import XCTest

/// APP-06a R3-02：平台返利明确未开放（features.platform_status=not_launched）时，列表卡与详情大卡共用的展示映射
/// （设计稿 ProductCardDegrade ①）：保留商品价格与副行，返利标签、预估返后、「以结算为准」及读屏金额都不出现，
/// 按钮置灰「{平台}返利即将开放」。maintenance 只改按钮。
final class PlatformNotLaunchedMappingTests: XCTestCase {
    private let texts: (String) -> String = { key in
        switch key {
        case "platform.jd": "京东"
        case ProductCardKeys.retryLater: "稍后再试"
        case ProductCardKeys.platformComingSoon: "{platform_name}返利即将开放"
        case "btn.buy.coupon": "领券购买"
        default: key
        }
    }

    /// 普通可返利报价：券后 ¥29.9、预估返 ¥2.69、预估返后 ¥27.21；比价口径带「以结算为准」。
    private let card: [String: Any] = [
        "platform": "jd", "title": "洗衣液", "price_fen": 3990, "coupon_fen": 1000, "final_price_fen": 2990,
        "est_net_price_fen": 2721, "rebate_min_fen": 269, "rebate_max_fen": 269, "rebate_basis": "normal",
        "benefit_tags": [String](), "is_presale": false, "cta": ["text_key": "btn.buy.coupon"],
        "disclaimer_keys": ["price_basis", "rebate_compare"], "availability": "ok",
    ]

    private func mapped(_ status: String?) -> ProductCardData {
        ProductCardMapper.applyPurchaseStatus(
            ProductCardMapper.map(card, texts: texts).data, statusRaw: status, texts: texts
        )
    }

    /// 卡上会被看到或读出的全部金额文字（价格、副行、返利标签、预估返后、底行说明）。
    private func shownTexts(_ data: ProductCardData) -> [String] {
        var all = [data.price.mainAmount, data.price.mainAccessibilityText]
        all += data.subLines.flatMap { [$0.text, $0.spoken] }
        if data.showsRebate {
            all += [data.rebate.text, data.rebate.accessibilityText]
            if let note = data.settlementNote {
                all.append(note)
            }
        }
        return all
    }

    func testConfigOnToNotLaunchedHidesRebateAmountsKeepsPrice() {
        let on = mapped("on")
        XCTAssertTrue(on.showsRebate)
        XCTAssertEqual(on.buyState, .normal)
        XCTAssertNotNil(on.estNet)
        XCTAssertTrue(shownTexts(on).contains { $0.contains("预估返") }, "on：显示返利金额")
        XCTAssertTrue(shownTexts(on).contains { $0.contains("2.69") })
        XCTAssertTrue(shownTexts(on).contains { $0.contains("27.21") }, "on：显示预估返后")

        let off = mapped("not_launched")
        XCTAssertFalse(off.showsRebate, "未开放：不显示返利标签")
        XCTAssertTrue(off.rebateNotLaunched)
        XCTAssertNil(off.estNet)
        XCTAssertNil(off.estNetAccessibility)
        XCTAssertNil(off.settlementNote)
        XCTAssertEqual(off.buyState, .retryLater("京东返利即将开放"), "按钮置灰并显示平台文案")
        let shown = shownTexts(off)
        XCTAssertFalse(shown.contains { $0.contains("预估返") }, "未开放：没有返利与预估返后（含读屏）：\(shown)")
        XCTAssertFalse(shown.contains { $0.contains("2.69") || $0.contains("27.21") })
        XCTAssertEqual(off.price.mainAmount, on.price.mainAmount, "商品价格保留")
        XCTAssertFalse(off.price.mainAmount.isEmpty)
        XCTAssertFalse(off.hidesPrice)
    }

    func testMaintenanceAndUnknownKeepRebate() {
        let maintenance = mapped("maintenance")
        XCTAssertTrue(maintenance.showsRebate, "维护中只改按钮（不在 R3-02 范围）")
        XCTAssertNotNil(maintenance.estNet)
        XCTAssertEqual(maintenance.buyState, .retryLater("稍后再试"))
        for status in [nil, "on", "bogus"] {
            let data = mapped(status)
            XCTAssertTrue(data.showsRebate)
            XCTAssertFalse(data.rebateNotLaunched)
            XCTAssertEqual(data.buyState, .normal)
        }
    }

    /// R3F-04（共性 34）：平台购买开关与入账规则互不替代。not_launched 只隐藏金额，详情入账说明仍按入账规则显示；
    /// 反过来购买开关为 on 也不会让不可返利 / 价格不可用的卡显示入账说明。
    func testPurchaseSwitchDoesNotReplaceSettleNoteRule() {
        let off = mapped("not_launched")
        XCTAssertFalse(off.showsRebate, "not_launched：金额隐藏")
        XCTAssertNil(off.estNet)
        XCTAssertTrue(
            ProductCardMapper.showsSettleNote(off, priceUnavailable: false),
            "not_launched：可返利、价格可用的卡仍显示入账说明（购买开关不是入账开关）"
        )
        XCTAssertEqual(
            ProductCardMapper.showsSettleNote(off, priceUnavailable: false),
            ProductCardMapper.showsSettleNote(mapped("on"), priceUnavailable: false),
            "入账说明与购买开关无关"
        )
        XCTAssertFalse(ProductCardMapper.showsSettleNote(off, priceUnavailable: true), "价格不可用：按原规则不显示")

        var noRebate = card
        noRebate["rebate_basis"] = "none"
        noRebate["rebate_min_fen"] = 0
        noRebate["rebate_max_fen"] = 0
        let on = ProductCardMapper.applyPurchaseStatus(
            ProductCardMapper.map(noRebate, texts: texts).data, statusRaw: "on", texts: texts
        )
        XCTAssertEqual(on.rebate.kind, .none)
        XCTAssertEqual(on.buyState, .normal, "购买开关 on")
        XCTAssertFalse(ProductCardMapper.showsSettleNote(on, priceUnavailable: false), "on 不能让暂无返利的卡显示入账说明")
    }
}
