@testable import Couli
import CouliNetwork
import Foundation
import Router
import Wallet
import WalletCore
import XCTest

/// 收款账号（BR-WDR-02、FUND-03，AC-S2-21 / AC-S2-54 ① 客户端部分，AC-S2-62 ⑩⑰㉒，G12–G15）。
final class PayoutAccountTests: WalletFlowTestCase {
    func payoutActions(_ controller: PayoutAccountController) -> PayoutActions {
        PayoutActions.make(controller, controller.state, risk: controller.flow.state.riskDialog?.id)
    }

    /// 已绑定只显示服务端脱敏字段与本月剩余次数；【更换收款账号】打开表单（回调核对渲染版本与账号身份）。
    func testBoundShowsMaskedFieldsOnly() async throws {
        let fixture = make()
        let controller = try await payout(fixture)
        let account = try XCTUnwrap(controller.state.account)
        XCTAssertEqual(account.maskedAccount, "138****5678")
        XCTAssertEqual(account.maskedPayee, "**三")
        XCTAssertEqual(account.changeRemaining, 2)
        XCTAssertFalse(controller.state.editing)
        payoutActions(controller).change()
        XCTAssertTrue(controller.state.editing)
    }

    /// 未绑定直接显示表单；首次绑定也弹二次验证；成功从 Withdraw 进来的出栈回发起页；表单与内存里的完整输入清空。
    func testFirstBindNeedsStepUpAndReturnsToWithdraw() async throws {
        script.ok("GET /v1/me/payout-account", "{}")
        script.on(
            "PUT /v1/me/payout-account", .envelope(code: 10003, data: "null", headers: [:]),
            .envelope(code: 0, data: WalletSamples.alipay, headers: [:])
        )
        let fixture = make()
        _ = try await withdraw(fixture)
        let controller = try await payout(fixture)
        XCTAssertTrue(controller.state.editing, "未绑定直接显示表单")
        payoutActions(controller).logon(" zhangsan@example.com ")
        payoutActions(controller).payee(" 测试三 ")
        payoutActions(controller).save()
        try await passStepUp(controller.flow.stepUp)
        await waitUntil("保存后没有回到提现页") { fixture.router.path.last?.route == WalletRoutes.withdraw }
        XCTAssertEqual(saves.count, 2)
        XCTAssertEqual(saves[0].header("Idempotency-Key"), saves[1].header("Idempotency-Key"))
        let body = saves[1].json
        XCTAssertEqual(body["payout_method"] as? String, "alipay")
        XCTAssertEqual(body["alipay_logon_id"] as? String, "zhangsan@example.com", "只去首尾空白")
        XCTAssertEqual(body["payee_name"] as? String, "测试三")
        XCTAssertEqual(WalletStubProtocol.requests("POST", "/v1/auth/sms-codes").first?.json["action"] as? String,
                       "payout_account_change")
        XCTAssertEqual(controller.state.form, PayoutForm(), "清空表单与内存中的完整输入")
    }

    /// 本地校验：必填为空不发请求，就地提示；20001（card_no）在卡号旁提示、保留输入；30307 页内提示保留输入；30303 change_limit 文案。
    func testFieldAndBusinessErrorsStayOnPage() async throws {
        script.ok("GET /v1/me/payout-account", "{}")
        let fixture = make()
        let controller = try await payout(fixture)
        payoutActions(controller).save()
        XCTAssertEqual(controller.state.localErrors, ["alipay_logon_id", "payee_name"])
        XCTAssertTrue(saves.isEmpty)
        payoutActions(controller).method(WalletJSON.bankCard)
        payoutActions(controller).card("6222 0000 0000 0009")
        payoutActions(controller).card("6222x")
        XCTAssertEqual(controller.state.form.cardNo, "6222 0000 0000 0009", "卡号只收数字、空格、连字符")
        payoutActions(controller).bank("测试银行")
        payoutActions(controller).payee("测试三")
        controller.flow.stepUp.state.map { StepUpActions.make(controller.flow.stepUp, $0).close() }
        script.fail("PUT /v1/me/payout-account", 20001, data: "{\"fields\":[\"card_no\"]}")
        fixture.wallet.deps.tokens.put(action: "payout_account_change", account: "user-a", token: "t", expireAtMs: .max)
        payoutActions(controller).save()
        await waitUntil { controller.flow.state.fieldErrors == ["card_no"] }
        XCTAssertEqual(controller.state.form.cardNo, "6222 0000 0000 0009", "保留输入")
        XCTAssertEqual(saves.last?.header("X-Step-Up-Token"), "t", "未过期的同 action token 带上（G17）")
        for (code, key) in [(30307, "error.30307"), (30303, "error.30303.payout_account_change_limit")] {
            script.fail("PUT /v1/me/payout-account", code, data: code == 30303
                ? "{\"reason\":\"payout_account_change_limit\"}" : "null")
            fixture.wallet.deps.tokens.put(
                action: "payout_account_change",
                account: "user-a",
                token: "t",
                expireAtMs: .max
            )
            payoutActions(controller).save()
            await waitUntil { controller.flow.state.error?.key == key }
            XCTAssertEqual(fixture.router.path.last?.route, WalletRoutes.payoutAccount, "留在本页，不重复压入同名页")
        }
    }

    /// 结果未知 → 待确认（PayoutAccountPending*）：摘要本机脱敏（G15），完整请求体只在未决记录；【放弃】二次确认后 abandoned → 表单可用。
    func testUnknownSaveEntersPendingWithMaskedSummary() async throws {
        script.ok("GET /v1/me/payout-account", "{}")
        script.on("PUT /v1/me/payout-account", .disconnect)
        let fixture = make()
        let controller = try await payout(fixture)
        fixture.wallet.deps.tokens.put(action: "payout_account_change", account: "user-a", token: "t", expireAtMs: .max)
        payoutActions(controller).logon("13800135678")
        payoutActions(controller).payee("测试三")
        payoutActions(controller).save()
        await waitUntil { controller.flow.state.pending != nil }
        let summary = try XCTUnwrap(PayoutPendingSummary.decode(controller.flow.state.pending?.summary ?? ""))
        XCTAssertEqual(summary.account, "138****5678")
        XCTAssertEqual(summary.payee, "**三")
        XCTAssertFalse(controller.flow.state.pending?.summary.contains("13800135678") ?? true, "摘要不含完整登录号")
        flowActions(controller.flow).askAbandon()
        flowActions(controller.flow).abandon()
        await waitUntil { controller.flow.state.pending == nil }
        XCTAssertEqual(
            WalletStubProtocol.requests("POST", "/v1/idempotency-keys/abandon").first?.json["action"] as? String,
            "payout_account_change"
        )
    }

    /// 读取得到 30304（未实名）：可见时去实名，回来仍在本页（G05）。
    func testRealnameRequiredOnLoadGuides() async throws {
        script.fail("GET /v1/me/payout-account", 30304)
        let fixture = make()
        _ = try await payout(fixture)
        await waitUntil { fixture.router.path.last?.route == WalletRoutes.realName }
    }
}
