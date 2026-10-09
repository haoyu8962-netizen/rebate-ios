import DesignSystem
import Foundation
import ProductSearch
import Purchase
@testable import Trade
import XCTest

/// APP-06b 共性第 47 条（iOS 第 2 轮评审 I-R2-03）：价格口径未知（券额未补齐）时弹窗各行都用不带口径词的中性写法，不默认按有券写「券后」。
/// 第 43 条修订与第 46 条的用例在 LessonsRound3Tests。
@MainActor
final class LessonsRound4Tests: XCTestCase {
    /// 与 App 草稿表同字的几条（只用于断言口径词）。
    private struct DraftTexts: SearchTexts {
        let table = [
            "trade.price_changed.before": "之前（{price_label}）",
            "trade.price_changed.before_plain": "之前",
            "trade.price_changed.now": "现在（{price_label}）",
            "trade.price_changed.now_plain": "现在",
            "trade.rebate_gone.note": "继续购买不会获得返利",
            "trade.rebate_gone.body": "价格没有变化，{price_label} {price}。继续购买不会获得返利",
            "trade.rebate_gone.body_changed": "{price_now} {price}。继续购买不会获得返利",
            "trade.rebate_gone.body_plain": "价格没有变化，现在 {price}。继续购买不会获得返利",
        ]

        func text(_ key: String) -> String {
            table[key] ?? ""
        }

        func format(_ key: String, _ vars: [String: String]) -> String {
            var result = table[key] ?? ""
            for (name, value) in vars {
                result = result.replacingOccurrences(of: "{\(name)}", with: value)
            }
            return result
        }
    }

    private let text = PurchaseText(texts: DraftTexts())

    func testPriceLabelUnknownCouponIsNotAfterCoupon() {
        var unknown = TradeFixtures.card(coupon: 0)
        unknown["coupon_fen"] = NSNull()
        XCTAssertNil(PurchaseText.priceLabel(unknown), "券额未知：口径未定，不默认「券后」")
        unknown.removeValue(forKey: "coupon_fen")
        XCTAssertNil(PurchaseText.priceLabel(unknown))
        XCTAssertEqual(PurchaseText.priceLabel(TradeFixtures.card(coupon: 0)), PriceTerms.salePrice)
        XCTAssertEqual(PurchaseText.priceLabel(TradeFixtures.card(coupon: 500)), PriceTerms.afterCoupon)
        XCTAssertEqual(PurchaseText.priceLabel(TradeFixtures.card(platform: "pdd", coupon: 0)), PriceTerms.pddPrice)
        XCTAssertEqual(text.beforeLine(unknown), "之前")
        XCTAssertEqual(text.nowLine(unknown), "现在")
        XCTAssertEqual(text.beforeLine(TradeFixtures.card(coupon: 0)), "之前（售价）")
        XCTAssertEqual(text.nowLine(TradeFixtures.card(coupon: 500)), "现在（券后）")
    }

    /// 无券商品 2990 → 首次 open 改价到 3290（券额置未知）→ 取消，补齐请求未返回 → 再次购买：本次新旧价都是 3290、返利归零。
    /// 「价格没有变化」与「之前」行都不带口径词。
    func testRebateGoneAfterUnfilledPriceChangeUsesPlainLines() async {
        let rig = PurchaseHarness(card: TradeFixtures.card(final: 2990, coupon: 0, rebate: (100, 229)))
        rig.controller.buy(rig.env.card, spm: nil)
        await eventually { rig.opens().count == 1 }
        rig.replyOpen(0, TradeFixtures.ok(TradeFixtures.open(extra: [
            "price_changed": true, "old_final_price_fen": 2990, "new_final_price_fen": 3290, "new_link_id": "L1b",
            "new_rebate_min_fen": 100, "new_rebate_max_fen": 229,
        ])))
        await eventually { rig.controller.state.dialog != nil }
        rig.controller.dismissDialog()
        XCTAssertTrue(rig.env.card["coupon_fen"] is NSNull, "改价后券额置未知，补齐请求没有返回")
        XCTAssertFalse(rig.env.refetches.isEmpty)

        rig.controller.buy(rig.env.card, spm: nil)
        await eventually { rig.opens().count == 2 }
        rig.replyOpen(1, TradeFixtures.ok(TradeFixtures.open(extra: [
            "old_final_price_fen": 3290, "new_final_price_fen": 3290,
            "new_rebate_min_fen": 0, "new_rebate_max_fen": 0,
        ])))
        await eventually { rig.controller.state.dialog != nil }
        XCTAssertEqual(rig.controller.state.dialog, .confirmRebateGone(priceFen: 3290, oldFen: 3290))
        let before = rig.controller.cardBeforeResponse
        let body = text.rebateGoneBody(
            newFen: 3290, oldFen: 3290, before: before, after: rig.controller.state.card ?? [:]
        )
        XCTAssertEqual(body, "价格没有变化，现在 \(CouliFormat.money(fen: 3290))。继续购买不会获得返利")
        XCTAssertFalse(body.contains(PriceTerms.afterCoupon))
        XCTAssertEqual(text.beforeLine(before), "之前", "「之前」行同样不带口径词")
        XCTAssertTrue(rig.ports.launched.isEmpty)
    }

    /// 口径已知时照常带口径词；新价不同走 body_changed，新价未知只说明没有返利（第 45 条不回退）。
    func testRebateGoneBodyKnownLabels() {
        let noCoupon = TradeFixtures.card(final: 2990, coupon: 0)
        XCTAssertEqual(
            text.rebateGoneBody(newFen: 2990, oldFen: 2990, before: noCoupon, after: noCoupon),
            "价格没有变化，售价 \(CouliFormat.money(fen: 2990))。继续购买不会获得返利"
        )
        var pending = noCoupon
        pending["coupon_fen"] = NSNull()
        XCTAssertEqual(
            text.rebateGoneBody(newFen: 3080, oldFen: 2990, before: noCoupon, after: pending),
            "现在 \(CouliFormat.money(fen: 3080))。继续购买不会获得返利"
        )
        XCTAssertEqual(
            text.rebateGoneBody(newFen: nil, oldFen: 2990, before: noCoupon, after: pending), "继续购买不会获得返利"
        )
    }
}
