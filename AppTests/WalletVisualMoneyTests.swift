@testable import Couli
import DesignSystem
import Foundation
import Router
import UIKit
import Wallet
import WalletCore
import XCTest

/// APP-09v-a 资金红线（钱包是资金只读页，brief §0「资金页口径」、§3）：金额只取服务端字段、不相加不推算、null 不补 0；视觉改动不改置灰判定、
/// 去向与请求次数（G-W02 不预取 rules、G-W03 不取 getMe、G-W05 旧数据置灰）。按钮回调取页面渲染时的同一份（`WalletActions.make`，
/// 生产 WalletScreen 同一个构造）；真实点击另在 UITests/WalletVisualUITests（Debug 请求记录断言去向与次数）。
@MainActor
final class WalletVisualMoneyTests: WalletVisualTestCase {
    /// visualWallet.no_sum 故意让各字段对不上：页面只显示服务端原值，不出现 available、estimated_fen、任何相加 / 相减结果。
    func testNoSumShowsServerFieldsOnly() async throws {
        try await openWallet("no_sum", waitFor: "wallet.paused")
        XCTAssertEqual(
            try text("wallet.hero.amount"),
            WalletVisualData.money(1234),
            "可提现 = withdrawable_fen（不是 available）"
        )
        XCTAssertEqual(try text("wallet.hero.frozen.value"), WalletVisualData.money(456))
        XCTAssertEqual(try text("wallet.hero.withdrawn.value"), WalletVisualData.money(789))
        XCTAssertEqual(try text("wallet.estimate.left.value"), WalletVisualData.money(5678), "预估 = estimated_total_fen")
        XCTAssertEqual(try text("wallet.estimate.left.note"), "其中已收货 " + WalletVisualData.money(2))
        XCTAssertEqual(try text("wallet.paused.text"), "其中 " + WalletVisualData.money(3) + " 暂缓入账")
        // available 9900、estimated_fen 1、以及常见的错误推算（相加 / 相减）都不能出现
        for fen: Int64 in [9900, 1, 1234 + 456, 1 + 2 + 3, 5678 - 2, 1234 + 789, 2 + 3] {
            let wrong = WalletVisualData.money(fen)
            XCTAssertFalse(allTexts.contains(wrong), "出现了非服务端字段的金额 \(wrong)")
        }
    }

    /// 缺字段 / null / 字符串金额：整份摘要不可用（错误态），不补 0、不显示部分金额。
    func testMalformedSummaryIsNotZeroFilled() async throws {
        let base = try WalletVisualData.summary("normal")
        var missing = base
        missing.removeValue(forKey: "frozen_fen")
        var null = base
        null["withdrawable_fen"] = NSNull()
        var string = base
        string["estimated_total_fen"] = "5678"
        for (name, object) in [("缺字段", missing), ("null", null), ("字符串金额", string)] {
            let page = try fresh()
            try WalletVisualScript.summary(page.script, object: object)
            try await page.showWallet()
            _ = await page.stable { $0.controller?.state.phase == .error }
            XCTAssertEqual(page.controller?.state.phase, .error, "\(name)：错误态")
            XCTAssertNil(page.controller?.state.summary, "\(name)：不造摘要")
            XCTAssertNil(host?.probes["wallet.hero"], "\(name)：不画主卡（不显示 ¥0）")
        }
    }

    /// G-W02：【提现】只进 Withdraw（空参数、一次），钱包页不预取 rules、不发写请求；风控冻结也可点（BR-WDR-05 细则）。
    func testWithdrawGoesToWithdrawWithoutRulesPrefetch() async throws {
        for summary in ["normal", "risk"] {
            let (page, _) = try await openWallet(summary, waitFor: nil)
            let controller = try XCTUnwrap(page.controller)
            XCTAssertTrue(controller.state.withdrawEnabled, "\(summary)：【提现】可点")
            let before = WalletStubProtocol.requests.count
            WalletActions.make(controller, controller.state).withdraw()
            await waitUntil("\(summary)：没有进 Withdraw") { page.fixture.router.path.last?.route == WalletRoutes.withdraw }
            let pushed = page.fixture.router.path.filter { $0.route == WalletRoutes.withdraw }
            XCTAssertEqual(pushed.count, 1, "\(summary)：恰好一次")
            XCTAssertEqual(pushed.first?.params, [:], "\(summary)：空参数")
            let after = WalletStubProtocol.requests.dropFirst(before)
            XCTAssertFalse(after.contains { $0.path == "/v1/withdrawals/rules" }, "\(summary)：钱包不预取 rules（G-W02）")
            XCTAssertFalse(after.contains { $0.method != "GET" }, "\(summary)：无写请求")
        }
    }

    /// 置灰的三种情形（待抵扣、withdraw_enabled=false、断网旧数据）：回调不导航、不发请求。
    func testDisabledWithdrawDoesNothing() async throws {
        for summary in ["negative", "disabled"] {
            let (page, _) = try await openWallet(summary, waitFor: nil)
            try assertWithdrawInert(page, summary)
        }
        let (page, _) = try await openStale(waitFor: nil)
        try assertWithdrawInert(page, "断网旧数据")
    }

    /// 眼睛：只切本机偏好，不发请求、不换路由；再点恢复原值。
    func testMaskToggleAddsNoRequest() async throws {
        let (page, _) = try await openWallet("normal", waitFor: nil)
        let controller = try XCTUnwrap(page.controller)
        let before = WalletStubProtocol.requests.count
        let path = page.fixture.router.path
        WalletActions.make(controller, controller.state).toggleMask()
        XCTAssertTrue(page.wallet.mask.hidden)
        WalletActions.make(controller, controller.state).toggleMask()
        XCTAssertFalse(page.wallet.mask.hidden)
        await settle()
        XCTAssertEqual(WalletStubProtocol.requests.count, before, "眼睛不发请求")
        XCTAssertEqual(page.fixture.router.path, path, "眼睛不导航")
    }

    /// 提现记录、风控条、入口：去向与参数不变（WithdrawRecords {}、RiskNotice {}、OrderList {}、Ledger {}），各一次，无写请求。
    func testOtherExitsKeepRoutes() async throws {
        let cases: [(summary: String, route: String)] = [
            ("normal", WalletRoutes.withdrawRecords), ("risk", WalletRoutes.riskNotice),
            ("normal", WalletRoutes.orderList), ("normal", WalletRoutes.ledger),
        ]
        for (summary, route) in cases {
            let act: (WalletActions) -> Void = route == WalletRoutes
                .withdrawRecords ? { $0.records() } : { $0.entry(route) }
            let (page, _) = try await openWallet(summary, waitFor: nil)
            let controller = try XCTUnwrap(page.controller)
            let before = WalletStubProtocol.requests.count
            act(WalletActions.make(controller, controller.state))
            let router = page.fixture.router
            if route == WalletRoutes.orderList {
                // 订单是 Tab 根：切 Tab，不入栈（WalletPageTests 同口径）
                await waitUntil("没有切到 OrderList") { router.tabRoot.route == route }
                XCTAssertEqual(router.tabRoot.params, [:], "OrderList 空参数")
            } else {
                await waitUntil("没有进 \(route)") { router.path.last?.route == route }
                XCTAssertEqual(router.path.filter { $0.route == route }.count, 1, "\(route) 一次")
                XCTAssertEqual(router.path.last?.params, [:], "\(route) 空参数")
            }
            XCTAssertFalse(WalletStubProtocol.requests.dropFirst(before).contains { $0.method != "GET" }, "无写请求")
            // a v3（评审 r1 S2-1）：进程内不渲染目的页（只有 Router 入栈 / 切 Tab），点击之后的任何 getMe 都是钱包发的——必须为零（G-W03）
            await settle()
            let mine = WalletStubProtocol.requests.dropFirst(before).filter { $0.path == "/v1/me" }
            XCTAssertEqual(mine.count, 0, "\(route)：点击时钱包不取 getMe（G-W03）")
        }
    }

    private func assertWithdrawInert(_ page: WalletVisualHost, _ name: String, file: StaticString = #filePath,
                                     line: UInt = #line) throws {
        let controller = try XCTUnwrap(page.controller, file: file, line: line)
        XCTAssertFalse(controller.state.withdrawEnabled, "\(name)：置灰", file: file, line: line)
        let before = WalletStubProtocol.requests.count
        let path = page.fixture.router.path
        WalletActions.make(controller, controller.state).withdraw()
        XCTAssertEqual(page.fixture.router.path, path, "\(name)：不导航", file: file, line: line)
        XCTAssertEqual(WalletStubProtocol.requests.count, before, "\(name)：不发请求", file: file, line: line)
    }
}
