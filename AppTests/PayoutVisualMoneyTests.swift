@testable import Couli
import CouliNetwork
import Foundation
import Router
import Wallet
import WalletCore
import XCTest

/// 资金写页回归（底版绿、实现后必须仍绿）：保存 / 提交 / 签署的条件、请求体、幂等、回调、执行器都不动。只等执行器，不等测量（a 组 v1 经验）。
@MainActor
final class PayoutVisualMoneyTests: PayoutVisualTestCase {
    /// 支付宝：保存恰一次；请求体只有这三项；带幂等键与 step-up 令牌。
    func testSaveAlipayOnceExactBody() async throws {
        let host = try await openAndSave(.envelope(code: 0, data: PayoutVisualData.payoutBody("boundAlipay"),
                                                   headers: [:]), needProbes: false)
        await waitUntil { self.saves.count == 1 }
        await quietWindow(0.3)
        XCTAssertEqual(saves.count, 1, "恰一次")
        let form = try PayoutVisualData.form("alipay")
        let body = try XCTUnwrap(saves.first?.json as? [String: String])
        XCTAssertEqual(body, ["payout_method": "alipay", "alipay_logon_id": try XCTUnwrap(form["alipayAccount"]),
                              "payee_name": try XCTUnwrap(form["payeeName"])], "请求体一字不改")
        XCTAssertNotNil(saves.first?.header("Idempotency-Key"), "带幂等键")
        XCTAssertEqual(saves.first?.header("X-Step-Up-Token"), "t", "带 step-up")
        XCTAssertEqual(host.payout?.state.form, PayoutForm(), "成功后清空表单与内存里的完整输入")
    }

    /// W75 / G-W23：银行卡请求体仍带 card_no / bank_name。
    func testSaveBankKeepsBankName() async throws {
        let (host, _) = try await openPayout(needProbes: false)
        let saved = try PayoutVisualData.payoutBody("boundBank")
        host.server.script.on("PUT /v1/me/payout-account", .envelope(code: 0, data: saved, headers: [:]))
        host.grantStepUp()
        try fillBank(host)
        host.payoutActions?.save()
        await waitUntil { self.saves.count == 1 }
        let form = try PayoutVisualData.form("bank")
        let body = try XCTUnwrap(saves.first?.json as? [String: String])
        XCTAssertEqual(body, ["payout_method": "bank_card", "card_no": try XCTUnwrap(form["cardNo"]),
                              "bank_name": try XCTUnwrap(form["bankName"]),
                              "payee_name": try XCTUnwrap(form["payeeName"])])
    }

    /// 换方式、输入零写；本地校验失败零写；空表单不发。
    func testChoosingAndTypingWriteNothing() async throws {
        let (host, _) = try await openPayout(needProbes: false)
        host.payoutActions?.method(WalletJSON.bankCard)
        host.payoutActions?.method(WalletJSON.alipay)
        try fillAlipay(host)
        host.payoutActions?.payee("")
        host.payoutActions?.save()
        await quietWindow(0.3)
        XCTAssertEqual(writes, [], "零写")
        XCTAssertEqual(host.payout?.state.localErrors, ["payee_name"], "本地校验只报空字段")
    }

    /// 【更换收款账号】只开表单，零写、不重读。
    func testChangeOnlyOpensForm() async throws {
        let (host, _) = try await openPayout("boundAlipay", needProbes: false)
        let reads = WalletStubProtocol.requests("GET", "/v1/me/payout-account").count
        host.payoutActions?.change()
        await quietWindow(0.3)
        XCTAssertEqual(host.payout?.state.editing, true)
        XCTAssertEqual(writes, [], "零写")
        XCTAssertEqual(WalletStubProtocol.requests("GET", "/v1/me/payout-account").count, reads, "不重读")
    }

    /// G-W21：null 次数不置灰的执行层前提（字段缺失解析成 nil），0 解析成 0；服务端 30303 兜底不变。
    func testG21RemainingParsedAsIs() async throws {
        let (exhausted, _) = try await openPayout("boundExhausted", needProbes: false)
        XCTAssertEqual(exhausted.payout?.state.account?.changeRemaining, 0)
        let (bound, _) = try await openPayout("boundAlipay", needProbes: false)
        XCTAssertEqual(bound.payout?.state.account?.changeRemaining, 2)
    }

    /// G-W13 / W79 / W81：错误分类全部不变、留在本页、保留输入、按钮恢复。
    func testSaveErrorClassificationUnchanged() async throws {
        let cases = [("changeLimit", "error.30303.payout_account_change_limit"),
                     ("verifyLimit", "error.30303.payout_account_verify_limit"),
                     ("payeeMismatch", "error.30307"), ("accountTaken", "error.30308"), ("busy", "error.40901")]
        for (name, key) in cases {
            let error = try PayoutVisualData.saveError(name)
            let host = try await openAndSave(.envelope(code: error.code, data: error.data, headers: [:]),
                                             needProbes: false)
            await waitUntil("\(name) 没有结果") { host.flow?.state.error != nil }
            XCTAssertEqual(host.flow?.state.error?.key, key, name)
            XCTAssertNil(host.flow?.state.fieldErrorKey, "\(name)：不是字段错误")
            XCTAssertEqual(saves.count, 1, name)
            XCTAssertEqual(host.flow?.state.canSubmit, true, "\(name)：按钮恢复")
            XCTAssertEqual(host.fixture.router.path.last?.route, WalletRoutes.payoutAccount, "\(name)：留在本页")
            XCTAssertFalse(host.payout?.state.form.payeeName.isEmpty ?? true, "\(name)：保留输入")
        }
    }

    /// 44001：动作不变，【知道了】零写，申诉恰一次出口，弹窗关闭。
    func testRiskDialogActions() async throws {
        let host = try await openAndSave(.envelope(code: 44001, data: "null", headers: [:]), needProbes: false)
        await waitUntil { host.flow?.state.riskDialog != nil }
        host.flowActions?.dismissRisk()
        await waitUntil { host.flow?.state.riskDialog == nil }
        XCTAssertEqual(saves.count, 1, "【知道了】零写")
    }

    /// 换号后旧回调零写入（共性第 4、52、59、63 条：回调捕获渲染时身份）。
    func testStaleCallbacksAfterAccountSwitch() async throws {
        let (host, _) = try await openPayout(needProbes: false)
        try fillAlipay(host)
        let stale = try XCTUnwrap(host.payoutActions)
        host.grantStepUp()
        try host.fixture.switchAccount(to: "user-b")
        await settle()
        stale.save()
        stale.logon("13900000000")
        stale.method(WalletJSON.bankCard)
        await quietWindow(0.4)
        XCTAssertEqual(saves.count, 0, "旧回调零写入")
        XCTAssertNotEqual(host.payout?.state.form.alipayLogonId, "13900000000", "旧回调不写新表单")
    }

    // MARK: - 实名

    /// 打开同意半屏不发请求；默认不勾；未勾选【同意并继续】零调用。
    func testConsentNeverSubmitsWithoutCheck() async throws {
        let (host, _) = try await openRealName(needProbes: false)
        _ = try await openConsent(host, needProbes: false)
        XCTAssertEqual(host.realName?.state.consentChecked, false, "默认不勾选")
        host.realNameActions?.agree()
        await quietWindow(0.2)
        XCTAssertEqual(realBackend?.calls.count, 0, "未勾选零提交")
        host.realNameActions?.toggleConsent()
        await quietWindow(0.2)
        XCTAssertEqual(realBackend?.calls.count, 0, "勾选本身零提交")
    }

    /// 勾选 + 同意恰一次；身份证小写 x 规整成 X；连点不重发；成功出栈一次、清空。
    func testAgreeSubmitsOnceNormalized() async throws {
        let (host, _) = try await openRealName(needProbes: false)
        _ = try await openConsent(host, needProbes: false)
        let depth = host.fixture.router.path.count
        host.realNameActions?.toggleConsent()
        let agree = try XCTUnwrap(host.realNameActions).agree
        agree()
        agree()
        await waitUntil("提交没有发出") { self.realBackend?.calls.count == 1 }
        await quietWindow(0.4)
        XCTAssertEqual(realBackend?.calls.count, 1, "恰一次")
        let form = try PayoutVisualData.realnameForm()
        XCTAssertEqual(realBackend?.calls.first?.name, form.name)
        XCTAssertEqual(realBackend?.calls.first?.idNo, form.idNo.uppercased(), "规整后的身份证号")
        XCTAssertEqual(realBackend?.calls.first?.key.isEmpty, false, "带幂等键")
        await waitUntil("成功后出栈") { host.fixture.router.path.count == depth - 1 }
    }

    /// 【暂不认证】零提交、内容保留、再开仍不勾。
    func testDeclineWritesNothingKeepsInput() async throws {
        let (host, _) = try await openRealName(needProbes: false)
        _ = try await openConsent(host, needProbes: false)
        host.realNameActions?.toggleConsent()
        host.realNameActions?.decline()
        await quietWindow(0.2)
        XCTAssertEqual(realBackend?.calls.count, 0)
        XCTAssertNil(host.realName?.state.consentId)
        XCTAssertFalse(host.realName?.state.name.isEmpty ?? true, "内容保留")
        _ = try await openConsent(host, needProbes: false)
        XCTAssertEqual(host.realName?.state.consentChecked, false, "再开不勾选")
    }

    /// 旧半屏实例的回调不作用于新实例（渲染时票据）。
    func testStaleConsentCallbacksIgnored() async throws {
        let (host, _) = try await openRealName(needProbes: false)
        _ = try await openConsent(host, needProbes: false)
        let stale = try XCTUnwrap(host.realNameActions)
        host.realNameActions?.decline()
        _ = try await openConsent(host, needProbes: false)
        stale.toggleConsent()
        stale.agree()
        await quietWindow(0.3)
        XCTAssertEqual(host.realName?.state.consentChecked, false)
        XCTAssertEqual(realBackend?.calls.count, 0)
    }

    /// 20001 data.fields：两字段各自关联，不在错误条重复。
    func testFieldErrorsMapToFields() async throws {
        let (host, _) = try await openRealName(needProbes: false)
        let error = try PayoutVisualData.realnameError("fields")
        realBackend?.fail(error.code, data: error.data)
        _ = try await openConsent(host, needProbes: false)
        await agree(host)
        XCTAssertEqual(host.realName?.state.fieldErrors, ["name", "id_no"])
        XCTAssertNil(host.realName?.state.error, "不重复播报")
    }

    /// Release 形态：没有后端时不可提交、零调用（G-W24）。
    func testReleaseShapeNeverSubmits() async throws {
        let (host, _) = try await openRealName(backend: false, needProbes: false)
        XCTAssertEqual(host.realName?.available, false)
        XCTAssertEqual(host.realName?.submitEnabled, false)
        host.realNameActions?.submit()
        XCTAssertNil(host.realName?.state.consentId)
    }

    // MARK: - 劳务

    /// 勾选零请求；未勾选签署零调用；签署恰一次，版本与 sha256 是服务端原值；连点不重发；成功出栈；读取只 1 次。
    func testSignOnceWithServerValues() async throws {
        let (host, _) = try await openLabor(needProbes: false)
        let depth = host.fixture.router.path.count
        host.laborActions?.sign()
        await quietWindow(0.2)
        XCTAssertEqual(laborBackend?.signs.count, 0, "未勾选零签署")
        XCTAssertEqual(host.laborPage?.state.checked, false, "默认不勾选")
        host.laborActions?.toggle()
        await quietWindow(0.2)
        XCTAssertEqual(laborBackend?.signs.count, 0, "勾选零请求")
        let sign = try XCTUnwrap(host.laborActions).sign
        sign()
        sign()
        await waitUntil("签署没有发出") { self.laborBackend?.signs.count == 1 }
        let first = try PayoutVisualData.laborFirst()
        XCTAssertEqual(laborBackend?.signs.first?.version, first["version"] as? String)
        XCTAssertEqual(laborBackend?.signs.first?.sha, first["text_sha256"] as? String, "sha256 原样回传")
        await waitUntil("成功后出栈") { host.fixture.router.path.count == depth - 1 }
        XCTAssertEqual(laborBackend?.signs.count, 1, "恰一次")
        XCTAssertEqual(laborBackend?.readCount, 1, "读取只 1 次")
    }

    /// 签署失败留在本页，可再签恰一次；换号后旧回调零签署。
    func testSignFailureAndStaleCallback() async throws {
        let (host, _) = try await openLabor(needProbes: false)
        laborBackend?.failSign(50301)
        host.laborActions?.toggle()
        host.laborActions?.sign()
        await waitUntil { host.laborPage?.state.error != nil }
        XCTAssertEqual(laborBackend?.signs.count, 1)
        XCTAssertEqual(host.laborPage?.state.signing, false)
        let stale = try XCTUnwrap(host.laborActions)
        try host.fixture.switchAccount(to: "user-b")
        await settle()
        stale.sign()
        await quietWindow(0.4)
        XCTAssertEqual(laborBackend?.signs.count, 1, "旧回调零签署")
    }
}
