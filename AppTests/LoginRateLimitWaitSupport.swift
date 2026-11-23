@testable import Couli
import Foundation
@testable import Login
import SwiftUI
import UIKit
import XCTest

/// FU-LOGIN-RATE-LIMIT-WAIT-ios（D10-2767）写测共用：真实 App 组合（MeAppFixture + 本地 WalletStubProtocol 假服务）里的
/// 生产 ApiClient、生产 RouterLoginHost、App 文案表，只把 LoginService 的时钟换成可推进的假时钟（同 LoginHarness.advance 的做法），
/// 这样 Retry-After=600 / 86400 的等待不必真等。页面里的倒计时仍由生产的 1 秒计时刷新（每拍读 service.now）。
final class LoginRateLimitWaitClock: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Int64 = 1_700_000_000_000

    var millis: Int64 {
        lock.withLock { stored }
    }

    func advance(seconds: Int64) {
        lock.withLock { stored += seconds * 1000 }
    }
}

@MainActor
final class LoginRateLimitWaitRig {
    let fixture: MeAppFixture
    let clock = LoginRateLimitWaitClock()
    let service: LoginService
    let texts: LoginTexts

    init(_ fixture: MeAppFixture) {
        self.fixture = fixture
        let clock = clock
        // 与 AppLogin 同一个 ApiClient、同一个 RouterLoginHost；只换时钟
        service = LoginService(client: fixture.client, host: fixture.login.host, clock: { clock.millis })
        texts = fixture.login.pageConfig(restricted: false).texts
    }

    /// 每次进页新建一份配置（新 LoginViewModel），截止时间仍在同一个 service 里。
    func config() -> LoginPageConfig {
        LoginPageConfig(service: service, texts: texts)
    }

    func advance(_ seconds: Int64) {
        clock.advance(seconds: seconds)
    }

    // MARK: - 期望文案（App 文案表）

    var getCodeText: String {
        texts.text("login.get_code")
    }

    var limitedText: String {
        texts.text("error.42901")
    }

    var resendText: String {
        texts.text("login.code.resend")
    }

    var canResendText: String {
        texts.text("bind_phone.can_resend")
    }

    func countdownText(_ seconds: Int) -> String {
        texts.format("login.code.countdown", ["n": String(seconds)])
    }
}

/// 42901 回包（Retry-After 秒）。
func rateLimitWaitReply(retryAfter: Int) -> WalletStubProtocol.Reply {
    .envelope(code: 42901, data: "null", headers: ["Retry-After": String(retryAfter)])
}

/// 发码成功回包（60 秒倒计时）。
func rateLimitWaitSentReply() -> WalletStubProtocol.Reply {
    .envelope(code: 0, data: "{\"resend_after_sec\":60,\"expires_in_sec\":300}", headers: [:])
}

/// 一段文字里「{n} 秒」形式出现的所有秒数。
func rateLimitWaitSeconds(in text: String) -> [Int] {
    guard let regex = try? NSRegularExpression(pattern: "(\\d+)\\s*秒") else { return [] }
    let range = NSRange(text.startIndex..., in: text)
    return regex.matches(in: text, range: range).compactMap { match in
        Range(match.range(at: 1), in: text).flatMap { Int(text[$0]) }
    }
}

/// 页面级用例的公共部分（照 A11yLoginTests：挂生产 LoginView 进临时窗口，经无障碍树键入、双击、读按钮文字与可用状态）。
@MainActor
class LoginRateLimitWaitPageCase: MeTestCase {
    static let phoneA = "13800005678"
    static let phoneB = "13900001234"
    var canvas: A11yCanvas?

    override func setUp() async throws {
        try await super.setUp()
        try A11yTree.enable(self)
    }

    override func tearDown() {
        canvas?.close()
        canvas = nil
        super.tearDown()
    }

    func mount(_ rig: LoginRateLimitWaitRig) async -> A11yCanvas {
        canvas?.close()
        let canvas = A11yCanvas(AnyView(LoginView(config: rig.config())))
        self.canvas = canvas
        await canvas.pump(0.8)
        return canvas
    }

    func close(_ canvas: A11yCanvas) async {
        canvas.close()
        self.canvas = nil
        await quietWindow(0.3)
    }

    func type(_ text: String, in canvas: A11yCanvas, file: StaticString = #filePath, line: UInt = #line) async throws {
        func fields(_ view: UIView) -> [UITextField] {
            ((view as? UITextField).map { [$0] } ?? []) + view.subviews.flatMap(fields)
        }
        let field = try XCTUnwrap(fields(canvas.window).first { $0.keyboardType == .phonePad },
                                  "没有手机号输入框", file: file, line: line)
        _ = field.becomeFirstResponder()
        field.insertText(text)
        await canvas.pump(0.3)
        canvas.window.endEditing(true)
        await canvas.pump(0.3)
    }

    func scene(_ canvas: A11yCanvas) -> String {
        let nodes = A11yTree.nodes(canvas.root).filter { $0.id.hasPrefix("login.") }
            .map { "\($0)\($0.traits.contains(.notEnabled) ? " 不可用" : "")" }
        return "\n登录页元素：\n\(nodes.joined(separator: "\n"))"
    }

    func tap(_ id: String, in canvas: A11yCanvas, file: StaticString = #filePath, line: UInt = #line) async throws {
        let enabled = await canvas.wait(4) { nodes in
            nodes.contains { $0.id == id && $0.isElement && !$0.traits.contains(.notEnabled) }
        }
        XCTAssertTrue(enabled, "\(id) 不在树里或一直不可用\(scene(canvas))", file: file, line: line)
        let node = try XCTUnwrap(A11yTree.elements(canvas.root).first { $0.id == id }, file: file, line: line)
        XCTAssertTrue(A11yTree.activate(node), "\(id) 没有接住双击\(scene(canvas))", file: file, line: line)
        await canvas.pump(0.3)
    }

    /// 键入号码、勾协议、点【获取验证码】。
    func requestCode(_ phone: String, in canvas: A11yCanvas) async throws {
        try await type(phone, in: canvas)
        if A11yTree.node("login.agreeCheckbox", in: canvas.root)?.traits.contains(.selected) != true {
            try await tap("login.agreeCheckbox", in: canvas)
        }
        try await tap("login.getCode", in: canvas)
    }

    /// 清掉号码再键入另一个（经生产清除按钮 login.phoneClear）。
    func switchPhone(to phone: String, in canvas: A11yCanvas) async throws {
        try await tap("login.phoneClear", in: canvas)
        try await type(phone, in: canvas)
    }

    func node(_ id: String, in canvas: A11yCanvas) -> A11yNode? {
        A11yTree.elements(canvas.root).first { $0.id == id }
    }

    /// 等 `id` 的文字变成 `label`、可用状态为 `enabled`（最多 `seconds` 秒；生产计时 1 秒一拍）。
    func expect(_ id: String, label: String, enabled: Bool, in canvas: A11yCanvas, seconds: Double = 4,
                _ message: String, file: StaticString = #filePath, line: UInt = #line) async {
        let reached = await canvas.wait(seconds) { nodes in
            nodes.contains { node in
                node.id == id && node.isElement && node.label == label
                    && node.traits.contains(.notEnabled) == !enabled
            }
        }
        XCTAssertTrue(reached, "\(message)：期望 \(id)「\(label)」\(enabled ? "可用" : "不可用")\(scene(canvas))",
                      file: file, line: line)
    }

    /// 常驻提示行出现（文字 error.42901）/ 不出现。
    func expectNotice(_ shown: Bool, _ rig: LoginRateLimitWaitRig, in canvas: A11yCanvas, seconds: Double = 4,
                      _ message: String, file: StaticString = #filePath, line: UInt = #line) async {
        let reached = await canvas.wait(seconds) { nodes in
            let notice = nodes.first { $0.id == "login.rateLimitNotice" }
            return shown ? notice?.label == rig.limitedText : notice == nil
        }
        XCTAssertTrue(reached, "\(message)：login.rateLimitNotice 应\(shown ? "出现（error.42901）" : "不出现")"
            + scene(canvas), file: file, line: line)
    }

    /// 树里任何文字都不出现大于 60 的秒数（D10-2767 ①：超过 60 秒不按秒显示）。
    func assertNoLongSeconds(in canvas: A11yCanvas, _ moment: String, file: StaticString = #filePath,
                             line: UInt = #line) {
        let long = A11yTree.nodes(canvas.root).filter { node in
            (rateLimitWaitSeconds(in: node.label) + rateLimitWaitSeconds(in: node.value)).contains { $0 > 60 }
        }
        XCTAssertTrue(long.isEmpty, "\(moment)：不应出现大于 60 的秒数，实际 \(long)\(scene(canvas))",
                      file: file, line: line)
    }
}
