@testable import Couli
import CouliNetwork
import DesignSystem
import SwiftUI
import UIKit
import Wallet
@testable import WalletCore
import XCTest

/// 测试 v2：实现变异 F2、F5、F7、F8、F10 只被字面守卫杀死或存活，这里补显示层 / 系统层的行为断言。都挂真实半屏。
/// 各探针自身的有效性在 `StepUpVisualOracleTests`（testGestureDismissJudge、testReturnProbeFiresOnSubmit、
/// testEscapeProbeReachesSwiftUIAction）。
extension StepUpVisualMoneyTests {
    /// F7：验证中输入框真的不可编辑（控制器层会丢弃改码，这条看显示层）；答复回来恢复。先正后反。
    func testInputFieldLockedWhileVerifying() async throws {
        let host = try await panelOnWithdraw()
        host.server.script.on("POST /v1/auth/step-up", .hold)
        await waitUntil("半屏里没有输入框") { self.sheetField() != nil }
        XCTAssertEqual(sheetField()?.isEnabled, true, "先正：就绪时可输入")
        try enterCode("123456")
        try panelActions().verify()
        await waitUntil { self.stepUp?.state?.phase == .verifying && !WalletStubProtocol.heldIds.isEmpty }
        await waitUntil("验证中输入框要锁定") { self.sheetField()?.isEnabled == false }
        let held = try XCTUnwrap(WalletStubProtocol.heldIds.first)
        WalletStubProtocol.release(held, with: Self.wrongCode)
        await waitUntil("错码回来后输入框要恢复") { self.sheetField()?.isEnabled == true }
    }

    /// F7：取不到号码时输入框同样不可编辑。
    func testInputFieldLockedWithoutPhone() async throws {
        try await panelOnWithdraw(phone: false)
        await waitUntil("半屏里没有输入框") { self.sheetField() != nil }
        await waitUntil("noPhone 输入框要锁定") { self.sheetField()?.isEnabled == false }
    }

    /// F2：系统手势收起的闸门是关的（下滑、点遮罩走同一闸门，两宿主）。UI 真手势杀不死 F2：面板一打开就聚焦弹键盘，键盘在时真点遮罩、
    /// 真拖把手都不收起，而半屏打开期间 UI 测试没有收键盘的办法（交回 v2 §3）。
    func testGestureDismissLockedByUIKit() async throws {
        for payout in [false, true] {
            let host: WithdrawVisualHost = if payout {
                try await panelOnPayout()
            } else {
                try await panelOnWithdraw()
            }
            await quietWindow(0.8)
            let presented = try XCTUnwrap(host.window?.rootViewController?.presentedViewController)
            XCTAssertFalse(gestureDismissAllowed(presented), "payout=\(payout)：系统手势不能收起")
            XCTAssertNotNil(stepUp?.state, "payout=\(payout)")
        }
    }

    /// F8：对真实输入框按回车（输满时）零验证、面板不动。
    func testReturnNeverVerifies() async throws {
        try await panelOnWithdraw()
        await waitUntil("半屏里没有输入框") { self.sheetField() != nil }
        try enterCode("123456")
        await settle()
        pressReturn(try XCTUnwrap(sheetField()))
        await quietWindow(0.8)
        XCTAssertEqual(verifies.count, 0, "回车零验证")
        XCTAssertEqual(stepUp?.state?.phase, .ready)
        XCTAssertEqual(stepUp?.state?.code, "123456")
    }

    /// F10：读屏焦点在验证码框时做擦除，走关闭出口：面板收起、零验证、零重放。
    func testEscapeClosesThroughExit() async throws {
        try enableAccessibilityTree()
        let host = try await panelOnWithdraw()
        try enterCode("123456")
        await quietWindow(0.8)
        let root = try XCTUnwrap(host.window?.rootViewController?.presentedViewController?.view)
        let code = try XCTUnwrap(accessibilityNode("stepUp.code", under: root), "无障碍树里没有 stepUp.code")
        XCTAssertTrue(performEscape(from: code), "擦除要有人接住")
        await waitUntil("擦除没有关闭面板") { self.stepUp?.state == nil }
        await quietWindow(0.4)
        XCTAssertEqual(verifies.count, 0, "擦除零验证")
        XCTAssertEqual(submits.count, 1, "擦除零重放")
    }

    /// F5：发码限流（42901）期间【重新获取】画成不可用，回调也不发码；限流外同一状态是可用色（先正后反）。
    func testResendDisabledWhileSmsRateLimited() async throws {
        let (_, normal) = try await openSheet(sms: Self.serverDown, waitFor: "stepUp.resend.label")
        let label = try rect("stepUp.resend.label")
        XCTAssertTrue(inkMostly(normal, in: label, CouliColor.textLink, not: CouliColor.textSecondary), "先正：可用色")
        let limited = WalletStubProtocol.Reply.envelope(code: 42901, data: "null", headers: ["Retry-After": "120"])
        let (_, image) = try await openSheet(sms: limited, waitFor: "stepUp.resend.label")
        let blocked = try rect("stepUp.resend.label")
        XCTAssertTrue(inkMostly(image, in: blocked, CouliColor.textSecondary, not: CouliColor.textLink), "限流置灰")
        try panelActions().resend()
        await quietWindow(0.4)
        XCTAssertEqual(smsSends.count, 1, "限流期不发码")
    }
}
