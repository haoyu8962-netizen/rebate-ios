@testable import Couli
import CouliNetwork
import DesignSystem
import Foundation
import Router
import SwiftUI
import UIKit
import Wallet
import WalletCore
import XCTest

/// 资金回归守卫（全部只等执行器，底版应为绿，实现后必须仍绿）：用页面同一份渲染时回调；真实点击计数在 UITests/WithdrawVisualUITests。
@MainActor
final class WithdrawVisualMoneyTests: WithdrawVisualTestCase {
    /// G-W12：计算中仍可提交，恰一次，金额 = 当前输入，不等估算。
    func testCalculatingStillSubmitsOnce() async throws {
        let host = try await freshPage(estimate: "estimated")
        host.server.setEstimateReply(.hold)
        try await host.show()
        _ = await host.stable { $0.controller?.state.phase == .content }
        host.actions?.amount("10")
        await waitUntil { host.controller?.state.estimate == .calculating }
        XCTAssertEqual(host.controller?.state.display(slaDefault: texts)?.submitEnabled, true, "计算中仍可提交")
        host.server.script.on("POST /v1/withdrawals", .hold)
        host.actions?.submit()
        await waitUntil { self.submits.count == 1 }
        host.actions?.submit()
        await quietWindow(0.4)
        XCTAssertEqual(submits.count, 1, "在途重复点击不增加请求")
        XCTAssertEqual(submits.first?.json["amount_fen"] as? Int, 1000)
        XCTAssertEqual(submits.first?.json.count, 1)
        XCTAssertNotNil(submits.first?.header("Idempotency-Key"))
    }

    /// G-W12 行为（v2 / F2）：页面上的【提交】在计算中仍是可用外观——进程内回调不经按钮 enabled，只有画出来的按钮才看得见条件。
    /// 先正后反：空金额置灰（不是主色实底）→ 计算中主色实底。计算中窗口只有防抖 0.5 秒，UI 真点抢不准，所以用挂起的估算在进程内定住。
    func testG12SubmitRendersEnabledWhileCalculating() async throws {
        let host = try await freshPage(estimate: "estimated")
        host.server.setEstimateReply(.hold)
        try await host.show()
        let empty = await host.stable { $0.controller?.state.phase == .content && $0.probes["withdraw.submit"] != nil }
        XCTAssertLessThan(try submitFill(XCTUnwrap(empty)), 0.1, "前提：空金额【提交】置灰")
        host.actions?.amount("10")
        let calculating = await host.stable(motion: true) {
            $0.controller?.state.estimate == .calculating && $0.probes["withdraw.calculating"] != nil
        }
        XCTAssertEqual(host.controller?.state.estimate, .calculating, "前提：停在计算中")
        XCTAssertGreaterThan(try submitFill(XCTUnwrap(calculating)), 0.8, "G-W12：计算中【提交】不置灰")
    }

    /// 【提交】左端（避开文字）接近主色实底的占比。
    private func submitFill(_ image: UIImage) throws -> Double {
        let slice = try rect("withdraw.submit").insetBy(dx: 4, dy: 8).divided(atDistance: 8, from: .minXEdge).slice
        return share(image, in: slice, near: pixel(CouliColor.brandPrimary, dark: false), tolerance: 12)
    }

    /// 【确定放弃】连发（v2 / F3）：同一份回调同步调两次、在途再走一遍 ask → abandon，都只发一次；挂起期间按钮状态不解除。
    /// 实现的 F3 变异（回调里调两次）被执行器 `abandonConfirmKey` 闸门挡住，是等价变异；本用例守闸门本身（去掉闸门的 F3b 必红），见 v2 交回。
    func testAbandonDoubleCallSendsOnce() async throws {
        let (host, _) = try await openWithdraw(estimate: "estimated", needProbes: false)
        try await enterPending()
        host.server.script.on("POST /v1/idempotency-keys/abandon", .hold)
        host.flowActions?.askAbandon()
        await waitUntil { host.flow?.state.abandonConfirmKey != nil }
        let abandon = try XCTUnwrap(host.flowActions).abandon
        abandon()
        abandon()
        await waitUntil { self.abandons.count >= 1 }
        host.flowActions?.askAbandon()
        host.flowActions?.abandon()
        abandon()
        await quietWindow(0.4)
        XCTAssertEqual(abandons.count, 1, "连发恰一次")
        XCTAssertEqual(host.fixture.api.calls("abandon:createWithdrawal"), 1, "执行器只进一次网络入口（网络层另有一道闸门，请求数看不出）")
        XCTAssertEqual(host.flow?.state.pending?.inFlight, true, "在途")
        XCTAssertEqual(submits.count, 1, "不发提交")
    }

    /// 无效金额（空、0、半截、超位）零提交。
    func testInvalidAmountsZeroWrites() async throws {
        let (host, _) = try await openWithdraw(needProbes: false)
        for text in ["", "0", "0.00", ".", "5.", "1.234"] {
            host.actions?.amount(text)
            host.actions?.submit()
        }
        await quietWindow(0.4)
        XCTAssertEqual(writes, [], "无效金额零写请求")
    }

    /// 【全部提现】只填 max_withdrawable_fen、档位只填该档；都不提交（W39、W41）。
    func testFillOnlyNoWrites() async throws {
        let (host, _) = try await openWithdraw(needProbes: false)
        host.actions?.fillAll()
        XCTAssertEqual(host.controller?.state.amountText, "12", "不是 12.34")
        host.actions?.quick(500)
        XCTAssertEqual(host.controller?.state.amountText, "5")
        await quietWindow(0.3)
        XCTAssertEqual(writes, [], "零写请求")
    }

    /// 【再想想】零请求、【确定放弃】恰一次 abandon（原键）、【确认】恰一次（原键原体）。
    func testAbandonAndConfirmExactlyOnceWithOriginalKey() async throws {
        let (host, _) = try await openWithdraw(estimate: "estimated", needProbes: false)
        try await enterPending()
        let key = try XCTUnwrap(submits.first?.header("Idempotency-Key"))
        host.flowActions?.askAbandon()
        await waitUntil { host.flow?.state.abandonConfirmKey != nil }
        XCTAssertEqual(abandons.count, 0, "打开弹窗零请求")
        host.flowActions?.cancelAbandon()
        await quietWindow(0.3)
        XCTAssertEqual(abandons.count, 0, "【再想想】零请求")
        XCTAssertEqual(submits.count, 1, "【再想想】不发提交")
        XCTAssertNotNil(host.flow?.state.pending, "仍待确认")

        host.flowActions?.askAbandon()
        await waitUntil { host.flow?.state.abandonConfirmKey != nil }
        host.server.script.ok("POST /v1/idempotency-keys/abandon", "{\"outcome\":\"abandoned\",\"original\":null}")
        let abandon = try XCTUnwrap(host.flowActions).abandon
        abandon()
        await waitUntil { host.flow?.state.pending == nil }
        abandon()
        await quietWindow(0.3)
        XCTAssertEqual(abandons.count, 1, "【确定放弃】恰一次，连点不重发")
        XCTAssertEqual(abandons.first?.json["idempotency_key"] as? String, key, "放弃的是原键")
        XCTAssertEqual(submits.count, 1, "放弃不发提交")
        XCTAssertEqual(host.flow?.state.toast?.key ?? SensitiveOutcome.abandonedKey, SensitiveOutcome.abandonedKey)
    }

    func testConfirmExactlyOnceSameKeySameBody() async throws {
        let (host, _) = try await openWithdraw(estimate: "estimated", needProbes: false)
        try await enterPending()
        let first = try XCTUnwrap(submits.first)
        host.server.script.ok("POST /v1/withdrawals", WalletSamples.withdrawal("W-confirm"))
        let confirm = try XCTUnwrap(host.flowActions).confirm
        confirm()
        confirm()
        await waitUntil("确认后没有进记录") { host.fixture.router.path.last?.route == WalletRoutes.withdrawRecords }
        XCTAssertEqual(submits.count, 2, "确认恰一次")
        XCTAssertEqual(submits[1].header("Idempotency-Key"), first.header("Idempotency-Key"), "原键")
        XCTAssertEqual(submits[1].body, first.body, "原体")
        XCTAssertEqual(abandons.count, 0)
    }

    /// 44001：【知道了】零请求、零客服；【联系客服申诉】恰一次出口、不再提交；金额保留。
    func testRiskDialogActions() async throws {
        let (host, _) = try await openWithdraw(amount: "10", estimate: "estimated", needProbes: false)
        host.server.script.fail("POST /v1/withdrawals", 44001)
        host.actions?.submit()
        await waitUntil { host.flow?.state.riskDialog != nil }
        host.flowActions?.dismissRisk()
        await quietWindow(0.3)
        XCTAssertNil(host.flow?.state.riskDialog)
        XCTAssertEqual(submits.count, 1)
        XCTAssertEqual(host.fixture.router.path.last?.route, WalletRoutes.withdraw, "【知道了】不离开")
        XCTAssertEqual(host.controller?.state.amountText, "10", "金额保留")
        host.actions?.submit()
        await waitUntil { host.flow?.state.riskDialog != nil }
        host.actions?.appeal()
        await waitUntil { host.fixture.router.path.last?.route == WalletRoutes.help }
        XCTAssertEqual(submits.count, 2, "申诉不再提交")
    }

    /// G-W13 只挪显示位置：六个金额类码、三个非金额码的错误分类都不变（键、不转字段错误、输入保留、键结束、提交恰一次）。
    func testSubmitErrorClassificationUnchanged() async throws {
        let reasons: [String?] = [
            nil, "below_min", "not_multiple", "above_max", "above_method_max", "net_too_small", "account_frozen",
            "payee_daily_users", "self_purchase_required",
        ]
        for reason in reasons {
            let (host, _) = try await openWithdraw(amount: "10", estimate: "estimated", needProbes: false)
            let code = reason == nil ? 30301 : 30303
            let data = reason.map { "{\"reason\":\"\($0)\"}" } ?? "null"
            host.server.script.fail("POST /v1/withdrawals", code, data: data)
            host.actions?.submit()
            await waitUntil("\(code) \(reason ?? "")：没有错误") { host.flow?.state.error != nil }
            XCTAssertEqual(host.flow?.state.error?.key, reason.map { "error.30303.\($0)" } ?? "error.30301")
            XCTAssertNil(host.flow?.state.fieldErrorKey, "不转字段错误")
            XCTAssertEqual(host.flow?.state.phase, .editing, "键结束回到可编辑")
            XCTAssertEqual(host.controller?.state.amountText, "10", "输入保留")
            XCTAssertEqual(submits.count, 1, "提交恰一次")
        }
    }

    /// 旧画面回调（渲染时票据）：换账号后旧的提交 / 确认 / 放弃零写入（共性第 4、52、59、63、64 条）。
    func testStaleCallbacksWriteNothingAfterAccountSwitch() async throws {
        let (host, _) = try await openWithdraw(estimate: "estimated", needProbes: false)
        try await enterPending()
        let stale = try XCTUnwrap(host.flowActions)
        let staleSubmit = try XCTUnwrap(host.actions).submit
        let before = writes
        try host.fixture.switchAccount(to: "user-b")
        await settle()
        stale.confirm()
        stale.askAbandon()
        stale.abandon()
        staleSubmit()
        await quietWindow(0.5)
        XCTAssertEqual(writes, before, "旧回调换号后零写入")
    }

    /// 不能提现时 submit 回调零写入；引导按钮恰一次打开前置页、不提交（W46）。
    func testBlockedGuideOpensRouteOnceZeroWrites() async throws {
        let (host, _) = try await openWithdraw("blocked_30305", payout: "empty", needProbes: false)
        host.actions?.submit()
        await quietWindow(0.2)
        XCTAssertEqual(writes, [], "不能提现零提交")
        let depth = host.fixture.router.path.count
        host.actions?.guide()
        await waitUntil { host.fixture.router.path.last?.route == WalletRoutes.payoutAccount }
        XCTAssertEqual(host.fixture.router.path.count, depth + 1, "恰一次")
    }

    /// G-W15：规则回调去向 = 配置的 Help / article_id；没配置零导航。
    func testRulesCallback() async throws {
        let (host, _) = try await openWithdraw("blocked_30309", needProbes: false)
        host.actions?.rules()
        await waitUntil { host.fixture.router.path.last?.route == WalletRoutes.help }
        XCTAssertEqual(host.fixture.router.path.last?.params["article_id"], .string(WithdrawVisualData.articleId))
        let (none, _) = try await openWithdraw("blocked_30309", help: false, needProbes: false)
        let depth = none.fixture.router.path.count
        none.actions?.rules()
        await quietWindow(0.2)
        XCTAssertEqual(none.fixture.router.path.count, depth, "没配置零导航")
    }
}
