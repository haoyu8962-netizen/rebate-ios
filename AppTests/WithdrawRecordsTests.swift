@testable import Couli
import CouliNetwork
import Foundation
import Router
import Wallet
import WalletCore
import XCTest

/// 提现记录（AC-S2-20 ①–④ 文案、AC-S2-25、BR-WDR-25、G08、G27、G30）：状态标题与副文案、带 withdrawal_id 打开放在最前并展开、30701 静默、
/// 交易流水号【复制】只走统一写入口、【修改收款账号】→ PayoutAccount、【联系客服】→ Help。
final class WithdrawRecordsTests: WalletFlowTestCase {
    func records(_ fixture: WalletAppFixture, focus: String? = nil) async throws -> WithdrawRecordsController {
        let params: [String: JSONValue] = focus.map { [WalletRoutes.withdrawalId: .string($0)] } ?? [:]
        let entry = try XCTUnwrap(fixture.open(WalletRoutes.withdrawRecords, params: params))
        let controller = try XCTUnwrap(entry.controller as? WithdrawRecordsController)
        controller.load()
        await waitUntil { controller.state.phase != .loading && !controller.firstPagePending }
        return controller
    }

    static func item(_ id: String, _ status: String, reason: String? = nil, failAction: String? = nil) -> String {
        WalletSamples.withdrawal(id, status: status)
            .replacingOccurrences(
                of: "\"reason_code\":null",
                with: "\"reason_code\":\(reason.map { "\"\($0)\"" } ?? "null")"
            )
            .replacingOccurrences(of: "\"fail_action\":null",
                                  with: "\"fail_action\":\(failAction.map { "\"\($0)\"" } ?? "null")")
    }

    /// AC-S2-20 / AC-S2-25：PENDING_REVIEW（manual）、APPROVED、PAYING、PAID_API、REJECTED、FAILED（含 fail_action）的标题与副文案按 G08。
    func testStatusTitlesAndSubLines() async throws {
        let items = [
            Self.item("W1", "PENDING_REVIEW"), Self.item("W2", "APPROVED"), Self.item("W3", "PAYING"),
            Self.item("W4", "PAID_API"), Self.item("W5", "REJECTED", reason: "ORDER_ABNORMAL"),
            Self.item("W6", "FAILED", reason: "PAYEE_ACCOUNT_STATUS_ERROR", failAction: "change_payout_account"),
        ]
        script.ok("GET /v1/withdrawals", "{\"items\":[\(items.joined(separator: ","))],\"next_cursor\":null}")
        let fixture = make()
        let controller = try await records(fixture)
        let texts = WalletDraftTexts()
        let rendered = controller.state.items.map { item -> (String, [String]) in
            let display = WithdrawalText.of(item, slaText: nil)
            return (texts.text(display.titleKey), WithdrawalText.render(display, texts: texts) { "¥\($0 / 100)" })
        }
        XCTAssertEqual(rendered.map(\.0), ["审核中", "审核中", "打款中", "已到账", "未通过", "打款未成功"])
        XCTAssertEqual(rendered[0].1, ["人工审核，工作日 24 小时内处理，节假日顺延", "¥10 已冻结"])
        XCTAssertEqual(rendered[2].1, ["处理中，结果会通知你"])
        XCTAssertEqual(rendered[3].1, ["已转入支付宝 138****5678，到账 ¥10"])
        XCTAssertEqual(rendered[4].1, ["部分订单状态待核实，请稍后重新申请；¥10 已退回可提现余额"])
        XCTAssertEqual(rendered[5].1, ["收款支付宝账号状态异常；¥10 已退回可提现余额，可修改收款账号后重新提现"])
        let actions = RecordsActions.make(controller, controller.state)
        actions.changeAccount("W6")
        // 要实名的资金页：本会话还没查过实名状态时先取 GET /v1/me 再打开（iOS I02）
        await waitUntil { fixture.router.path.last?.route == WalletRoutes.payoutAccount }
    }

    /// 带 withdrawal_id 打开：另取详情，放在最前并展开；PAID_API 的交易流水号【复制】走统一写入口（先记自写 hash），剪贴板内容等于
    /// channel_order_id，台账有记录；记录失败就不写、提示失败。
    func testFocusFrontExpandedAndCopyThroughWriter() async throws {
        let fixture = make()
        let controller = try await records(fixture, focus: "W9")
        XCTAssertEqual(controller.state.items.first?.withdrawalId, "W9")
        XCTAssertTrue(controller.state.expanded.contains("W9"))
        XCTAssertEqual(WalletStubProtocol.requests("GET", "/v1/withdrawals/W9").count, 1)
        let copy = RecordsActions.make(controller, controller.state).copy
        copy("W9", "fixture-channel-001")
        XCTAssertEqual(fixture.system.last, "fixture-channel-001")
        XCTAssertNotNil(fixture.ledgerStore.read("self_written"), "台账有自写 hash")
        XCTAssertEqual(controller.state.toast?.key, "withdraw_detail.copied")
        fixture.ledgerStore.failWrites = true
        RecordsActions.make(controller, controller.state).copy("W9", "fixture-channel-001")
        XCTAssertEqual(controller.state.toast?.key, "withdraw_detail.copy_failed", "记不下就不写、提示失败")
        XCTAssertEqual(fixture.system.changeCount, 1)
    }

    /// 30701（不是本人的按不存在处理）：只显示列表，不提示。
    func testFocusNotFoundIsSilent() async throws {
        script.fail("GET /v1/withdrawals/W404", 30701)
        let fixture = make()
        let controller = try await records(fixture, focus: "W404")
        XCTAssertEqual(controller.state.items.map(\.withdrawalId), ["W1"])
        XCTAssertNil(controller.state.toast)
    }

    /// 空态；翻页按 next_cursor（新一轮第一页回来前不翻页，共性第 20 条）；【联系客服】→ Help。
    func testEmptyPagingAndContact() async throws {
        script.ok("GET /v1/withdrawals", "{\"items\":[],\"next_cursor\":null}")
        let fixture = make()
        let empty = try await records(fixture)
        XCTAssertEqual(empty.state.phase, .empty)
        fixture.router.path.removeAll()
        script.on(
            "GET /v1/withdrawals",
            .envelope(code: 0, data: "{\"items\":[\(Self.item("W1", "PAYING"))],\"next_cursor\":\"p1\"}", headers: [:]),
            .envelope(code: 0, data: "{\"items\":[\(Self.item("W2", "PAYING"))],\"next_cursor\":null}", headers: [:])
        )
        let controller = try await records(fixture)
        RecordsActions.make(controller, controller.state).loadMore()
        await waitUntil { controller.state.items.count == 2 }
        XCTAssertTrue(WalletStubProtocol.requests("GET", "/v1/withdrawals").last?.query.contains("cursor=p1") ?? false)
        RecordsActions.make(controller, controller.state).contact()
        XCTAssertEqual(fixture.router.path.last?.route, WalletRoutes.help)
    }
}
