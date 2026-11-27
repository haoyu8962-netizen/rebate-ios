@testable import Couli
import CouliNetwork
import Foundation
import Wallet
@testable import WalletCore
import XCTest

/// FU-IOS-STEPUP-SILENT-MISMATCH（App 接线 + 渲染）：经生产入口（提现【提交】/ 收款【保存】→ 10003 → 面板）、真实 ApiClient 与生产半屏。
/// - 修复前红：发码那一刻会话读得到同一账号、没有可用 access（造法同 LockIosStepUpWiringTests.testSessionWithoutAccessAtSendSendsNothingOnPayout：
///   在 `AppWallet.phoneBound` 钩子里把存储会话的 access 置空，不换会话世代、不发通知）→ 零发送，面板显示发送失败提示、说明位不是
///   「已发送」、【重新获取】可点；会话恢复可用令牌后点【重新获取】照常带令牌发出 1 次。
/// - D10-1790：「同账号、同世代、此刻没有 access」仍按身份核对不过；sentArrived 判 stale 时面板落到发送失败 + 可重新获取；真换会话 / 登出
///   随后由会话变化通知收起，全程不多发。
/// 修复前：access 置空后登录世代读为 nil，`AppWallet.check` 判 .stale；`settleSms` 对 stale 不结算、不释放槽位，槽位进
/// awaitingIdentity，`sentArrived` 因此按 waiting 强制 .unknown，面板进等身份（awaitingIdentity=true、phase .sending、显示【重试】、
/// 说明位仍「已发送」）。修复后 `settleSms` 对 stale 只释放本次 ticket，面板落到发送失败态。
@MainActor
final class FuIosStepUpSilentMismatchWiringTests: StepUpVisualTestCase {
    /// 发码那一刻（面板 admit 之后、交给网络层之前）执行一次 `hook`。
    private func arm(_ host: WithdrawVisualHost, _ hook: @escaping @MainActor (WalletAppFixture) -> Void) {
        let armed = LockIosOnceFlag()
        let fixture = host.fixture
        host.wallet.phoneBound = { _ in
            if armed.once() {
                hook(fixture)
            }
            return true
        }
    }

    /// 提现页输入 10 元、点【提交】→ 10003 → 不开面板，等结算成 error.10003（D10-3641：提现 10003 不再开面板）。
    private func withdraw10003() async throws -> WithdrawVisualHost {
        let (host, _) = try await openWithdraw(amount: "10", estimate: "estimated", needProbes: false)
        host.wallet.clock = { Self.frozenMillis }
        host.server.script.on("POST /v1/withdrawals", Self.need, .envelope(
            code: 0, data: WalletSamples.withdrawal("W-step"), headers: [:]
        ))
        host.server.script.on("POST /v1/auth/sms-codes", Self.smsOk())
        host.actions?.submit()
        await waitUntil("提现 10003 没有结算", timeout: 8) { host.flow?.state.error != nil }
        return host
    }

    /// 收款账号页（未绑定）填支付宝、点【保存】→ 10003 → 面板打开（不等落定：修复前可能落不定）。`sms`：发码答复（nil = 成功）。
    /// D10-3641：原提现页到面板的用例都挪到这里（提现 10003 不再开面板）。
    private func payoutPanel(sms: WalletStubProtocol.Reply? = nil,
                             hook: (@MainActor (WalletAppFixture) -> Void)? = nil) async throws -> WithdrawVisualHost {
        let host = try await freshPage(payout: "empty")
        host.server.script.on("PUT /v1/me/payout-account", Self.need, .envelope(
            code: 0, data: WalletSamples.alipay, headers: [:]
        ))
        host.server.script.on("POST /v1/auth/sms-codes", sms ?? Self.smsOk())
        try await host.show(WalletRoutes.payoutAccount)
        _ = await host.stable { $0.payout.map { $0.state.phase != .loading } ?? false }
        host.wallet.clock = { Self.frozenMillis }
        if let hook {
            arm(host, hook)
        }
        let controller = try XCTUnwrap(host.payout)
        func actions() -> PayoutActions {
            PayoutActions.make(controller, controller.state, risk: controller.flow.state.riskDialog?.id)
        }
        actions().logon("zhangsan@example.com")
        actions().payee("测试三")
        actions().save()
        await waitUntil("收款账号页没有打开面板", timeout: 8) { controller.flow.stepUp.state != nil }
        return host
    }

    private func idle(_ host: WithdrawVisualHost) async {
        guard let flow = host.flow else { return }
        for _ in 0..<3 {
            await flow.stepUp.whenIdle()
            await flow.whenIdle()
        }
    }

    /// 半屏里此刻显示的文字（测量随视图消失而移除）。
    private var sheetTexts: [String] {
        page?.probes.records.filter { $0.key.hasPrefix("stepUp.") }.values.map(\.text).filter { !$0.isEmpty } ?? []
    }

    private static func blankAccess(_ fixture: WalletAppFixture) {
        try? fixture.tokens.save(
            access: "", refresh: "rt", scope: "full", account: "user-a", loginEpoch: "fixture-login-user-a"
        )
    }

    private static func restoreAccess(_ fixture: WalletAppFixture) {
        try? fixture.tokens.save(
            access: "at", refresh: "rt", scope: "full", account: "user-a", loginEpoch: "fixture-login-user-a"
        )
    }

    /// 没有可用 access 的发码落定后：零发送；面板不收起、可输入、提示发送失败、不起倒计时；半屏说明位不是「已发送」、显示错误、有【重新获取】；
    /// 恢复令牌后点【重新获取】带令牌恰发 1 次并起倒计时。
    private func assertFailureThenResend(_ host: WithdrawVisualHost, _ label: String,
                                         file: StaticString = #filePath, line: UInt = #line) async throws {
        await idle(host)
        await quietWindow(0.5)
        XCTAssertTrue(smsSends.isEmpty, "\(label)：没有 access：零发送", file: file, line: line)
        XCTAssertEqual(host.fixture.api.calls(StepUpController.sendOperation), 1, "\(label)：前提：调用了发码入口",
                       file: file, line: line)
        let stepUp = try XCTUnwrap(host.flow?.stepUp, file: file, line: line)
        let state = try XCTUnwrap(stepUp.state, "\(label)：没换会话、没登出：面板不收起", file: file, line: line)
        XCTAssertFalse(state.awaitingIdentity, "\(label)：不进等身份", file: file, line: line)
        XCTAssertEqual(state.phase, .ready, "\(label)：停在可输入，不卡在发送中", file: file, line: line)
        XCTAssertEqual(state.error?.key, StepUpController.sendFailedKey, "\(label)：一条没发不得静默：提示发送失败",
                       file: file, line: line)
        XCTAssertEqual(state.resendLeftSec, 0, "\(label)：没发出：不起倒计时", file: file, line: line)

        _ = await host.stable(seconds: 6, file: file, line: line) { $0.probes["stepUp.title"] != nil }
        XCTAssertFalse(sheetTexts.contains(texts.text("step_up.sent")),
                       "\(label)：说明位不得显示「已发送」（现显示 \(sheetTexts)）", file: file, line: line)
        XCTAssertEqual(page?.probes["stepUp.error.text"]?.text, texts.text(StepUpController.sendFailedKey),
                       "\(label)：半屏显示发送失败提示", file: file, line: line)
        XCTAssertTrue(has("stepUp.resend"), "\(label)：显示【重新获取】", file: file, line: line)
        XCTAssertFalse(has("stepUp.countdown"), "\(label)：不显示倒计时", file: file, line: line)
        XCTAssertFalse(has("stepUp.sending"), "\(label)：不显示发送中", file: file, line: line)

        Self.restoreAccess(host.fixture)
        let now = try XCTUnwrap(stepUp.state, file: file, line: line)
        StepUpActions.make(stepUp, now).resend()
        await waitUntil("\(label)：【重新获取】没有发出", file: file, line: line) { self.smsSends.count == 1 }
        await idle(host)
        await quietWindow(0.3)
        XCTAssertEqual(smsSends.count, 1, "\(label)：恰发 1 次", file: file, line: line)
        XCTAssertEqual(smsSends.first?.header("Authorization"), "Bearer at", "\(label)：带本人令牌",
                       file: file, line: line)
        XCTAssertNil(stepUp.state?.error, "\(label)：发出后清掉错误", file: file, line: line)
        XCTAssertGreaterThan(stepUp.state?.resendLeftSec ?? 0, 0, "\(label)：发出后起倒计时", file: file, line: line)
        XCTAssertEqual(stepUp.state?.sendFailed, false, "\(label)：发出后清掉 sendFailed", file: file, line: line)
        _ = await host.stable(seconds: 6, file: file, line: line) { $0.probes["stepUp.sent"] != nil }
        XCTAssertEqual(page?.probes["stepUp.sent"]?.text, texts.text("step_up.sent"),
                       "\(label)：重新发出后说明位重新显示「已发送」", file: file, line: line)
    }

    // MARK: - 修复前红

    // D10-3641：原 testWithdrawPanelWithoutAccessShowsSendFailureAndResendCarriesToken 改断新行为（改收款孪生见下一条）
    /// 提现提交得到 10003（D10-3639 C）：不开面板、半屏不出现、不调用发码入口、零发送；提现只发 1 次，回编辑态提示 error.10003。
    /// 「没有 access 时发送失败、重新获取带令牌」只剩改收款面板（下一条）。
    func testWithdraw10003OpensNoSheet() async throws {
        let host = try await withdraw10003()
        await idle(host)
        await quietWindow(0.5)
        let flow = try XCTUnwrap(host.flow)
        XCTAssertNil(flow.stepUp.state, "提现 10003 不开面板")
        XCTAssertEqual(host.fixture.api.calls(StepUpController.sendOperation), 0, "不调用发码入口")
        XCTAssertTrue(smsSends.isEmpty, "零发送")
        XCTAssertEqual(flow.state.phase, .editing, "回编辑态")
        XCTAssertEqual(flow.state.error?.key, "error.10003", "提示 error.10003")
        XCTAssertEqual(WalletStubProtocol.requests("POST", "/v1/withdrawals").count, 1, "提现只发 1 次（不重放）")
        _ = await host.stable { _ in true }
        XCTAssertFalse(has("stepUp.title"), "半屏不出现")
    }

    /// 改收款面板：同上。
    func testPayoutPanelWithoutAccessShowsSendFailureAndResendCarriesToken() async throws {
        let host = try await payoutPanel(hook: Self.blankAccess)
        try await assertFailureThenResend(host, "改收款")
    }

    // MARK: - 身份已失效（D10-1790：同账号同世代没有 access 也算核对不过；sentArrived 判 stale 时落到发送失败 + 可重新获取）

    /// 身份已失效后的面板：要么已收起，要么是发送失败态（可输入、网络错误提示、无倒计时、不等身份）。两者都不显示「已发送」后的倒计时。
    private func assertFailedOrGone(_ stepUp: StepUpController, _ label: String,
                                    file: StaticString = #filePath, line: UInt = #line) {
        guard let state = stepUp.state else { return }
        XCTAssertFalse(state.awaitingIdentity, "\(label)：判 stale 不进等身份", file: file, line: line)
        XCTAssertEqual(state.phase, .ready, "\(label)：失败态可输入", file: file, line: line)
        XCTAssertEqual(state.error?.key, StepUpController.sendFailedKey, "\(label)：失败态提示发送失败", file: file, line: line)
        XCTAssertEqual(state.resendLeftSec, 0, "\(label)：不起倒计时", file: file, line: line)
    }

    /// 非 GET 请求（写入、发码、验证）。会话变化通知后各页按新身份重取的 GET 不计。
    private var nonGets: [String] {
        WalletStubProtocol.requests.filter { $0.method != "GET" }.map { "\($0.method) \($0.path)" }
    }

    private func slot(_ host: WithdrawVisualHost, _ action: String) -> SmsDeadlines.Slot {
        SmsDeadlines.Slot(
            account: "user-a", phone: host.wallet.stepUpPhone(account: "user-a") ?? StepUpController.boundSlot,
            action: action
        )
    }

    /// 发码挂起 → `change` → 放行迟到的成功（带 resend_after_sec）→ 落定。
    private func lateSuccess(after change: @MainActor (WalletAppFixture) -> Void) async throws
        -> (WithdrawVisualHost, StepUpController) {
        let host = try await payoutPanel(sms: .hold)
        let stepUp = try XCTUnwrap(host.flow?.stepUp)
        await waitUntil("发码没有挂起") { WalletStubProtocol.heldIds.count == 1 }
        change(host.fixture)
        let held = try XCTUnwrap(WalletStubProtocol.heldIds.first)
        WalletStubProtocol.release(held, with: Self.smsOk(48))
        await idle(host)
        await quietWindow(0.5)
        return (host, stepUp)
    }

    // D10-3641：原 testAccountSwappedBeforeSendFailsOrCollapsesThenCollapses 前置由提现挪到改收款
    /// 发码前存储换成别的账号（同一会话世代，清空通知还没到）→ account_mismatch、零发送；面板失败态或已收起（不倒计时、不等身份）；
    /// 换代通知到达后收起。
    func testAccountSwappedBeforeSendFailsOrCollapsesThenCollapsesOnPayout() async throws {
        let host = try await payoutPanel { fixture in
            try? fixture.tokens.save(
                access: "at-b", refresh: "rt-b", scope: "full", account: "user-b", loginEpoch: "fixture-login-user-b"
            )
        }
        let stepUp = try XCTUnwrap(host.flow?.stepUp)
        await idle(host)
        await quietWindow(0.5)
        XCTAssertEqual(host.fixture.api.calls(StepUpController.sendOperation), 1, "前提：调用了发码入口")
        XCTAssertTrue(smsSends.isEmpty, "换了账号：零发送")
        assertFailedOrGone(stepUp, "换账号")

        host.fixture.wallet.checkSession()
        await waitUntil("换代后面板没有收起") { stepUp.state == nil }
        await quietWindow(0.3)
        XCTAssertNil(stepUp.state, "收起")
        XCTAssertTrue(smsSends.isEmpty)
    }

    // D10-3641：原 testSessionChangeWhileSendInFlightFailsThenCollapsesWithoutNewRequests 前置由提现挪到改收款
    /// 发码在途时真换会话 / 登出（存储已变、清空通知还没到）→ 迟到的成功：面板失败态或已收起；旧面板【重新获取】不发；通知到达后收起。
    /// 全程 sms-codes 只有最初 1 次，非 GET 请求不增加。假设：stale 判定先于读结果体；会话变化通知走 AppLogin → AppWallet.checkSession
    /// → rebuild → SensitiveFlow.sessionChanged → stepUp.dismiss；通知后各页按新身份重取的 GET 不算「新请求」。
    func testSessionChangeWhileSendInFlightFailsThenCollapsesWithoutNewRequestsOnPayout() async throws {
        let changes: [(String, @MainActor (WalletAppFixture) -> Void)] = [
            ("换会话", { try? $0.swapTokensSilently(to: "user-b") }),
            ("登出", { $0.network.client.signOut() }),
        ]
        for (label, change) in changes {
            let (host, stepUp) = try await lateSuccess(after: change)
            let before = nonGets
            XCTAssertEqual(smsSends.count, 1, "\(label)：前提：最初发码 1 次")
            assertFailedOrGone(stepUp, label)
            if let state = stepUp.state {
                StepUpActions.make(stepUp, state).resend()
                await quietWindow(0.3)
            }
            host.fixture.routing.sessionStateChanged(resumePending: false)
            await waitUntil("\(label)：会话变化通知后面板没有收起") { stepUp.state == nil }
            await idle(host)
            await quietWindow(0.5)
            XCTAssertNil(stepUp.state, "\(label)：最终收起")
            XCTAssertEqual(smsSends.count, 1, "\(label)：全程 sms-codes 只有最初 1 次")
            XCTAssertEqual(nonGets, before, "\(label)：没有任何新的写入 / 发码 / 验证请求")
        }
    }

    // D10-3641：原 testStaleLateSuccessDoesNotStartCountdownOrSharedDeadline 前置由提现挪到改收款
    /// stale 分支不读结果体：发码在途时 access 被置空（同账号同世代）、迟到的成功带 resend_after_sec=48 → 面板发送失败态、不起倒计时，
    /// 共享截止时间不写（SmsDeadlines 该槽位剩余 0）。
    func testStaleLateSuccessDoesNotStartCountdownOrSharedDeadlineOnPayout() async throws {
        let (host, stepUp) = try await lateSuccess(after: Self.blankAccess)
        XCTAssertEqual(smsSends.count, 1, "前提：请求实际发出 1 次")
        let state = try XCTUnwrap(stepUp.state, "没换会话、没登出：面板不收起")
        assertFailedOrGone(stepUp, "access 空")
        XCTAssertEqual(state.error?.key, StepUpController.sendFailedKey)
        XCTAssertEqual(
            host.wallet.deps.sms.remaining(slot(host, PayoutAccountController.action), now: Self.frozenMillis), 0,
            "不写共享截止时间"
        )
        _ = await host.stable(seconds: 6) { $0.probes["stepUp.title"] != nil }
        XCTAssertFalse(has("stepUp.countdown"), "不显示倒计时")
        XCTAssertFalse(sheetTexts.contains(texts.text("step_up.sent")), "说明位不显示「已发送」")
    }

    // D10-3641：原 testStaleSuccessThenResend42901ShowsRateLimitAndDisables 前置由提现挪到改收款
    /// 结果其实成功但回来时 access 空着 → 发送失败；恢复令牌后点【重新获取】，服务端 42901（Retry-After 120）→ 现有限频提示
    /// error.42901、发码禁用期按 Retry-After 起算，禁用期内再点不发。
    func testStaleSuccessThenResend42901ShowsRateLimitAndDisablesOnPayout() async throws {
        let (host, stepUp) = try await lateSuccess(after: Self.blankAccess)
        assertFailedOrGone(stepUp, "access 空")
        XCTAssertEqual(stepUp.state?.error?.key, StepUpController.sendFailedKey, "先是发送失败")
        Self.restoreAccess(host.fixture)
        host.server.script.on(
            "POST /v1/auth/sms-codes", .envelope(code: 42901, data: "null", headers: ["Retry-After": "120"])
        )
        let failed = try XCTUnwrap(stepUp.state)
        StepUpActions.make(stepUp, failed).resend()
        await waitUntil("【重新获取】没有发出") { self.smsSends.count == 2 }
        await idle(host)
        await waitUntil("没有落到限频提示") { stepUp.state?.error?.key == "error.42901" }
        XCTAssertEqual(smsSends.last?.header("Authorization"), "Bearer at", "重新获取带本人令牌")
        XCTAssertEqual(stepUp.state?.phase, .ready)
        XCTAssertEqual(stepUp.state?.resendLeftSec, 0, "限频不起倒计时")
        let gate = host.wallet.deps.gates.sms
        XCTAssertTrue(gate.active, "按 Retry-After 进发码禁用期")
        XCTAssertGreaterThan(gate.remainingMillis, 100_000, "按 Retry-After 120 秒")
        let limited = try XCTUnwrap(stepUp.state)
        StepUpActions.make(stepUp, limited).resend()
        await quietWindow(0.4)
        XCTAssertEqual(smsSends.count, 2, "禁用期内再点不发")
    }

    // D10-3641：原 testLogoutWhileSendInFlightCollapsesSilently 前置由提现挪到改收款
    /// 对照（应绿）：发码在途时登出并已发通知 → 面板先收起；迟到的成功不重新打开、不弹错误。
    func testLogoutWhileSendInFlightCollapsesSilentlyOnPayout() async throws {
        let host = try await payoutPanel(sms: .hold)
        let stepUp = try XCTUnwrap(host.flow?.stepUp)
        await waitUntil("发码没有挂起") { WalletStubProtocol.heldIds.count == 1 }
        host.fixture.network.client.signOut()
        host.fixture.routing.sessionStateChanged(resumePending: false)
        await waitUntil("登出后面板没有收起") { stepUp.state == nil }
        let held = try XCTUnwrap(WalletStubProtocol.heldIds.first)
        WalletStubProtocol.release(held, with: Self.smsOk())
        await idle(host)
        await quietWindow(0.5)
        XCTAssertNil(stepUp.state, "迟到结果不重新打开面板、不弹错误")
        XCTAssertFalse(has("stepUp.error.text"))
    }
}
