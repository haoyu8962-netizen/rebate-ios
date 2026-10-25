@testable import Couli
import DesignSystem
import Foundation
import SwiftUI
import UIKit
import XCTest

/// APP-06v-a 底栏、加载骨架与适配（§2.6、§2.7、§4.4、§4.5，G-D13）。
@MainActor
final class ProductVisualAdaptTests: ProductVisualTestCase {
    // MARK: - 底栏（§2.6，GUIDE §7.2）

    func testBottomBarEntryIconAboveTextAndPaddingFollowsSafeArea() async throws {
        for bottom: CGFloat in [34, 0] {
            let page = try await open("tb_coupon_range", canvas: .init(bottom: bottom)).0
            let bar = try page.probes.rect("product.bottomBar")
            let content = try page.probes.rect("product.bottomBar.content")
            assertNear(bar.minX, 0, 0.5, "底栏白底铺满整宽（左）")
            assertNear(bar.width, 390, 0.5, "底栏白底铺满整宽")
            assertNear(bar.maxY, 956, 0.5, "底栏白底到窗口底（含安全区）")
            assertNear(content.minX - bar.minX, 16, 1, "底栏左内边距 16")
            assertNear(bar.maxX - content.maxX, 16, 1, "底栏右内边距 16")
            assertNear(content.minY - bar.minY, 12, 1.5, "底栏上内边距 12（含 1 分隔线）")
            assertNear(bar.maxY - content.maxY, max(bottom, 16), 1, "底栏下内边距 = max(安全区, 16)")

            let ask = try page.probes.rect("product.askAI")
            let icon = try page.probes.rect("product.askAI.icon")
            let label = try XCTUnwrap(page.probes["product.askAI.label"], "缺 product.askAI.label")
            XCTAssertGreaterThanOrEqual(ask.width, 44 - 0.01, "【问问 AI】命中宽 ≥ 44")
            XCTAssertGreaterThanOrEqual(ask.height, 44 - 0.01, "【问问 AI】命中高 ≥ 44")
            assertNear(icon.width, 24, 1, "【问问 AI】图标 24（不是文字按钮）")
            assertNear(label.fontSize, 12, 0.5, "【问问 AI】文字 12（caption）")
            XCTAssertLessThanOrEqual(icon.maxY, label.rect.minY + 0.5, "图标在上、文字在下（竖排入口）")
            assertInside(icon, ask, "图标在入口命中区内")
            assertInside(label.rect, ask, "文字在入口命中区内")

            let buy = try page.probes.rect("product.buy")
            XCTAssertGreaterThanOrEqual(buy.height, 48 - 0.5, "主按钮最小高 48")
            XCTAssertGreaterThanOrEqual(buy.minX, ask.maxX - 0.5, "主按钮在入口右侧")
            assertNear(buy.maxX, content.maxX, 0.5, "主按钮占余宽到右内边距")
            assertDisjoint(ask, buy, "入口与主按钮命中区不重叠")
        }
    }

    func testOutOfScopeControlsAreNotDrawn() async throws {
        let page = try await open("tb_coupon_range").0
        XCTAssertNotNil(page.probes["product.askAI"], "前提：底栏测量已上报")
        for id in ["product.favorite", "product.priceTrend", "product.share", "product.searchSimilar"] {
            XCTAssertNil(page.probes[id], "\(id) 不在本任务（G-D01 / G-D02 / G-D06），不放点了没反应的假控件")
        }
        XCTAssertEqual(AppStubProtocol.requests.filter { $0.path.hasPrefix("/v1/products/") }.count, 1,
                       "只发一次 getProduct；不请求价格走势")
    }

    // MARK: - 大屏（§4.5）

    func testWideScreenCentersContentAndBottomBarAt600WithFullWidthSurface() async throws {
        let page = try await open("tb_coupon_range", canvas: .init(width: 840)).0
        let column = try page.probes.rect("product.content")
        let bar = try page.probes.rect("product.bottomBar")
        let barContent = try page.probes.rect("product.bottomBar.content")
        XCTAssertLessThanOrEqual(column.width, 600 + 0.5, "内容区限宽 600")
        assertNear(column.midX, 420, 1, "内容区水平居中")
        XCTAssertLessThanOrEqual(barContent.width, 600 + 0.5, "底栏内容限宽 600")
        assertNear(barContent.midX, 420, 1, "底栏内容居中")
        assertNear(bar.width, 840, 0.5, "底栏白底铺满 840 整宽")
        let hero = try page.probes.rect("product.hero")
        assertInside(hero, column, "头图在 600 列内")
    }

    // MARK: - 内容列与卡片不越出屏幕（v2，实现交回 T1 / 变异 M4）

    /// 金额「在卡内」不够：超长金额若不退档，会把价格大卡和内容列一起撑宽越出屏幕，金额仍在卡内（M4 漏网）。
    /// 这里直接锁住列与卡的外框：窄屏左右各留 16、不越窗口；宽屏 600 限宽且左右留白相等；卡、头图、金额段都在列内。
    func testColumnAndCardStayOnScreenWith16MarginsNarrowMaxTextAndWide() async throws {
        let cases: [(String, ProductVisualHost.Canvas)] = [
            ("long_amount", .init(width: 320, size: .accessibility5)),
            ("long_amount", .init(width: 320, size: .accessibility3)),
            ("tb_coupon_range", .init(width: 320, size: .accessibility5)),
            ("tb_coupon_range", .init(width: 840)),
            ("long_amount", .init(width: 840, size: .accessibility5)),
        ]
        for (id, canvas) in cases {
            let page = try await open(id, canvas: canvas).0
            try assertOnScreen(page, canvas: canvas, name: "\(id)@\(Int(canvas.width))/\(canvas.size)")
        }
    }

    /// 评审 r1 S1-1：退档不能取决于金额字形宽度的小数位（自确认回路）。按与页面同一字体（系统等宽数字粗体、largeTitle 曲线）
    /// 在最大字号下量候选金额的单行宽，挑出「小数部分 ≥ 0.5」与「最贴近整数」两种、且都超出可用宽的超长主价，各开一页验证不越界、不截断。
    func testExtremeAmountsStayOnScreenWhateverTheWidthFractionAtMaxText() async throws {
        let canvas = ProductVisualHost.Canvas(width: 320, size: .accessibility5)
        let picks = try Self.extremePrices(available: canvas.width - 64)
        XCTAssertNotNil(picks.half, "候选里要有单行宽小数部分 ≥ 0.5 的超长金额：\(picks.log)")
        XCTAssertNotNil(picks.whole, "候选里要有单行宽贴近整数（小数 < 0.1）的超长金额：\(picks.log)")
        XCTContext.runActivity(named: "候选金额宽度") { $0.add(XCTAttachment(string: picks.log)) }
        for fen in [picks.half, picks.whole].compactMap(\.self) {
            var card = try ProductVisualCards.card("long_amount")
            card["price_fen"] = fen
            card["final_price_fen"] = fen
            card["coupon_fen"] = 0
            card["est_net_price_fen"] = fen - 100
            let page = try await open(card: ProductVisualCards.today(card), canvas: canvas).0
            let price = try XCTUnwrap(page.probes["product.amount.price"], "缺主价测量")
            XCTAssertEqual(price.text, CouliFormat.money(fen: Int64(fen)), "主价就是这张卡的超长金额")
            try assertOnScreen(page, canvas: canvas, name: "主价 \(price.text)@320/AX5")
        }
    }

    // MARK: - 200% 字号（§4.4，G-D13）

    func testLargeTextAmountsAreWholeInsideCardAt390And320() async throws {
        for (id, width) in [("tb_coupon_range", CGFloat(390)), ("tb_coupon_range", 320), ("long_amount", 320)] {
            let page = try await open(id, canvas: .init(width: width, size: .accessibility3)).0
            let card = try page.probes.rect("product.card")
            let parts = page.probes.records.values.filter { $0.role == "amount-part" }
            let expected = id == "long_amount"
                ? [
                    "product.amount.price",
                    "product.amount.rebate.min",
                    "product.amount.rebate.max",
                    "product.amount.estNet",
                ]
                : [
                    "product.amount.price",
                    "product.amount.before",
                    "product.amount.coupon",
                    "product.amount.rebate.min",
                    "product.amount.rebate.max",
                    "product.amount.estNet",
                ]
            XCTAssertEqual(Set(parts.map(\.id)).intersection(expected).count, expected.count,
                           "\(id)@\(width)：金额段都要上报（\(expected)），实际 \(parts.map(\.id).sorted())")
            for part in parts {
                XCTAssertGreaterThan(part.naturalWidth, 0, "\(part.id)：须上报无约束自然宽度")
                XCTAssertGreaterThanOrEqual(part.rect.width, part.naturalWidth - 0.5,
                                            "\(id)@\(width) \(part.id)「\(part.text)」被截断或压缩")
                XCTAssertGreaterThan(part.fontSize, part.baseFontSize, "\(part.id)：字号随系统放大，不缩字")
                assertInside(part.rect, card, "\(id)@\(width) \(part.id) 在卡内（不越出卡片）")
            }
            for (lhs, rhs) in pairs(parts) {
                assertDisjoint(lhs.rect, rhs.rect, "\(id)@\(width) \(lhs.id) 与 \(rhs.id) 不重叠")
            }
        }
    }

    func testLargeTextBottomBarStaysOneRowOnlyWhenButtonTextFitsOneLine() async throws {
        let cases = [
            BarCase(id: "tb_coupon_range", width: 390, twoRows: false), BarCase(id: "tb_coupon_range", width: 320),
            BarCase(id: "jd_no_coupon_single", width: 390), BarCase(
                id: "jd_no_coupon_single",
                width: 320,
                twoRows: true
            ),
        ]
        for item in cases {
            let (id, width, twoRows) = (item.id, item.width, item.twoRows)
            let page = try await open(id, canvas: .init(width: width, size: .accessibility3)).0
            let content = try page.probes.rect("product.bottomBar.content")
            let ask = try page.probes.rect("product.askAI")
            let buy = try page.probes.rect("product.buy")
            let label = try XCTUnwrap(page.probes["product.buy.label"], "缺 product.buy.label")
            let lineHeight = label.fontSize * 1.1
            let lines = max(1, Int(ceil(label.naturalWidth / max(label.rect.width, 1) - 0.01)))
            XCTAssertGreaterThanOrEqual(label.rect.height, CGFloat(lines) * lineHeight - 1,
                                        "\(id)@\(width) 按钮字「\(label.text)」被截断：需 \(lines) 行，实际高 \(label.rect.height)")
            assertInside(label.rect, buy, "\(id)@\(width) 按钮字在按钮内")
            XCTAssertGreaterThan(label.fontSize, label.baseFontSize, "按钮字随系统放大")
            if sameRow(ask, buy) {
                XCTAssertLessThan(label.rect.height, lineHeight * 1.5,
                                  "\(id)@\(width)：一行放不下时须改两行（G-D13），不能在同一行里把按钮字折行")
                XCTAssertNotEqual(twoRows, true, "\(id)@\(width)：「\(label.text)」在 200% 下应改两行")
            } else {
                XCTAssertGreaterThanOrEqual(buy.minY, ask.maxY - 0.5, "两行时：上行入口、下行主按钮")
                assertNear(ask.minX, content.minX, 1, "两行时入口左对齐")
                XCTAssertGreaterThanOrEqual(buy.width, content.width - 1, "两行时主按钮通栏")
                XCTAssertNotEqual(twoRows, false, "\(id)@\(width)：「\(label.text)」放得下时不改两行")
            }
            XCTAssertLessThanOrEqual(buy.maxY, 956 - 34 + 0.5, "主按钮在安全区之上、可点")
        }
    }

    // MARK: - 加载骨架（§2.7）

    func testLoadingSkeletonFollowsRealLayoutWithoutAmounts() async throws {
        let page = try await openState(.hold).0
        let hero = try page.probes.rect("product.skeleton.hero")
        let card = try page.probes.rect("product.skeleton.card")
        assertNear(hero.width, 358, 0.5, "骨架头图块同宽")
        assertNear(hero.height, hero.width * ProductVisualLayoutTests.heroRatio, 1, "骨架头图块同比例")
        let inner = card.width - 32
        assertNear(try page.probes.rect("product.skeleton.price").width, inner * 0.4, 2, "价格行 40%")
        assertNear(try page.probes.rect("product.skeleton.title1").width, inner, 2, "标题第一行 100%")
        assertNear(try page.probes.rect("product.skeleton.title2").width, inner * 0.7, 2, "标题第二行 70%")
        for id in ["product.skeleton.price", "product.skeleton.rebate", "product.skeleton.title1",
                   "product.skeleton.title2"] {
            assertInside(try page.probes.rect(id), card, "\(id) 在骨架价格卡内")
        }
        assertInside(try page.probes.rect("product.skeleton.button"), try page.probes.rect("product.bottomBar"),
                     "骨架按钮块在底栏内")
        XCTAssertTrue(page.probes.records.values.filter { $0.role == "amount-part" }.isEmpty, "加载中不画金额占位字")
    }

    /// 200% 底栏用例：`twoRows` 为 nil 时只按「同一行则按钮字不折行」的规则判定。
    private struct BarCase {
        let id: String
        let width: CGFloat
        var twoRows: Bool?
    }

    private func pairs(_ items: [CouliLayoutProbeRecord]) -> [(CouliLayoutProbeRecord, CouliLayoutProbeRecord)] {
        let sorted = items.sorted { $0.id < $1.id }
        var result: [(CouliLayoutProbeRecord, CouliLayoutProbeRecord)] = []
        for index in sorted.indices {
            for other in sorted.indices where other > index {
                result.append((sorted[index], sorted[other]))
            }
        }
        return result
    }
}
