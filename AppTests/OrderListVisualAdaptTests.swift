@testable import Couli
import DesignSystem
import Foundation
import Orders
import SwiftUI
import UIKit
import XCTest

/// APP-08v-a 列表适配（brief §2.6、§4.5、§4.6；§9 风险 4、5、7）：200%（AX3）× 390 / 320 压力值、840 大屏统一 600 列、
/// 窄屏大字号筛选行与眼睛（APP-08 共性第 11 条）。裁切判据同时比尺寸与位置（APP-06v-a r2）。
@MainActor
final class OrderListVisualAdaptTests: OrderVisualTestCase {
    private func stressScript() throws -> OrderVisualStub.Script {
        var script = try listScript()
        script.pages["self"] = try .data(OrderVisualData.page("stress"))
        return script
    }

    /// 200% × 390 / 320：长金额 ¥88888.88 / ¥99999.99 不缩不裁、纵排返利在上；19 位单号完整、在卡内；标题仍单行；胶囊随字号增高。
    func testFont200StressAmountsNumberAndPill() async throws {
        for width: CGFloat in [390, 320] {
            let canvas = OrderVisualHost.Canvas(width: width, height: 1200, size: .accessibility3)
            let (_, image) = try await openList(stressScript(), canvas: canvas,
                                                waitFor: "order.card.STRESS.amount.left", images: [])
            let surface = ProductVisualPixels.RGB(CouliColor.backgroundSurface, dark: false)
            let card = try rect("order.card.STRESS")
            let content = try rect("orders.content")
            assertNear(card.minX, content.minX + 16, 1, "\(width)：卡片左边距 16")
            assertNear(card.maxX, content.maxX - 16, 1, "\(width)：卡片右边距 16（没被金额撑宽）")
            try assertWholeAmount("order.card.STRESS.amount.left", inside: card, "\(width)：实付 ¥88888.88")
            try assertWholeAmount("order.card.STRESS.amount.right", inside: card, "\(width)：预估返 ¥99999.99")
            try assertAmountInkFillsFrame("order.card.STRESS.amount.left", image: image, background: surface,
                                          "\(width)：实付字形没被父级裁切")
            try assertAmountInkFillsFrame("order.card.STRESS.amount.right", image: image, background: surface,
                                          "\(width)：预估返字形没被父级裁切")
            let left = try record("order.card.STRESS.amount.left")
            let right = try record("order.card.STRESS.amount.right")
            XCTAssertEqual(left.text, OrderVisualData.money(8_888_888))
            XCTAssertEqual(right.text, OrderVisualData.money(9_999_999))
            XCTAssertGreaterThan(left.fontSize, left.baseFontSize, "\(width)：金额随字号放大（真 200%）")
            XCTAssertLessThanOrEqual(right.rect.maxY, left.rect.minY + 0.5, "\(width)：纵排时返利在上")
            let number = try rect("order.card.STRESS.number")
            assertInside(number, card, "\(width)：19 位单号整段在卡内")
            let title = try record("order.card.STRESS.title")
            XCTAssertLessThanOrEqual(title.rect.height, title.fontSize * 1.6, "\(width)：商品标题单行省略（唯一允许省略）")
            let pill = try record("order.card.STRESS.status.label")
            let pillRect = try rect("order.card.STRESS.status")
            XCTAssertGreaterThan(pill.fontSize, pill.baseFontSize, "\(width)：胶囊文字随字号放大")
            XCTAssertGreaterThanOrEqual(pillRect.height + 0.5, pill.rect.height, "\(width)：胶囊增高不裁字")
            assertInside(pill.rect, pillRect, "\(width)：胶囊文字在胶囊内")
        }
    }

    /// 长单号折行后【复制】不停在多行中部（Android a r1 S2-2）：要么跟在单号末行文字之后（同一末行，墨迹间距 0–16），
    /// 要么整体换到下一行、回到单号列起点；且【复制】是单行整体、命中 ≥ 44。
    func testFont200MultilineNumberCopyFollowsLastLineOrWrapsWhole() async throws {
        let canvas = OrderVisualHost.Canvas(width: 320, height: 1200, size: .accessibility3)
        let (_, image) = try await openList(stressScript(), canvas: canvas, waitFor: "order.card.STRESS.copy",
                                            images: [])
        let number = try record("order.card.STRESS.number")
        let label = try record("order.card.STRESS.copy.label")
        let hit = try rect("order.card.STRESS.copy")
        assertHit(hit, covers: label.rect, "复制")
        let lineHeight = UIFont.systemFont(ofSize: number.fontSize).lineHeight
        XCTAssertGreaterThan(number.rect.height, lineHeight * 1.5, "前提：320 × 200% 下 19 位单号确实折成多行")
        XCTAssertLessThanOrEqual(label.rect.height, UIFont.systemFont(ofSize: label.fontSize).lineHeight * 1.5,
                                 "复制是单行整体")
        let wrapped = label.rect.minY >= number.rect.maxY - 0.5
        if wrapped {
            assertNear(label.rect.minX, number.rect.minX, 1, "整体换行时回到单号列起点")
        } else {
            let lastLine = CGRect(x: number.rect.minX, y: number.rect.maxY - lineHeight,
                                  width: max(0, label.rect.minX - number.rect.minX - 0.5), height: lineHeight)
            XCTAssertTrue(sameRow(label.rect, lastLine), "复制与单号末行同一行（不在多行中部）")
            XCTAssertGreaterThanOrEqual(label.rect.midY, number.rect.maxY - lineHeight, "复制不在多行中部")
            let surface = ProductVisualPixels.RGB(CouliColor.backgroundSurface, dark: false)
            let ink = try XCTUnwrap(inkRight(ProductVisualPixels(image), in: lastLine, background: surface),
                                    "单号末行没有墨迹")
            XCTAssertLessThanOrEqual(label.rect.minX - ink, 16, "复制紧随末行文字末端")
        }
    }

    /// 320 × 200% 已选长筛选值（「拼多多」「2026 年 10 月」）：两个筛选与眼睛命中区不重叠、眼睛完整在内容列内（共性第 11 条）。
    func testFont200NarrowFiltersAndEyeKeepFullTargets() async throws {
        var script = try listScript()
        script.pages["self"] = try .data(OrderVisualData.page("month_options"))
        let canvas = OrderVisualHost.Canvas(width: 320, height: 1200, size: .accessibility3)
        let (page, _) = try await openList(script, canvas: canvas)
        let controller = try XCTUnwrap(page.orders.listConfig?.controller)
        _ = controller.setPlatform("pdd")
        _ = await page.stable { _, _ in controller.snapshot.phase != .loading }
        _ = controller.setMonth("2026-10")
        _ = await page
            .stable { host, _ in host.probes["orders.filter.month"] != nil && controller.snapshot.phase != .loading }
        let content = try rect("orders.content")
        let eye = try rect("orders.mask.hit")
        assertInside(eye, content, "眼睛命中区完整在内容列内")
        let targets = try [rect("orders.filter.platform.hit"), rect("orders.filter.month.hit"), eye]
        for (index, lhs) in targets.enumerated() {
            XCTAssertGreaterThanOrEqual(lhs.height, 43.5, "目标 \(index) 命中 ≥ 44")
            for rhs in targets.dropFirst(index + 1) {
                assertDisjoint(lhs, rhs, "筛选 / 眼睛命中区不重叠")
            }
        }
    }

    /// 840 宽：头部、置顶行、提示条、卡片同一 600 列居中（APP-11v-a S2-4）。
    func testWideLayoutUsesOneCenteredColumnForHeaderPinnedAndCards() async throws {
        let canvas = OrderVisualHost.Canvas(width: 840, height: 2075)
        try await openList(listScript(self: "list_self_pinned"), canvas: canvas)
        let content = try rect("orders.content")
        assertNear(content.width, 600, 1, "内容限宽 600")
        assertNear(content.midX, 420, 1, "内容居中")
        for id in ["orders.titleRow", "orders.findPinned", "orders.tabs", "orders.searchBox", "order.card.A",
                   "order.card.J"] {
            assertInside(try rect(id), content, "\(id) 在 600 列内")
        }
        assertNear(try rect("orders.findPinned").width, 568, 1, "置顶行与卡片同宽（600 − 2 × 16）")
        assertNear(try rect("order.card.A").width, 568, 1, "卡片宽 568")

        let page = try fresh(listScript())
        try await page.prepareStale(canvas)
        _ = await page.stable { host, _ in host.probes["orders.stale"] != nil }
        assertInside(try rect("orders.stale"), try rect("orders.content"), "840 下提示条也在 600 列内")
    }

    /// 半屏是独立层：200% 时先断言半屏里的文字确实放大（APP-11v-b S2-4），再看选项完整、行高随字号增高。
    func testFont200SheetTextIsReallyScaled() async throws {
        let canvas = OrderVisualHost.Canvas(width: 390, height: 844, size: .accessibility3)
        let (page, _) = try await openList(listScript(), canvas: canvas)
        page.orders.listConfig?.sheet = .platform
        _ = await page.stable { host, _ in host.probes["orders.sheet.option.taobao.label"] != nil }
        let label = try record("orders.sheet.option.taobao.label")
        XCTAssertGreaterThan(label.fontSize, label.baseFontSize * 1.5, "半屏内字号确为大字号档")
        let row = try rect("orders.sheet.option.taobao")
        assertInside(label.rect, row, "选项文字完整在行内")
    }
}
