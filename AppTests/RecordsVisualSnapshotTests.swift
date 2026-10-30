@testable import Couli
import Foundation
import SnapshotTesting
import SwiftUI
import UIKit
import Wallet
import WalletCore
import XCTest

/// APP-09v-b 提现记录整页基准（brief §2.7、§5）：真实 App 组装、visualWithdrawRecords 同一份数据、与画板同宽。名字与 Android
/// `app/src/test/snapshots/records-v/` 对应（States-v2 / More 证据稿按分支各拍一张真实记录页局部，证据标题与附注不进产品）。
/// 每个有稿状态浅色一张、状态矩阵深色各一张（prompt「深色模式各一张状态矩阵」），另加 AX3 × 390 / 320、840。
/// 默认只比对（缺图失败）；`TEST_RUNNER_COULI_RECORD_SNAPSHOTS=1` 只录缺图（`.missing`），不覆盖已有基准。基准由实现者录。
/// 每张都等「两帧一致」+ 就绪条件（执行器阶段 + 该状态特有测量）；没有就绪条件的镜头不允许（APP-08v 测试 v3 S2-2）。
@MainActor
final class RecordsVisualSnapshotTests: RecordsVisualTestCase {
    enum Source {
        case page(String, expand: [String] = [], focus: String? = nil)
        case loading
        case error
        case loadingMore
        case moreError
    }

    struct Shot {
        let name: String
        let source: Source
        var canvas = RecordsVisualHost.Canvas()
        /// 就绪条件：该状态特有的测量编号（必须给）。
        let ready: String
    }

    private static func boards(dark: Bool) -> [Shot] {
        let suffix = dark ? "dark" : "light"
        let canvas = RecordsVisualHost.Canvas(height: dark ? 1000 : 844, dark: dark)
        let tall = RecordsVisualHost.Canvas(height: 1000, dark: dark)
        return [
            Shot(name: "WithdrawRecords-v2-\(suffix)", source: .page("list"), canvas: canvas, ready: "records.end"),
            Shot(name: "WithdrawRecordsPending-v2-GW10-\(suffix)", source: .page("list", expand: ["PENDING"]),
                 canvas: tall, ready: "records.detail.PENDING.service"),
            Shot(name: "WithdrawRecordsPaid-v2-GW10-\(suffix)", source: .page("list", expand: ["PAID"]), canvas: tall,
                 ready: "records.detail.PAID.copy"),
            Shot(name: "WithdrawRecordsFailed-v2-\(suffix)", source: .page("list", expand: ["FAILED"]), canvas: tall,
                 ready: "records.detail.FAILED.changeAccount"),
            Shot(name: "WithdrawRecordsAutoDeciding-v2-GW09-\(suffix)",
                 source: .page("board_auto_deciding", expand: ["AUTO_DECIDING"]), canvas: tall,
                 ready: "records.detail.AUTO_DECIDING"),
            Shot(name: "WithdrawRecordsAutoWaiting-v2-GW09-\(suffix)",
                 source: .page("board_auto_waiting", expand: ["AUTO_WAITING"]), canvas: tall,
                 ready: "records.detail.AUTO_WAITING"),
            Shot(name: "WithdrawRecordsPaying-v2-GW09-\(suffix)", source: .page("board_paying", expand: ["PAYING"]),
                 canvas: tall, ready: "records.detail.PAYING"),
            Shot(name: "WithdrawRecordsEmpty-\(suffix)", source: .page("empty"), canvas: canvas,
                 ready: "records.empty.icon"),
            Shot(name: "state-records-loading-\(suffix)", source: .loading, canvas: canvas, ready: "records.loading"),
            Shot(name: "state-records-error-\(suffix)", source: .error, canvas: canvas, ready: "records.error"),
            Shot(name: "state-records-loading-more-\(suffix)", source: .loadingMore, canvas: canvas,
                 ready: "records.loadingMore"),
            Shot(name: "state-records-more-error-\(suffix)", source: .moreError, canvas: canvas,
                 ready: "records.moreError"),
        ]
    }

    /// §1.1 B 有稿浅色 7 张 + 空态 + 无稿状态（加载骨架、首次失败、翻页中、翻页失败）。
    func testBoardsLight() async throws {
        try await run(Self.boards(dark: false))
    }

    /// 状态矩阵深色各一张；`WithdrawRecordsDark-GW10-dark` 对 WithdrawRecordsDark 画板（已到账展开，只截 1000 产品区）。
    func testBoardsDark() async throws {
        try await run([Shot(name: "WithdrawRecordsDark-GW10-dark", source: .page("list", expand: ["PAID"]),
                            canvas: .init(height: 1000, dark: true), ready: "records.detail.PAID.copy")]
                + Self.boards(dark: true))
    }

    /// WithdrawRecordsStates-v2 有字段的分支（G-W09 / G-W10 逐条记差异；②③④⑤⑰ 微信、⑧⑪⑯ 缺字段不拍）。
    func testStatesBranches() async throws {
        let branches: [(String, String)] = [
            ("States-v2-01-auto-review-GW09", "auto_review"),
            ("States-v2-06-auto-waiting-GW09", "auto_waiting"),
            ("States-v2-07-pending-fallback-GW10", "pending"),
            ("States-v2-09-approved-GW09", "approved"),
            ("States-v2-10-paying-GW09", "paying"),
            ("States-v2-12-paid", "paid"),
            ("States-v2-13-rejected", "rejected"),
            ("States-v2-14-failed-account", "failed"),
            ("States-v2-15-failed-other-GW09", "failed_other"),
        ]
        try await run(branches
            .map { Shot(name: "\($0.0)-light", source: .page($0.1), ready: "records.row.\($0.1.uppercased()).line") })
    }

    /// WithdrawRecordsMore 的分支（税、线下转账、扣回、5 种人工原因、未知状态）。
    func testMoreBranches() async throws {
        let branches: [(String, String)] = [
            ("More-01-tax-GW09", "tax"),
            ("More-02-manual-GW09", "manual"),
            ("More-03-negative-balance", "reject_negative_balance"),
            ("More-04-risk", "reject_risk_suspect"),
            ("More-04-order", "reject_order_abnormal"),
            ("More-04-payee", "reject_payee_info_invalid"),
            ("More-04-user-request-GW09", "reject_user_request"),
            ("More-04-other", "reject_other"),
            ("More-05-unknown", "unknown"),
        ]
        try await run(branches
            .map { Shot(name: "\($0.0)-light", source: .page($0.1), ready: "records.row.\($0.1.uppercased()).pill") })
    }

    /// 适配与定位：AX3 × 390（浅 / 深）/ 320 的已到账展开、840 限宽、定位到不同月份的单（置顶并展开）。
    func testAdaptationAndFocus() async throws {
        let ax = DynamicTypeSize.accessibility3
        try await run([
            Shot(name: "WithdrawRecordsPaid-v2-font200-w390-light", source: .page("list", expand: ["PAID"]),
                 canvas: .init(height: 1800, size: ax), ready: "records.detail.PAID.copy"),
            Shot(name: "WithdrawRecordsPaid-v2-font200-w390-dark", source: .page("list", expand: ["PAID"]),
                 canvas: .init(height: 1800, dark: true, size: ax), ready: "records.detail.PAID.copy"),
            Shot(name: "WithdrawRecordsPaid-v2-font200-w320-light", source: .page("list", expand: ["PAID"]),
                 canvas: .init(width: 320, height: 2200, size: ax), ready: "records.detail.PAID.copy"),
            Shot(name: "WithdrawRecords-w840-light", source: .page("list"), canvas: .init(width: 840, height: 1000),
                 ready: "records.end"),
            Shot(name: "state-records-focused-different-month-light", source: .page("next", focus: "FOCUS"),
                 canvas: .init(height: 1000), ready: "records.detail.FOCUS"),
        ])
    }

    // MARK: - 执行

    private func run(_ shots: [Shot], file: StaticString = #filePath, testName: String = #function,
                     line: UInt = #line) async throws {
        for shot in shots {
            try await take(shot, file: file, testName: testName, line: line)
        }
    }

    private func take(_ shot: Shot, file: StaticString, testName: String, line: UInt) async throws {
        XCTAssertFalse(shot.ready.isEmpty, "\(shot.name)：必须给就绪条件", file: file, line: line)
        let ready = shot.ready
        let image: UIImage?
        switch shot.source {
        case let .page(name, expand, focus):
            let phase: RecordsSnapshot.Phase = name == "empty" ? .empty : .content
            let (page, _) = try await openRecords(name, focus: focus, expand: expand, canvas: shot.canvas,
                                                  phase: phase, file: file, line: line)
            image = await page.stable(file: file, line: line) { $0.probes[ready] != nil }
        case .loading, .error:
            let page = try freshRecords()
            try page.server.setPage(RecordsVisualData.page("list"))
            let loading = if case .loading = shot.source {
                true
            } else {
                false
            }
            page.server.setFirst(loading ? .hold : .envelope(code: 50001, data: "null", headers: [:]))
            try await page.show(shot.canvas)
            let phase: RecordsSnapshot.Phase = loading ? .loading : .error
            image = await page.stable(file: file, line: line) {
                $0.controller?.state.phase == phase && $0.probes[ready] != nil
            }
        case .loadingMore, .moreError:
            let page = try freshRecords()
            try page.server.setPage(RecordsVisualData.page("pagination"))
            let failing = if case .moreError = shot.source {
                true
            } else {
                false
            }
            page.server.setMore(failing ? .envelope(code: 50001, data: "null", headers: [:]) : .hold)
            try await page.show(shot.canvas)
            image = await page.stable(file: file, line: line) { $0.probes[ready] != nil }
        }
        guard let image else { return }
        XCTAssertEqual(image.size, CGSize(width: shot.canvas.width, height: shot.canvas.height),
                       "\(shot.name)：画布尺寸", file: file, line: line)
        withSnapshotTesting(record: ProcessInfo.processInfo
            .environment["COULI_RECORD_SNAPSHOTS"] == "1" ? .missing : .never) {
                assertSnapshot(of: image, as: .image(precision: 0.99, perceptualPrecision: 0.98), named: shot.name,
                               file: file, testName: testName, line: line)
            }
    }
}
