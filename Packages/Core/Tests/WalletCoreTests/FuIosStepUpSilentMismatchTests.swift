import CouliNetwork
import Foundation
import OrderCore
@testable import WalletCore
import XCTest

/// FU-IOS-STEPUP-SILENT-MISMATCH（D10-1722 / D10-1720 / D10-1785）：二次验证面板身份仍是当前会话时，发码以「本地拒绝、一条没发」结束
/// （account_mismatch、session_unreadable）不得静默——落到面板的发送失败态（`StepUpController.sendFailedKey`、sendFailed）、停在可输入、
/// 不起倒计时、【重新获取】可点。复用 `StepUpPanelFixture`（替身环境身份恒为当前，替身 API 按脚本回答）。
/// - 修复前红：`testAccountMismatchOnSendWithCurrentIdentityShowsSendFailure`（修复前 `WalletErrors.of` 把 account_mismatch 归为
///   .cancelled，`StepUpController.failure` 返回 nil，面板无错误、说明位仍是「已发送」）；
/// - 对照（应绿）：session_unreadable 按发送失败提示；共用分类器对 account_mismatch 仍静默（读取类页面不因本单改变）；
///   提现 / 改收款【提交】【保存】路径（`SensitiveFlow.localRejected`）对 account_mismatch 维持原处理。
/// 说明位（「验证码已发送至你绑定的手机号」）由 `StepUpSheet` 按 `StepUpUiState.sendFailed` 决定显示与否；包内无法渲染，这里钉
/// sendFailed，渲染在 App 层用例里看（AppTests/FuIosStepUpSilentMismatchWiringTests）。
/// 身份核对不过（stale）的用例见 FuIosStepUpSilentMismatchStaleSlotTests.swift。
@MainActor
final class FuIosStepUpSilentMismatchTests: XCTestCase {
    static let payout = PayoutAccountController.action
    static let withdraw = WithdrawController.action
    static let alipay = ["payout_method": "alipay", "alipay_logon_id": "zhangsan@example.com"]
    static let withdrawBody = "{\"amount_cents\":1000}"
    static let payoutBody = "{\"payout_method\":\"alipay\",\"alipay_logon_id\":\"zhangsan@example.com\","
        + "\"payee_name\":\"测试三\"}"

    private var fixtures: [StepUpPanelFixture] = []

    override func tearDown() async throws {
        for fixture in fixtures {
            fixture.close()
        }
        fixtures = []
        try await super.tearDown()
    }

    private func make() -> StepUpPanelFixture {
        let fixture = StepUpPanelFixture()
        fixture.env.phone = "13800005678"
        fixture.env.bound = true
        fixtures.append(fixture)
        return fixture
    }

    private func open(_ fixture: StepUpPanelFixture, _ action: String) {
        fixture.open(action, summary: action == Self.payout ? Self.alipay : nil)
    }

    /// 第一次发码按 `reason` 本地拒绝（一条没发），之后的发码成功。
    private func scriptReject(_ fixture: StepUpPanelFixture, _ reason: String) {
        fixture.api.on(StepUpController.sendOperation, .localReject(reason: reason), StepUpPanelApi.smsOk)
    }

    /// 本地拒绝落定后的面板：不被收起、停在可输入、发送失败态（sendFailed + 发送失败文案键）、不起倒计时、共享截止时间不写、
    /// 【重新获取】可点；点【重新获取】照常再发 1 次、清掉 sendFailed 并起倒计时。
    private func assertSendFailedThenResend(
        _ fixture: StepUpPanelFixture, _ action: String, _ label: String,
        file: StaticString = #filePath, line: UInt = #line
    ) async throws {
        await fixture.landed(file: file, line: line)
        // 倒计时由 `countdown` 的任务下一拍写入：落定后在一段时间内持续看「不起倒计时」
        await stepUpHolds("\(label)：没发出：不起倒计时", file: file, line: line) {
            fixture.panel.state?.resendLeftSec == 0 && fixture.panel.state?.phase == .ready
        }
        XCTAssertEqual(fixture.smsCalls.count, 1, "\(label)：前提：打开即调用发码入口 1 次", file: file, line: line)
        XCTAssertTrue(fixture.env.isCurrent(fixture.env.owner), "\(label)：前提：面板身份仍是当前会话", file: file, line: line)
        let state = try XCTUnwrap(fixture.panel.state, "\(label)：面板身份仍有效，不得收起", file: file, line: line)
        XCTAssertFalse(state.awaitingIdentity, "\(label)：身份是当前，不进等身份", file: file, line: line)
        XCTAssertEqual(state.phase, .ready, "\(label)：停在可输入（可重新获取）", file: file, line: line)
        XCTAssertEqual(state.error?.key, StepUpController.sendFailedKey,
                       "\(label)：一条没发不得静默，提示发送失败", file: file, line: line)
        XCTAssertTrue(state.sendFailed, "\(label)：发送失败态（说明位不显示「已发送」）", file: file, line: line)
        XCTAssertEqual(state.resendLeftSec, 0, "\(label)：没发出：不起倒计时", file: file, line: line)
        let slot = SmsDeadlines.Slot(account: "user-a", phone: "13800005678", action: action)
        XCTAssertEqual(fixture.deps.sms.remaining(slot, now: fixture.env.now), 0, "\(label)：没发出：共享截止时间不写",
                       file: file, line: line)

        fixture.panel.resend(instance: state.instance)
        await fixture.landed(file: file, line: line)
        XCTAssertEqual(fixture.smsCalls.count, 2, "\(label)：【重新获取】可点，照常再发 1 次", file: file, line: line)
        XCTAssertEqual(fixture.panel.state?.phase, .ready, file: file, line: line)
        XCTAssertNil(fixture.panel.state?.error, "\(label)：重新发出后清掉错误", file: file, line: line)
        XCTAssertEqual(fixture.panel.state?.sendFailed, false, "\(label)：重新发出后清掉 sendFailed（说明位恢复「已发送」）",
                       file: file, line: line)
        XCTAssertEqual(fixture.panel.state?.resendLeftSec, 60, "\(label)：发出后起倒计时", file: file, line: line)
    }

    // MARK: - 修复前红

    /// 面板身份仍有效，发码本地 account_mismatch（会话读得到同一账号却没有可用 access：optional 没带上固定账号的令牌）：
    /// 不静默，提示发送失败、停在可输入、无倒计时；【重新获取】照常发出。提现、改收款两个 action 同口径。
    /// 修复前红在 error 断言：`WalletErrors.of` 把 account_mismatch 归为 .cancelled，`StepUpController.failure` 对 .cancelled
    /// 返回 nil，`onSent` 置 ready、error=nil；修复后 `onSent` 对 `unsentRejects` 走 `sendFailed()`。
    func testAccountMismatchOnSendWithCurrentIdentityShowsSendFailure() async throws {
        for action in [Self.withdraw, Self.payout] {
            let fixture = make()
            scriptReject(fixture, LocalRejectReason.accountMismatch)
            open(fixture, action)
            try await assertSendFailedThenResend(fixture, action, "\(action) account_mismatch")
            fixture.close()
        }
    }

    // MARK: - 对照（应绿）

    /// 对照：发码本地 session_unreadable（会话读不出）同样落到发送失败态（`unsentRejects`）；本单不得改坏。
    func testSessionUnreadableOnSendShowsSendFailure() async throws {
        for action in [Self.withdraw, Self.payout] {
            let fixture = make()
            scriptReject(fixture, LocalRejectReason.sessionUnreadable)
            open(fixture, action)
            try await assertSendFailedThenResend(fixture, action, "\(action) session_unreadable")
            fixture.close()
        }
    }

    /// 对照：共用分类器 `WalletErrors.of` 对 account_mismatch 仍静默（钱包摘要、收款账号读取、提现页收款行、记录等读取路径都经它，
    /// 任务书「不改其它场景对 account_mismatch 的静默处理」）；修复只能落在面板发码这一处。
    func testSharedClassifierKeepsAccountMismatchSilent() {
        let fixture = make()
        let mismatch = ApiResult.localReject(reason: LocalRejectReason.accountMismatch)
        XCTAssertEqual(WalletErrors.of(mismatch).kind, .cancelled)
        XCTAssertEqual(WalletErrors.of(mismatch).textKey, "")
        XCTAssertEqual(WalletErrors.of(mismatch, probe: fixture.deps.gates.sms.probe()).kind, .cancelled)
    }

    /// 对照：提现【提交】、改收款【保存】本身被本地 account_mismatch 拒（表单身份仍有效）维持现状——`SensitiveFlow.localRejected`
    /// （SensitiveFlow.swift:336-348）回编辑态、键结束、提示网络错误；不开面板、不发码。本单不改这条路径。
    func testSubmitLocalAccountMismatchKeepsExistingHandling() async {
        for withdraw in [true, false] {
            let fixture = make()
            let operation = withdraw ? WithdrawController.operation : PayoutAccountController.operation
            let action = withdraw ? WithdrawController.action : PayoutAccountController.action
            let outcomeOp = withdraw ? SensitiveOutcome.withdraw : SensitiveOutcome.payoutAccount
            let gate = withdraw ? fixture.deps.gates.withdraw : fixture.deps.gates.payout
            let body = withdraw ? Self.withdrawBody : Self.payoutBody
            let flow = SensitiveFlow(
                deps: fixture.deps, operationId: operation, action: action, outcomeOp: outcomeOp, gate: gate,
                marksWalletDirty: false, alive: { true }, owner: fixture.env.owner,
                stepUpSummary: { StepUpSummary.payoutChange(body: $0) }
            )
            fixture.api.on(operation, .localReject(reason: LocalRejectReason.accountMismatch))
            flow.submit(body: body, summary: "{}", owner: fixture.env.owner)
            for _ in 0..<3 {
                await flow.stepUp.whenIdle()
                await flow.whenIdle()
                await Task.yield()
            }
            XCTAssertEqual(fixture.api.calls(operation).count, 1, "\(action)：前提：提交入口调用 1 次")
            XCTAssertEqual(flow.state.phase, .editing, "\(action)：回编辑态（现状）")
            XCTAssertNil(flow.reuseKey, "\(action)：键结束不用（现状）")
            XCTAssertEqual(flow.state.error?.key, WalletErrors.networkKey, "\(action)：提示网络错误（现状，不因本单改变）")
            XCTAssertNil(flow.stepUp.state, "\(action)：不开二次验证面板")
            XCTAssertTrue(fixture.smsCalls.isEmpty, "\(action)：不发码")
        }
    }

    /// D10-1792 ③a：打开调用 send() 那一刻身份就是 stale（同账号旧世代）→ 不读绑定状态、不占槽位、零发送，落到发送失败态；
    /// 【重新获取】前置（可输入、无倒计时、无禁用期）都满足，只差身份（身份恢复后的重新获取见 `FuIosStepUpStaleSlotTests`）。
    func testStaleAtOpenFallsToSendFailedWithoutSendingOrHoldingSlot() async throws {
        let fixture = make()
        let stale = staleSlotOwner(generation: 0)
        fixture.panel.open(action: Self.withdraw, owner: stale, onToken: { _ in }, onClosed: {})
        await fixture.idle()
        // 发码任务若被起了会在下一拍交给 API、倒计时任务下一拍写入：在一段时间内持续看「零发送、不起倒计时」
        await stepUpHolds("打开即 stale：零发送、不起倒计时") {
            fixture.smsCalls.isEmpty && fixture.panel.state?.resendLeftSec == 0
        }
        try assertStaleSendFailed(fixture.panel, "打开即 stale")
        XCTAssertFalse(fixture.deps.gates.sms.active, "【重新获取】不被禁用期挡")
        XCTAssertTrue(fixture.smsCalls.isEmpty, "发码请求零发送")
        XCTAssertTrue(fixture.env.boundQueries.isEmpty, "不读绑定状态")
        XCTAssertFalse(fixture.deps.sms.busy(staleSlot), "槽位不被占用")
        XCTAssertEqual(fixture.deps.sms.remaining(staleSlot, now: fixture.env.now), 0, "不写共享截止时间")
    }
}
