@testable import Couli
import CouliNetwork
import Foundation
import Wallet
import WalletCore
import XCTest

/// APP-13a-2-ios 零变化（桩上绿、实现后仍须绿；照 FuIosWalletScopeZeroChangeTests 写法）：WalletCore 为换号开二次验证控制器的公开口子之后
/// （D10-2203 ②「只加可见性 / 可选参数，提现与收款调用点不动」），提现、改收款打开的二次验证面板逐字照旧：发码体、验证体（提现无 summary、
/// 改收款带 summary）、10003 后原键原体重放 1 次带新 token、发码 / 验证 42901 写共享 gates.sms / gates.verify。
/// 升锁 6c97062（D10-2903 ① 甲）起提现不再要求二次验证：提现那条改成「只发一次、不出面板」，发码体 / 重放带 token 的断言挪到改收款。
@MainActor
final class App13a2WalletZeroChangeTests: WalletFlowTestCase {
    private static let smsSend = "/v1/auth/sms-codes"
    private static let verify = "/v1/auth/step-up"

    private func payoutActions(_ controller: PayoutAccountController) -> PayoutActions {
        PayoutActions.make(controller, controller.state, risk: controller.flow.state.riskDialog?.id)
    }

    /// 提现（升锁 6c97062，D10-2903 ① 甲：提现不再要求二次验证）：提交只发一次，首次那把键，不带 token，不发码、不验证、不出面板。
    /// 原「提现面板发码体逐字节、原键原体重放带新 token」挪到改收款：testPayoutPanelSmsBodyAndReplayTokenUnchanged；
    /// 「提现验证不带 summary」挪不过去（改收款验证体必须带 summary，由 testPayoutPanelUnchanged 与 LockIosStepUpSummaryWiringTests 钉住）。
    func testWithdrawSubmitsOnceWithoutPanel() async throws {
        let fixture = make()
        let controller = try await withdraw(fixture)
        await typeAmount(controller, "10")
        actions(controller).submit()
        await waitUntil("没有进提现记录") { fixture.router.path.last?.route == WalletRoutes.withdrawRecords }
        await settle()
        XCTAssertTrue(WalletStubProtocol.requests("POST", Self.smsSend).isEmpty, "不发码")
        XCTAssertTrue(WalletStubProtocol.requests("POST", Self.verify).isEmpty, "不验证")
        XCTAssertEqual(posts.count, 1, "只发一次")
        XCTAssertNotNil(posts.first?.header("Idempotency-Key"))
        XCTAssertNil(posts.first?.header("X-Step-Up-Token"))
        XCTAssertNil(controller.flow.stepUp.state, "不出面板")
    }

    /// (零变化，由提现挪来) 改收款保存 10003 → 面板：发码体逐字节只有 action + purpose；原键原体重放 1 次、带新 token。
    func testPayoutPanelSmsBodyAndReplayTokenUnchanged() async throws {
        script.ok("GET /v1/me/payout-account", "{}")
        script.on("PUT /v1/me/payout-account", .envelope(code: 10003, data: "null", headers: [:]),
                  .envelope(code: 0, data: WalletSamples.alipay, headers: [:]))
        let fixture = make()
        let controller = try await payout(fixture)
        payoutActions(controller).logon("zhangsan@example.com")
        payoutActions(controller).payee("测试三")
        payoutActions(controller).save()
        try await passStepUp(controller.flow.stepUp)
        await waitUntil("没有重放") { self.saves.count == 2 }
        XCTAssertEqual(WalletStubProtocol.requests("POST", Self.smsSend).last?.body,
                       "{\"action\":\"payout_account_change\",\"purpose\":\"step_up\"}", "(零变化) 发码体")
        XCTAssertEqual(saves[1].header("Idempotency-Key"), saves[0].header("Idempotency-Key"), "(零变化) 原键")
        XCTAssertEqual(saves[1].body, saves[0].body, "(零变化) 原体")
        XCTAssertEqual(saves[1].header("X-Step-Up-Token"), "fixture-step-up")
    }

    /// (零变化) 改收款保存 10003 → 面板 action=payout_account_change：验证体带 summary（D10-1667），原键原体重放。
    func testPayoutPanelUnchanged() async throws {
        script.ok("GET /v1/me/payout-account", "{}")
        script.on("PUT /v1/me/payout-account", .envelope(code: 10003, data: "null", headers: [:]),
                  .envelope(code: 0, data: WalletSamples.alipay, headers: [:]))
        let fixture = make()
        let controller = try await payout(fixture)
        payoutActions(controller).logon("zhangsan@example.com")
        payoutActions(controller).payee("测试三")
        payoutActions(controller).save()
        let stepUp = controller.flow.stepUp
        await waitUntil("面板没有打开") { stepUp.state != nil }
        XCTAssertEqual(stepUp.state?.action, "payout_account_change")
        try await passStepUp(stepUp)
        await waitUntil("没有重放") { self.saves.count == 2 }
        let verify = try XCTUnwrap(WalletStubProtocol.requests("POST", Self.verify).last)
        XCTAssertNotNil(verify.json["summary"], "(零变化) 改收款验证带 summary")
        XCTAssertEqual(saves[1].header("Idempotency-Key"), saves[0].header("Idempotency-Key"))
        XCTAssertEqual(saves[1].body, saves[0].body)
    }

    // D10-3641：原 testWithdrawPanel42901GatesUnchanged 前置由提现挪到改收款
    /// (零变化) 改收款面板的验证 42901 照写共享 gates.verify，发码 42901 照写 gates.sms（两份分开）。
    func testPayoutPanel42901GatesUnchanged() async throws {
        script.ok("GET /v1/me/payout-account", "{}")
        script.on("PUT /v1/me/payout-account", .envelope(code: 10003, data: "null", headers: [:]))
        script.on("POST /v1/auth/step-up", .envelope(code: 42901, data: "null", headers: ["Retry-After": "30"]))
        let fixture = make()
        let controller = try await payout(fixture)
        payoutActions(controller).logon("zhangsan@example.com")
        payoutActions(controller).payee("测试三")
        payoutActions(controller).save()
        try await passStepUp(controller.flow.stepUp)
        await waitUntil("(零变化) 验证 42901 没有写入 gates.verify") { fixture.wallet.deps.gates.verify.active }
        XCTAssertFalse(fixture.wallet.deps.gates.sms.active, "(零变化) 发码闸门不受验证 42901 影响")
    }
}
