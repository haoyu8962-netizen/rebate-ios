@testable import Couli
import CouliNetwork
import Foundation
import Router
import Wallet
import WalletCore
import XCTest

/// D10-1002 前提：生产默认换成真实实名后端之后，原 `testReleaseShapeNeverSubmits` / `testReleaseShapeIdentityPagesSendNothing`
/// 保的「Release 形态不会误提交资金动作」仍要成立——生产接线（不调 installBackends：实名为契约实现、劳务协议后端 nil）下，走完实名页
/// （底版：暂未开放；实现：同意 + 提交成功），再进提现：rules 要求先签劳务协议（block_code 10004）时点【提交】、去签署页点【同意并签署】，
/// 都不发任何提现 / 收款账号 / 劳务签署 / 二次验证 / 作废请求；实名成功也不重放提现。底版与实现都应绿；去掉提现提交门槛
/// （WithdrawController.submit 的 display.submitEnabled / serverBlocked 判断）、实名成功后重放提现、劳务 nil 时仍签署的变异应红。
final class RealnameFundsNoFundWriteTests: RealnameFundsTestCase {
    /// 资金类写请求（含其前置：二次验证发码 / 验证、未决键作废）。
    private static func isFundWrite(_ request: WalletStubProtocol.Recorded) -> Bool {
        switch (request.method, request.path) {
        case ("POST", "/v1/withdrawals"), ("PUT", "/v1/me/payout-account"), ("POST", "/v1/idempotency-keys/abandon"),
             ("POST", "/v1/auth/step-up"), ("POST", "/v1/auth/sms-codes"):
            true
        default:
            request.path.hasPrefix("/v1/me/labor-agreement") && request.method != "GET"
        }
    }

    func testRealRealnameWithoutLaborBackendSendsNoFundWrite() async throws {
        scriptUnverifiedThenVerified()
        script.ok("GET /v1/withdrawals/rules", WalletSamples.rules(can: false, block: 10004))
        let fixture = make()
        // 实名页：底版不可提交（什么都不发），实现发同意 + 实名提交并成功出栈；两种都不得带出资金写
        let page = try await openFromWithdraw(fixture)
        fill(page)
        submitWithConsent(page)
        await quietWindow(1.5)
        XCTAssertFalse(WalletStubProtocol.requests.contains(where: Self.isFundWrite), "实名提交带出了资金写（重放提现？）")
        // 提现：rules 要求先签劳务协议 → 点【提交】不发
        fixture.router.path.removeAll()
        let form = try await withdraw(fixture)
        await typeAmount(form, "5")
        actions(form).submit()
        await settle()
        XCTAssertNil(form.flow.state.pending, "被挡时不进待确认")
        // 劳务协议后端未就绪：签署页「暂未提供」，点签署不发
        XCTAssertEqual(form.state.guide.route, WalletRoutes.laborAgreement)
        actions(form).guide()
        await waitUntil("劳务协议页没有打开") { fixture.router.path.last?.route == WalletRoutes.laborAgreement }
        let labor = try XCTUnwrap(fixture.page(WalletRoutes.laborAgreement)?.controller as? LaborAgreementController)
        labor.load()
        XCTAssertEqual(labor.state.phase, .unavailable, "劳务协议后端未就绪")
        LaborActions.make(labor, labor.state).sign()
        await quietWindow(1.0)
        let writes = WalletStubProtocol.requests.filter(Self.isFundWrite).map { "\($0.method) \($0.path)" }
        XCTAssertEqual(writes, [], "资金动作被误提交")
    }
}
