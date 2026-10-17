@testable import Couli
import CouliNetwork
import Foundation
import Router
import Wallet
@testable import WalletCore
import XCTest

/// F-X-22（资金风险，RW-03 同口径）：写请求成功响应在身份暂时未知时到达——不显示为可重试错误、同一笔不能再提交，身份确认后按原结果
/// 落地；无论经回前台还是本页【重试】恢复，写请求总数都是 1。
final class FollowupIos0712FixReworkMoneyTests: WalletFlowTestCase {
    /// 提现成功遇未知：等待期间无错误、【提交】不可用且点了不发；恢复（回前台 / 本页【重试】）后按成功进提现记录，POST 总数 1。
    func testWithdrawSuccessWhileUnknownNeverResubmits() async throws {
        for viaForeground in [true, false] {
            WalletStubProtocol.reset()
            script.install()
            let fixture = make()
            let controller = try await withdraw(fixture)
            await typeAmount(controller, "10")
            script.on("POST /v1/withdrawals", .hold)
            actions(controller).submit()
            await waitUntil("提交没有挂住") { WalletStubProtocol.heldIds.count == 1 }
            let held = try XCTUnwrap(WalletStubProtocol.heldIds.first)
            fixture.store.failReads(fromNth: 1)
            WalletStubProtocol.release(
                held, with: .envelope(code: 0, data: WalletSamples.withdrawal("W-new"), headers: [:])
            )
            await waitUntil("结果没有到达") { controller.flow.state.awaitingIdentity }
            let waiting = controller.flow.state
            XCTAssertNil(waiting.error, "成功结局不显示为错误")
            XCTAssertFalse(waiting.canSubmit, "同一笔不能再提交")
            actions(controller).submit()
            await settle()
            XCTAssertEqual(posts.count, 1, "等待期间再点不发")
            fixture.store.stopFailing()
            if viaForeground {
                fixture.wallet.sceneChanged(active: false)
                fixture.wallet.sceneChanged(active: true)
            } else {
                flowActions(controller.flow).recheck()
            }
            await waitUntil("恢复后没有按成功落地") {
                fixture.router.path.last?.route == WalletRoutes.withdrawRecords
            }
            await settle()
            XCTAssertEqual(posts.count, 1, "写请求总数 1（\(viaForeground ? "回前台" : "本页重试")）")
            fixture.router.path.removeAll()
        }
    }

    /// 收款账号保存成功遇未知：等待期间无错误、【保存】不可用；回前台恢复后按成功落地，PUT 总数 1。
    func testPayoutSaveSuccessWhileUnknownNeverResaves() async throws {
        script.ok("GET /v1/me/payout-account", "{}")
        let fixture = make()
        let controller = try await payout(fixture)
        fixture.wallet.deps.tokens.put(
            action: PayoutAccountController.action, account: "user-a", token: "t", expireAtMs: Int64.max
        )
        let actions = PayoutActions.make(controller, controller.state, risk: nil)
        actions.logon(" zhangsan@example.com ")
        actions.payee(" 测试三 ")
        script.on("PUT /v1/me/payout-account", .hold)
        PayoutActions.make(controller, controller.state, risk: nil).save()
        await waitUntil("保存没有挂住") { WalletStubProtocol.heldIds.count == 1 }
        let held = try XCTUnwrap(WalletStubProtocol.heldIds.first)
        fixture.store.failReads(fromNth: 1)
        WalletStubProtocol.release(held, with: .envelope(code: 0, data: WalletSamples.alipay, headers: [:]))
        await waitUntil("结果没有到达") { controller.flow.state.awaitingIdentity }
        let waiting = controller.flow.state
        XCTAssertNil(waiting.error, "成功结局不显示为错误")
        XCTAssertFalse(waiting.canSubmit, "不能再保存")
        fixture.store.stopFailing()
        fixture.wallet.sceneChanged(active: false)
        fixture.wallet.sceneChanged(active: true)
        await waitUntil("恢复后没有按成功落地") { !controller.flow.state.awaitingIdentity }
        await settle()
        let landed = controller.flow.state
        XCTAssertNil(landed.error)
        XCTAssertEqual(WalletStubProtocol.requests("PUT", "/v1/me/payout-account").count, 1, "PUT 总数 1")
    }
}
