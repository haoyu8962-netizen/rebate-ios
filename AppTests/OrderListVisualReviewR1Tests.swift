@testable import Couli
import DesignSystem
import Foundation
import OrderCore
import Orders
import SwiftUI
import UIKit
import XCTest

/// APP-08v-a 测试 v3：独立评审 r1 S2-1（身份暂时未知的整页错误态 / 切分享不画置顶行）与 S2-3（AX3 下半屏选项放不下时能滚到最后一项并选中）。
@MainActor
final class OrderListVisualReviewR1Tests: OrderVisualTestCase {
    override func tearDown() async throws {
        host?.fixture.store.disarm()
        try await super.tearDown()
    }

    // MARK: - S2-1

    /// 先正：服务端置顶的空页画置顶行；再反：身份暂时未知（会话读取失败）时下拉刷新 → 整页错误态，置顶行不画、右上入口回来。
    func testIdentityUnknownRefreshErrorPageDrawsNoPinnedRow() async throws {
        let empty = try OrderVisualData.change(OrderVisualData.page("list_self_empty"), ["claim_entry_pinned": true])
        var script = try listScript()
        script.pages["self"] = .data(empty)
        let (page, _) = try await openList(script, waitFor: "orders.findPinned", images: [])
        XCTAssertNotNil(host?.probes["orders.findPinned"], "前提：置顶的空页画置顶行")
        let controller = try XCTUnwrap(page.orders.listConfig?.controller)

        page.fixture.store.failReads(fromNth: 1)
        _ = controller.refresh()
        _ = await page.stable { _, _ in controller.snapshot.phase == .error }
        XCTAssertEqual(controller.snapshot.phase, .error, "前提：身份暂时未知的刷新结算为整页错误态")
        XCTAssertTrue(controller.snapshot.identityPending, "前提：确是身份未知路径")
        XCTAssertNil(host?.probes["orders.findPinned"], "整页错误态不画置顶行")
        XCTAssertNotNil(host?.probes["orders.findEntry"], "整页错误态显示右上入口")
    }

    /// 身份暂时未知时切到「分享」：分享页（整页错误态）不画置顶行。
    func testIdentityUnknownSwitchToShareDrawsNoPinnedRow() async throws {
        let (page, _) = try await openList(listScript(self: "list_self_pinned"), waitFor: "orders.findPinned")
        XCTAssertNotNil(host?.probes["orders.findPinned"], "前提：自购置顶")
        let controller = try XCTUnwrap(page.orders.listConfig?.controller)

        page.fixture.store.failReads(fromNth: 1)
        _ = controller.setScope("share")
        _ = await page.stable { _, _ in controller.snapshot.phase == .error }
        XCTAssertEqual(controller.snapshot.query.scope, "share")
        XCTAssertEqual(controller.snapshot.phase, .error, "前提：身份暂时未知时切分享进整页错误态")
        XCTAssertNil(host?.probes["orders.findPinned"], "分享页不画置顶行")
        XCTAssertNotNil(host?.probes["orders.findEntry"], "分享页显示右上入口")
    }

    // MARK: - S2-3

    /// AX3 × 390：14 个月（独立 fixture month_options_long）+「全部」放不下——先证明最后一项起初在可视区外（确实走滚动分支），
    /// 再把半屏里的滚动区滚到底：最后一项完整进可视区、命中 ≥ 44、字号确为大字号档；选中由 UI 真点用例 `testMonthSheetAtAX3ScrollsToLastMonthAndSelects`
    /// 证明（进程内无法真点）。
    func testMonthSheetAtAX3ScrollsToLastOfFourteenMonths() async throws {
        var script = try listScript()
        script.pages["self"] = try .data(OrderVisualData.page("month_options_long"))
        let canvas = OrderVisualHost.Canvas(size: .accessibility3)
        let (page, _) = try await openList(script, canvas: canvas)
        page.orders.listConfig?.sheet = .month
        _ = await page.stable { host, _ in host.probes["orders.sheet.option.2025-09"] != nil }
        try await assertScrollsToLast(page, canvas: canvas, first: "all", last: "2025-09", count: 15)
    }

    /// 平台选项固定 4 项（全部 + 淘宝 / 京东 / 拼多多，不由数据决定），竖屏手机上 AX3 放得下；这里用 390 × 340 的矮窗口逼出放不下，
    /// 同样要求滚到最后一项（拼多多）完整可见；选中由 UI 真点 `testPlatformSheetAtAX3LastOptionSelects` 证明。
    func testPlatformSheetOnShortWindowScrollsToLast() async throws {
        let canvas = OrderVisualHost.Canvas(height: 340, size: .accessibility3)
        let (page, _) = try await openList(listScript(), canvas: canvas, waitFor: "orders.findEntry", images: [])
        page.orders.listConfig?.sheet = .platform
        _ = await page.stable { host, _ in host.probes["orders.sheet.option.pdd"] != nil }
        try await assertScrollsToLast(page, canvas: canvas, first: "all", last: "pdd", count: 4)
    }

    // MARK: - 工具

    private func assertScrollsToLast(_ page: OrderVisualHost, canvas: OrderVisualHost.Canvas, first: String,
                                     last: String, count: Int, file: StaticString = #filePath,
                                     line: UInt = #line) async throws {
        let options = host?.probes.ids(prefix: "orders.sheet.option.").filter { $0.split(separator: ".").count == 4 }
        XCTAssertEqual(options?.count, count, "选项个数", file: file, line: line)
        let visibleBottom = canvas.height - canvas.bottom
        let before = try rect("orders.sheet.option.\(last)", file: file, line: line)
        XCTAssertGreaterThan(before.maxY, visibleBottom, "前提：最后一项起初在可视区外（放不下、走滚动分支）", file: file,
                             line: line)
        let window = try XCTUnwrap(page.window, file: file, line: line)
        let anchor = try rect("orders.sheet.option.\(first)", file: file, line: line)
        let scroller = try XCTUnwrap(
            Self.sheetScrollView(in: window, containing: CGPoint(x: anchor.midX, y: anchor.midY)),
            "半屏里没有可滚动的正文区",
            file: file,
            line: line
        )
        let bottom = CGPoint(x: 0, y: max(0, scroller.contentSize.height - scroller.bounds.height
                + scroller.adjustedContentInset.bottom))
        scroller.setContentOffset(bottom, animated: false)
        _ = await page.stable { host, _ in
            (host.probes["orders.sheet.option.\(last)"]?.rect.maxY ?? .infinity) <= visibleBottom + 0.5
        }
        let row = try rect("orders.sheet.option.\(last)", file: file, line: line)
        XCTAssertGreaterThanOrEqual(row.minY, 0, "最后一项顶边在窗口内", file: file, line: line)
        XCTAssertLessThanOrEqual(row.maxY, visibleBottom + 0.5, "最后一项完整进可视区（不被截断）", file: file, line: line)
        XCTAssertGreaterThanOrEqual(row.height, 43.5, "最后一项命中 ≥ 44", file: file, line: line)
        let label = try record("orders.sheet.option.\(last).label", file: file, line: line)
        XCTAssertGreaterThan(label.fontSize, label.baseFontSize * 1.5, "半屏内字号确为大字号档", file: file, line: line)
        assertInside(label.rect, row, "选项文字完整在行内", file: file, line: line)
    }

    /// 包含该点、竖向内容超出可视高、面积最小的滚动视图（半屏正文区；排除底下整页列表与横滑胶囊）。
    static func sheetScrollView(in root: UIView, containing point: CGPoint) -> UIScrollView? {
        var found: [UIScrollView] = []
        func walk(_ view: UIView) {
            if let scroll = view as? UIScrollView, !scroll.isHidden, scroll.window != nil,
               scroll.convert(scroll.bounds, to: nil).contains(point),
               scroll.contentSize.height > scroll.bounds.height + 1 {
                found.append(scroll)
            }
            view.subviews.forEach(walk)
        }
        walk(root)
        return found.min { lhs, rhs in
            lhs.bounds.width * lhs.bounds.height < rhs.bounds.width * rhs.bounds.height
        }
    }
}
