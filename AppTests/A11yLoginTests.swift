@testable import Couli
import DesignSystem
import Foundation
import Login
import SwiftUI
import UIKit
import XCTest

/// FU-IOS-A11Y（QA-12b iOS 报告 P8 登录）：真实 App 组合（MeAppFixture + 本地假服务）出生产短信登录页，打开 SwiftUI 无障碍树，
/// 按读屏的方式操作（系统输入框键入、双击按钮、Z 形擦除）。
/// - A11Y-03 / 共性 ②：手机号格式错、验证码错时立即播报错误，焦点移到出错的框（焦点经 `couliFocusProbe` 报编号：手机号
///   `login.phone` 或错误行 `login.phoneError`；验证码 `login.code` 或 `login.codeError`）。读屏开着（替身）时生产写法若等播报结束再移焦，
///   用例在拦到播报后补发系统「播报结束」通知。
/// - A11Y-01 / 共性 ④：协议确认、注册被拦（44001）、注销中（10007）三种弹窗都能用读屏「返回」手势关闭，等同【取消】/【我知道了】：
///   不发码、不跳客服、不离开登录页。
@MainActor
final class A11yLoginTests: MeTestCase {
    private static let phone = "13800005678"
    lazy var probes = A11yProbes()
    private var canvas: A11yCanvas?

    override func setUpWithError() throws {
        try super.setUpWithError()
        script.ok("POST /v1/auth/sms-codes", "{\"resend_after_sec\":60,\"expires_in_sec\":300}")
    }

    override func setUp() async throws {
        try await super.setUp()
        try A11yTree.enable(self)
    }

    override func tearDown() {
        canvas?.close()
        canvas = nil
        super.tearDown()
    }

    // MARK: - 操作

    private func mount(_ fixture: MeAppFixture) async -> A11yCanvas {
        let page = LoginView(config: fixture.login.pageConfig(restricted: false))
        let canvas = A11yCanvas(AnyView(page), probe: probes.probe)
        self.canvas = canvas
        await canvas.pump(0.8)
        return canvas
    }

    private func type(_ text: String, keyboard: UIKeyboardType, in canvas: A11yCanvas,
                      file: StaticString = #filePath, line: UInt = #line) async throws {
        func fields(_ view: UIView) -> [UITextField] {
            ((view as? UITextField).map { [$0] } ?? []) + view.subviews.flatMap(fields)
        }
        let field = try XCTUnwrap(fields(canvas.window).first { $0.keyboardType == keyboard },
                                  "没有 \(keyboard.rawValue) 输入框", file: file, line: line)
        _ = field.becomeFirstResponder()
        field.insertText(text)
        await canvas.pump(0.3)
        canvas.window.endEditing(true)
        await canvas.pump(0.3)
    }

    /// 失败时附上的现场（v5）：已发请求 + 树里 login.* 元素（值、可用与否）+ 弹窗标题类元素。
    private func scene(_ canvas: A11yCanvas) -> String {
        let sent = WalletStubProtocol.requests.map { "\($0.method) \($0.path)" }
        let nodes = A11yTree.nodes(canvas.root).filter { $0.id.hasPrefix("login.") || ($0.isElement && $0.isHeader) }
            .map { "\($0)\($0.traits.contains(.notEnabled) ? " 不可用" : "")" }
        return "\n请求：\(sent)\n登录页元素：\n\(nodes.joined(separator: "\n"))"
    }

    func tap(_ id: String, in canvas: A11yCanvas, file: StaticString = #filePath,
             line: UInt = #line) async throws {
        let ready = await canvas.wait { $0.contains { $0.id == id && $0.isElement } }
        XCTAssertTrue(ready, "树里没有 \(id)\(scene(canvas))", file: file, line: line)
        // 等它可用再双击（绑定回写、重绘可能晚一两帧；不可用时双击不触发动作，v5）
        let enabled = await canvas.wait(3) { nodes in
            nodes.contains { $0.id == id && $0.isElement && !$0.traits.contains(.notEnabled) }
        }
        XCTAssertTrue(enabled, "\(id) 一直不可用\(scene(canvas))", file: file, line: line)
        let node = try XCTUnwrap(A11yTree.elements(canvas.root).first { $0.id == id }, file: file, line: line)
        XCTAssertTrue(A11yTree.activate(node), "\(id) 没有接住双击\(scene(canvas))", file: file, line: line)
        await canvas.pump(0.3)
    }

    /// 填验证码（v5）：页面上可能不止一个数字键盘框；逐个试，直到树里 `login.code` 的值就是这串码。
    private func enterCode(_ code: String, in canvas: A11yCanvas, file: StaticString = #filePath,
                           line: UInt = #line) async {
        func fields(_ view: UIView) -> [UITextField] {
            ((view as? UITextField).map { [$0] } ?? []) + view.subviews.flatMap(fields)
        }
        for field in fields(canvas.window) where field.keyboardType == .numberPad {
            _ = field.becomeFirstResponder()
            field.insertText(code)
            await canvas.pump(0.3)
            if A11yTree.node("login.code", in: canvas.root)?.value == code {
                break
            }
        }
        canvas.window.endEditing(true)
        let filled = await canvas.wait(3) { $0.contains { $0.id == "login.code" && $0.value == code } }
        XCTAssertTrue(filled, "验证码没有填进 login.code\(scene(canvas))", file: file, line: line)
    }

    /// 同意协议、获取验证码、进验证码步、填 6 位码。
    func codeStep(_ fixture: MeAppFixture, phone: String = A11yLoginTests.phone) async throws -> A11yCanvas {
        let canvas = await mount(fixture)
        try await type(phone, keyboard: .phonePad, in: canvas)
        let agreed = A11yTree.node("login.agreeCheckbox", in: canvas.root)?.traits.contains(.selected) == true
        if !agreed {
            try await tap("login.agreeCheckbox", in: canvas)
        }
        try await tap("login.getCode", in: canvas)
        let entered = await canvas.wait(8) { $0.contains { $0.id == "login.code" } }
        XCTAssertTrue(entered, "前提：发码成功进验证码步\(scene(canvas))")
        await enterCode("123456", in: canvas)
        return canvas
    }

    /// 等错误行出现 → 拦到含错误文字的立即播报 → 补发「播报结束」→ 焦点报到 `targets` 之一。
    func assertAnnouncedAndFocused(_ errorID: String, targets: Set<String>, in canvas: A11yCanvas,
                                   file: StaticString = #filePath, line: UInt = #line) async throws {
        let shown = await canvas.wait(8) { $0.contains { $0.id == errorID } }
        XCTAssertTrue(shown, "前提：出错误行 \(errorID)\(scene(canvas))", file: file, line: line)
        let message = try XCTUnwrap(A11yTree.node(errorID, in: canvas.root), file: file, line: line).label
        XCTAssertFalse(message.isEmpty, file: file, line: line)
        let post = await A11yAudit.waitAnnouncement(containing: message)
        XCTAssertNotNil(post, "错误「\(message)」要播报（A11Y-03）；实际：\(A11yPostTap.posts)", file: file, line: line)
        XCTAssertEqual(post?.queued, false, "输入错误立即读（打断当前朗读）", file: file, line: line)
        A11yAudit.finishAnnouncement(post?.text ?? message)
        await waitUntil("焦点要移到出错的框 \(targets.sorted())；实际 \(probes.focused)", timeout: 9.5,
                        file: file, line: line) {
            !targets.isDisjoint(with: self.probes.focused)
        }
    }

    // MARK: - A11Y-03

    func testPhoneErrorIsAnnouncedAndFocusesPhoneField() async throws {
        A11yAudit.installTap(self, voiceOver: true)
        let canvas = await mount(make(account: nil))
        try await type("123", keyboard: .phonePad, in: canvas)
        probes.clearFocus()
        try await tap("login.getCode", in: canvas)
        try await assertAnnouncedAndFocused("login.phoneError", targets: ["login.phone", "login.phoneError"],
                                            in: canvas)
        XCTAssertEqual(requests("POST", "/v1/auth/sms-codes").count, 0, "格式不对不发码")
    }

    // MARK: - A11Y-01 弹窗返回手势

    /// 弹窗打开后新出现的标题元素（弹窗标题）。
    private func dialogTitle(after headersBefore: Set<String>, in canvas: A11yCanvas,
                             file: StaticString = #filePath, line: UInt = #line) async throws -> A11yNode {
        let opened = await canvas.wait(8) { nodes in
            nodes.contains { $0.isElement && $0.isHeader && !headersBefore.contains($0.label) }
        }
        XCTAssertTrue(opened, "弹窗没有打开\(scene(canvas))", file: file, line: line)
        return try XCTUnwrap(A11yTree.elements(canvas.root).first { $0.isHeader && !headersBefore.contains($0.label) },
                             file: file, line: line)
    }

    private func headers(_ canvas: A11yCanvas) -> Set<String> {
        Set(A11yTree.elements(canvas.root).filter(\.isHeader).map(\.label))
    }

    private func assertEscapeCloses(_ title: A11yNode, in canvas: A11yCanvas, _ name: String,
                                    file: StaticString = #filePath, line: UInt = #line) async {
        XCTAssertTrue(A11yTree.escape(from: title.object), "\(name) 弹窗没有接住读屏「返回」手势（A11Y-01）",
                      file: file, line: line)
        let closed = await canvas.wait(3) { nodes in !nodes.contains { $0.isElement && $0.label == title.label } }
        XCTAssertTrue(closed, "\(name)：「返回」手势后弹窗要关闭", file: file, line: line)
        XCTAssertNotNil(A11yTree.node("login.page", in: canvas.root), "\(name)：仍在登录页", file: file, line: line)
    }

    func testAgreementConfirmClosesWithEscapeAsCancel() async throws {
        let fixture = make(account: nil)
        let canvas = await mount(fixture)
        try await type(Self.phone, keyboard: .phonePad, in: canvas)
        let before = headers(canvas)
        try await tap("login.getCode", in: canvas)
        let title = try await dialogTitle(after: before, in: canvas)
        await assertEscapeCloses(title, in: canvas, "协议确认")
        await quietWindow(0.6)
        XCTAssertEqual(requests("POST", "/v1/auth/sms-codes").count, 0, "返回手势等同【取消】：不算同意、不发码")
        XCTAssertNotNil(A11yTree.node("login.getCode", in: canvas.root), "留在手机号步")
    }

    func testBlockedAndDeletionDialogsCloseWithEscape() async throws {
        // 两轮各用一个号码：前一轮的发码倒计时 / 已收码状态不带进后一轮（v5）
        // 10007 只有 stage=processing 才是「注销中」（LoginFlow；同 LoginIntegrationTests，v7）
        let rounds = [(44001, "注册被拦", "13800005678", "null"),
                      (10007, "注销中", "13900001234", "{\"stage\":\"processing\"}")]
        for (code, name, phone, data) in rounds {
            script.fail("POST /v1/auth/login/sms", code, data: data)
            let fixture = make(account: nil)
            let canvas = try await codeStep(fixture, phone: phone)
            let paths = fixture.router.path.count
            let before = headers(canvas)
            try await tap("login.submit", in: canvas)
            let title = try await dialogTitle(after: before, in: canvas)
            await assertEscapeCloses(title, in: canvas, name)
            await quietWindow(0.6)
            XCTAssertEqual(fixture.router.path.count, paths, "\(name)：返回手势等同【我知道了】，不跳客服 / 申诉")
            canvas.close()
            self.canvas = nil
        }
    }
}
