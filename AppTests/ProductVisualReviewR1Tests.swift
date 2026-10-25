@testable import Couli
import DesignSystem
import Foundation
import SwiftUI
import UIKit
import XCTest

/// APP-06v-a 测试 v2：独立评审 r1 S2-4 提的用例缺口（比价行 200%、头图加载失败、有价格 + 金额未知）。判据沿用 v1，不放宽。
@MainActor
final class ProductVisualReviewR1Tests: ProductVisualTestCase {
    // MARK: - S2-4-1 比价原因行在 200% 下不撑高；命中区不压胶囊、不压取价行

    func testCompareReasonAtLargeTextKeepsVisualRowAndHitClearOfCapsuleAndFetchedRow() async throws {
        let cases: [ProductVisualHost.Canvas] = [
            .init(), .init(width: 320, size: .accessibility3), .init(width: 390, size: .accessibility3),
        ]
        for canvas in cases {
            let name = "比价行@\(Int(canvas.width))/\(canvas.size)"
            let page = try await open("pdd_price_compare", statuses: ["pdd": "on"], canvas: canvas).0
            let row = try page.probes.rect("product.compareReason")
            let capsule = try page.probes.rect("product.compareReason.capsule")
            let label = try page.probes.rect("product.similar.label")
            let hit = try page.probes.rect("product.similar")
            let fetched = try page.probes.rect("product.fetchedAt")
            let visual = capsule.union(label)
            assertNear(row.minY, visual.minY, 1, "\(name)：原因行上缘 = 胶囊与按钮字的上缘（命中区不撑高）")
            assertNear(row.maxY, visual.maxY, 1, "\(name)：原因行下缘 = 胶囊与按钮字的下缘（命中区不撑高）")
            if canvas.size == .large {
                assertNear(row.height, 32, 2, "\(name)：默认字号视觉行 32")
            }
            XCTAssertGreaterThanOrEqual(hit.width, 44 - 0.01, "\(name)：命中宽 ≥ 44")
            XCTAssertGreaterThanOrEqual(hit.height, 44 - 0.01, "\(name)：命中高 ≥ 44")
            assertNear(hit.midY, label.midY, 1, "\(name)：命中区以按钮字为中心上下对称扩展")
            assertInside(label, hit, "\(name)：按钮字在命中区内")
            assertDisjoint(hit, capsule, "\(name)：命中区不压到胶囊（折行后按钮单独一行时也不行）")
            assertDisjoint(hit, fetched, "\(name)：命中区不压到取价行")
            XCTAssertLessThanOrEqual(row.maxY, fetched.minY + 0.5, "\(name)：取价行在原因行之下")
        }
    }

    // MARK: - S2-4-2 头图加载失败：只显示占位底

    func testFailedHeroShowsPlaceholderOnlyWithSameFrame() async throws {
        var card = try ProductVisualCards.screenshotCard("tb_coupon_range")
        card["image"] = "https://img.example.test/product-v/broken.png"
        let (page, image) = try await open(card: card, expectImage: false)
        XCTAssertTrue(ProductVisualImages.served.contains { $0.hasSuffix("/product-v/broken.png") }, "前提：请求了失败图")
        let hero = try page.probes.rect("product.hero")
        assertNear(hero.width, 358, 0.5, "失败时头图框不变（宽）")
        assertNear(hero.height, hero.width * ProductVisualLayoutTests.heroRatio, 1, "失败时头图框不变（比例）")
        let pixels = ProductVisualPixels(image)
        let placeholder = ProductVisualPixels.RGB(CouliColor.backgroundPlaceholder, dark: false)
        let inner = hero.insetBy(dx: 3, dy: 3)
        XCTAssertEqual(pixels.count(in: inner, step: 3) { $0.isStripe }, 0, "失败时不画任何图")
        let total = pixels.count(in: inner, step: 3) { _ in true }
        let filled = pixels.count(in: inner, step: 3) { $0.near(placeholder, tolerance: 6) }
        XCTAssertGreaterThanOrEqual(Double(filled), Double(total) * 0.95,
                                    "失败时头图框基本都是 background.placeholder 占位底（brief §2.2：至多一个「商品图」字样）")
    }

    // MARK: - S2-4-5 价格字段有值 + 金额未知（specs/product-visual-extra-cards.json）

    /// BR-PRICE-08：amount_unknown（拼多多直链）「不显示任何价格与返利金额，显示『可返利，金额以订单为准』，按钮『去购买』」。
    /// 卡上价格字段故意有值（¥15.34 / ¥3 / ¥12.34），锁住「有值也不显示」；对照的正常 pdd 卡先验价格测量确实会上报。
    func testAmountUnknownHidesEvenPresentPricesAndShowsUnknownRebate() async throws {
        let normal = try await open("pdd_coupon", statuses: ["pdd": "on"]).0
        XCTAssertNotNil(normal.probes["product.amount.price"], "前提：正常 pdd 卡上报主价测量")

        let card = try ProductVisualCards.card("pdd_amount_unknown_priced")
        XCTAssertEqual(card["final_price_fen"] as? Int, 1234, "前提：fixture 价格字段有值")
        let page = try await open("pdd_amount_unknown_priced", statuses: ["pdd": "on"]).0
        XCTAssertTrue(page.probes.records.values.filter { $0.role == "amount-part" }.isEmpty,
                      "金额未知：不显示任何价格与返利金额（价格字段有值也不显示，不补 0、不推算）")
        for id in ["product.card", "product.rebateTag", "product.title", "product.disclaimer"] {
            XCTAssertNotNil(page.probes[id], "金额未知：仍显示 \(id)（返利位写「可返利，金额以订单为准」）")
        }
        let button = try XCTUnwrap(page.probes["product.buy.label"], "缺 product.buy.label")
        XCTAssertEqual(button.text, "去购买", "按钮「去购买」，不拼任何金额")
    }
}
