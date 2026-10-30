@testable import Couli
import DesignSystem
import Foundation
import SwiftUI
import UIKit
import Wallet
import WalletCore
import XCTest

/// APP-09v-b 分页时机与记录级滚动锚点（Android b 评审 r1 S1 / S2-1、r2 S2-1 搬到 iOS）：
/// - 只在真正滚到底时才发下一页（按月合卡后整月一大块，懒加载容器的预取 / 提前出现不得把页脚提前建出来触发翻页）；20 → 40 → 60 连续多页、
///   每页恰好一次带游标的请求；
/// - 展开 / 收起、翻页追加、刷新前插同月新单、同 ID 上方记录内容变高之后，可视区顶上的那张单仍停在原位置（记录 ID + 相对偏移）。
/// 分页用例只看真实列表请求（WalletStubProtocol 记录）与真实滚动视图，不依赖测量桥；锚点用例用 `records.row.<id>` / `records.detail.<id>`。
@MainActor
final class RecordsVisualPagingTests: RecordsVisualTestCase {
    private func openSameMonth(_ count: Int, next: String?) async throws -> RecordsVisualHost {
        let page = try freshRecords()
        try page.server.setPage(items: RecordsVisualData.sameMonth(count), next: next)
        // v2 / T2：派生单也配详情（照拷 pending 详情），展开时假服务回详情而不是 30701，展开就绪条件「详情已到」才等得到
        try page.server.setDetails(RecordsVisualData.sameMonthDetails(count))
        try await page.show()
        _ = await page.stable { $0.controller?.state.phase == .content && $0.scroller != nil }
        return page
    }

    /// 小步滚动（每次 60）直到离真实底部还有 `margin`，每步都让布局与出现回调跑完。
    private func creep(_ page: RecordsVisualHost, until margin: CGFloat) async {
        var target = page.offset
        while target + 60 < page.maxOffset - margin {
            target += 60
            page.scroll(to: target)
            try? await Task.sleep(for: .milliseconds(60))
        }
        await quietWindow(0.8)
    }

    /// Android r1 S1：首批 20 条同月（整月一张卡）、连续三页；小步滚到离底 240 之前不得翻页；滚到底恰好一次带下一游标的请求。
    func testNoPrefetchBeforeRealBottomAcrossPages() async throws {
        let page = try await openSameMonth(20, next: "p2")
        try page.server.setPage("p2", items: RecordsVisualData.sameMonth(20, start: 21), next: "p3")
        try page.server.setPage("p3", items: RecordsVisualData.sameMonth(20, start: 41), next: nil)
        await quietWindow(0.8)
        XCTAssertEqual(RecordsVisualServer.moreRequests, 0, "首屏（20 条撑满一屏以上）不翻页")
        for round in 1...2 {
            XCTAssertGreaterThan(page.maxOffset, 600, "前提：第 \(round) 页内容远超一屏")
            await creep(page, until: 240)
            XCTAssertEqual(RecordsVisualServer.moreRequests, round - 1,
                           "第 \(round) 轮：离真实底部还有 240 时不得翻页（预取 / 页脚提前出现触发了 loadMore）")
            page.scroll(to: page.maxOffset)
            await waitUntil("滚到底后没有翻页", timeout: 5) { RecordsVisualServer.moreRequests >= round }
            await waitUntil("翻页结果没追加", timeout: 5) { page.controller?.state.items.count == 20 * (round + 1) }
            await quietWindow(1.0)
            XCTAssertEqual(RecordsVisualServer.moreRequests, round, "第 \(round) 轮：滚到底恰好一次翻页")
            XCTAssertEqual(RecordsVisualServer.listQueries.last.flatMap(RecordsVisualServer.cursor), "p\(round + 1)",
                           "按 next_cursor 翻页")
        }
        XCTAssertEqual(RecordsVisualServer.listQueries.filter { RecordsVisualServer.cursor($0) == nil }.count, 1,
                       "第一页只取一次")
    }

    // MARK: - 锚点

    /// 把某张单滚到可视区顶 + `offset`（懒加载时逐步向下找）。
    private func bring(_ page: RecordsVisualHost, _ id: String, toTopOffset offset: CGFloat,
                       file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0..<30 {
            _ = await page.stable(seconds: 3) { _ in true }
            guard let frame = page.frame(of: id), let top = page.viewport?.minY else {
                page.scroll(to: page.offset + 300)
                continue
            }
            let delta = frame.minY - (top + offset)
            if abs(delta) < 0.5 {
                return
            }
            page.scroll(to: page.offset + delta)
        }
        XCTFail("没能把 \(id) 滚到可视区顶 \(offset)（缺 records.row.\(id) 测量？§4 测量桥）", file: file, line: line)
    }

    private func assertAnchor(_ page: RecordsVisualHost, _ id: String, _ offset: CGFloat, _ message: String,
                              file: StaticString = #filePath, line: UInt = #line) async {
        _ = await page.stable(seconds: 4) { _ in true }
        let anchor = page.anchor()
        XCTAssertEqual(anchor?.id, id, "\(message)：可视区顶上的单变了", file: file, line: line)
        if let value = anchor?.offset {
            assertNear(value, offset, 1, "\(message)：\(id) 相对可视区顶的偏移", file: file, line: line)
        }
    }

    /// 展开 / 收起：被点的那张单顶边不动（展开卡接在原位置，收起回到原位置）。
    func testExpandCollapseKeepsRecordInPlace() async throws {
        let page = try await openSameMonth(20, next: nil)
        try await bring(page, "R08", toTopOffset: 40)
        try page.toggle("R08")
        _ = await page.stable { $0.probes["records.detail.R08"] != nil && $0.controller?.state.details["R08"] != nil }
        let top = try viewport().minY
        assertNear(try XCTUnwrap(page.frame(of: "R08")).minY - top, 40, 1, "展开卡顶边停在原位置")
        try page.toggle("R08")
        _ = await page.stable { $0.probes["records.row.R08"] != nil && $0.probes["records.detail.R08"] == nil }
        assertNear(try XCTUnwrap(page.frame(of: "R08")).minY - top, 40, 1, "收起后回到原位置")
    }

    /// 翻页追加：滚到底触发下一页，追加后可视区顶上的单与偏移不变。
    func testLoadMoreKeepsAnchor() async throws {
        let page = try await openSameMonth(20, next: "p2")
        try page.server.setPage("p2", items: RecordsVisualData.sameMonth(20, start: 21), next: nil)
        page.scroll(to: page.maxOffset)
        _ = await page.stable(seconds: 3) { _ in true }
        let before = try XCTUnwrap(page.anchor(), "缺 records.row.<id> 测量（§4 测量桥）")
        await waitUntil("没有翻页", timeout: 5) { page.controller?.state.items.count == 40 }
        await assertAnchor(page, before.id, before.offset, "翻页追加后")
    }

    /// Android r1 S2-2：浏览月中记录时刷新，服务端在同月最前插入一张新单——当前那张单（R10，顶在可视区上方 11）不被推移。
    func testRefreshPrependSameMonthKeepsAnchor() async throws {
        let page = try await openSameMonth(20, next: nil)
        try await bring(page, "R10", toTopOffset: -11)
        await assertAnchor(page, "R10", -11, "前提")
        var fresh = try RecordsVisualData.sameMonth(1, start: 0, prefix: "NEW")
        fresh[0]["created_at"] = "2026-10-12T09:00:00+08:00"
        try page.server.setPage(items: fresh + RecordsVisualData.sameMonth(20), next: nil)
        XCTAssertEqual(page.controller?.refresh(), true, "刷新被受理")
        await waitUntil("刷新结果没提交", timeout: 5) { page.controller?.state.items.count == 21 }
        await assertAnchor(page, "R10", -11, "同月前插后")
    }

    /// Android r2 S2-1：刷新返回同样的 ID / 顺序 / 月份，只是上方 R05 由审核中变成带长原因的打款未成功（首句变长换行、行变高）——
    /// 当前那张单仍停在原位置。
    func testRefreshSameIdsTallerRowAboveKeepsAnchor() async throws {
        let page = try await openSameMonth(20, next: nil)
        try await bring(page, "R10", toTopOffset: -11)
        var items = try RecordsVisualData.sameMonth(20)
        let failed = try XCTUnwrap((RecordsVisualData.page("failed")["items"] as? [[String: Any]])?.first)
        var changed = failed
        changed["withdrawal_id"] = "R05"
        changed["created_at"] = items[4]["created_at"]
        items[4] = changed
        try page.server.setPage(items: items, next: nil)
        XCTAssertEqual(page.controller?.refresh(), true, "刷新被受理")
        await waitUntil("刷新结果没提交", timeout: 5) { page.controller?.state.items[4].status == "FAILED" }
        await assertAnchor(page, "R10", -11, "上方同 ID 记录变高后")
    }
}
