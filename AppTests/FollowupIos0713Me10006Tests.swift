@testable import Couli
import CouliNetwork
import Foundation
import Me
@testable import MeCore
import Router
import XCTest

/// FU-IOS-0713 必测 3 补（编排裁定 ⑤）：因 10006 进入风险说明时，getMe 响应到达而身份持续暂时未知 → 无内容的可重试结算态里
/// 「返回」可见（接口约定 `RiskNoticeController.showsBack`，页面导航栏按它显示）、【联系客服】【退出登录】可点；恢复后正常（按服务端
/// 版式：banned 没有返回，客服 / 退出照常）。全部经生产入口：网络层 10006 统一落点 → Router 打开 → `MePageEntry.appeared`
/// → 渲染时的 `RiskNoticeActions`。
final class FollowupIos0713Me10006Tests: MeTestCase {
    static let banned = MeSamples.me(risk: "banned", reason: "account_security")

    /// 任一请求 10006 → 落到风险说明（栈里只留它，记「因 10006 进入」）；getMe 挂住后在身份持续未知时放行，等页面结算。
    private func enteredBy10006UnknownSettled(_ fixture: MeAppFixture) async throws -> RiskNoticeController {
        script.fail("GET /v1/wallet/summary", 10006)
        script.on("GET /v1/me", .hold, .envelope(code: 0, data: Self.banned, headers: [:]))
        fixture.router.open(RouteRequest(route: "OrderList", from: .inApp))
        _ = await fixture.client.send(ApiCall(operationId: "getWalletSummary"))
        await waitUntil("没有落到风险说明") { fixture.router.path.map(\.route) == [AppMe.riskNotice] }
        let entry = try XCTUnwrap(fixture.me.entry(for: try XCTUnwrap(fixture.router.path.last)))
        let controller = try XCTUnwrap(entry.controller() as? RiskNoticeController)
        XCTAssertTrue(controller.enteredBy10006, "前提：因 10006 进入")
        entry.appeared()
        await waitUntil("getMe 没有挂住") { WalletStubProtocol.heldIds.count == 1 }
        let held = try XCTUnwrap(WalletStubProtocol.heldIds.first)
        fixture.store.failReads(fromNth: 1)
        WalletStubProtocol.release(held, with: .envelope(code: 0, data: Self.banned, headers: [:]))
        await waitUntil("身份未知时响应回来后停在加载中（无出口）") { controller.state.phase != .loading }
        return controller
    }

    /// 身份持续未知期间：可重试结算态，「返回」可见，【联系客服】打开客服半屏，【退出登录】确认后结束本地会话（故障保持到会话结束）。
    func testEnteredBy10006UnknownSettledStateHasBackCsAndLogout() async throws {
        let fixture = make()
        let controller = try await enteredBy10006UnknownSettled(fixture)
        XCTAssertNil(controller.state.risk, "前提：没有采用身份未知时的响应")
        XCTAssertEqual(controller.state.phase, .error, "无内容：可重试的结算态")
        XCTAssertTrue(controller.showsBack, "身份未知期间「返回」可见")
        XCTAssertEqual(fixture.router.path.map(\.route), [AppMe.riskNotice], "前提：返回之前仍在风险说明")
        RiskNoticeActions.make(controller, controller.state).contactCs()
        await waitUntil("身份未知期间【联系客服】没有打开客服") { fixture.me.cs.sheet != nil }
        RiskNoticeActions.make(controller, controller.state).askLogout()
        let dialog = try XCTUnwrap(controller.state.logoutDialog, "身份未知期间【退出登录】可点（弹确认框）")
        RiskNoticeActions.make(controller, controller.state).confirmLogout(dialog)
        // 故障一直保持到本地会话结束（完成信号：未包装的令牌存储读到「没有会话」），之后才撤掉
        await waitUntil("身份持续未知时确认退出，本地会话没有结束") { (try? fixture.tokens.readSession()) == nil }
        fixture.store.disarm()
    }

    /// 恢复后正常：Keychain 恢复后一次身份同步 → 显示服务端 banned 版式（没有返回，与 `model.showBack` 一致），仍记「因 10006 进入」，
    /// 【联系客服】照常。
    func testEnteredBy10006UnknownThenRecoveredShowsNormalLayout() async throws {
        let fixture = make()
        let controller = try await enteredBy10006UnknownSettled(fixture)
        XCTAssertTrue(controller.showsBack, "前提：未知期间「返回」可见")
        fixture.store.disarm()
        fixture.me.syncIdentity()
        await waitUntil("恢复后没有显示说明") { controller.state.phase == .content }
        let model = try XCTUnwrap(controller.model())
        XCTAssertTrue(RiskLayout.isBanned(model.layoutRaw), "按服务端版式（\(model.layoutRaw)）")
        XCTAssertEqual(controller.showsBack, model.showBack, "恢复后按版式决定返回")
        XCTAssertFalse(controller.showsBack, "banned 没有返回")
        XCTAssertTrue(fixture.me.enteredBy10006(fixture.me.currentIdentity), "仍记因 10006 进入")
        RiskNoticeActions.make(controller, controller.state).contactCs()
        await waitUntil("恢复后【联系客服】没有打开客服") { fixture.me.cs.sheet != nil }
    }
}
