@testable import Couli
import CouliNetwork
import Foundation
import Generated
import Router
import Wallet
import WalletCore
import XCTest

/// APP-09 iOS 第 3 轮评审 R3-01（R3-02 的界面用例在 UITests/WalletReviewR3UITests.swift）：定位详情请求被同单更新的详情请求取代后，
/// 第一页提交不得回落采用它的旧响应置顶 / 展开（共性第 20、54、81 条）。三个用例共用前置：带 W2 定位打开 → 首次定位详情失败（列表含 W2、
/// 无详情）→ 下拉刷新，定位请求 F1 挂起 → 展开 W2，发出更新的详情请求 F2（挂起）→ F1 先以旧记录成功返回。
final class WalletReviewR3Tests: WalletFlowTestCase {
    /// R3-01：F2 仍在途 → 第一页正常提交（加载结束），W2 不置顶、不采用 F1 的旧记录、没有详情；F2 仍挂着，不另发请求。
    func testSupersededFocusNotPinnedWhileNewerDetailInFlight() async throws {
        let (controller, f2) = try await supersededFocus()
        XCTAssertEqual(WalletStubProtocol.heldIds, [f2], "F2 仍在途")
        XCTAssertEqual(WalletStubProtocol.requests("GET", "/v1/withdrawals/W2").count, 3, "首次定位、F1、F2 各一次，不另发")
        XCTAssertEqual(RecordSections.make(controller.state).map(\.id), ["month-2026-10"], "没有置顶区")
    }

    /// R3-01：F1 之后 F2 失败 → W2 仍不置顶，保留列表数据（不留 F1 的旧记录），提示失败。
    func testSupersededFocusNotPinnedWhenNewerDetailFails() async throws {
        let (controller, f2) = try await supersededFocus()
        WalletStubProtocol.release(f2, with: .envelope(code: 50001, data: "null", headers: [:]))
        await waitUntil("F2 的失败没有结算") { controller.state.toast != nil }
        await settle()
        XCTAssertNil(controller.state.pinnedId, "F2 失败：不置顶")
        XCTAssertEqual(controller.state.items.map(\.withdrawalId), ["W1", "W2"])
        XCTAssertEqual(controller.state.items.last?.status, "PAYING", "保留列表数据，不留 F1 的旧记录")
        XCTAssertNil(controller.state.details["W2"])
        XCTAssertFalse(controller.state.refreshing)
    }

    /// R3-01：F1 之后 F2 成功 → 此刻才用 F2 的详情置顶并展开（整卡与详情同一份数据）。
    func testSupersededFocusPinnedWithNewerDetailWhenItSucceeds() async throws {
        let (controller, f2) = try await supersededFocus()
        let fresh = WalletSamples.withdrawal("W2", status: "PAID_API", channel: "ch-f2")
        WalletStubProtocol.release(f2, with: .envelope(code: 0, data: fresh, headers: [:]))
        await waitUntil("F2 的详情没有到位") { controller.state.details["W2"]?.channelOrderId == "ch-f2" }
        XCTAssertEqual(controller.state.pinnedId, "W2", "最新请求成功后置顶")
        XCTAssertEqual(controller.state.items.map(\.withdrawalId), ["W2", "W1"])
        XCTAssertEqual(controller.state.items.first?.status, "PAID_API", "置顶的是 F2 的详情")
        XCTAssertTrue(controller.state.expanded.contains("W2"), "置顶单展开")
        XCTAssertEqual(RecordSections.make(controller.state).map(\.id), ["pinned", "month-2026-10"])
    }

    /// 用例期间保持组合存活（执行器的依赖不归它持有）。
    private var fixture: WalletAppFixture?

    override func tearDown() {
        fixture = nil
        super.tearDown()
    }

    /// 公共前置（见类注释）。返回执行器与仍挂起的 F2 编号；返回前已断言第一页正常提交且没有采用 F1 的旧记录。
    private func supersededFocus() async throws -> (WithdrawRecordsController, Int) {
        let list = "{\"items\":[\(WithdrawRecordsTests.item("W1", "PAYING")),"
            + "\(WithdrawRecordsTests.item("W2", "PAYING"))],\"next_cursor\":null}"
        script.ok("GET /v1/withdrawals", list)
        script.on("GET /v1/withdrawals/W2", .envelope(code: 50001, data: "null", headers: [:]), .hold)
        let fixture = make()
        self.fixture = fixture
        let entry = try XCTUnwrap(fixture.open(
            WalletRoutes.withdrawRecords, params: [WalletRoutes.withdrawalId: .string("W2")]
        ))
        let controller = try XCTUnwrap(entry.controller as? WithdrawRecordsController)
        controller.load()
        await waitUntil("首次加载没有结算") { controller.state.phase == .content && !controller.firstPagePending }
        await settle()
        XCTAssertNil(controller.state.pinnedId, "前提：首次定位失败不置顶")
        XCTAssertNil(controller.state.details["W2"], "前提：W2 没有详情")
        if let toast = controller.state.toast {
            controller.consumeToast(toast.id)
        }

        XCTAssertTrue(controller.refresh(), "下拉刷新开始")
        await waitUntil("定位请求 F1 没有发出") { WalletStubProtocol.heldIds.count == 1 }
        XCTAssertTrue(controller.firstPagePending, "前提：第一页还没提交")
        RecordsActions.make(controller, controller.state).toggle("W2")
        await waitUntil("展开的详情请求 F2 没有发出") { WalletStubProtocol.heldIds.count == 2 }
        let held = WalletStubProtocol.heldIds
        let stale = WithdrawRecordsTests.item("W2", "PENDING_REVIEW")
        WalletStubProtocol.release(held[0], with: .envelope(code: 0, data: stale, headers: [:]))
        await waitUntil("第一页没有提交") { !controller.firstPagePending }
        await settle()

        XCTAssertEqual(controller.state.phase, .content, "第一页加载正常结束")
        XCTAssertFalse(controller.state.refreshing, "刷新指示结束")
        XCTAssertNil(controller.state.pinnedId, "被取代的定位请求不置顶")
        XCTAssertEqual(controller.state.items.map(\.withdrawalId), ["W1", "W2"], "按列表顺序")
        XCTAssertEqual(controller.state.items.last?.status, "PAYING", "不采用 F1 的旧记录")
        XCTAssertNil(controller.state.details["W2"], "F1 的旧记录不进详情")
        XCTAssertTrue(controller.state.expanded.contains("W2"), "用户的展开保留")
        return (controller, held[1])
    }
}
