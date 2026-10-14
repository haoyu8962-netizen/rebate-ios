@testable import Couli
import CouliNetwork
import Foundation
import Generated
import Router
import SwiftUI
import Wallet
import WalletCore
import XCTest

/// APP-09 iOS 第 2 轮评审 R2-01、R2-03、R2-04、R2-05、R2-06（R2-02 的界面用例在 UITests/WalletReviewR2UITests.swift）。
final class WalletReviewR2Tests: WalletFlowTestCase {
    // MARK: - R2-01 放弃 completed 原结果 30306

    /// R2-01：已有允许的 rules → 结果未知 → 放弃返回 completed、original.code=30306 → 与直接得到 30306 同一出口：记下服务端阻断；随后重取
    /// rules 失败（旧的允许 rules 仍在）→【提交】仍禁用，不发提交。
    func testAbandonCompletedOriginal30306KeepsSubmitBlockedWhenRulesFail() async throws {
        let fixture = make()
        let controller = try await withdraw(fixture)
        try await enterPending(controller)
        XCTAssertEqual(controller.state.rules?.canWithdraw, true, "前提：已有允许提现的 rules")
        XCTAssertFalse(controller.state.serverBlocked)
        let original = "{\"code\":30306,\"msg\":\"\",\"data\":null}"
        script.ok("POST /v1/idempotency-keys/abandon", "{\"outcome\":\"completed\",\"original\":\(original)}")
        script.fail("GET /v1/withdrawals/rules", 50001)
        let rulesBefore = WalletStubProtocol.requests("GET", "/v1/withdrawals/rules").count
        flowActions(controller.flow).askAbandon()
        flowActions(controller.flow).abandon()
        await waitUntil("放弃没有结算") { controller.flow.state.pending == nil }
        await waitUntil("放弃之后没有重取 rules 或重取没有失败") {
            WalletStubProtocol.requests("GET", "/v1/withdrawals/rules").count > rulesBefore
                && controller.state.readError != nil
        }
        await settle()
        XCTAssertEqual(controller.flow.state.error?.key, "error.30306", "显示原结果的错误")
        XCTAssertTrue(controller.state.serverBlocked, "completed 原结果 30306：记下服务端阻断")
        XCTAssertEqual(controller.state.rules?.canWithdraw, true, "rules 重取失败，旧的允许 rules 仍在")
        XCTAssertEqual(controller.state.inputFen, 1000, "前提：金额仍合法")
        let display = try XCTUnwrap(controller.state.display())
        let enabled = display.submitEnabled && controller.flow.state.canSubmit && !controller.state.serverBlocked
        XCTAssertFalse(enabled, "【提交】仍禁用")
        let postsBefore = posts.count
        actions(controller).submit()
        await settle()
        XCTAssertEqual(posts.count, postsBefore, "阻断期间点【提交】不发请求")
    }

    // MARK: - R2-03 scenePhase inactive

    /// R2-03：经 CouliApp 的 scenePhase 接线（AppWallet.scenePhaseChanged）：实名查询在途时 inactive → active，查询成功也不再打开提现页；
    /// 提交在途时 inactive → active，迟到的 44001 不弹窗、迟到的 10003 不开二次验证面板（结论只留在页内）。
    func testInactiveThenActiveVoidsWaitingNavigationAndOverlays() async throws {
        script.on("GET /v1/me", .hold)
        let fixture = make()
        _ = try XCTUnwrap(fixture.open(WalletRoutes.wallet))
        let origin = try XCTUnwrap(fixture.router.path.last?.id)
        fixture.wallet.open(WalletRoutes.withdraw, params: [:], from: origin)
        await waitUntil("实名查询没有发出") { WalletStubProtocol.heldIds.count == 1 }
        fixture.wallet.scenePhaseChanged(.inactive)
        fixture.wallet.scenePhaseChanged(.active)
        let heldMe = try XCTUnwrap(WalletStubProtocol.heldIds.first)
        WalletStubProtocol.release(heldMe, with: .envelope(code: 0, data: WalletSamples.me, headers: [:]))
        await waitUntil("实名查询没有回来") { fixture.wallet.realnameVerified() }
        await settle()
        XCTAssertEqual(fixture.router.path.last?.id, origin, "inactive 过的点击不再导航")

        script.ok("GET /v1/me", WalletSamples.me)
        let controller = try await withdraw(fixture)
        await typeAmount(controller, "10")
        for code in [44001, 10003] {
            script.on("POST /v1/withdrawals", .hold)
            actions(controller).submit()
            await waitUntil("提交没有发出") { WalletStubProtocol.heldIds.count == 1 }
            let before = controller.flow.state.error?.id
            fixture.wallet.scenePhaseChanged(.inactive)
            fixture.wallet.scenePhaseChanged(.active)
            await waitUntil("回到 active 后页面没有变成可见") { controller.flow.visibleNow }
            let held = try XCTUnwrap(WalletStubProtocol.heldIds.first)
            WalletStubProtocol.release(held, with: .envelope(code: code, data: "null", headers: [:]))
            await waitUntil("迟到的 \(code) 没有结算") {
                controller.flow.state.error != nil && controller.flow.state.error?.id != before
            }
            await settle()
            XCTAssertNil(controller.flow.state.riskDialog, "迟到的 \(code) 不弹风控弹窗")
            XCTAssertNil(controller.flow.stepUp.state, "迟到的 \(code) 不开二次验证面板")
        }
    }

    // MARK: - R2-04 刷新后再次分页插入展开的记录

    /// R2-04：第二页 W2 已展开且有 PAID_API 详情（流水号）→ 下拉刷新，第一页不含 W2（旧详情作废、W2 仍展开）→ 再次分页插入 W2 → 按本轮重取
    /// 详情，展开卡恢复流水号。
    func testPagingReinsertedExpandedRecordRefetchesDetail() async throws {
        let page1 = "{\"items\":[\(WithdrawRecordsTests.item("W1", "PAYING"))],\"next_cursor\":\"p1\"}"
        let page2 = "{\"items\":[\(WithdrawRecordsTests.item("W2", "PENDING_REVIEW"))],\"next_cursor\":null}"
        script.on(
            "GET /v1/withdrawals", .envelope(code: 0, data: page1, headers: [:]),
            .envelope(code: 0, data: page2, headers: [:]), .envelope(code: 0, data: page1, headers: [:]),
            .envelope(code: 0, data: page2, headers: [:])
        )
        let fixture = make()
        let entry = try XCTUnwrap(fixture.open(WalletRoutes.withdrawRecords))
        let controller = try XCTUnwrap(entry.controller as? WithdrawRecordsController)
        controller.load()
        await waitUntil { controller.state.phase == .content && !controller.firstPagePending }
        RecordsActions.make(controller, controller.state).loadMore()
        await waitUntil { controller.state.items.count == 2 }
        RecordsActions.make(controller, controller.state).toggle("W2")
        await waitUntil("详情没有到位") { controller.state.details["W2"]?.channelOrderId == "fixture-channel-001" }
        let detailsBefore = WalletStubProtocol.requests("GET", "/v1/withdrawals/W2").count
        XCTAssertTrue(controller.refresh(), "刷新开始")
        await waitUntil { !controller.firstPagePending && controller.state.items.map(\.withdrawalId) == ["W1"] }
        XCTAssertNil(controller.state.details["W2"], "前提：刷新后旧详情作废")
        XCTAssertTrue(controller.state.expanded.contains("W2"), "前提：W2 仍是展开")
        RecordsActions.make(controller, controller.state).loadMore()
        await waitUntil("分页没有回来") { controller.state.items.count == 2 }
        await waitUntil("再次插入的展开记录没有重取详情") {
            controller.state.details["W2"]?.channelOrderId == "fixture-channel-001"
        }
        XCTAssertEqual(WalletStubProtocol.requests("GET", "/v1/withdrawals/W2").count, detailsBefore + 1, "只重取一次")
        XCTAssertEqual(controller.state.items.last?.status, "PAID_API", "整卡与详情同一份数据")
    }

    // MARK: - R2-05 定位历史月份的记录

    /// R2-05：按 withdrawal_id 定位一张 9 月记录，普通列表含 10 月与其他 9 月记录 → 定位单在独立的置顶区，其余每个月只有一组、分区标识唯一；
    /// 继续分页（含 9 月、8 月与定位单本身）后仍不重复。
    func testFocusedHistoricalRecordPinnedWithUniqueMonthSections() async throws {
        let page1 = "{\"items\":[\(Self.record("W10", "2026-10-05")),\(Self.record("W9b", "2026-09-25"))],"
            + "\"next_cursor\":\"p1\"}"
        let page2 = "{\"items\":[\(Self.record("W9a", "2026-09-20")),\(Self.record("W9c", "2026-09-10")),"
            + "\(Self.record("W8", "2026-08-03"))],\"next_cursor\":null}"
        script.on(
            "GET /v1/withdrawals", .envelope(code: 0, data: page1, headers: [:]),
            .envelope(code: 0, data: page2, headers: [:])
        )
        script.ok("GET /v1/withdrawals/W9a", Self.record("W9a", "2026-09-20"))
        let fixture = make()
        let entry = try XCTUnwrap(fixture.open(
            WalletRoutes.withdrawRecords, params: [WalletRoutes.withdrawalId: .string("W9a")]
        ))
        let controller = try XCTUnwrap(entry.controller as? WithdrawRecordsController)
        controller.load()
        await waitUntil { controller.state.phase == .content && !controller.firstPagePending }
        var sections = RecordSections.make(controller.state)
        XCTAssertEqual(sections.map(\.id), ["pinned", "month-2026-10", "month-2026-09"])
        XCTAssertEqual(sections.first?.items.map(\.withdrawalId), ["W9a"], "定位单在置顶区")
        XCTAssertEqual(sections.last?.items.map(\.withdrawalId), ["W9b"])

        RecordsActions.make(controller, controller.state).loadMore()
        await waitUntil("分页没有回来") { controller.state.nextCursor == nil && !controller.state.loadingMore }
        sections = RecordSections.make(controller.state)
        XCTAssertEqual(sections.map(\.id), ["pinned", "month-2026-10", "month-2026-09", "month-2026-08"])
        XCTAssertEqual(Set(sections.map(\.id)).count, sections.count, "分区标识唯一")
        XCTAssertEqual(sections[2].items.map(\.withdrawalId), ["W9b", "W9c"], "同一个月只有一组")
        let ids = sections.flatMap(\.items).map(\.withdrawalId)
        XCTAssertEqual(ids, ["W9a", "W10", "W9b", "W9c", "W8"], "定位单不重复")
    }

    // MARK: - R2-06 实名表单首错定位

    /// R2-06：真实实名页收到 20001、fields=[id_no] → 身份证号旁的错误提示作为焦点与滚动目标，视图出现后播报一次；普通重绘不再播报；下一次
    /// 20001 事件再播报一次；已填内容保留。
    func testRealNameFirstFieldErrorAnnouncedOncePerEvent() async throws {
        let spoken = SpokenLog()
        WalletAnnounceProbe.observe = { spoken.lines.append($0) }
        defer { WalletAnnounceProbe.observe = nil }
        let fixture = make()
        fixture.wallet.installBackends(realname: FieldErrorRealName(), labor: nil)
        await verifyRealname(fixture)
        let entry = try XCTUnwrap(fixture.open(WalletRoutes.realName))
        let page = try XCTUnwrap(entry.controller as? RealNameController)
        RealNameActions.make(page, page.state).name("测试")
        RealNameActions.make(page, page.state).idNo("000000000000000003")
        let host = HostedPage(entry.screen())
        defer { host.close() }
        await host.pump()
        let fieldError = WalletDraftTexts().text("error.20001")

        await submitRealName(page)
        await waitUntil("没有字段错误") { page.state.fieldErrors == [RealNameController.fieldId] }
        await host.pump(until: { !spoken.lines.isEmpty })
        XCTAssertEqual(spoken.lines, [fieldError], "首个错误字段的提示播报一次")
        XCTAssertNil(page.state.error, "带字段的 20001 不另出页内错误条（不重复播报）")
        XCTAssertEqual(page.state.idNo, "000000000000000003", "保留输入")
        XCTAssertEqual(page.state.name, "测试")

        page.objectWillChange.send()
        await host.pump(rounds: 15)
        XCTAssertEqual(spoken.lines.count, 1, "重绘不重复播报")

        let firstEvent = page.state.fieldErrorId
        await submitRealName(page)
        await waitUntil { page.state.fieldErrorId > firstEvent }
        await host.pump(until: { spoken.lines.count == 2 })
        XCTAssertEqual(spoken.lines, [fieldError, fieldError], "新的 20001 事件再播报一次")
    }

    private func submitRealName(_ page: RealNameController) async {
        RealNameActions.make(page, page.state).submit()
        RealNameActions.make(page, page.state).toggleConsent()
        RealNameActions.make(page, page.state).agree()
        await waitUntil("实名没有提交") { !page.state.submitting }
    }

    static func record(_ id: String, _ day: String) -> String {
        WalletSamples.withdrawal(id)
            .replacingOccurrences(of: "2026-10-12T10:00:00+08:00", with: "\(day)T10:00:00+08:00")
    }
}

/// 测试用实名后端：总回 20001、fields=[id_no]（契约没有接口，G01）。不保存姓名、身份证号。
final class FieldErrorRealName: RealNameBackend, @unchecked Sendable {
    func submit(name _: String, idNo _: String, idempotencyKey _: String,
                owner _: RequestOwnership?) async -> ApiResult {
        .failure(
            code: 20001, msg: "", data: Data("{\"fields\":[\"id_no\"]}".utf8), traceId: "fixture-trace",
            effect: ErrorEffect(code: 20001, kind: .toast), idempotencyKey: nil
        )
    }
}
