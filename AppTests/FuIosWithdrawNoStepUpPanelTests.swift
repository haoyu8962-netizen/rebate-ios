@testable import Couli
import CouliNetwork
import Foundation
import Me
import MeCore
import Router
import Wallet
@testable import WalletCore
import XCTest

/// FU-IOS-WITHDRAW-STEPUP-PANEL-CLEANUP 写测（D10-3639 A 甲 / B / C，D10-2124）：提现这一路不再走二次验证面板。
/// SensitiveFlow 加初始化参数 `stepUpEnabled`（缺省 true），只有 WithdrawController 传 false；为 false 时提现收到 10003 不论首次、
/// 确认阶段、页面是否被覆盖，一律按现有 stepUpExhausted 的终态结算（首次提交：结束本键、回编辑态、error.10003；确认阶段：保持待确认、
/// pendingNotice = error.10003），不开面板、不发码、不重放；发送与确认都不从 `deps.tokens` 取令牌。改收款、注销调用点零行为变化。
/// 全部经生产入口（WalletAppFixture：真实 Router、真实 ApiClient，只把传输层换成本地假服务），按钮走页面同一份渲染时回调。
/// 令牌那条另把提现页执行器的钱包入口包一层记录（TokenSpyWalletApi）：网络层本就不给提现带 X-Step-Up-Token，看请求头抓不到
/// flow 有没有取令牌，只能看 flow 交给钱包入口的 stepUpToken。
final class FuIosWithdrawNoStepUpPanelTests: WalletFlowTestCase {
    static let need = WalletStubProtocol.Reply.envelope(code: 10003, data: "null", headers: [:])
    static let alipaySummary = ["payout_method": "alipay", "alipay_logon_id": "zhangsan@example.com"]
    static let account = "user-a"

    var smsSent: [WalletStubProtocol.Recorded] {
        WalletStubProtocol.requests("POST", "/v1/auth/sms-codes")
    }

    var verifies: [WalletStubProtocol.Recorded] {
        WalletStubProtocol.requests("POST", "/v1/auth/step-up")
    }

    // MARK: - 提现：10003 不开面板

    /// 首次提交收到 10003：不开面板、不发码、不验证；提现 POST 只发 1 次（不重放）；回编辑态、提示 error.10003、不进待确认；
    /// 本键结束——再点【提交】发出新的一次且换新键。
    func testFirstSubmit10003EndsKeyWithoutPanel() async throws {
        script.on("POST /v1/withdrawals", Self.need)
        let fixture = make()
        let controller = try await withdraw(fixture)
        await typeAmount(controller, "10")
        actions(controller).submit()
        await waitUntil("提交没有发出") { self.posts.count == 1 }
        await idle(controller.flow)
        await quietWindow(0.3)
        assertNoPanel(fixture, controller.flow)
        XCTAssertEqual(posts.count, 1, "提现 POST 只发 1 次（不重放）")
        XCTAssertEqual(controller.flow.state.phase, .editing, "回编辑态")
        XCTAssertEqual(controller.flow.state.error?.key, "error.10003", "提示 error.10003")
        XCTAssertNil(controller.flow.state.pending, "不进待确认")
        await assertNextSubmitUsesNewKey(controller)
    }

    /// 确认阶段（先断连进待确认）收到 10003：不开面板、不发码；确认只发 1 次（断连 1 + 确认 1，原键）；保持待确认、原键在卡上、
    /// pendingNotice 为 error.10003，【确认】/【放弃】恢复可用。
    func testConfirm10003KeepsPendingWithoutPanel() async throws {
        let fixture = make()
        let controller = try await withdraw(fixture)
        try await enterPending(controller)
        await idle(controller.flow)
        let key = try XCTUnwrap(controller.flow.state.pending?.key, "前提：待确认卡带原键")
        XCTAssertEqual(posts.count, 1, "前提：首次提交断连 1 次")
        script.on("POST /v1/withdrawals", Self.need)
        flowActions(controller.flow).confirm()
        await waitUntil("确认没有发出") { self.posts.count == 2 }
        await idle(controller.flow)
        await quietWindow(0.3)
        assertNoPanel(fixture, controller.flow)
        XCTAssertEqual(posts.count, 2, "断连 1 + 确认 1，不重放")
        XCTAssertEqual(fixture.api.calls("confirm:" + WithdrawController.operation), 1, "确认入口只调 1 次")
        XCTAssertEqual(posts[1].header("Idempotency-Key"), posts[0].header("Idempotency-Key"), "确认沿用原键")
        XCTAssertEqual(posts[1].body, posts[0].body, "确认沿用原请求体")
        XCTAssertEqual(controller.flow.state.phase, .pending, "保持待确认")
        XCTAssertEqual(controller.flow.state.pending?.key, key, "待确认卡仍是原键")
        XCTAssertEqual(controller.flow.state.pendingNotice?.key, "error.10003", "待确认卡提示 error.10003")
        XCTAssertTrue(controller.flow.state.pendingActionsEnabled, "【确认】/【放弃】恢复可用")
    }

    /// 提现页被覆盖（onScreen=false）时收到 10003：同首次提交的终态——不开面板、回编辑态、error.10003；本键结束（回到页面后再点
    /// 【提交】换新键，不再沿用被覆盖时那把键）。
    func testCovered10003EndsKeyLikeFirstSubmit() async throws {
        script.on("POST /v1/withdrawals", .hold)
        let fixture = make()
        let controller = try await withdraw(fixture)
        await typeAmount(controller, "10")
        actions(controller).submit()
        await waitUntil("提交没有发出") { WalletStubProtocol.heldIds.count == 1 }
        controller.setVisible(false)
        XCTAssertFalse(controller.flow.visibleNow, "前提：提现页被覆盖")
        let held = try XCTUnwrap(WalletStubProtocol.heldIds.first)
        WalletStubProtocol.release(held, with: Self.need)
        await waitUntil("被覆盖时的 10003 没有结算") { controller.flow.state.error != nil }
        await idle(controller.flow)
        assertNoPanel(fixture, controller.flow)
        XCTAssertEqual(posts.count, 1, "提现 POST 只发 1 次（不重放）")
        XCTAssertEqual(controller.flow.state.phase, .editing, "回编辑态")
        XCTAssertEqual(controller.flow.state.error?.key, "error.10003", "提示 error.10003")
        XCTAssertNil(controller.flow.state.pending, "不进待确认")
        controller.setVisible(true)
        await idle(controller.flow)
        await typeAmount(controller, "10")
        await assertNextSubmitUsesNewKey(controller)
    }

    /// 预置提现 action 的缓存令牌：首次提交（断连进待确认）与【确认上一笔】交给钱包入口的 stepUpToken 都是 nil（flow 不取缓存令牌）；
    /// 缓存令牌原样留着。请求头本就不带（网络层），只作旁证。
    func testSubmitAndConfirmDoNotTakeCachedWithdrawToken() async throws {
        let fixture = make()
        await verifyRealname(fixture)
        let spied = await spiedWithdraw(fixture)
        let controller = spied.controller
        spied.deps.tokens.put(
            action: WithdrawController.action, account: Self.account, token: "t-withdraw-cached", expireAtMs: .max
        )
        try await enterPending(controller)
        await idle(controller.flow)
        XCTAssertEqual(spied.spy.sendTokens(WithdrawController.operation), [nil], "首次提交：不取缓存令牌")
        XCTAssertEqual(cachedWithdrawToken(spied.deps), "t-withdraw-cached", "提交后缓存令牌原样留着")

        flowActions(controller.flow).confirm()
        await waitUntil("确认没有发出") { self.posts.count == 2 }
        await idle(controller.flow)
        XCTAssertEqual(spied.spy.confirmTokens(WithdrawController.operation), [nil], "确认上一笔：不取缓存令牌")
        XCTAssertEqual(cachedWithdrawToken(spied.deps), "t-withdraw-cached", "确认后缓存令牌原样留着")
        XCTAssertNil(posts[0].header("X-Step-Up-Token"), "旁证：首次提交不带头")
        XCTAssertNil(posts[1].header("X-Step-Up-Token"), "旁证：确认不带头")
        XCTAssertEqual(posts[1].header("Idempotency-Key"), posts[0].header("Idempotency-Key"), "确认沿用原键")
    }

    /// D10-3645 ①：提现流程任何时刻都不持有 step-up 令牌。每一步发出前都重新预置提现 action 的缓存令牌（10003 的共享结算会按 action
    /// 清掉它），依次走：首次提交得 10003 → 再提交断连进待确认 → 确认得 10003 → 再确认断连；交给钱包入口的令牌每一次都是 nil。
    func testWithdrawFlowNeverHoldsStepUpTokenEvenAfter10003() async {
        let fixture = make()
        await verifyRealname(fixture)
        let spied = await spiedWithdraw(fixture)
        let controller = spied.controller
        await typeAmount(controller, "10")
        let steps: [(reply: WalletStubProtocol.Reply, confirm: Bool)] = [
            (Self.need, false), (.disconnect, false), (Self.need, true), (.disconnect, true),
        ]
        for (index, step) in steps.enumerated() {
            spied.deps.tokens.put(
                action: WithdrawController.action, account: Self.account, token: "t-cached-\(index)", expireAtMs: .max
            )
            script.on("POST /v1/withdrawals", step.reply)
            if step.confirm {
                await waitUntil("第 \(index) 步：待确认卡不可确认") { controller.flow.state.pendingActionsEnabled }
                flowActions(controller.flow).confirm()
            } else {
                actions(controller).submit()
            }
            await waitUntil("第 \(index) 步没有发出") { self.posts.count == index + 1 }
            await idle(controller.flow)
        }
        XCTAssertEqual(spied.spy.sendTokens(WithdrawController.operation), [nil, nil], "两次提交（含 10003 之后）都不带令牌")
        XCTAssertEqual(spied.spy.confirmTokens(WithdrawController.operation), [nil, nil], "两次确认（含 10003 之后）都不带令牌")
        XCTAssertTrue(spied.spy.allTokens.allSatisfy { $0 == nil }, "钱包入口的任何一次调用都不带令牌")
        XCTAssertEqual(cachedWithdrawToken(spied.deps), "t-cached-3", "最后预置的缓存令牌原样留着（没被取用）")
        assertNoPanel(fixture, controller.flow)
        XCTAssertEqual(posts.count, 4, "提交 2 + 确认 2，不重放")
        XCTAssertTrue(posts.allSatisfy { $0.header("X-Step-Up-Token") == nil }, "旁证：请求头都不带")
        XCTAssertNotEqual(posts[1].header("Idempotency-Key"), posts[0].header("Idempotency-Key"), "10003 后再提交换新键")
        XCTAssertEqual(Set(posts[1...].map { $0.header("Idempotency-Key") }).count, 1, "两次确认沿用第二次提交的原键")
        XCTAssertEqual(controller.flow.state.phase, .pending, "最后一次确认断连：保持待确认")
    }

    // MARK: - 对照：改收款、注销照旧（今天绿、改后仍须绿）

    /// 改收款【保存】收到 10003：照常打开面板（action=payout_account_change）并发码 1 次；保存带上了摘要相同的缓存令牌（取用令牌）。
    func testPayoutSave10003StillOpensPanelAndTakesToken() async throws {
        script.ok("GET /v1/me/payout-account", "{}")
        script.on("PUT /v1/me/payout-account", Self.need)
        let fixture = make()
        let controller = try await payout(fixture)
        fixture.wallet.deps.tokens.put(
            action: PayoutAccountController.action, account: Self.account, token: "t-payout-cached", expireAtMs: .max,
            summary: StepUpSummary.key(Self.alipaySummary)
        )
        let render = { PayoutActions.make(controller, controller.state, risk: controller.flow.state.riskDialog?.id) }
        render().logon(" zhangsan@example.com ")
        render().payee("测试三")
        render().save()
        await waitUntil("改收款 10003 后面板没有打开") { controller.flow.stepUp.state != nil }
        await idle(controller.flow)
        XCTAssertEqual(saves.count, 1, "保存发出 1 次（得到 10003）")
        XCTAssertEqual(saves.first?.header("X-Step-Up-Token"), "t-payout-cached", "改收款照常取用缓存令牌")
        XCTAssertEqual(controller.flow.stepUp.state?.action, PayoutAccountController.action)
        XCTAssertEqual(smsSent.count, 1, "面板发码 1 次")
        XCTAssertEqual(smsSent.first?.json["action"] as? String, PayoutAccountController.action)
        XCTAssertNil(controller.flow.state.error, "开面板，不是终态错误条")
        controller.flow.stepUp.state.map { StepUpActions.make(controller.flow.stepUp, $0).close() }
        await idle(controller.flow)
    }

    /// 注销【申请注销】收到 10003：照常打开面板（action=account_deletion）并发码；申请带上了缓存的注销令牌（取用令牌）。
    func testDeletionApply10003StillOpensPanelAndTakesToken() async throws {
        script.ok("GET /v1/me/deletion", "null")
        script.on("POST /v1/me/deletion", Self.need)
        let fixture = make()
        let host = try await deletionPage(fixture)
        let controller = host.controller
        fixture.wallet.deps.tokens.put(
            action: SensitiveFlow.deletionAction, account: Self.account, token: "t-deletion-cached", expireAtMs: .max
        )
        let render = { DeleteAccountActions.make(controller, controller.state, controller.flow.state) }
        if !controller.state.waiver {
            render().toggleWaiver()
        }
        render().apply()
        await waitUntil("注销 10003 后面板没有打开", timeout: 8) { controller.flow.stepUp.state != nil }
        await idle(controller.flow)
        let applies = WalletStubProtocol.requests("POST", "/v1/me/deletion")
        XCTAssertEqual(applies.count, 1, "申请发出 1 次（得到 10003）")
        XCTAssertEqual(applies.first?.header("X-Step-Up-Token"), "t-deletion-cached", "注销照常取用缓存令牌")
        XCTAssertEqual(controller.flow.stepUp.state?.action, SensitiveFlow.deletionAction)
        XCTAssertEqual(smsSent.count, 1, "面板发码 1 次")
        XCTAssertEqual(smsSent.first?.json["action"] as? String, SensitiveFlow.deletionAction)
        controller.flow.stepUp.state.map { StepUpActions.make(controller.flow.stepUp, $0).close() }
        await idle(controller.flow)
    }

    // MARK: - 辅助

    /// 等本流程与其面板已排队的请求、回包结算完成（不含面板倒计时）。
    private func idle(_ flow: SensitiveFlow) async {
        for _ in 0..<3 {
            await flow.stepUp.whenIdle()
            await flow.whenIdle()
        }
    }

    /// 不开面板：没有面板状态，没有发码 / 验证请求，发码 / 验证入口都没被调用。
    private func assertNoPanel(_ fixture: WalletAppFixture, _ flow: SensitiveFlow,
                               file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertNil(flow.stepUp.state, "不开二次验证面板", file: file, line: line)
        XCTAssertTrue(smsSent.isEmpty, "不发码", file: file, line: line)
        XCTAssertTrue(verifies.isEmpty, "不验证", file: file, line: line)
        XCTAssertEqual(fixture.api.calls(StepUpController.sendOperation), 0, "不调发码入口", file: file, line: line)
        XCTAssertEqual(fixture.api.calls(StepUpController.verifyOperation), 0, "不调验证入口", file: file, line: line)
    }

    /// 再点一次【提交】（脚本改回成功）：发出新的一次，键与之前每一次都不同，请求体仍是这次的金额。
    private func assertNextSubmitUsesNewKey(_ controller: WithdrawController,
                                            file: StaticString = #filePath, line: UInt = #line) async {
        let before = posts.count
        script.ok("POST /v1/withdrawals", WalletSamples.withdrawal("W-next"))
        actions(controller).submit()
        await idle(controller.flow)
        await settle()
        XCTAssertEqual(posts.count, before + 1, "本键已结束：再点【提交】发出新的一次", file: file, line: line)
        guard posts.count == before + 1 else { return }
        let next = posts[before]
        let newKey = next.header("Idempotency-Key")
        XCTAssertNotNil(newKey, file: file, line: line)
        for earlier in posts.prefix(before) {
            XCTAssertNotEqual(newKey, earlier.header("Idempotency-Key"), "下次提交换新键", file: file, line: line)
        }
        XCTAssertEqual(next.json["amount_fen"] as? Int, 1000, "请求体是这次的金额", file: file, line: line)
    }

    private func cachedWithdrawToken(_ deps: WalletDeps) -> String? {
        deps.tokens.take(action: WithdrawController.action, account: Self.account, nowMs: 0)
    }

    /// 带令牌记录的提现页执行器与它的依赖。
    private struct Spied {
        let controller: WithdrawController
        let deps: WalletDeps
        let spy: TokenSpyWalletApi
    }

    /// 同一套 App 组合与假服务，只把钱包入口包一层 TokenSpyWalletApi（转给夹具的 CountingWalletApi → 真实 ApiClient）。执行器用生产
    /// 构造 `WithdrawController(deps:owner:)`（与 AppWallet+Pages.withdrawEntry 同一个初始化，`stepUpEnabled` 由它自己传）；
    /// 令牌缓存是这份 deps 自己的。
    private func spiedWithdraw(_ fixture: WalletAppFixture) async -> Spied {
        let base: WalletDeps = fixture.wallet.deps
        let spy = TokenSpyWalletApi(base.api)
        let deps = WalletDeps(
            api: spy, env: base.env, gates: base.gates, cache: base.cache, mask: base.mask, realname: base.realname,
            labor: base.labor, texts: base.texts
        )
        let controller = WithdrawController(deps: deps, owner: base.env.currentOwner())
        controller.start()
        await waitUntil("rules 没有到位") { controller.state.phase == .content }
        return Spied(controller: controller, deps: deps, spy: spy)
    }

    /// 注销页放进导航栈（下面是 Settings），经 AppWallet 取页面、启动，等到可申请的初始态（同 FuIosWalletSettlementScopeSupport 写法）。
    private func deletionPage(_ fixture: WalletAppFixture) async throws -> MePageHost<DeleteAccountController> {
        let destination = RouteDestination(route: DeleteAccountController.route)
        fixture.router.path = [RouteDestination(route: "Settings"), destination]
        let entry = try XCTUnwrap(fixture.wallet.entry(for: destination), "注销页没有登记到钱包页面表")
        let host = try XCTUnwrap(entry.controller as? MePageHost<DeleteAccountController>, "注销页执行器类型")
        host.controller.start()
        await waitUntil("注销页没有进入可申请的初始态", timeout: 8) {
            host.controller.view.kind == .initial && host.controller.view.applyEnabledWhenChecked
        }
        return host
    }
}

/// 钱包调用入口的令牌记录（只在本文件用）：记下 flow 交给 `send` / `confirmPending` 的 stepUpToken，再原样转给内层入口。
private final class TokenSpyWalletApi: WalletApi, @unchecked Sendable {
    private struct Entry {
        let operationId: String
        let token: String?
    }

    private let inner: WalletApi
    private let lock = NSLock()
    private var sent: [Entry] = []
    private var confirmed: [Entry] = []

    init(_ inner: WalletApi) {
        self.inner = inner
    }

    /// 某个 operationId 经 `send` 交来的令牌（按调用顺序）。
    func sendTokens(_ operationId: String) -> [String?] {
        lock.withLock { sent.filter { $0.operationId == operationId }.map(\.token) }
    }

    /// 某个 operationId 经 `confirmPending` 交来的令牌（按调用顺序）。
    func confirmTokens(_ operationId: String) -> [String?] {
        lock.withLock { confirmed.filter { $0.operationId == operationId }.map(\.token) }
    }

    /// 经 `send` 与 `confirmPending` 交来的全部令牌（不分 operationId）。
    var allTokens: [String?] {
        lock.withLock { (sent + confirmed).map(\.token) }
    }

    private func record(send operationId: String, _ token: String?) {
        lock.withLock { sent.append(Entry(operationId: operationId, token: token)) }
    }

    private func record(confirm operationId: String, _ token: String?) {
        lock.withLock { confirmed.append(Entry(operationId: operationId, token: token)) }
    }

    func send(
        _ call: ApiCall, isValid: @escaping @Sendable () -> Bool, sendAllowed: @escaping @Sendable () -> Bool,
        expected: RequestOwnership?
    ) async -> ApiResult {
        record(send: call.operationId, call.stepUpToken)
        return await inner.send(call, isValid: isValid, sendAllowed: sendAllowed, expected: expected)
    }

    func confirmPending(operationId: String, stepUpToken: String?, target: PendingTarget) async -> ApiResult {
        record(confirm: operationId, stepUpToken)
        return await inner.confirmPending(operationId: operationId, stepUpToken: stepUpToken, target: target)
    }

    func abandonPending(operationId: String, target: PendingTarget) async -> ApiResult {
        await inner.abandonPending(operationId: operationId, target: target)
    }

    func pendingStatus(operationId: String) async -> PendingLookup {
        await inner.pendingStatus(operationId: operationId)
    }

    func restorePending() async {
        await inner.restorePending()
    }
}
