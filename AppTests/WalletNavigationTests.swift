@testable import Couli
import CouliNetwork
import Foundation
import Generated
import Router
import Wallet
import WalletCore
import XCTest

/// 路由参数丢弃（AC-S1-81 ⑫）、实名前置查询（共性第 9、21、31、57 条）、二次验证面板身份与共享发码倒计时（共性第 6、17、60 条）、钱包失效
/// 通知的归属（共性第 61 条）。
final class WalletNavigationTests: WalletFlowTestCase {
    /// 带参数打开四个资金与实名页：Router 丢弃全部参数照常打开，页面无预填；记 route_params_dropped（只有路由名与个数）。
    func testFundRoutesDropParamsAndTrack() async throws {
        let fixture = make()
        await verifyRealname(fixture)
        let routes = [
            WalletRoutes.withdraw,
            WalletRoutes.payoutAccount,
            WalletRoutes.laborAgreement,
            WalletRoutes.realName,
        ]
        for route in routes {
            fixture.router.open(RouteRequest(
                route: route, values: ["amount_fen": .number(500), "payee_name": .string("fixture")], from: .inApp
            ))
            let top = try XCTUnwrap(fixture.router.path.last)
            XCTAssertEqual(top.route, route)
            XCTAssertEqual(top.params, [:], "\(route) 丢弃全部参数")
            fixture.router.path.removeAll()
        }
        let events = fixture.tracked.events.filter { $0.name == "route_params_dropped" }
        XCTAssertEqual(events.map(\.fields["route"]), routes.map { .string($0) })
        XCTAssertTrue(events.allSatisfy { $0.fields["dropped_count"] == .integer(2) })
        XCTAssertTrue(events.allSatisfy { $0.fields.count == 2 }, "只有路由名与个数")
    }

    /// 实名完成：清掉已填内容、刷新 realname_status、出栈回发起页（不重放）。
    func testRealnameSuccessClosesPageAndRefreshesStatus() async throws {
        script.on(
            "GET /v1/me", .envelope(code: 0, data: "{\"realname_status\":\"none\",\"phone_bound\":true}", headers: [:]),
            .envelope(code: 0, data: WalletSamples.me, headers: [:])
        )
        let fixture = make()
        fixture.wallet.installBackends(realname: FixtureRealName(), labor: nil)
        let wallet = try XCTUnwrap(fixture.open(WalletRoutes.wallet))
        fixture.wallet.open(WalletRoutes.withdraw, params: [:], from: fixture.router.path.last?.id)
        await waitUntil { fixture.router.path.last?.route == WalletRoutes.realName }
        let page = try XCTUnwrap(fixture.page(WalletRoutes.realName)?.controller as? RealNameController)
        RealNameActions.make(page, page.state).name("测试三")
        RealNameActions.make(page, page.state).idNo("000000000000000000")
        RealNameActions.make(page, page.state).submit()
        RealNameActions.make(page, page.state).toggleConsent()
        RealNameActions.make(page, page.state).agree()
        await waitUntil("实名完成后没有出栈") { fixture.router.path.last?.route == WalletRoutes.wallet }
        await waitUntil("实名状态没有刷新") { fixture.wallet.realnameVerified() }
        XCTAssertNotNil(wallet.controller)
        XCTAssertTrue(posts.isEmpty, "不重放")
    }

    /// 实名查询读取失败（5xxxx）：显示在发起页（统一文案 + trace6）并可重试，不当成未实名继续导航；42901 写入共享读禁用期。
    func testRealnameQueryFailureShowsOnOriginWithoutNavigation() async throws {
        script.fail("GET /v1/me", 50001)
        let fixture = make()
        let entry = try XCTUnwrap(fixture.open(WalletRoutes.wallet))
        let origin = try XCTUnwrap(fixture.router.path.last?.id)
        fixture.wallet.open(WalletRoutes.withdraw, params: [:], from: origin)
        await waitUntil { entry.context.openError != nil }
        XCTAssertEqual(fixture.router.path.last?.id, origin, "不导航")
        let message = try XCTUnwrap(entry.context.openError?.message(WalletDraftTexts()))
        XCTAssertTrue(message.contains("6789ab"), "带 trace6")
        script.ok("GET /v1/me", WalletSamples.me)
        entry.context.retryOpen()
        await waitUntil("重试成功后打开") { fixture.router.path.last?.route == WalletRoutes.withdraw }
    }

    /// 实名查询在途时发起页被覆盖：导航许可作废（回来也不恢复），只记下结论（共性第 31、57 条）。
    func testRealnameQueryNavigationVoidWhenCovered() async throws {
        script.on("GET /v1/me", .hold)
        let fixture = make()
        _ = try XCTUnwrap(fixture.open(WalletRoutes.wallet))
        let origin = try XCTUnwrap(fixture.router.path.last?.id)
        fixture.wallet.open(WalletRoutes.withdraw, params: [:], from: origin)
        await waitUntil { WalletStubProtocol.heldIds.count == 1 }
        fixture.router.open(RouteRequest(route: WalletRoutes.help, from: .inApp))
        fixture.router.path.removeLast()
        let held = try XCTUnwrap(WalletStubProtocol.heldIds.first)
        WalletStubProtocol.release(held, with: .envelope(code: 0, data: WalletSamples.me, headers: [:]))
        await waitUntil { fixture.wallet.realnameVerified() }
        await settle()
        XCTAssertEqual(fixture.router.path.last?.id, origin, "被覆盖过的点击不再导航")
    }

    /// 二次验证面板沿用打开它的身份（共性第 60 条）：令牌已换后面板上的重新获取、验证零请求；发码倒计时按账号、号码、action 共享，重开面板恢复，
    /// 不重复发码（共性第 6、17 条）。
    func testStepUpPanelIdentityAndSharedSmsDeadline() async throws {
        script.fail("POST /v1/withdrawals", 10003)
        let fixture = make()
        let controller = try await withdraw(fixture)
        await typeAmount(controller, "10")
        actions(controller).submit()
        let stepUp = controller.flow.stepUp
        await waitUntil { stepUp.state?.phase == .ready && (stepUp.state?.resendLeftSec ?? 0) > 0 }
        XCTAssertEqual(WalletStubProtocol.requests("POST", "/v1/auth/sms-codes").count, 1)
        let panel = try XCTUnwrap(stepUp.state)
        StepUpActions.make(stepUp, panel).close()
        actions(controller).submit()
        await waitUntil { stepUp.state?.phase == .ready }
        XCTAssertEqual(WalletStubProtocol.requests("POST", "/v1/auth/sms-codes").count, 1, "倒计时内重开面板不重复发码")
        XCTAssertGreaterThan(stepUp.state?.resendLeftSec ?? 0, 0, "恢复倒计时")
        let reopened = try XCTUnwrap(stepUp.state)
        StepUpActions.make(stepUp, reopened).code("123456")
        try fixture.swapTokensSilently(to: "user-b")
        let filled = try XCTUnwrap(stepUp.state)
        StepUpActions.make(stepUp, filled).verify()
        await settle()
        XCTAssertTrue(WalletStubProtocol.requests("POST", "/v1/auth/step-up").isEmpty, "面板身份不是当前会话：不验证")
    }

    /// 钱包失效通知携带点击时的身份，订阅端只收自己会话的（共性第 53、61 条）。
    func testWalletDirtyOnlyForSameOwner() async throws {
        let fixture = make()
        let wallet = try XCTUnwrap(fixture.open(WalletRoutes.wallet)?.controller as? WalletController)
        wallet.load()
        await waitUntil { wallet.state.summary != nil }
        let count = WalletStubProtocol.requests("GET", "/v1/wallet/summary").count
        fixture.wallet.markWalletDirty(WalletOwner(account: "user-b", key: "user-b#1#0#0", request: nil))
        await settle()
        XCTAssertEqual(WalletStubProtocol.requests("GET", "/v1/wallet/summary").count, count, "别的身份不刷新")
        fixture.wallet.markWalletDirty(wallet.state.owner)
        await waitUntil { WalletStubProtocol.requests("GET", "/v1/wallet/summary").count == count + 1 }
    }
}
