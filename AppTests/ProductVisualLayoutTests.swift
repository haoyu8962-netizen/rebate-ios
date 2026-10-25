@testable import Couli
import DesignSystem
import Foundation
import SwiftUI
import UIKit
import XCTest

/// APP-06v-a 详情页主体：头图（contain、比例、去色）、推广角标、价格大卡（比价原因行、下架原位置灰）、口径块图标。
/// 全部读生产组件上报的实际框（§2 测量桥）与真实渲染像素；先验正常态再验变化态，防止「测量没报」让反向断言空过。
@MainActor
final class ProductVisualLayoutTests: ProductVisualTestCase {
    /// 画板 Product-v2：头图框 358 × 264（含 1 描边），390 宽页面左右各 16。
    static let heroRatio: CGFloat = 264.0 / 358.0

    // MARK: - 头图（§2.2，GUIDE §6「详情头图完整显示 contain」）

    func testHeroKeepsArtboardRatioAndContainsWholeImageLight() async throws {
        try await assertHeroContains(dark: false)
    }

    func testHeroContainsWholeImageDark() async throws {
        try await assertHeroContains(dark: true)
    }

    private func assertHeroContains(dark: Bool) async throws {
        let (page, image) = try await open("tb_coupon_range", canvas: .init(dark: dark))
        let hero = try page.probes.rect("product.hero")
        assertNear(hero.minX, 16, 0.5, "头图左边距 16")
        assertNear(hero.width, 358, 0.5, "头图宽 = 390 − 2 × 16")
        assertNear(hero.height, hero.width * Self.heroRatio, 1, "头图高宽比按画板 358 × 264")
        let placeholder = ProductVisualPixels.RGB(CouliColor.backgroundPlaceholder, dark: dark)
        XCTAssertEqual(
            ProductVisualJudge.containProblems(ProductVisualPixels(image), hero: hero, placeholder: placeholder),
            [],
            "头图完整显示（contain）+ 占位底留边（判据自证见 ProductVisualOracleTests）"
        )
        XCTAssertEqual(ProductVisualImages.served.filter { $0.hasSuffix("/product-v/milk.png") }.count, 1,
                       "单图（G-D03）：只请求契约 image 一张，不做轮播")
    }

    // MARK: - 下架原位置灰（§2.3，ProductOffShelf-v3；G-D06）

    func testOffShelfHidesEveryAmountBenefitAndDisclaimerButKeepsTitle() async throws {
        let normal = try await open("tb_coupon_range").0
        for id in ["product.card", "product.amount.price", "product.amount.before", "product.amount.coupon",
                   "product.amount.rebate.min", "product.amount.rebate.max", "product.amount.estNet",
                   "product.rebateTag", "product.benefitTags", "product.disclaimer", "product.title"] {
            XCTAssertNotNil(normal.probes[id], "正常态必须上报 \(id)（下架隐藏断言的前提）")
        }
        XCTAssertNil(normal.probes["product.offShelf"], "正常态没有「商品已下架」胶囊")

        let source = try ProductVisualCards.card("tb_off_shelf")
        XCTAssertEqual(source["final_price_fen"] as? Int, 4678, "前提：下架 fixture 保留旧金额，不能靠空数据通过")
        XCTAssertEqual(source["benefit_tags"] as? [String], ["有券"], "前提：下架 fixture 保留优惠标签")
        let page = try await open("tb_off_shelf").0
        for id in [
            "product.amount.price",
            "product.amount.before",
            "product.amount.coupon",
            "product.amount.rebate.min",
            "product.amount.rebate.max",
            "product.amount.estNet",
            "product.rebateTag",
            "product.benefitTags",
            "product.disclaimer",
            "product.compareReason",
        ] {
            XCTAssertNil(page.probes[id], "下架不显示 \(id)（金额、返利、预估返后、优惠标签、口径块整块不显示）")
        }
        let card = try page.probes.rect("product.card")
        let capsule = try page.probes.rect("product.offShelf")
        let title = try page.probes.rect("product.title")
        assertInside(capsule, card, "「商品已下架」胶囊在价格大卡内")
        XCTAssertLessThanOrEqual(capsule.minY - card.minY, 16.5, "胶囊在卡片顶部（内边距 16）")
        XCTAssertLessThan(capsule.maxY, title.minY, "胶囊在来源 + 标题之上")
        XCTAssertNil(page.probes["product.offShelf.searchSimilar"], "【搜相似商品】等 APP-SIM（G-D06），本任务不画")
    }

    func testOffShelfHeroIsDesaturatedLightAndDark() async throws {
        for dark in [false, true] {
            let (normal, normalImage) = try await open("tb_coupon_range", canvas: .init(dark: dark))
            let normalHero = try normal.probes.rect("product.hero").insetBy(dx: 2, dy: 2)
            XCTAssertGreaterThan(ProductVisualPixels(normalImage).count(in: normalHero) { $0.saturation > 0.5 }, 5000,
                                 "前提：正常态头图有彩色（dark=\(dark)）")
            let (page, image) = try await open("tb_off_shelf", canvas: .init(dark: dark))
            let hero = try page.probes.rect("product.hero").insetBy(dx: 2, dy: 2)
            let pixels = ProductVisualPixels(image)
            let placeholder = pixels.color(at: CGPoint(x: hero.midX, y: hero.minY + 3))
            XCTAssertGreaterThan(pixels.count(in: hero) { !$0.near(placeholder, tolerance: 24) }, 2000,
                                 "下架头图仍画出商品图（只是去色，dark=\(dark)）")
            XCTAssertLessThanOrEqual(ProductVisualJudge.saturatedCount(pixels, in: hero), 30,
                                     "下架头图饱和度 0（不是加半透明蒙层，dark=\(dark)）")
        }
    }

    // MARK: - 推广角标（G-D04，BR-TEXT-17）

    func testAdLabelIsVerbatimAtHeroTopLeft8AndNullDrawsNothing() async throws {
        let plain = try await open("tb_coupon_range").0
        XCTAssertNotNil(plain.probes["product.hero"], "前提：头图有测量")
        XCTAssertNil(plain.probes["product.adLabel"], "ad_label 为 null 不画角标、不补「推广」")

        let page = try await open("ad_label").0
        let hero = try page.probes.rect("product.hero")
        let label = try XCTUnwrap(page.probes["product.adLabel"], "ad_label 非 null 必须原样角标")
        XCTAssertEqual(label.text, "广告 · 平台原文", "原样显示，不 trim、不换字、不写死「推广」")
        assertNear(label.rect.minX - hero.minX, 8, 1, "角标距头图左 8")
        assertNear(label.rect.minY - hero.minY, 8, 1, "角标距头图上 8")
        assertInside(label.rect, hero, "角标在头图内")
    }

    // MARK: - 比价无返利原因行（§2.3，ProductPriceCompareCancelled-v2）

    func testCompareReasonSitsInCardAtRebatePositionWith32VisualRowAnd44Hit() async throws {
        let gone = try await open("tb_rebate_gone").0
        XCTAssertNotNil(gone.probes["product.rebateTag"], "前提：零返利卡显示「暂无返利」灰标签")
        XCTAssertNil(gone.probes["product.compareReason"], "非比价卡没有原因行")

        let page = try await open("pdd_price_compare", statuses: ["pdd": "on"]).0
        let card = try page.probes.rect("product.card")
        let row = try page.probes.rect("product.compareReason")
        let capsule = try page.probes.rect("product.compareReason.capsule")
        let similar = try page.probes.rect("product.similar")
        let price = try page.probes.rect("product.amount.price")
        let title = try page.probes.rect("product.title")
        assertInside(row, card, "原因行在价格大卡内（去掉卡外独立行）")
        XCTAssertLessThanOrEqual(price.maxY, row.minY + 0.5, "原因行在主价之下（返利标签的位置）")
        XCTAssertLessThanOrEqual(row.maxY, title.minY + 0.5, "原因行在来源 + 标题之上")
        XCTAssertNil(page.probes["product.rebateTag"], "原因行替代返利标签，不再另画「暂无返利」")
        assertNear(capsule.height, 32, 2, "灰胶囊高 32（画板 height: 32px）")
        assertNear(row.height, 32, 2, "视觉行高 32：44 命中区不得撑高行（Android 评审 r1 S2-1）")
        XCTAssertGreaterThanOrEqual(similar.width, 44 - 0.01, "【看看相似商品】命中宽 ≥ 44")
        XCTAssertGreaterThanOrEqual(similar.height, 44 - 0.01, "【看看相似商品】命中高 ≥ 44")
        assertNear(similar.midY, row.midY, 2, "命中区上下对称扩展，文字与胶囊同一行居中")
        XCTAssertGreaterThanOrEqual(similar.minX, capsule.maxX - 0.5, "命中区不压在胶囊上")
        for other in ["product.askAI", "product.buy"] {
            if let rect = page.probes[other]?.rect {
                assertDisjoint(similar, rect, "【看看相似商品】命中区与 \(other) 不重叠")
            }
        }
    }

    // MARK: - 口径块（§2.5：入账说明行是钟表图标）

    func testDisclaimerLinesUseInfoAndCreditLineDrawsClock() async throws {
        for (id, dark, count) in [("tb_coupon_range", false, 2), ("jd_no_coupon_single", false, 3),
                                  ("tb_coupon_range", true, 2)] {
            let (page, image) = try await open(id, canvas: .init(dark: dark))
            let icons = page.probes.ids(prefix: "product.disclaimer.icon.")
            XCTAssertEqual(icons.count, count, "\(id)：口径块每行左侧一个图标（price_basis…+ 入账说明）")
            guard icons.count == count else { continue }
            let pixels = ProductVisualPixels(image)
            let background = ProductVisualPixels.RGB(CouliColor.backgroundMuted, dark: dark)
            for (index, icon) in icons.enumerated() {
                let rect = try page.probes.rect(icon)
                assertNear(rect.width, 16, 1, "\(id)：口径行图标 16")
                let actual = ProductVisualIconProbe.ink(pixels, in: rect, background: background)
                let refs = await ProductVisualIconProbe.references(size: rect.size, dark: dark)
                let clock = refs[.clock] ?? []
                let info = refs[.info] ?? []
                let toClock = ProductVisualIconProbe.difference(actual, clock)
                let toInfo = ProductVisualIconProbe.difference(actual, info)
                let last = index == count - 1
                XCTAssertTrue(last ? toClock < toInfo : toInfo < toClock,
                              "\(id) 第 \(index) 行应画 \(last ? "钟表（入账说明）" : "i（口径句）")：离钟表 \(toClock)，离 i \(toInfo)")
            }
        }
    }

    func testZeroRebateKeepsPriceBasisLineButNoCreditLine() async throws {
        let page = try await open("tb_rebate_gone").0
        XCTAssertNotNil(page.probes["product.disclaimer"], "零返利仍常驻口径句（BR-PRICE-03 详情常驻全文）")
        XCTAssertEqual(page.probes.ids(prefix: "product.disclaimer.icon.").count, 1,
                       "零返利不显示入账说明（APP-06a 入账规则优先于画板样例，fixture notes）")
    }
}
