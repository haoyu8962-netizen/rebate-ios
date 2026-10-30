@testable import Couli
import DesignSystem
import Foundation
import Router
import SwiftUI
import UIKit
import Wallet
import WalletCore
import XCTest

/// APP-09v-b 资金页口径（brief §0「金额 null 不补 0、不推算、未知状态不显示写操作」、§5 资金零改动、G23 记录页不随钱包遮罩）：
/// - 明细金额逐项取服务端字段（independent：申请 12345、手续费 123、税 456、到账 9876 故意不满足加减关系）；
/// - 未知状态 / 不认识的通道：标题「处理中」，没有复制、修改收款账号、客服任何入口；
/// - 回调去向与次数（与真实点击同一份渲染时回调）：复制一次只写一次统一剪贴板入口；修改收款账号只进 PayoutAccount {}；客服只进统一出口；
///   旧画面（版本已前进）的回调零写入、零导航。
/// 后两组是对现行执行器的回归守卫（底版应为绿，实现后必须仍绿）。
@MainActor
final class RecordsVisualMoneyTests: RecordsVisualTestCase {
    /// 明细只显示服务端原值，不由申请 − 费 − 税 推算到账；手续费 / 税非 0 照写。
    func testIndependentAmountsShownAsIs() async throws {
        try await openRecords("independent", expand: ["INDEPENDENT"])
        let prefix = "records.detail.INDEPENDENT.field."
        XCTAssertEqual(try text(prefix + "amount.value"), RecordsVisualData.money(12345))
        XCTAssertEqual(try text(prefix + "fee.value"), RecordsVisualData.money(123))
        XCTAssertEqual(try text(prefix + "tax.value"), RecordsVisualData.money(456))
        XCTAssertEqual(try text(prefix + "net.value"), RecordsVisualData.money(9876))
        XCTAssertFalse(recordTexts.contains { $0.contains(RecordsVisualData.money(12345 - 123 - 456)) }, "不推算到账")
        XCTAssertEqual(try text("records.detail.INDEPENDENT.header.amount"), RecordsVisualData.money(12345))
    }

    /// 未知状态（FUTURE_STATUS，报文里故意带 fail_action 与流水号）：胶囊「处理中」中性，没有任何写操作或复制入口，流水号不出现。
    func testUnknownStatusIsReadOnly() async throws {
        try await openRecords("unknown", expand: ["UNKNOWN"])
        let prefix = "records.detail.UNKNOWN."
        XCTAssertEqual(try text(prefix + "header.pill.text"), "处理中")
        for id in ["changeAccount", "copy", "tradeNo.value", "service"] {
            XCTAssertNil(records?.probes[prefix + id], "未知状态不出 \(id)")
        }
        XCTAssertFalse(recordTexts.contains { $0.contains("MUST_NOT_COPY") }, "不显示流水号")
        XCTAssertTrue(probes(prefix: prefix + "status.").isEmpty, "未知状态没有副文案")
    }

    /// 执行层守卫（底版应为绿）：未知状态的复制 / 修改收款账号回调零写入、零导航。
    func testUnknownStatusCallbacksInert() async throws {
        let (page, _) = try await openRecords("unknown", expand: ["UNKNOWN"], needProbes: false)
        let controller = try XCTUnwrap(page.controller)
        let depth = page.fixture.router.path.count
        let actions = RecordsActions.make(controller, controller.state)
        actions.copy("UNKNOWN", "MUST_NOT_COPY")
        actions.changeAccount("UNKNOWN")
        await quietWindow(1)
        XCTAssertEqual(page.fixture.system.changeCount, 0, "未知状态复制零写入")
        XCTAssertEqual(page.fixture.router.path.count, depth, "未知状态修改账号零导航")
    }

    /// 微信零钱（不认识的通道，G-W10）：失败也不出修改收款账号 / 客服。
    func testWechatHasNoActions() async throws {
        try await openRecords("wechat", expand: ["WECHAT"])
        let prefix = "records.detail.WECHAT."
        XCTAssertNotNil(records?.probes[prefix + "header.amount"], "展开卡照常")
        for id in ["changeAccount", "copy", "service"] {
            XCTAssertNil(records?.probes[prefix + id], "微信不出 \(id)")
        }
    }

    /// G23：钱包金额隐藏开着时，记录页金额照常显示（不遮罩）。
    func testRecordsNotMaskedByWalletHide() async throws {
        let page = try freshRecords()
        page.wallet.mask.set(true)
        try page.server.setPage(RecordsVisualData.page("list"))
        try await page.show()
        _ = await page
            .stable { $0.controller?.state.phase == .content && $0.probes["records.row.PENDING.amount"] != nil }
        XCTAssertTrue(try text("records.row.PENDING.amount").contains(RecordsVisualData.money(1000)), "记录页不遮罩")
        XCTAssertFalse(recordTexts.contains("****"), "没有星号金额")
    }

    /// 回调去向与次数（守卫）：复制恰一次统一写入口且内容 = 流水号；修改收款账号恰一次 PayoutAccount {}；客服恰一次统一出口；
    /// 刷新后旧画面的回调零写入、零导航（共性第 4、63 条）。
    func testCallbacksExactlyOnceAndStaleIgnored() async throws {
        let (page, _) = try await openRecords(expand: ["PAID", "FAILED"], needProbes: false)
        let controller = try XCTUnwrap(page.controller)
        let stale = RecordsActions.make(controller, controller.state)
        let actions = RecordsActions.make(controller, controller.state)
        actions.copy("PAID", "20260928200040011100")
        XCTAssertEqual(page.fixture.system.changeCount, 1, "复制恰一次")
        XCTAssertEqual(page.fixture.system.last, "20260928200040011100")
        let writes = WalletStubProtocol.requests.filter { $0.method != "GET" }
        XCTAssertTrue(writes.isEmpty, "记录页零写请求：\(writes.map(\.path))")
        // 刷新让版本前进；旧画面的回调全部失效
        _ = controller.refresh()
        await waitUntil("刷新没完成", timeout: 5) { !controller.firstPagePending && controller.state.version > 0 }
        await quietWindow(0.5)
        let depth = page.fixture.router.path.count
        stale.copy("PAID", "20260928200040011100")
        stale.changeAccount("FAILED")
        await quietWindow(1)
        XCTAssertEqual(page.fixture.system.changeCount, 1, "旧回调复制零写入")
        XCTAssertEqual(page.fixture.router.path.count, depth, "旧回调零导航")
        RecordsActions.make(controller, controller.state).changeAccount("FAILED")
        await waitUntil("修改收款账号没有进 PayoutAccount", timeout: 5) {
            page.fixture.router.path.last?.route == WalletRoutes.payoutAccount
        }
        XCTAssertEqual(page.fixture.router.path.filter { $0.route == WalletRoutes.payoutAccount }.count, 1, "恰一次")
        XCTAssertEqual(page.fixture.router.path.last?.params.isEmpty, true, "PayoutAccount {}")
    }
}
