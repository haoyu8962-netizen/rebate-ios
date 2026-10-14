@testable import Couli
import CouliNetwork
import Foundation
import Router
import Wallet
import WalletCore
import XCTest

/// APP-09 iOS 接手后补的红线与共性用例（经真实 Router、真实 ApiClient 管线与页面渲染时取出的回调，只把传输层换成本地假服务）：
/// 编排者补充（从未结果未知的 42901 / 40901 结束键）、共性第 1、3、18、41、45、49 条与进程回收后金额草稿只按同一身份恢复（iOS I06）。
final class WalletLessonsTests: WalletFlowTestCase {
    /// 编排者补充 / 共性第 12 条：从未结果未知的提交收到 42901 → 键结束（不进待确认），按 Retry-After 写入提现的共享截止时间；
    /// 截止时间内【提交】在执行层被拦下（零 POST）；到期后再点用新键。
    func testNeverUnknown42901EndsKeyAndNextSubmitUsesNewKey() async throws {
        let fixture = make()
        let controller = try await withdraw(fixture)
        script.fail("POST /v1/withdrawals", 42901, headers: ["Retry-After": "1"])
        await typeAmount(controller, "10")
        actions(controller).submit()
        await waitUntil("42901 没有结算") { controller.flow.state.error?.key == "error.42901" }
        XCTAssertNil(controller.flow.state.pending, "从未结果未知的键不进待确认")
        XCTAssertTrue(fixture.gates.withdraw.active, "Retry-After 写入提现的共享截止时间")
        actions(controller).submit()
        await settle()
        XCTAssertEqual(posts.count, 1, "截止时间内不发")
        await waitUntil("禁用期没有到期", timeout: 4) { !fixture.gates.withdraw.active }
        script.ok("POST /v1/withdrawals", WalletSamples.withdrawal("W-after"))
        actions(controller).submit()
        await waitUntil("第二次提交没有发出") { posts.count == 2 }
        XCTAssertNotEqual(posts[0].header("Idempotency-Key"), posts[1].header("Idempotency-Key"), "键已结束，下次用新键")
    }

    /// 编排者补充（Android A05 / 鸿蒙 H09 同口径）：从未结果未知的提交收到 40901 → 提示 error.40901，不自动重发；下次点击用新键。
    func testNeverUnknown40901EndsKeyWithoutAutoResend() async throws {
        let fixture = make()
        let controller = try await withdraw(fixture)
        script.fail("POST /v1/withdrawals", 40901)
        await typeAmount(controller, "10")
        actions(controller).submit()
        await waitUntil("40901 没有结算") { controller.flow.state.phase == .editing && controller.flow.state.error != nil }
        await settle()
        XCTAssertEqual(posts.count, 1, "不换键自动重发")
        XCTAssertNil(controller.flow.state.pending)
        script.ok("POST /v1/withdrawals", WalletSamples.withdrawal("W-next"))
        actions(controller).submit()
        await waitUntil("第二次提交没有发出") { posts.count == 2 }
        XCTAssertNotEqual(posts[0].header("Idempotency-Key"), posts[1].header("Idempotency-Key"))
        _ = fixture
    }

    /// 共性第 1 条：确认在途时离开提现页（不取消），另开一个提现页实例；确认结算（成功）后，新页面按本机记录同步、退出待确认，
    /// 旧页面不改新页面。
    func testPendingSettledElsewhereResyncsCurrentPage() async throws {
        let fixture = make()
        let first = try await withdraw(fixture)
        try await enterPending(first)
        script.on("POST /v1/withdrawals", .hold)
        flowActions(first.flow).confirm()
        await waitUntil("确认没有发出") { WalletStubProtocol.heldIds.count == 1 }
        fixture.router.path.removeAll()
        XCTAssertFalse(first.alive)
        let second = try await withdraw(fixture)
        await waitUntil("新页面没有恢复待确认") { second.flow.state.pending != nil }
        let held = try XCTUnwrap(WalletStubProtocol.heldIds.first)
        WalletStubProtocol.release(held, with: .envelope(code: 0, data: WalletSamples.withdrawal("W-ok"), headers: [:]))
        await waitUntil("结算通知没有让新页面同步") { second.flow.state.pending == nil }
        XCTAssertTrue(second.flow.state.canSubmit)
        XCTAssertEqual(fixture.router.path.last?.route, WalletRoutes.withdraw, "旧页面的成功不替换新页面")
    }

    /// 共性第 18 条：放弃分支也处理前置引导（10005 → BindPhone）：打开对应页、保留未决键，回来仍是待确认，不自动重放。
    func testAbandonPrerequisiteGuideKeepsKey() async throws {
        let fixture = make()
        let controller = try await withdraw(fixture)
        try await enterPending(controller)
        let key = try XCTUnwrap(controller.flow.state.pending?.key)
        script.fail("POST /v1/idempotency-keys/abandon", 10005)
        flowActions(controller.flow).askAbandon()
        flowActions(controller.flow).abandon()
        await waitUntil("没有引导绑定手机") { fixture.router.path.last?.route == "BindPhone" }
        fixture.router.path.removeLast()
        await waitUntil("回来不是待确认") { controller.flow.state.pending?.key == key }
        XCTAssertEqual(posts.count, 1, "不重放")
    }

    /// 共性第 41 条：提交成功时提现页被覆盖（例：打开了收款账号页）——不在覆盖时替换；回到可见时再以提现记录替换本页，期间【提交】不可用。
    func testSuccessWhileCoveredReplacesWhenVisibleAgain() async throws {
        let fixture = make()
        let controller = try await withdraw(fixture)
        script.on("POST /v1/withdrawals", .hold)
        await typeAmount(controller, "10")
        actions(controller).submit()
        await waitUntil("提交没有发出") { WalletStubProtocol.heldIds.count == 1 }
        fixture.router.open(RouteRequest(route: WalletRoutes.payoutAccount, from: .inApp))
        await waitUntil("没有盖上收款账号页") { fixture.router.path.last?.route == WalletRoutes.payoutAccount }
        let held = try XCTUnwrap(WalletStubProtocol.heldIds.first)
        WalletStubProtocol.release(
            held,
            with: .envelope(code: 0, data: WalletSamples.withdrawal("W-cov"), headers: [:])
        )
        await waitUntil("成功没有记下") { controller.state.successPending }
        await settle()
        XCTAssertEqual(fixture.router.path.last?.route, WalletRoutes.payoutAccount, "被覆盖时不替换、不弹掉上层页面")
        fixture.router.path.removeLast()
        await waitUntil("回到可见后没有进提现记录") { fixture.router.path.last?.route == WalletRoutes.withdrawRecords }
        XCTAssertEqual(fixture.router.path.last?.params[WalletRoutes.withdrawalId]?.stringValue, "W-cov")
    }

    /// 共性第 45、56、62 条：估算被发送前限流拦下 → 结算本次估算（隐藏估算、页内 42901 与【重试】），不留下没有在途请求的「计算中」。
    func testEstimateGatedSettlesWithoutStuckCalculating() async throws {
        let fixture = make()
        let controller = try await withdraw(fixture)
        fixture.gates.read.start(3000)
        actions(controller).amount("10")
        await settle(40)
        try await Task.sleep(nanoseconds: 700_000_000)
        await settle()
        XCTAssertEqual(controller.state.estimate, .hidden, "不留下「计算中」")
        XCTAssertEqual(controller.state.readError?.key, "error.42901")
        XCTAssertFalse(
            WalletStubProtocol.requests("GET", "/v1/withdrawals/rules").contains { $0.query.contains("amount_fen") },
            "执行层拦下，零估算请求"
        )
    }

    /// 共性第 3 条：读取（收款账号页 getPayoutAccount）的 5xxxx 显示统一错误消息并带 trace6（文案没有占位符也独立追加），可重试。
    func testPayoutReadServerErrorShowsTrace6() async throws {
        script.fail("GET /v1/me/payout-account", 50001)
        let fixture = make()
        await verifyRealname(fixture)
        let entry = try XCTUnwrap(fixture.open(WalletRoutes.payoutAccount))
        let controller = try XCTUnwrap(entry.controller as? PayoutAccountController)
        controller.start()
        await waitUntil("读取失败没有结算") { controller.state.loadError != nil }
        let message = try XCTUnwrap(controller.state.loadError).message(WalletDraftTexts())
        // 假服务外壳的 trace_id 是 stub-trace-0123456789ab：末 6 位独立追加
        XCTAssertTrue(message.hasSuffix("（6789ab）"), "trace6 独立追加：\(message)")
        XCTAssertTrue(controller.state.phase == .error || controller.state.loadError != nil)
    }

    /// 共性第 49 条：确认流程打开的二次验证面板，所属的未决键在别处结算（这里由另一次作废结束）后同步收起，不再续发。
    func testConfirmStepUpPanelClosesWhenKeySettledElsewhere() async throws {
        let fixture = make()
        let controller = try await withdraw(fixture)
        try await enterPending(controller)
        script.fail("POST /v1/withdrawals", 10003)
        flowActions(controller.flow).confirm()
        await waitUntil("确认没有弹二次验证") { controller.flow.stepUp.state != nil }
        // 别处（同账号新开的另一个提现页实例）放弃了这个键
        let other = try await withdraw(fixture)
        await waitUntil("另一个页面没有恢复待确认") { other.flow.state.pending != nil }
        flowActions(other.flow).askAbandon()
        flowActions(other.flow).abandon()
        await waitUntil("另一个页面没有放弃成功") { other.flow.state.pending == nil }
        await waitUntil("键结束后面板没有收起") { controller.flow.stepUp.state == nil }
        let before = posts.count
        await settle()
        XCTAssertEqual(posts.count, before, "不再续发")
    }

    /// 进程回收后恢复已输入金额（iOS I06，共性第 59、65 条）：草稿按账号落盘；正常出栈删除草稿；进程被回收（页面没有出栈）后同一账号新建的
    /// 提现页恢复金额（不恢复估算），换了账号的不恢复。
    func testDraftRestoresOnlyForSameAccount() async throws {
        let fixture = make()
        let controller = try await withdraw(fixture)
        await typeAmount(controller, "8.5")
        // 模拟进程回收：页面没有走出栈出口；同一个缓存目录上组一个新的 App（同一账号）
        let reborn = make()
        let restored = try await withdraw(reborn)
        XCTAssertEqual(restored.state.amountText, "8.5", "同一账号恢复金额")
        // 换了账号的新进程不恢复（缓存归属不一致整体删除）
        let fresh = try await withdraw(make(account: "user-b"))
        XCTAssertEqual(fresh.state.amountText, "", "换了账号不恢复")
        // 正常出栈删除草稿
        let third = make()
        let page = try await withdraw(third)
        await typeAmount(page, "6")
        third.router.path.removeAll()
        let again = try await withdraw(make())
        XCTAssertEqual(again.state.amountText, "", "正常出栈后不再恢复")
    }

    /// 共性第 63、65 条（钱包页）：执行器构造时一次性固定身份，之后对当前会话只比较不赋值。令牌已换、清空通知还没执行的窗口里，旧页面渲染时
    /// 取出的【重试】/ 下拉回调不按新会话发请求（零 GET /v1/wallet/summary），也不把新账号的摘要套进旧页面。
    func testWalletPageFixedIdentityAfterSilentSwap() async throws {
        let fixture = make()
        let entry = try XCTUnwrap(fixture.open(WalletRoutes.wallet))
        let controller = try XCTUnwrap(entry.controller as? WalletController)
        controller.load()
        await waitUntil("摘要没有到位") { controller.state.phase == .content }
        let old = WalletActions.make(controller, controller.state)
        let before = WalletStubProtocol.requests("GET", "/v1/wallet/summary").count
        try fixture.swapTokensSilently(to: "user-b")
        old.retry()
        controller.load(refresh: true)
        await settle()
        XCTAssertEqual(WalletStubProtocol.requests("GET", "/v1/wallet/summary").count, before, "不以新会话重新绑定")
        XCTAssertEqual(controller.state.owner.account, "user-a", "固定身份不被改写")
    }

    /// 估算归属四项之③（BR-WDR-04 细则「估算响应的归属」，AC-S2-80 ⑩）：同一个金额先后发出两次估算（10 → 1 → 10），较早那次的响应晚到时，
    /// 即使金额对得上，也不是本实例最新序号，不得覆盖较新的估算。
    func testSameAmountOlderEstimateDoesNotOverrideNewer() async throws {
        let fixture = make()
        let controller = try await withdraw(fixture)
        script.on("GET /v1/withdrawals/rules", .hold)
        actions(controller).amount("10")
        await waitUntil("第一次估算没有发出", timeout: 3) { WalletStubProtocol.heldIds.count == 1 }
        actions(controller).amount("1")
        await waitUntil("第二次估算没有发出", timeout: 3) { WalletStubProtocol.heldIds.count == 2 }
        actions(controller).amount("10")
        await waitUntil("第三次估算没有发出", timeout: 3) { WalletStubProtocol.heldIds.count == 3 }
        let held = WalletStubProtocol.heldIds
        WalletStubProtocol.release(held[2], with: .envelope(code: 0, data: WalletSamples.rules(net: 900), headers: [:]))
        await waitUntil("最新一次估算没有显示") {
            if case let .shown(line, _) = controller.state.estimate {
                return line.netFen == 900
            }
            return false
        }
        WalletStubProtocol.release(
            held[0],
            with: .envelope(code: 0, data: WalletSamples.rules(net: 1000), headers: [:])
        )
        WalletStubProtocol.release(held[1], with: .envelope(code: 0, data: WalletSamples.rules(net: 100), headers: [:]))
        await settle(40)
        guard case let .shown(line, amount) = controller.state.estimate else {
            return XCTFail("估算被旧响应收起")
        }
        XCTAssertEqual(line.netFen, 900, "旧序号的响应不覆盖")
        XCTAssertEqual(amount, 1000)
        _ = fixture
    }
}
