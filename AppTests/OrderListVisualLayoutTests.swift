@testable import Couli
import DesignSystem
import Foundation
import OrderCore
import Orders
import SwiftUI
import UIKit
import XCTest

/// APP-08v-a 订单列表的结构 / 几何 / 像素用例（brief §2.1–§2.3、§9；gaps G-O02 / G-O04 / G-O10 / G-O13）。
/// 真实 App 组装（OrderVisualHost）、visualOrders 同一份数据、固定时钟；测量经 §2 测量桥。断言先正后反（APP-06v-a S2-2）。
@MainActor
final class OrderListVisualLayoutTests: OrderVisualTestCase {
    private let tall = OrderVisualHost.Canvas(height: 1740)

    // MARK: - 标题行 / 置顶找回（G-O04）

    /// 不置顶：标题 22、标题行视觉高 44（命中区不撑高，Android a r1 S2-4）、右上「未跟单？去找回」命中 ≥ 44 且包住文字；没有置顶行。
    func testTitleRowIs44WithTopRightFindEntry() async throws {
        try await openList(listScript())
        try assertFont("orders.title", base: 22, "标题「订单」")
        let row = try rect("orders.titleRow")
        assertNear(row.height, 44, 1, "标题行视觉高（右上入口的 44 命中区不能撑高标题行）")
        let hit = try rect("orders.findEntry")
        let label = try rect("orders.findEntry.label")
        assertHit(hit, covers: label, "右上找回入口")
        XCTAssertTrue(sameRow(label, try rect("orders.title")), "找回入口与标题同一行")
        XCTAssertNil(host?.probes["orders.findPinned"], "claim_entry_pinned=false 时不画置顶行")
    }

    /// 置顶（list_self_pinned）：先验不置顶时右上入口在，再验置顶后——整行在标题下、子 Tab 上，与内容列同宽；文字 17、图标 20；
    /// 整行命中 ≥ 44；右上入口不再出现（两者互斥）。
    func testPinnedRowReplacesTopRightEntryBetweenTitleAndTabs() async throws {
        try await openList(listScript())
        XCTAssertNotNil(host?.probes["orders.findEntry"], "前提：不置顶时右上入口存在")

        try await openList(listScript(self: "list_self_pinned"))
        XCTAssertNil(host?.probes["orders.findEntry"], "置顶时右上入口不显示（G-O04）")
        let pinned = try rect("orders.findPinned")
        let title = try rect("orders.titleRow")
        let tabs = try rect("orders.tabs")
        let content = try rect("orders.content")
        XCTAssertGreaterThanOrEqual(pinned.minY, title.maxY - 0.5, "置顶行在标题行之下")
        XCTAssertLessThanOrEqual(pinned.maxY, tabs.minY + 0.5, "置顶行在子 Tab 之上")
        assertNear(pinned.minX, content.minX + 16, 1, "置顶行左缘 = 内容列左边距 16")
        assertNear(pinned.maxX, content.maxX - 16, 1, "置顶行右缘 = 内容列右边距 16")
        XCTAssertGreaterThanOrEqual(pinned.height, 43.5, "整行一个目标，高 ≥ 44")
        try assertFont("orders.findPinned.label", base: 17, "置顶行文字")
        let icon = try rect("orders.findPinned.icon")
        assertNear(icon.width, 20, 1, "找回图标 20")
        assertInside(icon, pinned, "图标在置顶行内")
    }

    /// 置顶只在自购：分享子 Tab 的响应即使带 claim_entry_pinned=true 也不置顶（测试内派生报文，不改共用文件）。
    func testPinnedOnlyAppliesToSelfScope() async throws {
        let share = try OrderVisualData.change(OrderVisualData.page("list_share"), ["claim_entry_pinned": true])
        var script = try listScript()
        script.pages["share"] = .data(share)
        try await openList(script, scope: "share", waitFor: "order.card.E", images: [])
        XCTAssertNotNil(host?.probes["order.card.E"], "前提：分享列表已显示")
        XCTAssertNil(host?.probes["orders.findPinned"], "scope=share 不置顶")
        XCTAssertNotNil(host?.probes["orders.findEntry"], "分享子 Tab 仍是右上入口")
    }

    /// 断网显示上次数据时按不置顶（置顶值与当时时间有关，缓存不存它）：先在线置顶，再断网缓存 → 右上入口回来、置顶行消失。
    func testStaleCacheIsNeverPinned() async throws {
        let page = try fresh(listScript(self: "list_self_pinned"))
        try await page.prepareStale(tall)
        _ = await page.stable { host, _ in host.probes["orders.stale"] != nil }
        XCTAssertNotNil(host?.probes["orders.stale"], "前提：已是断网缓存态")
        XCTAssertNotNil(host?.probes["order.card.A"], "缓存数据照常显示")
        XCTAssertNil(host?.probes["orders.findPinned"], "缓存态不置顶")
        XCTAssertNotNil(host?.probes["orders.findEntry"], "缓存态显示右上入口")
    }

    // MARK: - 断网提示条

    /// 提示条：标题下、子 Tab 上；断网图标（wifi.slash，不再是 info / 警告三角）20；警告浅底（暖色，不是次要底）；文字「…今天 09:30…」。
    func testStaleBannerHasWifiOffIconWarningBackgroundAndPosition() async throws {
        for dark in [false, true] {
            let page = try fresh(listScript())
            try await page.prepareStale(OrderVisualHost.Canvas(height: 1794, dark: dark))
            let shot = await page.stable { host, _ in host.probes["orders.stale"] != nil }
            let image = try XCTUnwrap(shot)
            let banner = try rect("orders.stale")
            XCTAssertGreaterThanOrEqual(banner.minY, try rect("orders.titleRow").maxY - 0.5, "提示条在标题下")
            XCTAssertLessThanOrEqual(banner.maxY, try rect("orders.tabs").minY + 0.5, "提示条在子 Tab 上")
            let iconRect = try rect("orders.stale.icon")
            assertNear(iconRect.width, 20, 1, "断网图标 20")
            let background = ProductVisualPixels(image).color(at: CGPoint(x: banner.maxX - 4, y: banner.midY))
            let muted = ProductVisualPixels.RGB(CouliColor.backgroundMuted, dark: dark)
            XCTAssertFalse(background.near(muted, tolerance: 4), "提示条底色是警告浅底，不是次要底（\(background)）")
            XCTAssertGreaterThan(background.red - background.blue, 12, "警告浅底是暖色（\(background)）")
            let nearest = await nearestIcon(
                image, in: iconRect,
                candidates: ["wifi.slash", "exclamationmark.triangle", "info.circle"],
                background: Color(uiColor: UIColor(red: CGFloat(background.red) / 255,
                                                   green: CGFloat(background.green) / 255,
                                                   blue: CGFloat(background.blue) / 255, alpha: 1)), dark: dark
            )
            XCTAssertEqual(nearest, "wifi.slash", "提示条图标应为断网图标（dark=\(dark)）")
            XCTAssertTrue(try record("orders.stale.text").text.contains("09:30"), "缓存时刻「今天 09:30」")
        }
    }

    // MARK: - 子 Tab / 搜索 / 分组 / 筛选（视觉与命中区分开，§9 风险 1）

    func testHeaderControlsVisualHeightsAndHitTargetsDoNotOverlap() async throws {
        try await openList(listScript())
        assertNear(try rect("orders.tabs").height, 44 + 8, 1, "子 Tab 容器 = 44 视觉 + 上下内边距 4")
        for scope in ["self", "share"] {
            let hit = try rect("orders.tab.\(scope)")
            XCTAssertGreaterThanOrEqual(hit.height, 43.5, "子 Tab \(scope) 命中 ≥ 44")
        }
        assertNear(try rect("orders.searchBox").height, 44, 1, "搜索框视觉高 44")
        var hits: [(String, CGRect)] = []
        for group in OrderQuery.groups {
            let visual = try rect("orders.group.\(group)")
            assertNear(visual.height, 32, 1, "分组胶囊 \(group) 视觉高 32（命中区不撑高）")
            let hit = try rect("orders.group.\(group).hit")
            assertHit(hit, covers: visual, "分组胶囊 \(group)")
            hits.append((group, hit))
        }
        for filter in ["platform", "month"] {
            let visual = try rect("orders.filter.\(filter)")
            assertNear(visual.height, 32, 1, "筛选胶囊 \(filter) 视觉高 32")
            let hit = try rect("orders.filter.\(filter).hit")
            assertHit(hit, covers: visual, "筛选胶囊 \(filter)")
            hits.append((filter, hit))
            let chevron = try rect("orders.filter.\(filter).chevron")
            assertNear(chevron.width, 16, 1, "下箭头 16")
            assertInside(chevron, visual, "下箭头在胶囊内")
        }
        let eye = try rect("orders.mask.hit")
        XCTAssertGreaterThanOrEqual(eye.height, 43.5, "眼睛命中 ≥ 44")
        hits.append(("eye", eye))
        for (index, lhs) in hits.enumerated() {
            for rhs in hits.dropFirst(index + 1) {
                assertDisjoint(lhs.1, rhs.1, "命中区 \(lhs.0) 与 \(rhs.0) 不重叠")
            }
        }
        XCTAssertLessThan(try rect("orders.group.all").maxY, try rect("orders.filter.platform").minY,
                          "分组行在筛选行之上")
    }

    /// 分组胶囊：未选白底 + 描边、选中浅强调底（GUIDE「状态切换（订单）」）。
    func testGroupChipsSelectedSubtleUnselectedOutlined() async throws {
        let (_, image) = try await openList(listScript())
        let pixels = ProductVisualPixels(image)
        let selected = try rect("orders.group.all")
        let other = try rect("orders.group.estimating")
        let subtle = ProductVisualPixels.RGB(CouliColor.brandSubtle, dark: false)
        let surface = ProductVisualPixels.RGB(CouliColor.backgroundSurface, dark: false)
        let border = ProductVisualPixels.RGB(CouliColor.borderSubtle, dark: false)
        XCTAssertTrue(pixels.color(at: CGPoint(x: selected.minX + 8, y: selected.midY)).near(subtle, tolerance: 6),
                      "选中胶囊 brand.subtle 底")
        XCTAssertTrue(pixels.color(at: CGPoint(x: other.minX + 8, y: other.midY)).near(surface, tolerance: 6),
                      "未选胶囊白底")
        let edge = (0..<4).map { pixels.color(at: CGPoint(x: other.midX, y: other.minY + CGFloat($0) * 0.34)) }
        XCTAssertTrue(edge.contains { $0.near(border, tolerance: 14) }, "未选胶囊 1 描边 border.subtle（\(edge)）")
    }

    // MARK: - 半屏（O17、G-O13）

    /// 月份半屏：副标题「按付款时间」（G-O13）；选项行 ≥ 44、项间分隔线；选中项右侧圆圈对勾；earliest=2026-07 → 全部 + 10…7 月。
    func testMonthSheetSubtitleDividersAndCheckCircle() async throws {
        var script = try listScript()
        script.pages["self"] = try .data(OrderVisualData.page("month_options"))
        let (page, _) = try await openList(script, canvas: tall)
        page.orders.listConfig?.sheet = .month
        let shot = await page.stable { host, _ in host.probes["orders.sheet.option.all"] != nil }
        let image = try XCTUnwrap(shot)
        XCTAssertEqual(try record("orders.sheet.note").text, "按付款时间", "月份半屏副标题（G-O13）")
        let options = ["all", "2026-10", "2026-09", "2026-08", "2026-07"]
        var rows: [CGRect] = []
        for option in options {
            let row = try rect("orders.sheet.option.\(option)")
            XCTAssertGreaterThanOrEqual(row.height, 43.5, "选项 \(option) 行高 ≥ 44")
            rows.append(row)
        }
        XCTAssertNil(host?.probes["orders.sheet.option.2026-06"], "早于 earliest 的月份不出现")
        let check = try rect("orders.sheet.option.all.check")
        assertInside(check, rows[0], "选中项（全部）右侧对勾")
        XCTAssertNil(host?.probes["orders.sheet.option.2026-10.check"], "未选项没有对勾")
        let nearest = await nearestIcon(image, in: check, candidates: ["checkmark.circle", "checkmark"],
                                        background: CouliColor.backgroundSurface, dark: false)
        XCTAssertEqual(nearest, "checkmark.circle", "圆圈对勾，不是裸对勾")
        let pixels = ProductVisualPixels(image)
        let border = ProductVisualPixels.RGB(CouliColor.borderSubtle, dark: false)
        for index in 0..<(rows.count - 1) {
            let gap = CGRect(x: rows[index].midX - 20, y: rows[index].maxY - 1.5, width: 40,
                             height: max(3, rows[index + 1].minY - rows[index].maxY + 3))
            XCTAssertGreaterThan(count(pixels, in: gap, near: border, tolerance: 14), 0, "选项 \(index) 与下一项之间有分隔线")
        }
    }

    /// 平台半屏：淘宝 / 京东 / 拼多多前 20 官方图标（装饰），「全部平台」无图标；行 ≥ 44。
    func testPlatformSheetOptionsHave20PlatformIcons() async throws {
        let (page, _) = try await openList(listScript())
        page.orders.listConfig?.sheet = .platform
        _ = await page.stable { host, _ in host.probes["orders.sheet.option.taobao"] != nil }
        XCTAssertNil(host?.probes["orders.sheet.option.all.icon"], "全部平台没有图标")
        for platform in OrderPlatformOptions.platforms {
            let row = try rect("orders.sheet.option.\(platform)")
            XCTAssertGreaterThanOrEqual(row.height, 43.5, "\(platform) 行高 ≥ 44")
            let icon = try rect("orders.sheet.option.\(platform).icon")
            assertNear(icon.width, 20, 0.5, "\(platform) 图标 20")
            assertNear(icon.height, 20, 0.5, "\(platform) 图标 20")
            assertInside(icon, row, "\(platform) 图标在行内")
        }
    }

    // MARK: - 骨架（O18）

    /// 加载骨架按新卡结构：头行两块（徽标、右侧时间）、64 图块 + 右列三行、分隔线、两列数字块、胶囊块。
    func testSkeletonFollowsNewCardStructure() async throws {
        var script = try listScript()
        script.pages["self"] = .hold
        let page = try fresh(script)
        await page.showList()
        _ = await page.stable { host, _ in host.probes["orders.skeleton.0.image"] != nil }
        let prefix = "orders.skeleton.0."
        let card = try rect(prefix + "card")
        let badge = try rect(prefix + "badge")
        let time = try rect(prefix + "time")
        XCTAssertTrue(sameRow(badge, time), "头行两块同一行")
        assertNear(time.maxX, card.maxX - 16, 1, "时间块右对齐")
        let picture = try rect(prefix + "image")
        assertNear(picture.width, 64, 0.5, "图块 64")
        let lines = try (1...3).map { try rect(prefix + "line\($0)") }
        for line in lines {
            XCTAssertGreaterThanOrEqual(line.minX, picture.maxX + 8, "右列三行在图右侧")
        }
        let divider = try rect(prefix + "divider")
        XCTAssertGreaterThanOrEqual(divider.minY, picture.maxY - 0.5, "分隔线在商品块下")
        let amounts = try [rect(prefix + "amount1"), rect(prefix + "amount2")]
        XCTAssertTrue(sameRow(amounts[0], amounts[1]), "两列数字块并排")
        XCTAssertGreaterThanOrEqual(try rect(prefix + "pill").minY, amounts[0].maxY - 0.5, "胶囊块在数字块下")
    }
}
