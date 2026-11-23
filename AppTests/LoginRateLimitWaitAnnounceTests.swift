@testable import Couli
import Foundation
@testable import Login
import XCTest

/// FU-LOGIN-RATE-LIMIT-WAIT-ios（D10-2767 ①）读屏播报，ViewModel 层：生产 LoginViewModel + 同一个假时钟 LoginService。
/// 页面据 `announcementCount` 的变化发系统播报（LoginView.onChange），这里直接看计数与文字：
/// - 同一号码限流期内逐秒不播；走完恰好播一次「可以重新获取验证码」（bind_phone.can_resend）；
/// - 换号先清零：换走后旧号走完、再换回来都不播。
@MainActor
final class LoginRateLimitWaitAnnounceTests: MeTestCase {
    private static let phoneA = "13800005678"
    private static let phoneB = "13900001234"

    /// 同意协议后对 A 号点【获取验证码】，等到 42901（Retry-After 600）落定。
    private func limitedModel(_ rig: LoginRateLimitWaitRig) async -> LoginViewModel {
        let model = LoginViewModel(config: rig.config())
        model.setPhone(Self.phoneA)
        model.toggleAgreement()
        model.requestCode()
        await waitUntil("前提：A 号 42901 没有落定") { model.sendRateLimited && !model.sending }
        XCTAssertEqual(requests("POST", "/v1/auth/sms-codes").count, 1, "前提：发出一次发码")
        XCTAssertEqual(model.resendCountdown, 600, "前提：按 Retry-After 600 秒")
        return model
    }

    /// 走完播报恰好一次（计数 +1、文字「可以重新获取验证码」）；限流期内（含 ≤ 60 秒的逐秒倒计时）不播。
    func testLimitEndAnnouncedExactlyOnce() async {
        script.on("POST /v1/auth/sms-codes", rateLimitWaitReply(retryAfter: 600))
        let rig = LoginRateLimitWaitRig(make(account: nil))
        XCTAssertEqual(rig.canResendText, "可以重新获取验证码", "前提：播报文案")
        let model = await limitedModel(rig)
        let before = model.announcementCount

        rig.advance(540)
        await quietWindow(1.3)
        XCTAssertEqual(model.resendCountdown, 60, "前提：计时已刷新到剩 60 秒")
        XCTAssertEqual(model.announcementCount, before, "剩余 > 60 → 60 秒：不播")
        rig.advance(1)
        await quietWindow(1.3)
        rig.advance(1)
        await quietWindow(1.3)
        XCTAssertEqual(model.resendCountdown, 58, "前提：逐秒刷新")
        XCTAssertEqual(model.announcementCount, before, "逐秒倒计时期间不播")

        rig.advance(58)
        await waitUntil("限流走完要播报一次", timeout: 3) { model.announcementCount == before + 1 }
        XCTAssertFalse(model.sendRateLimited)
        XCTAssertEqual(model.announcement, rig.canResendText, "播「可以重新获取验证码」")
        await quietWindow(2.2)
        XCTAssertEqual(model.announcementCount, before + 1, "只播一次（计时停后不再播）")
        model.noteLimitEnd()
        XCTAssertEqual(model.announcementCount, before + 1, "走完之后再算一拍也不重播")
    }

    /// 换号：换到未限流号码立刻不在限流期；换走期间旧号走完、再换回来，都不播。
    func testSwitchingPhoneDoesNotAnnounce() async {
        script.on("POST /v1/auth/sms-codes", rateLimitWaitReply(retryAfter: 600))
        let rig = LoginRateLimitWaitRig(make(account: nil))
        let model = await limitedModel(rig)
        let before = model.announcementCount

        model.setPhone(Self.phoneB)
        XCTAssertFalse(model.sendRateLimited, "换到 B 号：不在限流期")
        XCTAssertEqual(model.resendCountdown, 0)
        model.noteLimitEnd()
        XCTAssertEqual(model.announcementCount, before, "换号不算走完，不播")

        model.setPhone(Self.phoneA)
        XCTAssertTrue(model.sendRateLimited, "换回 A 号：仍在限流期")
        model.setPhone(Self.phoneB)
        rig.advance(601)
        model.noteLimitEnd()
        await quietWindow(1.5)
        XCTAssertEqual(model.announcementCount, before, "换走期间 A 号走完：不播")

        model.setPhone(Self.phoneA)
        XCTAssertFalse(model.sendRateLimited, "A 号已过期")
        model.noteLimitEnd()
        await quietWindow(1.3)
        XCTAssertEqual(model.announcementCount, before, "换回已走完的 A 号：不补播")
        XCTAssertEqual(requests("POST", "/v1/auth/sms-codes").count, 1, "换号不发码")
    }
}
