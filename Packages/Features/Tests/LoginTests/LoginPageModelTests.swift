import CouliNetwork
import Foundation
@testable import Login
import Router
import Session
import XCTest

/// 登录页状态（view model）与布局（APP-05a 共性 7、8、9、11、12、15、16）：真实 LoginService + 本地假服务。
@MainActor
final class LoginPageModelTests: XCTestCase {
    private let phone = "13800138000"
    private let code = "123456"

    // MARK: - 页面状态（view model）

    /// 共性 11、12：发码 42901 只禁用发码入口；这个号码有效期内收到过码时仍可进验证码步、用旧码登录。
    func testSendRateLimitKeepsLoginUsable() async {
        let smsReply = MutableBox(okReply("{\"resend_after_sec\":60,\"expires_in_sec\":300}"))
        LoginStubProtocol.install { request in
            request.path == Paths.sms ? smsReply.value : okReply(loginData(scope: "full"))
        }
        let env = LoginHarness()
        let model = LoginViewModel(config: LoginPageConfig(service: env.service, texts: KeyTexts()))
        model.setPhone(phone)
        model.toggleAgreement()
        model.requestCode()
        await waitUntil { model.step == .code }
        // 61 秒后点【重新获取】：小时级频控 42901。
        env.advance(seconds: 61)
        smsReply.value = failReply(42901, headers: ["Retry-After": "3600"])
        model.requestCode()
        await waitUntil { model.toast != nil }
        XCTAssertTrue(model.sendRateLimited)
        XCTAssertFalse(model.loginRateLimited, "发码限流不禁用登录按钮")
        // 回手机号步再点【获取验证码】：不发码，直接进验证码步继续输入已收到的码。
        model.backToPhone()
        model.requestCode()
        XCTAssertEqual(model.step, .code)
        XCTAssertEqual(LoginStubProtocol.requests(path: Paths.sms).count, 2)
        model.setCode(code)
        XCTAssertTrue(model.canSubmit)
    }

    /// 共性 8：确认框里的协议链接打开协议正文、关闭确认框，不算同意。
    func testConfirmDialogLinkOpensAgreementWithoutConsent() {
        let env = LoginHarness()
        let config = LoginPageConfig(service: env.service, texts: KeyTexts())
        var opened: [String] = []
        config.onAgreement = { opened.append($0) }
        let model = LoginViewModel(config: config)
        model.setPhone(phone)
        model.requestCode()
        XCTAssertEqual(model.dialog, .agreeConfirm)
        model.openAgreementFromConfirm(LoginViewModel.privacyType)
        XCTAssertEqual(opened, ["privacy"])
        XCTAssertNil(model.dialog)
        XCTAssertFalse(model.agreed)
        model.requestCode()
        XCTAssertEqual(model.dialog, .agreeConfirm, "仍要确认")
    }

    /// 共性 7：验证码格按可用宽度分配，320pt（可用 288）在 100% 与 200% 字号下六格都在一行内、数字放得下、格高随字号增高。
    func testCodeCellLayoutFitsNarrowAndLargeText() {
        for scale in [1.0, 1.3, 2.0, 3.1] as [CGFloat] {
            for width in [288.0, 358.0] as [CGFloat] {
                let layout = CodeCellLayout.compute(availableWidth: width, scale: scale)
                XCTAssertLessThanOrEqual(layout.cellWidth * 6 + layout.spacing * 5, width + 0.01)
                XCTAssertLessThanOrEqual(layout.fontSize * 0.62 + 8, layout.cellWidth + 0.01)
                XCTAssertGreaterThanOrEqual(layout.cellHeight, layout.fontSize * 1.3)
            }
        }
        XCTAssertGreaterThan(CodeCellLayout.compute(availableWidth: 358, scale: 2).cellHeight,
                             CodeCellLayout.compute(availableWidth: 358, scale: 1).cellHeight)
    }

    /// 共性 16：发码遇到 50401（供应商超时，结果不确定）也允许进验证码步，输入实际收到的验证码；「继续输入」是独立入口。
    func testProviderTimeoutStillAllowsCodeEntry() async {
        LoginStubProtocol.install { request in
            request.path == Paths.sms ? failReply(50401) : okReply(loginData(scope: "full"))
        }
        let env = LoginHarness()
        let model = LoginViewModel(config: LoginPageConfig(service: env.service, texts: KeyTexts()))
        model.setPhone(phone)
        model.toggleAgreement()
        XCTAssertFalse(model.canContinueCode)
        model.requestCode()
        await waitUntil { model.step == .code }
        XCTAssertEqual(model.resendCountdown, 0, "结果不确定不起倒计时，可以重新获取")
        model.backToPhone()
        XCTAssertTrue(model.canContinueCode, "手机号步有独立的「继续输入验证码」入口")
        model.continueCode()
        XCTAssertEqual(model.step, .code)
        model.setCode(code)
        XCTAssertTrue(model.canSubmit)
    }

    /// 共性 15：手机号输入不先删字符或截断，统一走 normalize：含字母时保留原样并报 phone_invalid，不发码。
    func testPhoneInputKeepsRawTextAndReportsInvalid() {
        LoginStubProtocol.install { _ in okReply() }
        let env = LoginHarness()
        let model = LoginViewModel(config: LoginPageConfig(service: env.service, texts: KeyTexts()))
        model.setPhone("13800138O00")
        XCTAssertEqual(model.phoneText, "13800138O00")
        model.requestCode()
        XCTAssertEqual(model.phoneError, "error.20001.phone_invalid")
        XCTAssertEqual(model.phoneText, "13800138O00")
        XCTAssertNil(model.dialog)
        model.setPhone("+86 138-0013-8000")
        model.requestCode()
        XCTAssertEqual(model.dialog, .agreeConfirm, "合法写法照常进入发码流程")
    }

    /// 共性 9 的判定：只有 Login 页真的离开导航栈才算出栈；被别的页盖住不算。
    func testRemovesLoginDetection() {
        let login = RouteDestination(route: "Login")
        let other = RouteDestination(route: "Agreement")
        XCTAssertTrue(RouterLoginHost.removesLogin(from: [login], to: []))
        XCTAssertFalse(RouterLoginHost.removesLogin(from: [login], to: [login, other]))
        XCTAssertFalse(RouterLoginHost.removesLogin(from: [], to: [login]))
    }
}
