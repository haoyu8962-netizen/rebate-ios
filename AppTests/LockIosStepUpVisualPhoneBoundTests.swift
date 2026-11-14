@testable import Couli
import CouliNetwork
import Foundation
import Wallet
@testable import WalletCore
import XCTest

/// LOCK-ios 段 3（D10-1720 ④、D10-1682 ②、D10-1667）：视觉夹具里的 Me.phone_bound 接线（`panelOnWithdraw` / `panelOnPayout` 的
/// `phoneBound`，经 `AppWallet.phoneBound` → `stepUpPhoneBound`）。noPhone 只给已知没绑手机的改收款（以及换号 / 注销）面板；提现面板在
/// phone_bound=false 时照常发码（不进 noPhone，交给服务端判）。同一个夹具开关先证明能让改收款进 noPhone，提现那条才不是空过。
@MainActor
final class LockIosStepUpVisualPhoneBoundTests: StepUpVisualTestCase {
    /// 对照：phone_bound=false 的改收款面板进 noPhone、零发码（夹具开关确实生效）。
    func testPayoutPanelEntersNoPhoneWhenUnbound() async throws {
        try await panelOnPayout(phoneBound: false)
        await waitUntil("改收款面板没有落定") { self.stepUp?.state?.phase == .noPhone }
        XCTAssertEqual(smsSends.count, 0, "改收款没绑手机：不发码")
    }

    /// 提现面板在 phone_bound=false 时照常发码：不进 noPhone，发码 1 次（action=withdraw、不带 phone），起倒计时。
    func testWithdrawPanelStillSendsWhenUnbound() async throws {
        try await panelOnWithdraw(phoneBound: false)
        await waitUntil("提现面板没有起倒计时") {
            guard let state = self.stepUp?.state else { return false }
            return state.phase == .ready && state.resendLeftSec > 0
        }
        await quietWindow(0.3)
        XCTAssertNotEqual(stepUp?.state?.phase, .noPhone, "提现不按 phone_bound 本地拦")
        XCTAssertEqual(smsSends.count, 1, "提现照常发码 1 次")
        XCTAssertEqual(smsSends.first?.json["action"] as? String, WithdrawController.action)
        XCTAssertNil(smsSends.first?.json["phone"], "发码体不带 phone")
    }
}
