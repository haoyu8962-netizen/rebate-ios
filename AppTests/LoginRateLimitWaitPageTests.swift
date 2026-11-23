@testable import Couli
import Foundation
@testable import Login
import XCTest

/// FU-LOGIN-RATE-LIMIT-WAIT-ios（D10-2767 ①②③）页面级：生产 LoginView 挂进临时窗口，读无障碍树里
/// `login.getCode`（按钮文字、可用与否）、`login.rateLimitNotice`（常驻提示行）、验证码页 `login.countdown` / `login.resend`。
/// 规则：42901 剩余 > 60 秒显示 error.42901「操作太频繁，请稍后再试」；≤ 60 秒显示 login.code.countdown「{n} 秒后可重新获取」
/// 逐秒递减；走完恢复可用。时间经假时钟推进（Retry-After 600 / 3600 / 86400 不真等），显示由生产 1 秒计时刷新。
@MainActor
final class LoginRateLimitWaitPageTests: LoginRateLimitWaitPageCase {
    /// 前提文案（App 文案表）：几条期望文字确实是这几句，且彼此不同（否则「文字换了」无从判断）。
    private func assertTexts(_ rig: LoginRateLimitWaitRig, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(rig.getCodeText, "获取验证码", file: file, line: line)
        XCTAssertEqual(rig.limitedText, "操作太频繁，请稍后再试", file: file, line: line)
        XCTAssertEqual(rig.countdownText(60), "60 秒后可重新获取", file: file, line: line)
        XCTAssertEqual(rig.resendText, "重新获取", file: file, line: line)
    }

    // MARK: - ① ② 手机号步

    /// 手机号步 42901（Retry-After 600）：【获取验证码】置灰、文字为 error.42901；剩余 61 秒仍是频繁文案；剩 60 秒起换成
    /// 「{n} 秒后可重新获取」逐秒递减；走完恢复「获取验证码」可用。常驻提示 login.rateLimitNotice 限流期内一直在，走完消失。
    func testPhoneStepWaitTextCountsDownAndNoticeClears() async throws {
        script.on("POST /v1/auth/sms-codes", rateLimitWaitReply(retryAfter: 600))
        let rig = LoginRateLimitWaitRig(make(account: nil))
        assertTexts(rig)
        let canvas = await mount(rig)
        try await requestCode(Self.phoneA, in: canvas)
        XCTAssertEqual(requests("POST", "/v1/auth/sms-codes").count, 1, "前提：发出一次发码")

        await expect("login.getCode", label: rig.limitedText, enabled: false, in: canvas,
                     "42901 剩余 600 秒：按钮置灰、显示频繁文案")
        await expectNotice(true, rig, in: canvas, "42901 后输入框下常驻提示")
        XCTAssertNotNil(node("login.getCode", in: canvas), "仍在手机号步（这个号码没收到过码）")
        assertNoLongSeconds(in: canvas, "剩余 600 秒")

        rig.advance(539)
        await quietWindow(1.3)
        await expect("login.getCode", label: rig.limitedText, enabled: false, in: canvas,
                     "剩余 61 秒（> 60）：仍是频繁文案")
        assertNoLongSeconds(in: canvas, "剩余 61 秒")

        rig.advance(1)
        await expect("login.getCode", label: rig.countdownText(60), enabled: false, in: canvas,
                     "剩余 60 秒：换成按秒倒计时")
        rig.advance(1)
        await expect("login.getCode", label: rig.countdownText(59), enabled: false, in: canvas, "逐秒递减到 59")
        rig.advance(1)
        await expect("login.getCode", label: rig.countdownText(58), enabled: false, in: canvas, "逐秒递减到 58")
        await expectNotice(true, rig, in: canvas, seconds: 1, "倒计时期间常驻提示仍在")

        rig.advance(58)
        await expect("login.getCode", label: rig.getCodeText, enabled: true, in: canvas,
                     "限流走完：恢复「获取验证码」可用")
        await expectNotice(false, rig, in: canvas, "限流走完：常驻提示消失")
    }

    /// D10-2767 ①：Retry-After 86400 时任何时刻都不出现「86400 秒」这类大于 60 的秒数；> 60 秒一律频繁文案，≤ 60 秒才按秒。
    func testDayLongRetryAfterNeverShowsLongSeconds() async throws {
        script.on("POST /v1/auth/sms-codes", rateLimitWaitReply(retryAfter: 86400))
        let rig = LoginRateLimitWaitRig(make(account: nil))
        let canvas = await mount(rig)
        try await requestCode(Self.phoneA, in: canvas)

        await expect("login.getCode", label: rig.limitedText, enabled: false, in: canvas,
                     "剩余 86400 秒：频繁文案、置灰")
        assertNoLongSeconds(in: canvas, "剩余 86400 秒")
        await expectNotice(true, rig, in: canvas, "剩余 86400 秒：常驻提示")

        // 推进到剩余 3600、61 秒：每一拍之后都只看到频繁文案
        for (step, remaining) in [(Int64(82800), 3600), (Int64(3539), 61)] {
            rig.advance(step)
            await quietWindow(1.3)
            await expect("login.getCode", label: rig.limitedText, enabled: false, in: canvas,
                         "剩余 \(remaining) 秒：仍是频繁文案")
            assertNoLongSeconds(in: canvas, "剩余 \(remaining) 秒")
        }

        rig.advance(1)
        await expect("login.getCode", label: rig.countdownText(60), enabled: false, in: canvas,
                     "剩余 60 秒：按秒倒计时")
        assertNoLongSeconds(in: canvas, "剩余 60 秒")
    }

    // MARK: - 换号

    /// 换到未限流号码：常驻提示与等待文字立即消失、按钮恢复可用；换回限流号码又出现。
    func testSwitchingPhoneClearsAndRestoresWait() async throws {
        script.on("POST /v1/auth/sms-codes", rateLimitWaitReply(retryAfter: 600))
        let rig = LoginRateLimitWaitRig(make(account: nil))
        let canvas = await mount(rig)
        try await requestCode(Self.phoneA, in: canvas)
        await expect("login.getCode", label: rig.limitedText, enabled: false, in: canvas, "前提：A 号 42901")
        await expectNotice(true, rig, in: canvas, "前提：A 号常驻提示")

        try await switchPhone(to: Self.phoneB, in: canvas)
        await expect("login.getCode", label: rig.getCodeText, enabled: true, in: canvas, seconds: 1.5,
                     "换到未限流的 B 号：等待文字立即消失")
        await expectNotice(false, rig, in: canvas, seconds: 1.5, "换到 B 号：常驻提示立即消失")

        try await switchPhone(to: Self.phoneA, in: canvas)
        await expect("login.getCode", label: rig.limitedText, enabled: false, in: canvas, seconds: 1.5,
                     "换回 A 号：等待文字又出现")
        await expectNotice(true, rig, in: canvas, seconds: 1.5, "换回 A 号：常驻提示又出现")

        rig.advance(540)
        await expect("login.getCode", label: rig.countdownText(60), enabled: false, in: canvas,
                     "换回后照 A 号截止继续倒计时")
        XCTAssertEqual(requests("POST", "/v1/auth/sms-codes").count, 1, "换号不发码")
    }

    // MARK: - 关页重进

    /// 关页重进（新 LoginView / 新 ViewModel、同一个 LoginService）：同一号码仍显示等待与常驻提示，并照原截止倒计时。
    func testReopenedPageStillShowsWait() async throws {
        script.on("POST /v1/auth/sms-codes", rateLimitWaitReply(retryAfter: 600))
        let rig = LoginRateLimitWaitRig(make(account: nil))
        let first = await mount(rig)
        try await requestCode(Self.phoneA, in: first)
        await expect("login.getCode", label: rig.limitedText, enabled: false, in: first, "前提：42901")
        await close(first)

        let again = await mount(rig)
        try await type(Self.phoneA, in: again)
        await expect("login.getCode", label: rig.limitedText, enabled: false, in: again,
                     "重进后同一号码：仍置灰、显示频繁文案")
        await expectNotice(true, rig, in: again, "重进后同一号码：常驻提示仍在")

        rig.advance(540)
        await expect("login.getCode", label: rig.countdownText(60), enabled: false, in: again,
                     "重进后照服务层截止倒计时")
        rig.advance(60)
        await expect("login.getCode", label: rig.getCodeText, enabled: true, in: again, "走完恢复可用")
        await expectNotice(false, rig, in: again, "走完常驻提示消失")
        XCTAssertEqual(requests("POST", "/v1/auth/sms-codes").count, 1, "重进不重发")
    }

    // MARK: - ③ 验证码页

    /// 验证码页：发码成功、60 秒倒计时走完后点【重新获取】收到 42901（Retry-After 3600）——login.countdown 显示频繁文案
    /// （不按 3600 秒显示），不出现可点的 login.resend；剩 60 秒起按秒倒计时；限流走完才出现可用的【重新获取】。
    func testCodeStepResendRateLimitedShowsWaitNotResend() async throws {
        script.on("POST /v1/auth/sms-codes", rateLimitWaitSentReply(), rateLimitWaitReply(retryAfter: 3600))
        let rig = LoginRateLimitWaitRig(make(account: nil))
        let canvas = await mount(rig)
        try await requestCode(Self.phoneA, in: canvas)
        await expect("login.countdown", label: rig.countdownText(60), enabled: true, in: canvas, seconds: 8,
                     "前提：发码成功进验证码步、60 秒倒计时")

        rig.advance(60)
        await expect("login.resend", label: rig.resendText, enabled: true, in: canvas, "前提：倒计时走完出现【重新获取】")
        try await tap("login.resend", in: canvas)
        XCTAssertEqual(requests("POST", "/v1/auth/sms-codes").count, 2, "前提：重发发出")

        await expect("login.countdown", label: rig.limitedText, enabled: true, in: canvas,
                     "重发 42901 剩余 3600 秒：显示频繁文案")
        XCTAssertNil(node("login.resend", in: canvas), "限流期内没有可点的【重新获取】\(scene(canvas))")
        assertNoLongSeconds(in: canvas, "验证码页剩余 3600 秒")

        rig.advance(3539)
        await quietWindow(1.3)
        await expect("login.countdown", label: rig.limitedText, enabled: true, in: canvas, "剩余 61 秒：仍是频繁文案")
        assertNoLongSeconds(in: canvas, "验证码页剩余 61 秒")
        XCTAssertNil(node("login.resend", in: canvas), "剩余 61 秒：没有【重新获取】")

        rig.advance(1)
        await expect("login.countdown", label: rig.countdownText(60), enabled: true, in: canvas,
                     "剩余 60 秒：按秒倒计时")
        rig.advance(1)
        await expect("login.countdown", label: rig.countdownText(59), enabled: true, in: canvas, "逐秒递减到 59")
        XCTAssertNil(node("login.resend", in: canvas), "倒计时期间没有【重新获取】")

        rig.advance(59)
        await expect("login.resend", label: rig.resendText, enabled: true, in: canvas,
                     "限流走完：【重新获取】出现且可用")
        XCTAssertNil(node("login.countdown", in: canvas), "走完后不再显示等待")
    }
}
