import CouliNetwork
import Foundation
@testable import WalletCore
import XCTest

/// LOCK-ios 段 3（D10-1720）：`SensitiveFlow+Apply.swift` openStepUp 开头的 guard——改收款推不出摘要时不开二次验证面板、不发码。
/// 这里补首次提交分支（phase == submit）：生产里首次提交用的是本次保存的请求体，`StepUpSummary.payoutChange` 总推得出，
/// 走不到这条分支，所以直接构造一个改收款的 SensitiveFlow（action = PayoutAccountController.action、`stepUpSummary` 恒为 nil），
/// 复用 `StepUpPanelFixture` 的替身环境、替身 API 与真实 WalletDeps。
/// 期望与用户关闭面板同口径收尾：回到编辑态、本次键结束不用（reuseKey = nil，下次用新键）、错误条提示稍后再试。
@MainActor
final class LockIosStepUpSubmitNoSummaryTests: XCTestCase {
    private var fixtures: [StepUpPanelFixture] = []

    override func tearDown() async throws {
        for fixture in fixtures {
            fixture.close()
        }
        fixtures = []
        try await super.tearDown()
    }

    private func need10003() -> ApiResult {
        .failure(
            code: 10003, msg: "", data: nil, traceId: nil, effect: ErrorEffect(code: 10003, kind: .stepUp),
            idempotencyKey: nil
        )
    }

    /// 改收款流程，摘要推导恒为 nil；保存（savePayoutAccount）一律回 10003。
    private func makeFlow() -> (StepUpPanelFixture, SensitiveFlow) {
        let fixture = StepUpPanelFixture()
        fixture.env.phone = "13800005678"
        fixture.env.bound = true
        fixtures.append(fixture)
        let flow = SensitiveFlow(
            deps: fixture.deps, operationId: PayoutAccountController.operation,
            action: PayoutAccountController.action, outcomeOp: SensitiveOutcome.payoutAccount,
            gate: fixture.deps.gates.payout, marksWalletDirty: false, alive: { true }, owner: fixture.env.owner,
            stepUpSummary: { _ in nil }
        )
        fixture.api.on(PayoutAccountController.operation, need10003())
        return (fixture, flow)
    }

    private func idle(_ flow: SensitiveFlow) async {
        for _ in 0..<3 {
            await flow.stepUp.whenIdle()
            await flow.whenIdle()
            await Task.yield()
        }
    }

    private func save(_ fixture: StepUpPanelFixture, _ flow: SensitiveFlow) async {
        let body = "{\"payout_method\":\"alipay\",\"payee_name\":\"测试三\"}"
        flow.submit(body: body, summary: "{\"method\":\"alipay\"}", owner: fixture.env.owner)
        await idle(flow)
    }

    /// 首次提交得到 10003、推不出摘要：phase 回到 editing、reuseKey 为 nil、错误条为稍后再试；不开面板、不发码、不验证。
    /// 删掉 guard 首次提交分支里的 `state.phase = .editing`：submit 已把 phase 置为 submitting，guard 直接 return，phase 停在
    /// submitting，第一条断言变红。删掉 `reuseKey = nil`：10003 的结局 newKey 为 false，apply 不清键，reuseKey 仍是本次的键，
    /// reuseKey 断言变红，再次保存也会沿用原键（最后一条断言同样变红）。
    func testPayoutSubmitWithoutDerivableSummaryEndsKeyAndShowsRetryLater() async {
        let (fixture, flow) = makeFlow()
        await save(fixture, flow)

        let saves = fixture.api.calls(PayoutAccountController.operation)
        XCTAssertEqual(saves.count, 1, "前提：保存发出 1 次（得到 10003）")
        XCTAssertNotNil(saves.first?.idempotencyKey, "前提：保存带了幂等键")
        XCTAssertEqual(flow.state.phase, .editing, "推不出摘要：回到编辑态")
        XCTAssertNil(flow.reuseKey, "推不出摘要：本次键结束不用，下次用新键")
        XCTAssertEqual(flow.state.error?.key, SensitiveOutcome.retryLaterKey, "错误条提示稍后再试")
        XCTAssertNil(flow.state.pendingNotice, "首次提交不写待确认卡提示")
        XCTAssertNil(flow.stepUp.state, "不打开二次验证面板")
        XCTAssertNil(flow.stepUpIntent, "没有面板意图")
        XCTAssertTrue(fixture.smsCalls.isEmpty, "不发 sendSmsCode")
        XCTAssertTrue(fixture.verifyCalls.isEmpty, "不发 stepUp")
        XCTAssertTrue(flow.state.canSubmit, "提交入口恢复可用")

        // 再保存一次：键已结束，用新键（不是原键重放）
        await save(fixture, flow)
        let again = fixture.api.calls(PayoutAccountController.operation)
        XCTAssertEqual(again.count, 2, "再次保存发出")
        XCTAssertNotEqual(again[0].idempotencyKey, again[1].idempotencyKey, "再次保存用新键")
        XCTAssertTrue(fixture.smsCalls.isEmpty, "再次保存仍不发码")
        XCTAssertNil(flow.stepUp.state, "再次保存仍不开面板")
    }
}
