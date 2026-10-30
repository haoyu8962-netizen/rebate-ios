@testable import Couli
import DesignSystem
import Foundation
import SwiftUI
import UIKit
import Wallet
import WalletCore
import XCTest

/// APP-09v-b 提现记录页面状态（brief §2.2 第 5 条、§2.7「无稿：记录加载更多 / 错误」、W31、W35）：空态 EmptyState（流水图标、仍可下拉）、
/// 首次加载骨架（3 行，同收起行结构）、首次失败 / 断网（ErrorState +【重试】，重试成功恢复列表）、翻页中骨架与翻页失败；深色令牌；840 限宽。
@MainActor
final class RecordsVisualStateTests: RecordsVisualTestCase {
    /// W31：空态——EmptyState 用流水图标（list.bullet.rectangle，不是钱包 creditcard），标题 / 说明取字典；仍在可下拉的滚动容器里。
    func testW31EmptyLedgerIcon() async throws {
        let (page, image) = try await openRecords("empty", waitFor: "records.empty.icon", phase: .empty)
        XCTAssertNotNil(page.probes["records.empty"], "空态测量")
        let icon = try rect("records.empty.icon")
        let nearest = await nearestIcon(image, in: icon, candidates: ["list.bullet.rectangle", "creditcard"],
                                        background: CouliColor.backgroundCanvas, ink: CouliColor.textSecondary)
        XCTAssertEqual(nearest, "list.bullet.rectangle", "空态流水图标")
        XCTAssertNotNil(page.scroller, "空态仍在滚动容器里（可下拉刷新，共性第 82 条）")
        // 下拉刷新走同一个 refresh：成功后恢复列表、只多一次列表请求
        try page.server.setPage(RecordsVisualData.page("list"))
        let before = RecordsVisualServer.listQueries.count
        _ = page.controller?.refresh()
        _ = await page.stable { $0.controller?.state.phase == .content }
        XCTAssertEqual(RecordsVisualServer.listQueries.count, before + 1, "刷新只多一次列表请求")
    }

    /// W35：首次加载是骨架（容器 `records.loading`、3 行 `records.loading.row.0…2`，每行有可见骨架色块），不是孤零零的转圈。
    func testW35FirstLoadSkeleton() async throws {
        let page = try freshRecords()
        page.server.setFirst(.hold)
        try await page.show()
        let image = await page.stable { $0.controller?.state.phase == .loading && $0.probes["records.loading"] != nil }
        let shot = try XCTUnwrap(image)
        let container = try rect("records.loading")
        let muted = pixel(CouliColor.backgroundMuted, dark: false)
        var previous: CGRect?
        for index in 0..<3 {
            let row = try rect("records.loading.row.\(index)")
            assertInside(row, container, "第 \(index) 行在骨架容器内")
            XCTAssertGreaterThan(share(shot, in: row, near: muted, tolerance: 6), 0.12, "第 \(index) 行有骨架色块（不是空白占位）")
            if let previous {
                XCTAssertGreaterThanOrEqual(row.minY, previous.maxY - 0.5, "逐行向下")
            }
            previous = row
        }
        XCTAssertGreaterThan(share(shot, in: container.insetBy(dx: 4, dy: 4),
                                   near: pixel(CouliColor.backgroundSurface, dark: false), tolerance: 3), 0.3, "骨架在白卡里")
    }

    /// §2.7：首次读取失败（50001）与断网（传输层失败）都进 ErrorState（`records.error`）、不画「¥0」或空态；【重试】成功恢复列表。
    func testFirstLoadErrorAndOfflineRetry() async throws {
        for (name, reply) in [("50001", WalletStubProtocol.Reply.envelope(code: 50001, data: "null", headers: [:])),
                              ("断网", .disconnect)] {
            let page = try freshRecords()
            page.server.setFirst(reply)
            try page.server.setPage(RecordsVisualData.page("list"))
            try await page.show()
            _ = await page.stable { $0.controller?.state.phase == .error && $0.probes["records.error"] != nil }
            XCTAssertNotNil(records?.probes["records.error"], "\(name)：错误态测量")
            XCTAssertNil(records?.probes["records.empty"], "\(name)：不当成空态")
            XCTAssertFalse(recordTexts.contains { $0.contains(RecordsVisualData.money(0)) }, "\(name)：不显示 ¥0")
            page.server.setFirst(nil)
            _ = page.controller?.refresh()
            _ = await page.stable { $0.controller?.state.phase == .content && $0.probes["records.row.PENDING"] != nil }
            XCTAssertNotNil(records?.probes["records.row.PENDING"], "\(name)：重试后恢复列表")
        }
    }

    /// §2.7：翻页中显示 1 行骨架（`records.loadingMore`，不是「没有更多」）；翻页失败显示 `records.moreError`，旧列表保留。
    func testLoadingMoreAndMoreError() async throws {
        let page = try freshRecords()
        try page.server.setPage(RecordsVisualData.page("pagination"))
        page.server.setMore(.hold)
        try await page.show()
        _ = await page.stable { $0.controller?.state.loadingMore == true && $0.probes["records.loadingMore"] != nil }
        XCTAssertNotNil(records?.probes["records.loadingMore"], "翻页中骨架")
        XCTAssertNil(records?.probes["records.end"], "翻页中不出「没有更多」")
        XCTAssertNotNil(records?.probes["records.row.PENDING"], "旧列表照常")
        for id in WalletStubProtocol.heldIds {
            WalletStubProtocol.release(id, with: .envelope(code: 50001, data: "null", headers: [:]))
        }
        _ = await page.stable { $0.controller?.state.moreError != nil && $0.probes["records.moreError"] != nil }
        XCTAssertNotNil(records?.probes["records.moreError"], "翻页失败提示")
        XCTAssertNotNil(records?.probes["records.row.PENDING"], "翻页失败保留旧列表")
    }

    /// 深色（WithdrawRecordsDark）：卡片深色面、月份次文字深色、胶囊深色状态底；展开卡同。
    func testDarkTokens() async throws {
        let (_, image) = try await openRecords(expand: ["PAID"], canvas: .init(height: 1000, dark: true))
        let card = try rect(try record("records.row.PENDING").card)
        XCTAssertGreaterThan(share(image, in: card.insetBy(dx: 4, dy: 4), near: pixel(CouliColor.backgroundSurface,
                                                                                      dark: true), tolerance: 3), 0.5,
                             "月卡深色面")
        let detail = try rect("records.detail.PAID")
        XCTAssertGreaterThan(share(image, in: detail.insetBy(dx: 4, dy: 4), near: pixel(CouliColor.backgroundSurface,
                                                                                        dark: true), tolerance: 3), 0.5,
                             "展开卡深色面")
        XCTAssertGreaterThan(share(image, in: try rect("records.row.PENDING.pill").insetBy(dx: 2, dy: 2),
                                   near: pixel(CouliColor.token("status.pending.background"), dark: true),
                                   tolerance: 4),
                             0.35, "中性胶囊深色底")
        XCTAssertGreaterThan(share(image, in: try rect("records.detail.PAID.header.pill").insetBy(dx: 2, dy: 2),
                                   near: pixel(CouliColor.statusSuccessBackground, dark: true), tolerance: 4), 0.35,
                             "成功胶囊深色底")
        XCTAssertGreaterThan(count(image, in: try rect("records.month.2026-10"),
                                   near: pixel(CouliColor.textSecondary, dark: true)), 10, "月份标题深色次文字")
    }

    /// 大屏 840：内容限宽 600 居中，卡宽 568。
    func testW840ContentWidth() async throws {
        try await openRecords(canvas: .init(width: 840, height: 1000), waitFor: "records.row.PENDING")
        let card = try rect(try record("records.row.PENDING").card)
        assertNear(card.width, 568, 1, "卡宽 568")
        assertNear(card.midX, 420, 1, "居中")
    }
}
