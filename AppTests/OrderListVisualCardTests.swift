@testable import Couli
import DesignSystem
import Foundation
import OrderCore
import Orders
import SwiftUI
import UIKit
import XCTest

/// APP-08v-a 订单卡（brief §2.2；O9–O14；G-O02 资金红线、G21 金额隐藏、Android a r1 S2-2 / M10 复制位置）。
@MainActor
final class OrderListVisualCardTests: OrderVisualTestCase {
    private let tall = OrderVisualHost.Canvas(height: 1740)
    private let ids = ["A", "B", "M", "C", "J"]

    // MARK: - 卡片（O9–O14）

    /// 头行：来源徽标左、付款时间 12 右对齐到卡片内容右缘（卡片内边距 16）。
    func testCardHeaderTimeIsRightAligned() async throws {
        try await openList(listScript(), canvas: tall)
        for id in ids {
            let card = try rect("order.card.\(id)")
            let time = try rect("order.card.\(id).time")
            let badge = try rect("order.card.\(id).badge")
            try assertFont("order.card.\(id).time", base: 12, "卡 \(id) 付款时间")
            assertNear(time.maxX, card.maxX - 16, 1, "卡 \(id) 时间右对齐（不再紧挨徽标）")
            assertNear(badge.minX, card.minX + 16, 1, "卡 \(id) 徽标左对齐")
            XCTAssertTrue(sameRow(time, badge), "卡 \(id) 徽标与时间同一行")
        }
    }

    /// 商品块：64 图左；右列 标题 14 单行 → 件数 12 → 单号 12（单号在右列、不再是独立整行）；分隔线在商品块与金额之间。
    func testCardProductBlockRightColumnAndDivider() async throws {
        let (_, image) = try await openList(listScript(), canvas: tall)
        let pixels = ProductVisualPixels(image)
        for id in ids {
            let card = try rect("order.card.\(id)")
            let picture = try rect("order.card.\(id).image")
            assertNear(picture.width, 64, 0.5, "卡 \(id) 商品图 64")
            assertNear(picture.height, 64, 0.5, "卡 \(id) 商品图 64")
            let title = try record("order.card.\(id).title")
            assertNear(title.baseFontSize, 14, 0.5, "卡 \(id) 标题 14")
            XCTAssertLessThanOrEqual(title.rect.height, title.fontSize * 1.6, "卡 \(id) 标题单行（省略，不折行）")
            let quantity = try rect("order.card.\(id).quantity")
            let number = try rect("order.card.\(id).number")
            try assertFont("order.card.\(id).number", base: 12, "卡 \(id) 单号")
            for (name, column) in [("标题", title.rect), ("件数", quantity), ("单号", number)] {
                XCTAssertGreaterThanOrEqual(column.minX, picture.maxX + 8, "卡 \(id) \(name)在图右侧列")
                assertNear(column.minX, title.rect.minX, 0.5, "卡 \(id) \(name)与标题左对齐（同一列）")
            }
            XCTAssertLessThan(title.rect.maxY, quantity.minY + 0.5, "卡 \(id) 标题 → 件数")
            XCTAssertLessThan(quantity.maxY, number.minY + 0.5, "卡 \(id) 件数 → 单号")
            let divider = try rect("order.card.\(id).divider")
            XCTAssertLessThanOrEqual(divider.height, 1.5, "卡 \(id) 分隔线 1")
            assertNear(divider.width, card.width - 32, 1, "卡 \(id) 分隔线贯穿内容宽")
            XCTAssertGreaterThanOrEqual(divider.minY, max(picture.maxY, number.maxY) - 0.5, "卡 \(id) 分隔线在商品块下")
            let line = pixels.color(at: CGPoint(x: divider.midX, y: divider.midY))
            XCTAssertTrue(line.near(ProductVisualPixels.RGB(CouliColor.borderSubtle, dark: false), tolerance: 14),
                          "卡 \(id) 分隔线是 border.subtle 实线（\(line)），不是留白")
            if let left = host?.probes["order.card.\(id).amount.left"]?.rect {
                XCTAssertGreaterThanOrEqual(left.minY, divider.maxY - 0.5, "卡 \(id) 金额在分隔线下")
            }
        }
    }

    /// 【复制】紧跟单号文字（短单号同一行，按实际墨迹末端算间距 0–16，盒子撑满推到行尾也会被拦下——Android a M10）；
    /// 命中 ≥ 44 包住文字；分享单没有【复制】。
    func testCopyFollowsNumberInkAndShareHasNoCopy() async throws {
        let (_, image) = try await openList(listScript(), canvas: tall)
        let pixels = ProductVisualPixels(image)
        let surface = ProductVisualPixels.RGB(CouliColor.backgroundSurface, dark: false)
        for id in ids {
            let number = try rect("order.card.\(id).number")
            let label = try rect("order.card.\(id).copy.label")
            let hit = try rect("order.card.\(id).copy")
            try assertFont("order.card.\(id).copy.label", base: 12, "卡 \(id) 复制")
            assertHit(hit, covers: label, "卡 \(id) 复制")
            XCTAssertTrue(sameRow(number, label), "卡 \(id) 短单号与复制同一行")
            let band = CGRect(x: number.minX, y: number.minY, width: max(0, label.minX - number.minX - 0.5),
                              height: number.height)
            let ink = try XCTUnwrap(inkRight(pixels, in: band, background: surface), "卡 \(id) 单号没有墨迹")
            let gap = label.minX - ink
            XCTAssertGreaterThanOrEqual(gap, 0, "卡 \(id) 复制不压单号")
            XCTAssertLessThanOrEqual(gap, 16, "卡 \(id) 复制紧随单号文字末端（实际间距 \(gap)）")
        }
        try await openList(listScript(), scope: "share", waitFor: "order.card.E", images: [])
        XCTAssertNotNil(host?.probes["order.card.E.number"], "前提：分享单脱敏号在")
        for id in ["E", "OTHER", "F", "G"] {
            XCTAssertNil(host?.probes["order.card.\(id).copy"], "分享单 \(id) 没有【复制】")
        }
    }

    /// 金额格：列表左实付右返利（G-O07 只改详情），数值 17；PAID 单值不造区间（G-O02）。
    func testListAmountsPaidLeftRebateRightAt17() async throws {
        let (_, image) = try await openList(listScript(), canvas: tall)
        let surface = ProductVisualPixels.RGB(CouliColor.backgroundSurface, dark: false)
        try assertAmountInkFillsFrame("order.card.A.amount.left", image: image, background: surface, "A 实付字形完整")
        try assertAmountInkFillsFrame("order.card.A.amount.right", image: image, background: surface, "A 预估返字形完整")
        let left = try record("order.card.A.amount.left")
        let right = try record("order.card.A.amount.right")
        XCTAssertEqual(left.text, OrderVisualData.money(4560), "A 左格实付")
        XCTAssertEqual(right.text, OrderVisualData.money(123), "A 右格预估返单值")
        XCTAssertFalse(right.text.contains("–") || right.text.contains("-"), "PAID 不造区间（G-O02）")
        XCTAssertLessThan(left.rect.minX, right.rect.minX, "列表左实付、右返利")
        assertNear(left.baseFontSize, 17, 0.5, "金额 17")
        assertNear(right.baseFontSize, 17, 0.5, "金额 17")
        XCTAssertEqual(try record("order.card.B.amount.left").text, OrderVisualData.money(3000), "B 已付定金")
    }

    /// 资金红线：null 不补 0；UNKNOWN 不显示返利；已结算 / 推广收益无字段只标签（G-O02）；INVALID 不显示 est；非零 est 哨兵不泄漏。
    func testAmountsAreNeverInventedFromOtherFields() async throws {
        try await openList(listScript(), canvas: tall)
        XCTAssertNotNil(host?.probes["order.card.A.amount.right"], "前提：普通 PAID 卡有返利格测量")
        let texts = host?.probes.records.values.map(\.text) ?? []
        for sentinel: Int64 in [987_654, 765_432] {
            XCTAssertFalse(texts.contains(OrderVisualData.money(sentinel)), "est 哨兵 \(sentinel) 不得显示")
        }
        XCTAssertNil(host?.probes["order.card.M.amount.right"], "未知状态不显示返利金额")
        XCTAssertEqual(try record("order.card.M.amount.left").text, OrderVisualData.money(1990), "未知状态仍显示实付")

        // v2（实现交回 T1）：分享列表 4 张卡，G 在 844 画布之外，列表按需建行不会创建它；与 OrdersShare-v2 画板同高 1492
        try await openList(listScript(), scope: "share", canvas: .init(height: 1492), waitFor: "order.card.G",
                           images: [])
        for id in ["F", "G"] {
            let value = host?.probes["order.card.\(id).amount.right"]?.text ?? ""
            XCTAssertFalse(value.contains("¥"), "卡 \(id) 推广收益无字段：只显示标签，不显示金额（G-O02），实际「\(value)」")
            XCTAssertNotNil(host?.probes["order.card.\(id).amount.right.label"], "卡 \(id) 推广收益标签仍在")
        }

        var script = try listScript()
        script.pages["self"] = try .data(OrderVisualData.page("null_amounts"))
        try await openList(script, waitFor: "order.card.NULL", images: [])
        for side in ["left", "right"] {
            let value = host?.probes["order.card.NULL.amount.\(side)"]?.text ?? ""
            XCTAssertFalse(value.contains("¥0") || value == "0", "null 金额不补 0（\(side)：\(value)）")
        }
    }

    /// 金额隐藏：先确认可见，再隐藏——返利类「****」（不带 ¥、位数、正负号），实付 / 定金照常（G21）。
    func testHiddenMasksRebateOnlyKeepsPaidAndDeposit() async throws {
        try await openList(listScript(), canvas: tall)
        XCTAssertEqual(try record("order.card.A.amount.right").text, OrderVisualData.money(123), "前提：未隐藏时可见")
        try await openList(listScript(), canvas: tall, hidden: true)
        XCTAssertEqual(try record("order.card.A.amount.right").text, "****", "返利类隐藏为 ****")
        XCTAssertEqual(try record("order.card.C.amount.right").text, "****")
        XCTAssertEqual(try record("order.card.A.amount.left").text, OrderVisualData.money(4560), "实付不隐藏")
        XCTAssertEqual(try record("order.card.B.amount.left").text, OrderVisualData.money(3000), "已付定金不隐藏")
        let texts = host?.probes.records.values.map(\.text) ?? []
        XCTAssertFalse(texts.contains(OrderVisualData.money(123)), "隐藏后不得再画出原返利")
    }

    /// 状态胶囊（12 态逐个）：单独一行、高 22（随字号增高）；中性次要底 / 已结算松叶绿底；图标按状态
    /// （预估类钟表、INVALID / UNKNOWN / NO_REBATE 用 i、CLAWED_BACK 警告三角、已结算对勾），像素墨迹比对。
    func testStatusPillShapeColorAndIconPerStatus() async throws {
        let icons: [String: String] = [
            "DEPOSIT_PAID": "clock", "PAID": "clock", "WAITING": "clock", "CREDITING": "clock",
            "RIGHTS_PENDING": "clock", "REVIEWING": "clock", "NO_REBATE": "info.circle", "INVALID": "info.circle",
            "FUTURE_STATUS": "info.circle", "CLAWED_BACK": "exclamationmark.triangle",
            "CREDITED": "checkmark.circle", "CREDITED_PART_CLAWED": "checkmark.circle",
        ]
        let candidates = ["clock", "info.circle", "exclamationmark.triangle", "checkmark.circle"]
        for status in icons.keys.sorted() {
            let page = try OrderVisualData.statusPage(status)
            let id = try XCTUnwrap(OrderVisualData.items(page).first?["order_id"] as? String)
            var script = try listScript()
            script.pages["self"] = .data(page)
            let (_, image) = try await openList(script, waitFor: "order.card.\(id).status", images: [])
            let pill = try rect("order.card.\(id).status")
            assertNear(pill.height, 22, 1, "\(status) 胶囊高 22")
            if let amount = host?.probes["order.card.\(id).amount.left"]?.rect {
                XCTAssertGreaterThanOrEqual(pill.minY, amount.maxY - 0.5, "\(status) 胶囊单独一行（在金额下）")
            }
            let pixels = ProductVisualPixels(image)
            let fill = pixels.color(at: CGPoint(x: pill.maxX - 5, y: pill.midY))
            let success = status.hasPrefix("CREDITED")
            if success {
                XCTAssertGreaterThan(fill.green, fill.red + 8, "\(status) 已结算松叶绿底（\(fill)）")
            } else {
                XCTAssertTrue(fill.near(ProductVisualPixels.RGB(CouliColor.backgroundMuted, dark: false), tolerance: 6),
                              "\(status) 中性胶囊 background.muted 底（\(fill)）")
            }
            let iconRect = try rect("order.card.\(id).status.icon")
            assertNear(iconRect.width, 14, 1, "\(status) 胶囊图标 14")
            let nearest = await nearestIcon(
                image, in: iconRect, candidates: candidates,
                background: Color(uiColor: UIColor(red: CGFloat(fill.red) / 255, green: CGFloat(fill.green) / 255,
                                                   blue: CGFloat(fill.blue) / 255, alpha: 1)), dark: false
            )
            XCTAssertEqual(nearest, icons[status], "\(status) 胶囊图标")
        }
    }

    /// 占位图：普通无图仍「商品图」；分享单其他商品为文档图标占位，不写「商品图」（brief-android O14）。
    func testOtherProductPlaceholderIsDocumentIcon() async throws {
        let (_, image) = try await openList(listScript(), scope: "share", waitFor: "order.card.OTHER", images: [])
        XCTAssertEqual(host?.probes["order.card.F.placeholder"]?.text, "商品图", "前提：普通无图占位写「商品图」")
        XCTAssertNil(host?.probes["order.card.OTHER.placeholder"], "其他商品不写「商品图」")
        let icon = try rect("order.card.OTHER.placeholderIcon")
        assertInside(icon, try rect("order.card.OTHER.image"), "文档图标在 64 占位块内")
        let nearest = await nearestIcon(
            image, in: icon, candidates: ["doc.text", "photo", "questionmark.circle"],
            background: CouliColor.backgroundPlaceholder, dark: false
        )
        XCTAssertEqual(nearest, "doc.text", "其他商品占位为文档图标")
    }
}
