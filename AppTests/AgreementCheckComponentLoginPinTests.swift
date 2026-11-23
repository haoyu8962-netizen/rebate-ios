@testable import Couli
import DesignSystem
import Foundation
import Login
import SwiftUI
import UIKit
import XCTest

/// FU-IOS-AGREEMENT-CHECK-COMPONENT 回归钉（登录协议行）：换组件库勾选圆后，读屏文案、标识、命中区、行为逐字不变。
/// 现状 524f89e 上本就绿；钉的是「换组件后不许变」。夹具照 A11yLoginTests（MeAppFixture + 本地假服务出生产短信登录页，打开 SwiftUI
/// 无障碍树，按读屏方式双击）。
@MainActor
final class AgreementCheckComponentLoginPinTests: MeTestCase {
    private static let phone = "13800005678"
    private static let confirmTitle = "请阅读并同意协议"
    private var canvas: A11yCanvas?
    /// 整条用例强持有夹具（AppLogin、页面配置的闭包对它是 unowned / weak 引用），tearDown 再放（同 A11yLoginTests 在用例里持 fixture）。
    private var fixture: MeAppFixture?

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
        fixture = nil
        super.tearDown()
    }

    // MARK: - 操作（同 A11yLoginTests）

    private func mount() async -> A11yCanvas {
        let fixture = make(account: nil)
        self.fixture = fixture
        let canvas = A11yCanvas(AnyView(LoginView(config: fixture.login.pageConfig(restricted: false))))
        self.canvas = canvas
        await canvas.pump(0.8)
        return canvas
    }

    private func typePhone(in canvas: A11yCanvas, file: StaticString = #filePath, line: UInt = #line) async throws {
        func fields(_ view: UIView) -> [UITextField] {
            ((view as? UITextField).map { [$0] } ?? []) + view.subviews.flatMap(fields)
        }
        let field = try XCTUnwrap(fields(canvas.window).first { $0.keyboardType == .phonePad },
                                  "没有手机号输入框", file: file, line: line)
        _ = field.becomeFirstResponder()
        field.insertText(Self.phone)
        await canvas.pump(0.3)
        canvas.window.endEditing(true)
        await canvas.pump(0.3)
    }

    private func activate(_ id: String, in canvas: A11yCanvas, file: StaticString = #filePath,
                          line: UInt = #line) async throws {
        let enabled = await canvas.wait(3) { nodes in
            nodes.contains { $0.id == id && $0.isElement && !$0.traits.contains(.notEnabled) }
        }
        XCTAssertTrue(enabled, "\(id) 不在树里或不可用\n\(A11yTree.dump(A11yTree.elements(canvas.root)))",
                      file: file, line: line)
        let node = try XCTUnwrap(A11yTree.elements(canvas.root).first { $0.id == id }, file: file, line: line)
        XCTAssertTrue(A11yTree.activate(node), "\(id) 没有接住双击", file: file, line: line)
        await canvas.pump(0.3)
    }

    private func checkbox(_ canvas: A11yCanvas, file: StaticString = #filePath, line: UInt = #line) throws -> A11yNode {
        try XCTUnwrap(A11yTree.node("login.agreeCheckbox", in: canvas.root), "协议行标识 login.agreeCheckbox 不变",
                      file: file, line: line)
    }

    private func selected(_ expected: Bool, in canvas: A11yCanvas) async -> Bool {
        await canvas.wait(3) { nodes in
            nodes.contains { $0.id == "login.agreeCheckbox" && $0.traits.contains(.selected) == expected }
        }
    }

    // MARK: - 用例

    /// 协议行：一个读屏项「我已阅读并同意」+ 提示「未注册的手机号验证后自动创建账号」、按钮、默认未选中、命中区 ≥ 44；
    /// 《用户协议》《隐私政策》仍是两个独立读屏项（标识不变），与协议行命中区不重叠。
    func testAgreementRowSpokenTextIdentifierAndHitAreaUnchanged() async throws {
        let canvas = await mount()
        let row = try checkbox(canvas)
        XCTAssertTrue(row.isElement, "协议行是一个读屏项")
        XCTAssertEqual(row.label, "我已阅读并同意")
        XCTAssertEqual(row.object.accessibilityHint, "未注册的手机号验证后自动创建账号")
        XCTAssertTrue(row.isButton, "读屏为按钮")
        XCTAssertFalse(row.traits.contains(.selected), "默认未选中")
        // 量法同 UITests/LoginSmokeTests.swift checkHitTargetsAndOrder：读屏框含焦点环外扩 4pt，去掉外扩后核对；
        // 流式布局里协议行与链接相邻，外扩部分本就相交，只要求去外扩的框（再内缩 0.5）互不相交。
        let ring: CGFloat = 4
        let agreement = try XCTUnwrap(A11yTree.node("login.link.agreement", in: canvas.root), "协议链接标识不变")
        let privacy = try XCTUnwrap(A11yTree.node("login.link.privacy", in: canvas.root), "隐私链接标识不变")
        for node in [row, agreement, privacy] {
            XCTAssertTrue(node.isElement, "\(node.id) 是独立读屏项")
            XCTAssertGreaterThanOrEqual(node.frame.height, 43.5, "\(node.id) 命中区高 ≥ 44：\(node.frame)")
            XCTAssertGreaterThanOrEqual(node.frame.width, 43.5, "\(node.id) 命中区宽 ≥ 44：\(node.frame)")
        }
        let box = row.frame.insetBy(dx: ring, dy: ring)
        let link = agreement.frame.insetBy(dx: ring, dy: ring)
        let other = privacy.frame.insetBy(dx: ring, dy: ring)
        XCTAssertFalse(box.intersects(link.insetBy(dx: 0.5, dy: 0.5)), "协议行不压《用户协议》：\(box) \(link)")
        XCTAssertFalse(link.intersects(other.insetBy(dx: 0.5, dy: 0.5)), "两个链接不重叠：\(link) \(other)")
    }

    /// 未勾点【获取验证码】：仍弹「请阅读并同意协议」确认框，不发码。
    func testUncheckedGetCodeStillOpensAgreementConfirm() async throws {
        let canvas = await mount()
        try await typePhone(in: canvas)
        XCTAssertFalse(try checkbox(canvas).traits.contains(.selected), "前提：未勾")
        try await activate("login.getCode", in: canvas)
        let opened = await canvas.wait(8) { $0.contains { $0.isElement && $0.label == Self.confirmTitle } }
        XCTAssertTrue(opened, "未勾点获取验证码要弹协议确认框\n\(A11yTree.dump(A11yTree.elements(canvas.root)))")
        await quietWindow(0.6)
        XCTAssertEqual(requests("POST", "/v1/auth/sms-codes").count, 0, "确认框打开时不发码")
    }

    /// 读屏双击协议行勾上后点【获取验证码】：不弹确认框，直接发码进验证码步。
    func testCheckedGetCodeSkipsConfirmAndSendsCode() async throws {
        let canvas = await mount()
        try await typePhone(in: canvas)
        try await activate("login.agreeCheckbox", in: canvas)
        let checked = await selected(true, in: canvas)
        XCTAssertTrue(checked, "双击协议行后读屏为已选中")
        try await activate("login.getCode", in: canvas)
        let entered = await canvas.wait(8) { $0.contains { $0.id == "login.code" } }
        XCTAssertTrue(entered, "勾选后发码进验证码步")
        XCTAssertNil(A11yTree.elements(canvas.root).first { $0.label == Self.confirmTitle }, "勾选后不弹协议确认框")
        XCTAssertEqual(requests("POST", "/v1/auth/sms-codes").count, 1, "直接发码一次")
    }

    /// 协议行再双击取消勾选；点《用户协议》《隐私政策》链接只打开协议，不改勾选。
    func testToggleBackAndLinksDoNotToggle() async throws {
        let canvas = await mount()
        try await activate("login.agreeCheckbox", in: canvas)
        let checked = await selected(true, in: canvas)
        XCTAssertTrue(checked, "第一次双击勾上")
        try await activate("login.agreeCheckbox", in: canvas)
        let unchecked = await selected(false, in: canvas)
        XCTAssertTrue(unchecked, "再双击取消")
        for id in ["login.link.agreement", "login.link.privacy"] {
            try await activate(id, in: canvas)
            await quietWindow(0.4)
            XCTAssertFalse(try checkbox(canvas).traits.contains(.selected), "点 \(id) 不勾选")
        }
    }
}
