@testable import Couli
import CouliNetwork
import Foundation
import Router
import Wallet
@testable import WalletCore
import XCTest

/// FU-IOS-0712 重理后补修三（RV-01、RV-02）：确认 / 放弃从发起到结果采用全程持有操作锁；确认的二次验证续发先补共享结算。
final class FollowupIos0712FixRework3Tests: WalletFlowTestCase {
    /// RV-01：真实恢复出的待确认页（新执行器，reuseKey 为 nil），【确认上一笔】在途时本机记录已被结束、待确认记录同步先读到 none，
    /// 结果回调随后才到且只有页面采用那次读取失败。页面不清待确认、不推进版本、不解除锁；恢复后按原结果落地，不新增写请求。
    func testRestoredPendingConfirmKeepsOperationLockWhenRecordVanishesFirst() async throws {
        let fixture = make()
        let first = try await withdraw(fixture)
        try await enterPending(first)
        fixture.router.path.removeLast()
        let controller = try await withdraw(fixture)
        await waitUntil("恢复页没有显示待确认") { controller.flow.state.pending != nil }
        XCTAssertNil(controller.flow.reuseKey, "前提：恢复页没有本进程的原键")
        let key = try XCTUnwrap(controller.flow.state.pending?.key)
        script.on("POST /v1/withdrawals", .hold)
        flowActions(controller.flow).confirm()
        await waitUntil("确认没有挂住") { WalletStubProtocol.heldIds.count == 1 }
        let version = controller.flow.state.pendingVersion
        // 网络层已结束这条记录、主线程回调还没到：待确认记录同步先读到 none
        try fixture.pendingBackend.delete(account: "user-a", key: key)
        controller.flow.refreshPending()
        await settle()
        let locked = controller.flow.state
        XCTAssertNotNil(locked.pending, "操作锁期间记录消失不清待确认")
        XCTAssertEqual(locked.pendingVersion, version, "不推进本笔版本")
        XCTAssertFalse(locked.canSubmit, "提交仍锁住")
        let posted = posts.count
        let held = try XCTUnwrap(WalletStubProtocol.heldIds.first)
        // 结果回调：共享结算核对（第 1 次）成功，页面采用核对（第 2 次）失败
        fixture.store.failRead(nth: 2)
        WalletStubProtocol.release(
            held, with: .envelope(code: 0, data: WalletSamples.withdrawal("W-confirm"), headers: [:])
        )
        await waitUntil("确认结果没有到达") { controller.flow.state.awaitingIdentity }
        actions(controller).submit()
        await settle()
        XCTAssertEqual(posts.count, posted, "等待期间不新增写请求")
        flowActions(controller.flow).recheck()
        await waitUntil("恢复后没有按原结果落地") {
            fixture.router.path.last?.route == WalletRoutes.withdrawRecords
        }
        await settle()
        XCTAssertEqual(posts.count, posted, "恢复后不新增写请求")
    }

    // D10-3641：原 testConfirmStepUpReplaySettlesSharedResultFirst 前置由提现挪到改收款
    /// RV-02：【确认上一笔】得到 10003，只有共享结算那次读取失败（结果留在会话级服务）；页面照常打开二次验证。验证成功后的续发
    /// 之前没有任何外部 checkSession：续发先请 App 核对、补完共享结算再发。
    func testConfirmStepUpReplaySettlesSharedResultFirstOnPayout() async throws {
        let fixture = make()
        let controller = try await enterPayoutPending(fixture)
        script.on("PUT /v1/me/payout-account", .hold)
        flowActions(controller.flow).confirm()
        await waitUntil("确认没有挂住") { WalletStubProtocol.heldIds.count == 1 }
        let held = try XCTUnwrap(WalletStubProtocol.heldIds.first)
        // 10003 回来后网络层自己先读一次会话（第 1 次），共享结算核对是第 2 次——只让它失败
        fixture.store.failRead(nth: 2)
        WalletStubProtocol.release(held, with: .envelope(code: 10003, data: "null", headers: [:]))
        await waitUntil("10003 没有被共享结算保留") { fixture.wallet.deps.settlement.hasHeld }
        script.on("PUT /v1/me/payout-account", .envelope(
            code: 0, data: WalletSamples.alipay, headers: [:]
        ))
        let posted = saves.count
        try await passStepUp(controller.flow.stepUp)
        await waitUntil("续发后没有落地（保存成功、面板收起）") { self.payoutLanded(controller) }
        let kept = fixture.wallet.deps.settlement.hasHeld
        XCTAssertFalse(kept, "续发前先补完共享结算")
        XCTAssertEqual(saves.count, posted + 1, "续发一次")
    }

    // MARK: - 改收款辅助（D10-3641）

    /// 改收款落地（对应提现的「进 withdrawRecords」）：保存成功、停在本页的「收款账号已保存」轻提示已出，面板收起。
    private func payoutLanded(_ controller: PayoutAccountController) -> Bool {
        controller.state.toast?.key == "payout.saved" && controller.flow.stepUp.state == nil
    }

    /// 打开收款账号页（未绑定直接是表单），填支付宝并【保存】；PUT 断连进待确认。
    private func enterPayoutPending(_ fixture: WalletAppFixture) async throws -> PayoutAccountController {
        script.ok("GET /v1/me/payout-account", "{}")
        script.on("PUT /v1/me/payout-account", .disconnect)
        let controller = try await payout(fixture)
        let render = { PayoutActions.make(controller, controller.state, risk: controller.flow.state.riskDialog?.id) }
        render().logon("zhangsan@example.com")
        render().payee("测试三")
        render().save()
        await waitUntil("没有进入待确认") { controller.flow.state.pending != nil && controller.flow.state.phase == .pending }
        return controller
    }
}
