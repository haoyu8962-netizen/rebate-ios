@testable import Couli
import CouliNetwork
import Foundation
import Wallet
@testable import WalletCore
import XCTest

/// LOCK-ios 段 3（D10-1720 ④、D10-1682 ②、D10-1667）：视觉夹具里的 Me.phone_bound 接线（`panelOnPayout` 的
/// `phoneBound`，经 `AppWallet.phoneBound` → `stepUpPhoneBound`）。noPhone 只给已知没绑手机的改收款（以及换号 / 注销）面板。
/// D10-3641（D10-3639 C）：提现 10003 不再开面板，原「提现面板在 phone_bound=false 时照常发码」改断新行为——phone_bound=false 下提现
/// 【提交】得 10003 不开面板、不发码、本键结束回编辑态并提示 error.10003。同一个夹具开关先证明能让改收款进 noPhone，提现那条才不是空过。
@MainActor
final class LockIosStepUpVisualPhoneBoundTests: StepUpVisualTestCase {
    /// 对照：phone_bound=false 的改收款面板进 noPhone、零发码（夹具开关确实生效）。
    func testPayoutPanelEntersNoPhoneWhenUnbound() async throws {
        try await panelOnPayout(phoneBound: false)
        await waitUntil("改收款面板没有落定") { self.stepUp?.state?.phase == .noPhone }
        XCTAssertEqual(smsSends.count, 0, "改收款没绑手机：不发码")
    }

    // D10-3641：原 testWithdrawPanelStillSendsWhenUnbound 改断新行为（提现 10003 不开面板）
    /// phone_bound=false 时提现【提交】得 10003：不开面板（不进 noPhone、也不进就绪）、零发码；提现只发 1 次（不重放）；回编辑态、提示
    /// error.10003（stepUpExhausted 终态）。
    func testWithdrawUnbound10003OpensNoPanel() async throws {
        let (host, _) = try await openWithdraw(amount: "10", estimate: "estimated", needProbes: false)
        host.wallet.clock = { Self.frozenMillis }
        host.wallet.phoneBound = { _ in false } // modify_existing ruling D10-1720 ④
        host.server.script.on("POST /v1/withdrawals", Self.need)
        let flow = try XCTUnwrap(host.flow, "提现页执行器不在")
        host.actions?.submit()
        await waitUntil("提现 10003 没有结算") { flow.state.error != nil }
        await quietWindow(0.5)
        XCTAssertNil(flow.stepUp.state, "提现不开面板")
        XCTAssertNil(host.window?.rootViewController?.presentedViewController, "没有半屏弹出")
        XCTAssertEqual(smsSends.count, 0, "提现不发码")
        XCTAssertEqual(verifies.count, 0, "提现不验证")
        XCTAssertEqual(submits.count, 1, "提现只发 1 次（不重放）")
        XCTAssertEqual(flow.state.phase, .editing, "回编辑态")
        XCTAssertEqual(flow.state.error?.key, "error.10003", "提示 error.10003")
        XCTAssertNil(flow.state.pending, "不进待确认")
    }
}
