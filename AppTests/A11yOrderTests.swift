@testable import Couli
import DesignSystem
import Foundation
import Orders
import SwiftUI
import UIKit
import XCTest

/// FU-IOS-A11Y（QA-12b iOS 报告 P5 订单）：订单视觉底座（真实 App 组装 + OrderVisualStub 假服务）挂生产订单列表 / 详情，打开 SwiftUI 无障碍树。
/// - A11Y-05 / 共性 ①（D10-1248 ⑨）：【复制】读「复制订单号 {no}」，{no} 是本行完整单号；列表与详情都改。
/// - A11Y-10：订单卡整卡项的角色是按钮。
/// - S2-1（NUM-WRAP 评审 r2）：320 宽 + AX3 下压力卡（19 位单号横滑）卡内读屏只有整卡、复制两项，横滑条不多出空停留点。
/// - A11Y-02：平台 / 月份半屏能用读屏「返回」手势关闭，订单页不出栈。
/// - A11Y-08（订单部分）：翻页失败行出现时播报错误文案，播报结束后焦点移到【重试】（焦点经 `couliFocusProbe("orders.pageRetry")` 报）。
@MainActor
final class A11yOrderTests: OrderVisualTestCase {
    private lazy var focus = A11yProbes()

    override func setUp() async throws {
        try await super.setUp()
        try A11yTree.enable(self)
    }

    /// 同 `openList`，另把焦点转移接到本用例（测量照旧报给宿主）。
    private func open(_ script: OrderVisualStub.Script, canvas: OrderVisualHost.Canvas = .init(),
                      waitFor: String = "order.card.A", file: StaticString = #filePath,
                      line: UInt = #line) async throws -> OrderVisualHost {
        let page = try fresh(script)
        let sink = focus
        page.probes.probe = A11yProbes.addingFocus(to: page.probes.probe) { sink.recordFocus($0) }
        await page.showList(canvas)
        _ = await page.stable(file: file, line: line) { host, _ in host.probes[waitFor] != nil }
        return page
    }

    private func window(_ page: OrderVisualHost, file: StaticString = #filePath,
                        line: UInt = #line) throws -> UIWindow {
        try XCTUnwrap(page.window, "页面没有挂上", file: file, line: line)
    }

    /// 测量里的卡编号（`order.card.<id>`，不含子项）。
    private func cardIDs(_ page: OrderVisualHost) -> [String] {
        page.probes.ids(prefix: "order.card.")
            .map { String($0.dropFirst("order.card.".count)) }
            .filter { !$0.contains(".") }
    }

    /// 卡上显示的单号（测量 `.number` 的文字去掉「订单号」前缀）。
    private func shownNumber(_ page: OrderVisualHost, prefix: String) -> String? {
        guard let text = page.probes[prefix + ".number"]?.text else { return nil }
        return text.components(separatedBy: " ").last
    }

    // MARK: - A11Y-05 复制读出本行完整单号

    func testListCopyReadsFullOrderNumberOfItsRow() async throws {
        let page = try await open(listScript())
        let nodes = try A11yTree.elements(window(page))
        var checked = 0
        for id in cardIDs(page) {
            let container = "order.card.\(id)"
            guard let copy = nodes.first(where: { $0.id == "order.copy" && $0.inside(container) }) else { continue }
            let number = try XCTUnwrap(shownNumber(page, prefix: container), "\(id)：可复制的卡要有单号测量")
            XCTAssertEqual(copy.label, "复制订单号 \(number)", "\(id)：【复制】要读出本行完整单号（D10-1248 ⑨）")
            checked += 1
        }
        XCTAssertGreaterThanOrEqual(checked, 2, "前提：自购列表至少两张可复制的卡（同屏多行要能区分）")
        let labels = nodes.filter { $0.id == "order.copy" }.map(\.label)
        XCTAssertEqual(Set(labels).count, labels.count, "同屏各行的【复制】名称不能相同：\(labels)")
    }

    func testDetailCopyReadsFullOrderNumber() async throws {
        let detail = try OrderVisualData.detail("detail_estimated")
        let id = try XCTUnwrap(detail["order_id"] as? String)
        let page = try fresh(OrderVisualStub.Script(details: [id: .data(detail)]))
        try await page.showDetail(id)
        _ = await page.stable { host, _ in host.probes["orderDetail.product.number"] != nil }
        let copy = try XCTUnwrap(A11yTree.elements(window(page)).first { $0.id == "order.copy" }, "详情没有【复制】")
        let number = try XCTUnwrap(shownNumber(page, prefix: "orderDetail.product"))
        XCTAssertEqual(copy.label, "复制订单号 \(number)", "详情【复制】同样读完整单号")
    }

    // MARK: - A11Y-10 整卡是按钮

    func testCardSummaryIsButton() async throws {
        let page = try await open(listScript())
        let nodes = try A11yTree.elements(window(page))
        let ids = cardIDs(page)
        XCTAssertFalse(ids.isEmpty)
        for id in ids {
            let container = "order.card.\(id)"
            let summary = nodes.filter {
                $0.inside(container) && ["order.number", "order.maskedNumber"].contains($0.id)
            }
            XCTAssertEqual(summary.count, 1, "\(id)：一个整卡项：\n\(A11yTree.dump(nodes.filter { $0.inside(container) }))")
            XCTAssertTrue(summary.allSatisfy(\.isButton), "\(id)：整卡项要读「按钮」（A11Y-10）：\(summary)")
            XCTAssertFalse(summary.contains { $0.traits.contains(.staticText) }, "\(id)：不能再是静态文字")
        }
    }

    // MARK: - S2-1 320 + AX3 卡内只有两项

    func testStressCardHasOnlySummaryAndCopyAt320AX3() async throws {
        var script = try listScript()
        script.pages["self"] = try .data(OrderVisualData.page("stress"))
        let page = try await open(script, canvas: .init(width: 320, height: 2400, size: .accessibility3),
                                  waitFor: "order.card.STRESS.number")
        let inside = try A11yTree.elements(window(page)).filter { $0.inside("order.card.STRESS") }
        let dump = A11yTree.dump(inside)
        XCTAssertEqual(inside.count, 2, "压力卡读屏只停整卡与【复制】两项（横滑条不多出停留点）：\n\(dump)")
        XCTAssertEqual(inside.filter { $0.id == "order.copy" }.count, 1, dump)
        XCTAssertEqual(inside.filter { ["order.number", "order.maskedNumber"].contains($0.id) }.count, 1, dump)
        XCTAssertFalse(inside.contains { $0.label.isEmpty }, "不能有空名称的停留点：\n\(dump)")
    }

    // MARK: - A11Y-02 平台 / 月份半屏

    func testFilterSheetsCloseWithEscape() async throws {
        let page = try await open(listScript())
        let config = try XCTUnwrap(page.orders.listConfig)
        let before = page.fixture.routing.router.path.count
        for sheet in [OrderFilterSheet.platform, .month] {
            let headersBefore = try Set(A11yTree.elements(window(page)).filter(\.isHeader).map(\.label))
            config.sheet = sheet
            await quietWindow(0.6)
            let elements = try A11yTree.elements(window(page))
            let header = try XCTUnwrap(elements.first { $0.isHeader && !headersBefore.contains($0.label) },
                                       "\(sheet) 半屏没有新出现的标题：\n\(A11yTree.dump(elements))")
            XCTAssertTrue(A11yTree.escape(from: header.object), "\(sheet) 半屏没有接住读屏「返回」手势（A11Y-02）")
            await quietWindow(0.5)
            XCTAssertNil(config.sheet, "\(sheet)：「返回」手势要关闭半屏")
            XCTAssertEqual(page.fixture.routing.router.path.count, before, "\(sheet)：手势不能把订单页退掉")
            config.sheet = nil
            await quietWindow(0.4)
        }
    }

    // MARK: - A11Y-08 翻页失败播报

    func testPageErrorIsAnnouncedThenFocusesRetry() async throws {
        A11yAudit.installTap(self, voiceOver: true)
        let script = try listScript(extra: ["cursor:visual-next-2": .error(50001)])
        let page = try await open(script, canvas: .init(height: 1740), waitFor: "orders.pageError")
        let row = try XCTUnwrap(A11yTree.node("orders.pageError", in: window(page)), "前提：翻页失败行")
        let message = row.label
        XCTAssertFalse(message.isEmpty)
        let post = await A11yAudit.waitAnnouncement(containing: message)
        XCTAssertNotNil(post, "翻页失败行出现时要播报「\(message)」（A11Y-08）；实际：\(A11yPostTap.posts)")
        XCTAssertEqual(post?.queued, false, "加载失败立即读（打断当前朗读），同搜索页翻页失败")
        A11yAudit.finishAnnouncement(post?.text ?? message)
        await waitUntil("播报结束后焦点要移到【重试】（orders.pageRetry）；实际 \(focus.focused)", timeout: 9.5) {
            self.focus.focused.contains("orders.pageRetry")
        }
    }
}
