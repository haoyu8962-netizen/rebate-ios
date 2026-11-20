@testable import Couli
import CouliNetwork
import Foundation
import MeCore
import Session
import WalletCore
import XCTest

/// FU-IOS-WALLETSETTLEMENT-SCOPE 写测 (b) 组「新页被禁用」：旧作用域（deletion_only）发出的写 / 发码 / 验证拿到 42901，不得把禁用期带到
/// 作用域变化后重建的新注销页上（任务书 §1 (b)、§2 第 3 条）：
/// - (b1) 42901 在作用域变化（且注销页已重建、resync 已跑过）之后才到 → 不写 `gates.deletion`（「作用域未变才写」）；
/// - (b2) 42901 在作用域变化之前已正当写入 → 作用域换代时 resync 对 `gates.deletion` reset；
/// - (b3) 注销面板的发码 42901 在作用域变化后到 → 不写 `gates.sms`；验证 42901 同理不写 `gates.verify`；
/// - (b3-对照) 作用域没变照写 `gates.sms`；作用域变化之前写入的 `gates.sms` 不被 reset（共享闸门，提现 / 改收款也用）。
///
/// 现状（改前）为什么红：WalletSettlement.applyWrite / settleRetryAfter 只按 WalletOwner 核对（不含作用域），同世代换作用域仍 .current，
/// 照写 gate；resyncDeletionScope 只清 token、重建页面，不动 gates.deletion。
@MainActor
final class FuIosWalletSettlementScopeGateTests: FuIosWalletSettlementScopeTestCase {
    /// 新注销页（重建后）可申请：勾选后【申请注销】可点，并真的写出一次。
    private func assertNewPageApplies(_ rebuilt: DeleteAccountController, writesBefore: Int, _ what: String) async {
        await ready(rebuilt, "\(what) 新页")
        deletionActions(rebuilt).toggleWaiver()
        XCTAssertTrue(rebuilt.applyEnabled, "\(what)：新注销页【申请注销】可点（不被旧作用域的 42901 禁用）")
        deletionActions(rebuilt).apply()
        await waitUntil("\(what)：新页的申请没有写出", timeout: 3) {
            self.sent(Self.deletionWrite).count == writesBefore + 1
        }
        await settle()
        XCTAssertNotEqual(rebuilt.flow.state.error?.key, Self.rateLimitKey, "\(what)：新页不显示 42901")
    }

    // MARK: - (b1) 迟到的旧作用域 42901 不写 gates.deletion

    /// (b1) 受限页首次申请在途，作用域变 full 并重建注销页（resync 已跑），之后旧申请才拿到 42901 → gates.deletion 不 active，新页可申请。
    /// 现状红：applyWrite 按 WalletOwner 核对仍 .current，照写 gates.deletion → 新页【申请注销】禁用到 Retry-After。
    /// 改后绿：注销 ticket 带作用域核对，此刻作用域已变 → 不写 gate（resync 的 reset 在 42901 之前，救不了这一种先后）。
    func testB1Late42901AfterScopeChangeDoesNotDisableNewPage() async throws {
        let fixture = restrictedFixture()
        let host = try await openDeletionPage(fixture)
        let old = host.controller
        script.on(Self.deletionWrite, .hold, Self.coolingReply)
        tapApply(old)
        await waitUntil("申请没有到达假服务") { self.heldId(Self.deletionWrite) != nil }

        try switchScope(fixture, to: SessionScope.full)
        let rebuilt = host.controller
        XCTAssertFalse(rebuilt === old, "前提：作用域变化后注销页按新作用域重建")
        let held = try XCTUnwrap(heldId(Self.deletionWrite))
        WalletStubProtocol.release(held, with: Self.retryAfter(30))
        await quietWindow(0.8)

        XCTAssertFalse(fixture.gates.deletion.active, "(b1) 作用域变化后到达的旧 42901 不写 gates.deletion")
        XCTAssertFalse(fixture.gates.deletion.blocked, "(b1) 注销按钮不置灰")
        await assertNewPageApplies(rebuilt, writesBefore: 1, "(b1)")
    }

    // MARK: - (b2) 作用域换代时 reset gates.deletion

    /// (b2) 先在 deletion_only 下拿 42901（gates.deletion active），随后作用域变 full、注销页重建 → 新页不被禁用。
    /// 现状红：resyncDeletionScope 不动 gates.deletion，禁用期带到新作用域的页面。改后绿：同一分支（作用域变化）reset gates.deletion。
    func testB2ScopeChangeResetsDeletionGateForRebuiltPage() async throws {
        let fixture = restrictedFixture()
        let host = try await openDeletionPage(fixture)
        let old = host.controller
        script.on(Self.deletionWrite, Self.retryAfter(30), Self.coolingReply)
        tapApply(old)
        await waitUntil("前提：受限作用域下的 42901 写入 gates.deletion") { fixture.gates.deletion.active }

        try switchScope(fixture, to: SessionScope.full)
        let rebuilt = host.controller
        XCTAssertFalse(rebuilt === old, "前提：作用域变化后注销页按新作用域重建")

        XCTAssertFalse(fixture.gates.deletion.active, "(b2) 作用域换代：gates.deletion reset")
        XCTAssertFalse(fixture.gates.deletion.blocked, "(b2) 注销按钮不置灰")
        await assertNewPageApplies(rebuilt, writesBefore: 1, "(b2)")
    }

    // MARK: - (b3) 注销面板的发码 / 验证

    /// 受限页申请 → 10003 → 注销的二次验证面板（action = account_deletion）。
    private func openDeletionPanel(_ fixture: WalletAppFixture) async throws -> DeleteAccountController {
        let host = try await openDeletionPage(fixture)
        let controller = host.controller
        script.on(Self.deletionWrite, .envelope(code: 10003, data: "null", headers: [:]), Self.coolingReply)
        tapApply(controller)
        await waitUntil("二次验证面板没有打开") { controller.flow.stepUp.state != nil }
        XCTAssertEqual(controller.flow.stepUp.state?.action, "account_deletion", "前提：注销的二次验证面板")
        return controller
    }

    /// (b3) 注销面板的发码在途，作用域变 full（注销页重建、面板随旧执行器收起；已发出的发码照常结算），之后发码拿到 42901 → gates.sms 不写。
    /// 现状红：settleRetryAfter 按 WalletOwner 核对仍 .current，照写 gates.sms。改后绿：注销面板发码带作用域核对，作用域已变不写。
    func testB3DeletionPanelSms42901AfterScopeChangeDoesNotWriteSmsGate() async throws {
        let fixture = restrictedFixture()
        script.on(Self.smsSend, .hold)
        _ = try await openDeletionPanel(fixture)
        await waitUntil("发码没有到达假服务") { self.heldId(Self.smsSend) != nil }

        try switchScope(fixture, to: SessionScope.full)
        let held = try XCTUnwrap(heldId(Self.smsSend))
        WalletStubProtocol.release(held, with: Self.retryAfter(120))
        await quietWindow(0.8)

        XCTAssertFalse(fixture.gates.sms.active, "(b3) 作用域变化后到达的注销面板发码 42901 不写 gates.sms")
    }

    /// (b3-对照) 作用域没变：注销面板发码的 42901 照写 gates.sms。现状绿、改后仍须绿（防「一律不写」）。
    func testB3ControlDeletionPanelSms42901SameScopeStillWritesSmsGate() async throws {
        let fixture = restrictedFixture()
        script.on(Self.smsSend, .hold)
        _ = try await openDeletionPanel(fixture)
        await waitUntil("发码没有到达假服务") { self.heldId(Self.smsSend) != nil }

        let held = try XCTUnwrap(heldId(Self.smsSend))
        WalletStubProtocol.release(held, with: Self.retryAfter(120))
        await waitUntil("(b3-对照) 作用域没变：发码 42901 没有写入 gates.sms") { fixture.gates.sms.active }
        XCTAssertGreaterThan(fixture.gates.sms.remainingMillis, 100_000, "按 Retry-After 120 秒")
    }

    /// (b3-对照) 作用域变化之前已正当写入的 gates.sms：作用域换代后仍保留（任务书 §2 第 3 条：不 reset 共享的 sms / verify gate，
    /// 提现 / 改收款也用）。现状绿、改后仍须绿（防把 reset 扩到共享闸门）。
    func testB3ControlScopeChangeDoesNotResetSharedSmsGate() async throws {
        let fixture = restrictedFixture()
        script.on(Self.smsSend, Self.retryAfter(120))
        _ = try await openDeletionPanel(fixture)
        await waitUntil("前提：受限作用域下的发码 42901 写入 gates.sms") { fixture.gates.sms.active }

        try switchScope(fixture, to: SessionScope.full)
        await settle()
        XCTAssertTrue(fixture.gates.sms.active, "(b3-对照) 作用域换代不 reset 共享的 gates.sms")
    }

    /// (b3-verify) 注销面板的验证在途，存储里作用域变 full（还没走同步出口：面板仍在，验证请求不被收起作废），之后验证拿到 42901 →
    /// gates.verify 不写。现状红：settleRetryAfter 照写 gates.verify。改后绿：注销面板验证带作用域核对（StepUpController.swift 验证调用点）。
    func testB3VerifyDeletionPanel42901AfterScopeChangeDoesNotWriteVerifyGate() async throws {
        let fixture = restrictedFixture()
        script.on(Self.stepUpVerify, .hold)
        let controller = try await openDeletionPanel(fixture)
        try await passStepUp(controller.flow.stepUp)
        await waitUntil("验证没有到达假服务") { self.heldId(Self.stepUpVerify) != nil }

        try switchScope(fixture, to: SessionScope.full, sync: false)
        XCTAssertNotNil(controller.flow.stepUp.state, "前提：面板仍在（验证请求有效）")
        let held = try XCTUnwrap(heldId(Self.stepUpVerify))
        WalletStubProtocol.release(held, with: Self.retryAfter(60))
        await quietWindow(0.8)

        XCTAssertFalse(fixture.gates.verify.active, "(b3-verify) 作用域变化后到达的注销面板验证 42901 不写 gates.verify")
    }
}
