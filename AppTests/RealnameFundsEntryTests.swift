@testable import Couli
import CouliNetwork
import Foundation
import Wallet
import WalletCore
import XCTest

/// 提现页入口从「去实名」到可进（staging 联调 P2）：未实名进提现被送进实名页；实名成功后复查 GET /v1/me、清掉已填内容、出栈回发起页
/// （不重放），再点【提现】直接进提现页并取 rules。
final class RealnameFundsEntryTests: RealnameFundsTestCase {
    func testWithdrawReachableAfterRealname() async throws {
        scriptUnverifiedThenVerified()
        let fixture = make()
        let page = try await submitOnce(fixture)
        await waitUntil("实名成功后没有出栈") { fixture.router.path.last?.route == WalletRoutes.wallet }
        await waitUntil("实名成功后本会话没有按已实名") { fixture.wallet.realnameVerified() }
        let post = try XCTUnwrap(realnamePosts.first)
        XCTAssertTrue(meGets.contains { $0.id > post.id }, "成功后复查 GET /v1/me（契约）")
        XCTAssertTrue(page.state.name.isEmpty, "成功后清掉姓名")
        XCTAssertTrue(page.state.idNo.isEmpty, "成功后清掉身份证号")
        XCTAssertTrue(posts.isEmpty, "不重放提现")
        fixture.wallet.open(WalletRoutes.withdraw, params: [:], from: fixture.router.path.last?.id)
        await waitUntil("实名后进不了提现页") { fixture.router.path.last?.route == WalletRoutes.withdraw }
        let entry = try XCTUnwrap(fixture.page(WalletRoutes.withdraw))
        let withdraw = try XCTUnwrap(entry.controller as? WithdrawController)
        withdraw.start()
        await waitUntil("提现页没有取 rules") {
            !WalletStubProtocol.requests("GET", "/v1/withdrawals/rules").isEmpty
        }
        XCTAssertEqual(realnamePosts.count, 1)
    }

    /// 提交成功（data.realname_status 恒为 verified）而复查 GET /v1/me 失败：本会话仍按已实名放行，不让用户再实名一次
    /// （与鸿蒙 RealNameController.verified 的 markVerified 一致）。
    func testSuccessCountsEvenIfRefreshFails() async throws {
        script.on("GET /v1/me", .envelope(code: 0, data: Self.unverifiedMe, headers: [:]),
                  .envelope(code: 50001, data: "null", headers: [:]))
        let fixture = make()
        _ = try await submitOnce(fixture)
        await waitUntil("复查失败后本会话没有按已实名") { fixture.wallet.realnameVerified() }
        fixture.router.path.removeAll()
        _ = try XCTUnwrap(fixture.open(WalletRoutes.wallet))
        fixture.wallet.open(WalletRoutes.withdraw, params: [:], from: fixture.router.path.last?.id)
        await waitUntil("复查失败后进不了提现页") { fixture.router.path.last?.route == WalletRoutes.withdraw }
        XCTAssertEqual(realnamePosts.count, 1, "不要求再实名")
    }

    /// 失败（30406）不当成已实名：停在实名页，保留已填内容便于更正（只在内存），再进提现仍先实名。
    func testFailureKeepsWithdrawBlocked() async throws {
        scriptAlwaysUnverified()
        script.fail("POST \(Self.path)", 30406)
        let fixture = make()
        let page = try await submitOnce(fixture)
        XCTAssertFalse(fixture.wallet.realnameVerified())
        XCTAssertEqual(fixture.router.path.last?.route, WalletRoutes.realName, "失败停在本页")
        XCTAssertFalse(page.state.idNo.isEmpty, "失败保留已填内容便于更正")
        XCTAssertTrue(WalletStubProtocol.requests("GET", "/v1/withdrawals/rules").isEmpty, "没进提现")
    }
}
