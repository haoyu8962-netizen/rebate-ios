@testable import Couli
import CouliNetwork
import Foundation
import Router
import Wallet
@testable import WalletCore
import XCTest

/// FU-IOS-0712 末轮窄修四（RC-05）：钱包摘要页的「待补取 + 可重试结算 + 身份确认时补取」推广到提现记录、提现、收款账号页。
final class FollowupIos0712FixR3dWalletTests: WalletFlowTestCase {
    /// 提现记录（发送前核对）：未知期间建页 → 恢复时识别成功、换上身份，紧接着加载的身份核对读取失败 → 结算为可重试的失败态并记待补取、
    /// 在途标记结清 → 再次恢复（判据相同）同一页补取并加载出列表。
    func testRecordsLoadAbortedBeforeSendResumesOnNextConfirmation() async throws {
        let fixture = make()
        fixture.router.open(RouteRequest(route: WalletRoutes.withdrawRecords, from: .inApp))
        let top = try XCTUnwrap(fixture.router.path.last)
        XCTAssertEqual(top.route, WalletRoutes.withdrawRecords, "前提：路由已通过守卫")
        fixture.tokens.failReads = .readFailed
        let entry = try XCTUnwrap(fixture.wallet.entry(for: top))
        fixture.tokens.failReads = nil
        let controller = try XCTUnwrap(entry.controller as? WithdrawRecordsController)
        XCTAssertNil(controller.state.owner.account, "前提：建页时身份未知")
        fixture.store.failReads(fromNth: 2)
        _ = fixture.wallet.entry(for: top)
        fixture.store.stopFailing()
        XCTAssertEqual(controller.state.owner.account, "user-a", "前提：已换上身份")
        XCTAssertTrue(controller.loadPending, "记下待补取")
        XCTAssertFalse(controller.firstPagePending, "在途标记已结清")
        XCTAssertEqual(controller.state.phase, .error, "不留无出口的加载态")
        _ = fixture.wallet.entry(for: top)
        XCTAssertTrue(controller.firstPagePending, "判据相同也补取")
        await waitUntil("补取后列表没有到位") { !controller.firstPagePending }
        let phase = controller.state.phase
        let items = controller.state.items.map(\.withdrawalId)
        XCTAssertEqual(phase, .content, "同页能加载")
        XCTAssertEqual(items, ["W1"])
        XCTAssertFalse(controller.loadPending)
    }

    /// 提现记录（响应核对）：第一页回来时身份核对读取失败 → 在途标记结清、结算为可重试的失败态；回前台的刷新不再被拒，同页加载出列表。
    func testRecordsLoadAbortedAtResponseLetsForegroundRefreshLoad() async throws {
        let fixture = make()
        script.on("GET /v1/withdrawals", .hold)
        let entry = try XCTUnwrap(fixture.open(WalletRoutes.withdrawRecords))
        let controller = try XCTUnwrap(entry.controller as? WithdrawRecordsController)
        controller.load()
        await waitUntil("第一页请求没有挂住") { WalletStubProtocol.heldIds.count == 1 }
        let held = try XCTUnwrap(WalletStubProtocol.heldIds.first)
        XCTAssertTrue(controller.firstPagePending, "前提：第一页在途")
        script.on("GET /v1/withdrawals")
        fixture.store.failReads(fromNth: 1)
        WalletStubProtocol.release(held, with: .envelope(
            code: 0, data: "{\"items\":[\(WalletSamples.withdrawal("W0"))],\"next_cursor\":null}", headers: [:]
        ))
        await waitUntil("响应核对没有结算") { !controller.firstPagePending }
        fixture.store.stopFailing()
        let phase = controller.state.phase
        XCTAssertEqual(phase, .error, "响应核对失败：可重试的失败态")
        XCTAssertTrue(controller.loadPending, "记下待补取")
        XCTAssertTrue(controller.state.items.isEmpty, "核对失败的响应不采用")
        // 回前台：页面重新可见即刷新（不再因在途标记被拒）
        fixture.wallet.sceneChanged(active: false)
        fixture.wallet.sceneChanged(active: true)
        XCTAssertTrue(controller.firstPagePending, "回前台的刷新已受理")
        await waitUntil("刷新后列表没有到位") { !controller.firstPagePending }
        let items = controller.state.items.map(\.withdrawalId)
        XCTAssertEqual(controller.state.phase, .content)
        XCTAssertEqual(items, ["W1"], "同页加载出列表")
    }

    /// 提现页：rules 响应回来时身份核对读取失败 → 结算为可重试的失败态并记待补取；身份再次确认（判据相同）时补取，同页加载出页头。
    func testWithdrawRulesAbortedAtResponseResumesOnNextConfirmation() async throws {
        let fixture = make()
        await verifyRealname(fixture)
        script.on("GET /v1/withdrawals/rules", .hold)
        let entry = try XCTUnwrap(fixture.open(WalletRoutes.withdraw), "提现页没有打开")
        let controller = try XCTUnwrap(entry.controller as? WithdrawController)
        controller.start()
        await waitUntil("rules 请求没有挂住") { WalletStubProtocol.heldIds.count == 1 }
        let held = try XCTUnwrap(WalletStubProtocol.heldIds.first)
        script.on("GET /v1/withdrawals/rules")
        fixture.store.failReads(fromNth: 1)
        WalletStubProtocol.release(held, with: .envelope(code: 0, data: WalletSamples.rules(), headers: [:]))
        await waitUntil("rules 响应核对没有结算") { controller.state.phase == .error }
        fixture.store.stopFailing()
        XCTAssertTrue(controller.loadPending, "记下待补取")
        XCTAssertNil(controller.state.rules, "核对失败的响应不采用")
        fixture.wallet.checkSession()
        await waitUntil("补取后页头没有到位") { controller.state.phase == .content }
        let rules = controller.state.rules
        XCTAssertNotNil(rules, "同页加载出页头")
        XCTAssertFalse(controller.loadPending)
    }

    /// 收款账号页：读取发送前身份核对读取失败 → 结算为可重试的失败态并记待补取；身份再次确认（判据相同）时补取，同页加载出账号。
    func testPayoutLoadAbortedBeforeSendResumesOnNextConfirmation() async throws {
        let fixture = make()
        await verifyRealname(fixture)
        script.on("GET /v1/me/payout-account", .hold)
        let entry = try XCTUnwrap(fixture.open(WalletRoutes.payoutAccount), "收款账号页没有打开")
        let controller = try XCTUnwrap(entry.controller as? PayoutAccountController)
        fixture.store.failReads(fromNth: 1)
        controller.load()
        fixture.store.stopFailing()
        XCTAssertTrue(controller.loadPending, "记下待补取")
        XCTAssertEqual(controller.state.phase, .error, "不留无出口的加载态")
        script.on("GET /v1/me/payout-account")
        fixture.wallet.checkSession()
        await waitUntil("补取后账号没有到位") { controller.state.phase != .error && controller.state.account != nil }
        let account = controller.state.account
        XCTAssertNotNil(account, "同页加载出账号")
        XCTAssertFalse(controller.loadPending)
    }
}
