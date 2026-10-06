@testable import DesignSystem
import XCTest

/// 向量之外的组件层约定：读屏文本、显示用不换行空格、保守的容错写法（rule-gaps.md）。
final class ComponentModelTests: XCTestCase {
    func testSpokenAmounts() {
        XCTAssertEqual(CouliFormat.moneySpoken(fen: 1990), "19.9 元")
        XCTAssertEqual(CouliFormat.moneySpoken(fen: -150), "负 1.5 元")
        XCTAssertEqual(CouliFormat.rebateRangeSpoken(minFen: 123, maxFen: 234), "1.23 元到 2.34 元")
        XCTAssertNil(CouliFormat.rebateRangeSpoken(minFen: 0, maxFen: 0))
        let price = PriceTagModel.make(
            platform: "taobao", priceFen: 3990, couponFen: 1000, finalPriceFen: 2990, isPresale: false
        )
        XCTAssertEqual(price.mainAccessibilityText, "券后 29.9 元")
        XCTAssertEqual(price.subLineAccessibilityText, "券前 39.9 元，券 10 元")
    }

    func testBuyButtonAccessibilityLabel() {
        let range = RebateTagModel.make(basis: "price_compare_risk", minFen: 123, maxFen: 234, loginRequired: false)
        XCTAssertEqual(
            BuyButtonModel.accessibilityLabel(base: "领券购买", rebate: range, amountHidden: false, context: "list"),
            "领券购买，预估返 1.23 元到 2.34 元"
        )
        XCTAssertEqual(
            BuyButtonModel.accessibilityLabel(base: "领券购买", rebate: range, amountHidden: true, context: "list"),
            "领券购买"
        )
        XCTAssertEqual(
            BuyButtonModel.accessibilityLabel(base: "去购买", rebate: range, amountHidden: false, context: "share"),
            "去购买"
        )
    }

    func testRangePartsBreakOnlyAtDash() {
        let range = RebateTagModel.make(basis: "price_compare_risk", minFen: 56, maxFen: 112, loginRequired: false)
        XCTAssertEqual(range.amountParts, ["¥0.56", "\u{2013}¥1.12"])
        XCTAssertEqual(range.label, PriceTerms.rebate)
        XCTAssertNil(range.singleAmount)
    }

    func testConservativeFallbacks() {
        // 一端为空：不猜金额，也不承诺「可返利」。
        XCTAssertEqual(
            RebateTagModel.make(basis: "normal", minFen: nil, maxFen: 100, loginRequired: false).kind,
            .none
        )
        // loginRequired 与 basis 矛盾：登录查看优先。
        XCTAssertEqual(RebateTagModel.make(basis: "normal", minFen: 1, maxFen: 1, loginRequired: true).kind, .login)
        // min > max：不排序，按异常显示「暂无返利」（编排者统一裁定）。
        let reversed = RebateTagModel.make(basis: "normal", minFen: 200, maxFen: 100, loginRequired: false)
        XCTAssertEqual(reversed.kind, .none)
        XCTAssertEqual(reversed.text, "暂无返利")
        // 未知 context 不拼后缀。
        let single = RebateTagModel.make(basis: "normal", minFen: 45, maxFen: 45, loginRequired: false)
        XCTAssertEqual(BuyButtonModel.text(base: "去购买", rebate: single, amountHidden: false, context: "x"), "去购买")
        // 非法纯日期原样返回。
        XCTAssertEqual(CouliFormat.dateOnly(isoDate: "2026-02-30", nowEpochMillis: 1_790_647_200_000), "2026-02-30")
        XCTAssertNil(EstNetModel.make(basis: "normal", minFen: 100, estNetPriceFen: nil))
    }

    func testAmountMaskHidesEveryDigit() {
        let note = AmountNote("其中已收货 ", amountFen: 3456)
        XCTAssertEqual(note.display(hidden: true), "其中已收货 ****")
        XCTAssertFalse(note.spoken(hidden: true).contains("34"))
        let item = AmountGridItem(label: "预估收益", value: .amount(5678), note: note, isRebate: true)
        let spoken = item.accessibilityText(hidden: true)
        XCTAssertFalse(spoken.contains(where: \.isNumber), spoken)
        XCTAssertEqual(AmountValue.amount(-150).display(hidden: true), "****")
        XCTAssertEqual(AmountValue.amount(-150).display(hidden: false), "-¥1.5")
    }

    func testAmountUnknownCardHidesPrice() {
        let rebate = RebateTagModel.make(basis: "amount_unknown", minFen: nil, maxFen: nil, loginRequired: false)
        let data = ProductCardData(
            platformName: "拼多多",
            title: "直链",
            price: PriceTagModel.make(platform: "pdd", priceFen: 0, couponFen: 0, finalPriceFen: 0, isPresale: false),
            rebate: rebate,
            estNet: "预估返后 ¥1",
            buyBase: "去购买",
            disclaimer: "",
            disclaimerButtonLabel: ""
        )
        XCTAssertTrue(data.hidesPrice)
        XCTAssertTrue(data.subLines.isEmpty)
        XCTAssertEqual(BuyButtonModel.text(base: "去购买", rebate: rebate, amountHidden: false, context: "list"), "去购买")
    }

    func testBreakablePiecesKeepAmountsWhole() {
        XCTAssertEqual(BreakableText.pieces("¥99999.99"), ["¥99999.99"])
        XCTAssertEqual(BreakableText.pieces("券前 ¥13345.67"), ["券前 ", "¥13345.67"])
        XCTAssertTrue(BreakableText.isAtomic("¥13345.67"))
        XCTAssertFalse(BreakableText.isAtomic("定金与尾款以下单页为准"))
        XCTAssertEqual(BreakableText.pieces("\u{2013}¥1.12"), ["\u{2013}¥1.12"])
        XCTAssertEqual(BreakableText.pieces("¥10"), ["¥10"])
        XCTAssertEqual(BreakableText.pieces("10 月结算"), ["10 ", "月结算"])
        XCTAssertEqual(BreakableText.pieces("****"), ["****"])
    }

    /// rule-gaps.md「编排者统一裁定」逐条（三端一致）。
    func testUnifiedRulingOnAbnormalData() {
        func kind(_ basis: String, _ minFen: Int64?, _ maxFen: Int64?, login: Bool = false) -> RebateTagKind {
            RebateTagModel.make(basis: basis, minFen: minFen, maxFen: maxFen, loginRequired: login).kind
        }
        for basis in ["normal", "price_compare_risk"] {
            XCTAssertEqual(kind(basis, nil, 100), .none, "缺下限 \(basis)")
            XCTAssertEqual(kind(basis, 100, nil), .none, "缺上限 \(basis)")
            XCTAssertEqual(kind(basis, -1, 100), .none, "下限为负 \(basis)")
            XCTAssertEqual(kind(basis, -200, -100), .none, "两端为负 \(basis)")
            XCTAssertEqual(kind(basis, 200, 100), .none, "min > max \(basis)")
            XCTAssertEqual(kind(basis, 0, 0), .none, "上限为 0 \(basis)")
            XCTAssertEqual(kind(basis, 100, 200), .range)
            XCTAssertEqual(kind(basis, 100, 100), .amount)
        }
        XCTAssertEqual(kind("mystery", 100, 100), .none, "未知 basis")
        XCTAssertEqual(RebateTagModel.make(basis: "mystery", minFen: 1, maxFen: 1, loginRequired: false).text, "暂无返利")
        // 「可返利，金额以订单为准」只给 amount_unknown。
        XCTAssertEqual(kind("amount_unknown", nil, nil), .unknown)
        XCTAssertEqual(kind("amount_unknown", 100, 200), .unknown)
        for basis in ["normal", "price_compare_risk", "no_rebate", "mystery"] {
            XCTAssertNotEqual(kind(basis, nil, nil), .unknown, basis)
        }
        // loginRequired 优先于 basis。
        XCTAssertEqual(kind("amount_unknown", nil, nil, login: true), .login)
        XCTAssertEqual(kind("no_rebate", nil, nil, login: true), .login)
        // 纯格式化同口径：min > max、负数返回 nil，读屏同样不读金额。
        XCTAssertNil(CouliFormat.rebateRange(minFen: 200, maxFen: 100))
        XCTAssertNil(CouliFormat.rebateRange(minFen: -1, maxFen: 100))
        XCTAssertNil(CouliFormat.rebateRangeSpoken(minFen: 200, maxFen: 100))
        // 券额 ≤ 0 按无券；只有 pdd 加「拼单」；dateOnly 非法原样；未知 context 不拼后缀；返后价为空不显示。
        let negativeCoupon = PriceTagModel.make(
            platform: "jd", priceFen: 1000, couponFen: -100, finalPriceFen: 1000, isPresale: false
        )
        XCTAssertTrue(negativeCoupon.noCoupon)
        XCTAssertEqual(negativeCoupon.mainLabel, "售价")
        XCTAssertEqual(
            PriceTagModel.make(platform: "unknown", priceFen: 1000, couponFen: 0, finalPriceFen: 1000, isPresale: false)
                .mainLabel,
            "售价"
        )
        XCTAssertEqual(CouliFormat.dateOnly(isoDate: "2026-13-01", nowEpochMillis: 1_790_647_200_000), "2026-13-01")
        let single = RebateTagModel.make(basis: "normal", minFen: 45, maxFen: 45, loginRequired: false)
        XCTAssertEqual(BuyButtonModel.text(base: "去购买", rebate: single, amountHidden: false, context: "x"), "去购买")
        XCTAssertNil(EstNetModel.make(basis: "price_compare_risk", minFen: 100, estNetPriceFen: nil))
    }

    /// 编排者补充：预估返后只在同卡 RebateTag 可显示金额（amount / range）且金额未隐藏时显示。
    func testEstNetFollowsRebateTag() {
        let estNet = EstNetModel.make(basis: "normal", minFen: 200, estNetPriceFen: 2721)
        XCTAssertEqual(estNet, "预估返后 ¥27.21")
        // 异常（min > max）：RebateTag 判「暂无返利」，预估返后也不显示，即使模型给了文字。
        let reversed = RebateTagModel.make(basis: "normal", minFen: 200, maxFen: 100, loginRequired: false)
        XCTAssertNil(EstNetLine.visibleText(estNet, rebate: reversed, amountHidden: false))
        let range = RebateTagModel.make(basis: "price_compare_risk", minFen: 100, maxFen: 200, loginRequired: false)
        XCTAssertEqual(EstNetLine.visibleText(estNet, rebate: range, amountHidden: false), estNet)
        XCTAssertNil(EstNetLine.visibleText(estNet, rebate: range, amountHidden: true))
        let single = RebateTagModel.make(basis: "normal", minFen: 200, maxFen: 200, loginRequired: false)
        XCTAssertEqual(EstNetLine.visibleText(estNet, rebate: single, amountHidden: false), estNet)
        for rebate in [
            RebateTagModel.make(basis: "amount_unknown", minFen: nil, maxFen: nil, loginRequired: false),
            RebateTagModel.make(basis: "normal", minFen: 200, maxFen: 200, loginRequired: true),
            RebateTagModel.make(basis: "no_rebate", minFen: 200, maxFen: 200, loginRequired: false),
        ] {
            XCTAssertNil(EstNetLine.visibleText(estNet, rebate: rebate, amountHidden: false), rebate.kindRaw)
        }
        // 卡片组件走同一判定。
        let card = ProductCardData(
            platformName: "淘宝",
            title: "异常返利",
            price: PriceTagModel.make(
                platform: "taobao",
                priceFen: 3000,
                couponFen: 0,
                finalPriceFen: 3000,
                isPresale: false
            ),
            rebate: reversed,
            estNet: estNet,
            buyBase: "去购买",
            disclaimer: "",
            disclaimerButtonLabel: ""
        )
        XCTAssertFalse(card.subLines.contains { $0.text == estNet })
    }

    /// R1-02：区间金额由组件统一格式化、隐藏、读屏，且只在破折号处拆段。
    func testAmountRangeValue() {
        let range = AmountValue.range(minFen: 8_888_888, maxFen: 9_999_999)
        XCTAssertEqual(range.displayParts(hidden: false), ["¥88888.88", "\u{2013}¥99999.99"])
        XCTAssertEqual(range.spoken(hidden: false), "88888.88 元到 99999.99 元")
        XCTAssertEqual(range.displayParts(hidden: true), ["****"])
        XCTAssertEqual(range.spoken(hidden: true), "金额已隐藏")
        XCTAssertEqual(AmountValue.range(minFen: 250, maxFen: 250).displayParts(hidden: false), ["¥2.5"])
        XCTAssertEqual(AmountValue.range(minFen: 250, maxFen: 250).spoken(hidden: false), "2.5 元")
        // 异常：不排序，显示与读屏都是「暂无返利」。
        XCTAssertEqual(AmountValue.range(minFen: 200, maxFen: 100).displayParts(hidden: false), ["暂无返利"])
        XCTAssertEqual(AmountValue.range(minFen: 200, maxFen: 100).spoken(hidden: false), "暂无返利")
        XCTAssertEqual(AmountValue.range(minFen: 0, maxFen: 0).display(hidden: false), "暂无返利")
        // 每一段都是不可拆分的金额段：段内不折行，只在段间（破折号前）折行。
        for part in range.displayParts(hidden: false) {
            XCTAssertEqual(BreakableText.pieces(part), [part])
            XCTAssertTrue(BreakableText.isAtomic(part))
        }
        let item = AmountGridItem(label: "预估返", value: range, isRebate: true)
        XCTAssertEqual(item.accessibilityText(hidden: false), "预估返，88888.88 元到 99999.99 元")
        XCTAssertEqual(item.accessibilityText(hidden: true), "预估返，金额已隐藏")
    }

    /// 数字格并排条件：每列放得下最宽的不可拆分段就并排，否则上下排；辅助字号档强制上下排。
    func testAmountGridColumnRule() {
        let column = AmountGridLayout.columnWidth(288, count: 2, spacing: 16)
        XCTAssertEqual(column, 136)
        XCTAssertTrue(AmountGridLayout.fitsSideBySide(
            columnWidth: column,
            widestParts: [100, 120],
            forceStacked: false
        ))
        XCTAssertFalse(AmountGridLayout.fitsSideBySide(
            columnWidth: column,
            widestParts: [100, 140],
            forceStacked: false
        ))
        XCTAssertFalse(AmountGridLayout.fitsSideBySide(columnWidth: column, widestParts: [10, 10], forceStacked: true))
    }

    /// R1-04：独立金额小字隐藏时读完整句「其中 金额已隐藏 暂缓入账」，不读星号也不读真实金额。
    func testAmountNoteSpokenWhenHidden() {
        let note = AmountNote("其中 ", amountFen: 456, suffix: " 暂缓入账")
        XCTAssertEqual(note.display(hidden: true), "其中 **** 暂缓入账")
        XCTAssertEqual(note.spoken(hidden: true), "其中 金额已隐藏 暂缓入账")
        XCTAssertEqual(note.spoken(hidden: false), "其中 4.56 元 暂缓入账")
    }

    /// R1-03：打开焦点进标题，关闭（按钮、遮罩、关闭键都走 isPresented → false）还给触发控件。
    func testModalFocusTransitions() {
        XCTAssertEqual(ModalFocus.transition(wasPresented: false, isPresented: true), .focusPanelTitle)
        XCTAssertEqual(ModalFocus.transition(wasPresented: true, isPresented: false), .restoreTrigger)
        XCTAssertEqual(ModalFocus.transition(wasPresented: true, isPresented: true), .none)
        XCTAssertEqual(ModalFocus.transition(wasPresented: false, isPresented: false), .none)
        // 还焦点要等关闭动画（0.2 s）结束、底层解除读屏隐藏之后。
        XCTAssertGreaterThan(ModalFocus.restoreDelayNanos, 200_000_000)
    }

    /// R1-05：首次出现、显示期间换内容、同文再提示都播报；同一请求不重复播报。
    func testToastAnnouncementPolicy() {
        let copied = CouliToastMessage("已复制")
        XCTAssertEqual(ToastAnnouncement.text(previous: nil, current: copied), "已复制")
        let saved = CouliToastMessage("已保存")
        XCTAssertEqual(ToastAnnouncement.text(previous: copied, current: saved), "已保存")
        let copiedAgain = CouliToastMessage("已复制")
        XCTAssertNotEqual(copied, copiedAgain)
        XCTAssertEqual(ToastAnnouncement.text(previous: copied, current: copiedAgain), "已复制")
        XCTAssertNil(ToastAnnouncement.text(previous: copied, current: copied))
        XCTAssertNil(ToastAnnouncement.text(previous: copied, current: nil))
    }
}
