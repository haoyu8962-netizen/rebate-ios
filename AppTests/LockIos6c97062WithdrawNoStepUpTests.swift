@testable import Couli
import CouliNetwork
import Foundation
import Generated
import Wallet
@testable import WalletCore
import XCTest

/// FU-IOS-CONTRACT-LOCK-6c97062（B1-02zzzc #385，D10-2903 ① 甲）：提现不再要求二次验证，App 层经真实 ApiClient（脚本假服务）钉：
/// - 契约前提：createWithdrawal 没有 x-step-up、x-error-codes 没有 10003（服务端不再回 10003，「提现 → 10003 → 面板」场景已不存在；
///   脚本假服务仍能按旧场景回 10003，那批用例随 FU-IOS-WITHDRAW-STEPUP-PANEL-CLEANUP 退役），但仍是敏感操作、放弃 action = withdraw；
/// - 提现请求不带 X-Step-Up-Token：带头仍按 stepUp（ApiClient+Prepare callHeaders），缓存里残留旧提现令牌时提交、【确认上一笔】都不带；
/// - 【确认上一笔】/【放弃上一笔】对提现照常可用（网络层入口改挂 sensitiveOperation / abandonAction 后不得在本地被拒）。
/// 现状（锁 d47f660、未实现）：契约前提那条编译红（sensitiveOperation / abandonAction 是新生成符号）；带头两条断言红（旧锁 stepUp = withdraw，
/// 缓存令牌会被带上）。
@MainActor
final class LockIos6c97062WithdrawNoStepUpTests: WalletFlowTestCase {
    static let staleToken = "t-stale-withdraw"

    var verifies: [WalletStubProtocol.Recorded] {
        WalletStubProtocol.requests("POST", "/v1/auth/step-up")
    }

    var abandons: [WalletStubProtocol.Recorded] {
        WalletStubProtocol.requests("POST", "/v1/idempotency-keys/abandon")
    }

    /// 契约前提（生成物）：提现 stepUp 为 nil、错误码表没有 10003，仍有 20903；sensitiveOperation = true、abandonAction = withdraw。
    func testContractWithdrawalIsSensitiveWithoutStepUp() throws {
        let operation = try XCTUnwrap(ApiOperations.byId("createWithdrawal"))
        XCTAssertNil(operation.stepUp, "提现不再要求二次验证")
        XCTAssertFalse(operation.errorCodes.contains(10003), "提现没有 10003")
        XCTAssertTrue(operation.errorCodes.contains(20903), "仍是敏感操作：作废后同键回 20903")
        XCTAssertTrue(operation.sensitiveOperation)
        XCTAssertEqual(operation.abandonAction, "withdraw")
    }

    /// 结果未知 → 待确认；缓存里残留旧提现令牌 →【确认上一笔】原键原体只重发一次，不带 X-Step-Up-Token，不验证、不出面板，落地提现记录。
    func testConfirmPendingWithStaleTokenSendsNoStepUpHeader() async throws {
        let fixture = make()
        let controller = try await withdraw(fixture)
        try await enterPending(controller)
        fixture.wallet.deps.tokens.put(
            action: "withdraw", account: "user-a", token: Self.staleToken, expireAtMs: .max
        )
        script.ok("POST /v1/withdrawals", WalletSamples.withdrawal("W-confirm"))
        flowActions(controller.flow).confirm()
        await waitUntil("没有进提现记录") { fixture.router.path.last?.route == WalletRoutes.withdrawRecords }
        await settle()
        XCTAssertEqual(posts.count, 2, "断连 1 + 确认 1")
        XCTAssertEqual(posts[0].header("Idempotency-Key"), posts[1].header("Idempotency-Key"), "原键")
        XCTAssertEqual(posts[0].body, posts[1].body, "原体")
        XCTAssertNil(posts[0].header("X-Step-Up-Token"))
        XCTAssertNil(posts[1].header("X-Step-Up-Token"), "缓存里有旧提现令牌也不带（带头仍按 stepUp）")
        XCTAssertTrue(verifies.isEmpty, "不验证")
        XCTAssertNil(controller.flow.stepUp.state, "不出面板")
    }

    /// 首次提交时缓存里已有旧提现令牌：只发一次，不带 X-Step-Up-Token（与 LockIosStepUpSummaryWiringTests.testWithdrawCachedTokenIsNotSent
    /// 同一事实，这里另钉「令牌不进请求体」与键在）。
    func testSubmitWithStaleTokenSendsNoStepUpHeader() async throws {
        let fixture = make()
        let controller = try await withdraw(fixture)
        fixture.wallet.deps.tokens.put(
            action: "withdraw", account: "user-a", token: Self.staleToken, expireAtMs: .max
        )
        await typeAmount(controller, "10")
        actions(controller).submit()
        await waitUntil("没有进提现记录") { fixture.router.path.last?.route == WalletRoutes.withdrawRecords }
        await settle()
        XCTAssertEqual(posts.count, 1, "只发一次")
        let post = try XCTUnwrap(posts.first)
        XCTAssertNotNil(post.header("Idempotency-Key"))
        XCTAssertNil(post.header("X-Step-Up-Token"), "缓存里有旧提现令牌也不带")
        XCTAssertNil(post.json["step_up_token"], "token 不进请求体")
        XCTAssertFalse(post.body.contains(Self.staleToken), "请求体里也没有令牌")
        XCTAssertTrue(verifies.isEmpty)
    }

    /// 结果未知 →【放弃上一笔】二次确认后作废：作废体 action = withdraw（取生成的 abandonAction）、键 = 原键，不带 Idempotency-Key；
    /// 得到 abandoned 后键结束、恢复【提交】。
    func testAbandonPendingUsesWithdrawAction() async throws {
        let fixture = make()
        let controller = try await withdraw(fixture)
        try await enterPending(controller)
        script.ok("POST /v1/idempotency-keys/abandon", "{\"outcome\":\"abandoned\",\"original\":null}")
        flowActions(controller.flow).askAbandon()
        XCTAssertNotNil(controller.flow.state.abandonConfirmKey, "先弹二次确认")
        flowActions(controller.flow).abandon()
        await waitUntil("放弃没有结算") { controller.flow.state.pending == nil }
        XCTAssertEqual(abandons.count, 1)
        let abandon = try XCTUnwrap(abandons.first)
        XCTAssertNil(abandon.header("Idempotency-Key"))
        XCTAssertEqual(abandon.json["action"] as? String, "withdraw")
        XCTAssertEqual(abandon.json["idempotency_key"] as? String, posts.first?.header("Idempotency-Key"))
        XCTAssertTrue(controller.flow.state.canSubmit, "键结束：恢复【提交】")
        XCTAssertEqual(controller.flow.state.toast?.key, "pending_confirm.abandoned", "作废成功（不是本地拒绝）")
    }
}
