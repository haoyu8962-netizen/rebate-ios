@testable import Couli
import CouliNetwork
import Foundation
import Router
import Wallet
@testable import WalletCore
import XCTest

/// LOCK-ios 段 3（App 接线）：二次验证面板的发码经真实 ApiClient 发出的样子，以及 AppWallet 的 phone_bound 接线。全部经生产入口
/// （提现【提交】/ 收款【保存】→ 10003 → 面板），只把传输层换成本地假服务。
/// - 发码 sendSmsCode {purpose: step_up, action}：full 会话带 Authorization、请求体不带 phone（即使 App 给了号码，B1-02zzz）；
/// - requiresSession（D10-1658 ④、S2-1）：发码那一刻会话读不出 / 没有可用 access → 本地拒、零发送，面板不起倒计时并提示发送失败（D10-1790）；受限会话屏障到期时
///   发码先等屏障刷新、带新令牌（D10-1722 (b)：只有这条在去掉 requiresSession 时变红）；
/// - phoneProvider 为 nil（Release）照常发码，倒计时内重开不重复发；
/// - phone_bound（AppLogin.phone 按面板身份那一代会话取，D10-1682 ②）：false 时改收款 noPhone；true / nil 照发（D10-1667）；提现 10003 不开面板
///   （D10-3639 C，D10-3641 起前四节的面板宿主由提现挪到改收款）。
/// 发码那一刻的故障经 `AppWallet.phoneBound` 插入：面板在身份核对（admit）之后、交给网络层之前同步读它，插在这里的故障只影响发码请求本身。
final class LockIosStepUpWiringTests: WalletFlowTestCase {
    static let need = WalletStubProtocol.Reply.envelope(code: 10003, data: "null", headers: [:])
    static let saved = WalletStubProtocol.Reply.envelope(code: 0, data: WalletSamples.alipay, headers: [:])

    var smsSent: [WalletStubProtocol.Recorded] {
        WalletStubProtocol.requests("POST", "/v1/auth/sms-codes")
    }

    func payoutActions(_ controller: PayoutAccountController) -> PayoutActions {
        PayoutActions.make(controller, controller.state, risk: controller.flow.state.riskDialog?.id)
    }

    /// 打开收款账号页（未绑定直接是表单），填支付宝并点【保存】得到 10003，等面板出现。`beforeSave` 在页面打开之后、保存之前执行。
    func openPayoutPanel(_ fixture: WalletAppFixture,
                         beforeSave: () -> Void = {}) async throws -> PayoutAccountController {
        script.ok("GET /v1/me/payout-account", "{}")
        script.on("PUT /v1/me/payout-account", Self.need, Self.saved)
        let controller = try await payout(fixture)
        payoutActions(controller).logon("zhangsan@example.com")
        payoutActions(controller).payee("测试三")
        beforeSave()
        payoutActions(controller).save()
        await waitUntil("二次验证面板没有打开") { controller.flow.stepUp.state != nil }
        return controller
    }

    func idle(_ flow: SensitiveFlow) async {
        for _ in 0..<3 {
            await flow.stepUp.whenIdle()
            await flow.whenIdle()
        }
    }

    /// 面板落定：noPhone，或 ready 且倒计时已起 / 有错误。
    func landedPanel(_ flow: SensitiveFlow, _ message: String = "面板没有落定") async {
        await idle(flow)
        await waitUntil(message) {
            guard let state = flow.stepUp.state else { return false }
            return state.phase == .noPhone || (state.phase == .ready && (state.resendLeftSec > 0 || state.error != nil))
        }
    }

    // MARK: - 1. requiresSession

    // D10-3641：原 testFullSessionSendCarriesAuthorizationAndNoPhone 前置由提现挪到改收款
    /// full 会话：发码带 Authorization（本人令牌），请求体只有 purpose=step_up 与 action，不带 phone（App 给了测试号也不上送）。
    func testFullSessionSendCarriesAuthorizationAndNoPhoneOnPayout() async throws {
        let fixture = make()
        let controller = try await openPayoutPanel(fixture)
        await landedPanel(controller.flow)
        XCTAssertEqual(smsSent.count, 1)
        let sms = try XCTUnwrap(smsSent.first)
        XCTAssertEqual(sms.header("Authorization"), "Bearer at", "带本人令牌")
        XCTAssertEqual(Set(sms.json.keys), ["purpose", "action"], "请求体只有 purpose 与 action")
        XCTAssertEqual(sms.json["purpose"] as? String, "step_up")
        XCTAssertEqual(sms.json["action"] as? String, "payout_account_change")
        XCTAssertNil(sms.json["phone"])
        XCTAssertGreaterThan(controller.flow.stepUp.state?.resendLeftSec ?? 0, 0, "倒计时已起")
    }

    // D10-3641：原 testUnreadableSessionAtSendRejectsLocallyAndShowsError 前置由提现挪到改收款
    /// 发码那一刻会话读不出：本地 session_unreadable、发码入口 1 次但实际发送 0 次；身份确认后面板停在可输入、不起倒计时、提示错误；
    /// 之后【重新获取】照常带令牌发出。
    func testUnreadableSessionAtSendRejectsLocallyAndShowsErrorOnPayout() async throws {
        let fixture = make()
        let armed = LockIosOnceFlag()
        fixture.wallet.phoneBound = { _ in
            if armed.once() {
                fixture.store.failReads(fromNth: 1)
            }
            return true
        }
        let controller = try await openPayoutPanel(fixture)
        let stepUp = controller.flow.stepUp
        await idle(controller.flow)
        XCTAssertEqual(fixture.api.calls(StepUpController.sendOperation), 1, "前提：面板调用了发码入口")
        XCTAssertTrue(smsSent.isEmpty, "会话读不出：零发送")
        fixture.store.stopFailing()
        fixture.wallet.checkSession()
        await landedPanel(controller.flow, "身份确认后面板没有落定")
        let state = try XCTUnwrap(stepUp.state, "面板不被收起")
        XCTAssertEqual(state.phase, .ready)
        XCTAssertEqual(state.resendLeftSec, 0, "没发出：不起倒计时")
        XCTAssertEqual(state.error?.key, WalletErrors.networkKey, "提示错误（本地拒绝按网络错误文案）")
        XCTAssertTrue(smsSent.isEmpty, "恢复后不自动补发")

        StepUpActions.make(stepUp, state).resend()
        await landedPanel(controller.flow)
        XCTAssertEqual(smsSent.count, 1, "【重新获取】照常发出")
        XCTAssertEqual(smsSent.first?.header("Authorization"), "Bearer at")
    }

    // D10-3641：原 testSessionWithoutAccessAtSendSendsNothing 前置由提现挪到改收款
    /// 发码那一刻会话没有可用 access（只剩 refresh）：不带令牌的发码零发送，面板不起倒计时。
    /// 只断言零发送与不起倒计时：网络层 `readyMismatch` 先核固定归属，面板固定了账号、optional 没带上令牌按 account_mismatch 本地结束、
    /// 零发送，走不到 requiresSession 的 session_unreadable 分支；会话少了 access 时持久化登录世代也读为 nil，面板身份核对不过，按 D10-1790
    /// 落到发送失败、可重新获取，不起倒计时（modify_existing ruling D10-1791：只改注释，断言不动）。
    func testSessionWithoutAccessAtSendSendsNothingOnPayout() async throws {
        let fixture = make()
        let armed = LockIosOnceFlag()
        fixture.wallet.phoneBound = { _ in
            if armed.once() {
                try? fixture.tokens.save(
                    access: "", refresh: "rt", scope: "full", account: "user-a", loginEpoch: "fixture-login-user-a"
                )
            }
            return true
        }
        let controller = try await openPayoutPanel(fixture)
        await idle(controller.flow)
        await quietWindow(0.5)
        XCTAssertEqual(fixture.api.calls(StepUpController.sendOperation), 1, "前提：面板调用了发码入口")
        XCTAssertTrue(smsSent.isEmpty, "没有 access：不带令牌的发码零发送")
        XCTAssertEqual(controller.flow.stepUp.state?.resendLeftSec ?? 0, 0, "没发出：不起倒计时")
        XCTAssertTrue(
            WalletStubProtocol.requests.filter { $0.path == "/v1/auth/sms-codes" && $0.header("Authorization") == nil }
                .isEmpty,
            "任何发码请求都不得不带令牌发出"
        )
    }

    // D10-3641：原 testRestrictedSessionSendWaitsForBarrierRefreshAndCarriesNewToken 前置由提现挪到改收款
    /// D10-1722 (b)：发码那一刻会话变成受限会话（deletion_only）且受限会话屏障到期（强更恢复为受支持重新挂上，刷新挂在假服务上）：
    /// 发码必须等这次刷新完成才发出、带刷新后的新令牌——刷新在途期间零发送，放行后恰发 1 次、Authorization 是新令牌、排在刷新之后。
    /// 上面两条（读不出 / 没有 access）去掉发码 ApiCall 的 `requiresSession` 照样零发送（prepare 的 session_unreadable、固定账号的
    /// account_mismatch 先拦下），抓不住；这条抓得住：x-auth=optional 的调用没置 requiresSession 时 `needsSession` 为 false、不等屏障，
    /// 发码会在刷新在途时立刻带旧受限令牌（Bearer at）发出。
    func testRestrictedSessionSendWaitsForBarrierRefreshAndCarriesNewTokenOnPayout() async throws {
        let fixture = make()
        let refreshed = WalletStubProtocol.Reply.envelope(
            code: 0,
            data: "{\"access_token\":\"at-new\",\"refresh_token\":\"rt-new\",\"session_scope\":\"full\","
                + "\"expires_in\":7200}",
            headers: [:]
        )
        script.on("POST /v1/auth/refresh", .hold)
        let armed = LockIosOnceFlag()
        fixture.wallet.phoneBound = { _ in
            if armed.once() {
                // 同一账号、同一登录世代、不换会话世代：只把存储里的会话改成受限，再按强更恢复挂上新一轮屏障（会立即发起单飞刷新）
                try? fixture.tokens.save(
                    access: "at", refresh: "rt", scope: "deletion_only", account: "user-a",
                    loginEpoch: "fixture-login-user-a"
                )
                fixture.network.client.updateStateChanged(UpdateRaw.below)
                fixture.network.client.updateStateChanged(UpdateRaw.supported)
            }
            return true
        }
        let controller = try await openPayoutPanel(fixture)
        await waitUntil("屏障刷新没有发出") { WalletStubProtocol.heldIds.count == 1 }
        await quietWindow(0.5)
        XCTAssertEqual(fixture.api.calls(StepUpController.sendOperation), 1, "前提：面板调用了发码入口")
        XCTAssertTrue(smsSent.isEmpty, "刷新在途：发码等屏障，不带旧受限令牌先发")
        let held = try XCTUnwrap(WalletStubProtocol.heldIds.first)
        WalletStubProtocol.release(held, with: refreshed)
        await landedPanel(controller.flow, "刷新完成后面板没有落定")
        XCTAssertEqual(smsSent.count, 1, "刷新完成后恰发 1 次")
        XCTAssertEqual(smsSent.first?.header("Authorization"), "Bearer at-new", "带刷新后的新令牌")
        let paths = WalletStubProtocol.requests.map(\.path)
        let refreshAt = try XCTUnwrap(paths.firstIndex(of: "/v1/auth/refresh"))
        let smsAt = try XCTUnwrap(paths.firstIndex(of: "/v1/auth/sms-codes"))
        XCTAssertLessThan(refreshAt, smsAt, "发码排在屏障刷新之后")
        XCTAssertGreaterThan(controller.flow.stepUp.state?.resendLeftSec ?? 0, 0, "发出后起倒计时")
    }

    // MARK: - 2. phoneProvider 为 nil

    // D10-3641：原 testNilPhoneProviderSendsAndReopenDoesNotResend 前置由提现挪到改收款
    /// Release 口径（phoneProvider 为 nil）：照常发码（不进 noPhone）；关闭面板后再【保存】得到 10003，新面板在倒计时内不重复发。
    func testNilPhoneProviderSendsAndReopenDoesNotResendOnPayout() async throws {
        let fixture = make()
        fixture.wallet.phoneProvider = { _ in nil }
        script.ok("GET /v1/me/payout-account", "{}")
        script.on("PUT /v1/me/payout-account", Self.need, Self.need, Self.saved)
        let controller = try await payout(fixture)
        payoutActions(controller).logon("zhangsan@example.com")
        payoutActions(controller).payee("测试三")
        payoutActions(controller).save()
        let stepUp = controller.flow.stepUp
        await waitUntil("二次验证面板没有打开") { stepUp.state != nil }
        await landedPanel(controller.flow)
        XCTAssertEqual(stepUp.state?.phase, .ready, "号码为 nil 不进 noPhone")
        XCTAssertEqual(smsSent.count, 1)
        XCTAssertNil(smsSent.first?.json["phone"])
        let first = try XCTUnwrap(stepUp.state)
        StepUpActions.make(stepUp, first).close()
        await waitUntil("关闭面板后没有回到编辑态") { controller.flow.state.phase == .editing }
        payoutActions(controller).save()
        await waitUntil("第二个面板没有打开") { stepUp.state.map { $0.instance != first.instance } ?? false }
        await landedPanel(controller.flow)
        XCTAssertEqual(stepUp.state?.phase, .ready)
        XCTAssertGreaterThan(stepUp.state?.resendLeftSec ?? 0, 0, "按共享截止恢复倒计时")
        XCTAssertEqual(fixture.api.calls(StepUpController.sendOperation), 1, "倒计时内不调用发码入口")
        XCTAssertEqual(smsSent.count, 1, "倒计时内不重复发码")
    }

    // MARK: - 3. phone_bound

    /// phone_bound=false（AppLogin.phone 记的面板那一代会话）：改收款面板进 noPhone、不发码。
    func testUnboundPayoutEntersNoPhone() async throws {
        let fixture = make()
        let controller = try await openPayoutPanel(fixture) {
            fixture.login.phone.record(false, generation: fixture.network.client.sessionGeneration)
        }
        await landedPanel(controller.flow)
        XCTAssertEqual(controller.flow.stepUp.state?.phase, .noPhone)
        XCTAssertEqual(fixture.api.calls(StepUpController.sendOperation), 0, "没绑手机：改收款不调用发码入口")
        XCTAssertTrue(smsSent.isEmpty)
    }

    // D10-3641：原 testUnboundWithdrawStillSends 改断新行为（提现 10003 不开面板，「提现面板不按 phone_bound 拦」已无从谈起）
    /// phone_bound=false：提现提交得到 10003 → 不开面板、不调用发码入口、不发码，回编辑态提示 error.10003，提现只发 1 次（D10-3639 C）。
    func testUnboundWithdraw10003NoPanel() async throws {
        let fixture = make()
        let controller = try await withdraw(fixture)
        fixture.login.phone.record(false, generation: fixture.network.client.sessionGeneration)
        script.on("POST /v1/withdrawals", Self.need)
        await typeAmount(controller, "10")
        actions(controller).submit()
        await waitUntil("提现 10003 没有结算") { controller.flow.state.error != nil }
        await idle(controller.flow)
        await quietWindow(0.3)
        XCTAssertNil(controller.flow.stepUp.state, "提现 10003 不开面板")
        XCTAssertEqual(fixture.api.calls(StepUpController.sendOperation), 0, "不调用发码入口")
        XCTAssertTrue(smsSent.isEmpty, "不发码")
        XCTAssertEqual(controller.flow.state.phase, .editing, "回编辑态")
        XCTAssertEqual(controller.flow.state.error?.key, "error.10003", "提示 error.10003")
        XCTAssertEqual(posts.count, 1, "提现只发 1 次（不重放）")
    }

    /// phone_bound=true（夹具缺省：短信登录的账号）：改收款照常发码。
    func testBoundPayoutSends() async throws {
        let fixture = make()
        let controller = try await openPayoutPanel(fixture)
        await landedPanel(controller.flow)
        XCTAssertEqual(controller.flow.stepUp.state?.phase, .ready)
        XCTAssertEqual(smsSent.count, 1, "已绑：照常发码")
        XCTAssertEqual(smsSent.first?.json["action"] as? String, "payout_account_change")
    }

    /// phone_bound 未知（nil：没查清、已换代）：改收款照常发码（服务端没绑手机回 20001 data.fields=[code]）。
    func testUnknownBoundPayoutSends() async throws {
        let fixture = make()
        fixture.wallet.phoneBound = { _ in nil }
        let controller = try await openPayoutPanel(fixture)
        await landedPanel(controller.flow)
        XCTAssertEqual(controller.flow.stepUp.state?.phase, .ready, "未知不进 noPhone")
        XCTAssertEqual(smsSent.count, 1, "未知：照常发码")
    }
}

/// 一次性开关（钩子只在第一次发码时生效）。
@MainActor
final class LockIosOnceFlag {
    private var fired = false

    func once() -> Bool {
        defer { fired = true }
        return !fired
    }
}
