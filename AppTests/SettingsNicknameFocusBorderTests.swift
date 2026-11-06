@testable import Couli
import DesignSystem
import Foundation
import UIKit
import XCTest

/// DS-02-iOS-1 计划 ③（评审 r1 S2-2）：昵称输入中描边取 border.active（浅 #28251F / 深 #F2EEE6），浅色 Release 用户看得见。
/// 入库快照都没有输入焦点，这里在进程内把生产昵称页的 UITextField 设为第一响应者（不走 UI 真点），截框左边 2pt 取色；
/// 错误优先：有错误时即使在输入中也取 status.error.text。
@MainActor
final class SettingsNicknameFocusBorderTests: SettingsVisualTestCase {
    private func textField(in view: UIView) -> UITextField? {
        if let field = view as? UITextField {
            return field
        }
        for child in view.subviews {
            if let field = textField(in: child) {
                return field
            }
        }
        return nil
    }

    /// 让昵称框拿到焦点，返回稳定后的一帧。
    private func focusField(file: StaticString = #filePath, line: UInt = #line) async throws -> UIImage {
        let window = try XCTUnwrap(page?.window, "昵称页没挂上窗口", file: file, line: line)
        let field = try XCTUnwrap(textField(in: window), "昵称页没有 UITextField", file: file, line: line)
        XCTAssertTrue(field.becomeFirstResponder(), "前提：昵称框拿到第一响应者", file: file, line: line)
        await settle()
        XCTAssertTrue(field.isFirstResponder, "前提：焦点保持在昵称框", file: file, line: line)
        return try await frame("nickname.field", file: file, line: line)
    }

    private func leftEdge(file: StaticString = #filePath, line: UInt = #line) throws -> CGRect {
        let field = try rect("nickname.field", file: file, line: line)
        return CGRect(x: field.minX, y: field.midY - 6, width: 2, height: 12)
    }

    private func assertFocusedBorder(dark: Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        try await openNickname(Setup(canvas: .init(dark: dark)), file: file, line: line)
        let image = try await focusField(file: file, line: line)
        let edge = try leftEdge(file: file, line: line)
        let active = pixel(CouliColor.token("border.active"), dark: dark)
        let control = pixel(CouliColor.borderControl, dark: dark)
        let side = dark ? "深" : "浅"
        XCTAssertGreaterThan(share(image, in: edge, near: active, tolerance: 20), 0.7,
                             "输入中描边应为 border.active（\(side)）", file: file, line: line)
        XCTAssertLessThan(share(image, in: edge, near: control, tolerance: 20), 0.2,
                          "输入中不再用 border.control（\(side)）", file: file, line: line)
    }

    func testFocusedBorderIsBorderActiveLight() async throws {
        try await assertFocusedBorder(dark: false)
    }

    func testFocusedBorderIsBorderActiveDark() async throws {
        try await assertFocusedBorder(dark: true)
    }

    /// 错误优先：有错误时即使在输入中也取错误色。
    /// v1.3：错误改用本地「超长」错误（输入相同文字时沿用，`NicknameController.input` 第 73–76 行）。v1.2 用 30415 服务端错误时红在
    /// 「0.0 不大于 0.7」：`input(_:)` 无条件清掉服务端错误（第 71 行），而 UITextField 拿到焦点后 SwiftUI 会把当前文字回写一次
    /// （PayoutVisualInputSyncTests 的实测记录），错误随之消失、框变成 border.active——取样时根本没有错误态，不是错误优先写反了。
    /// 这里先断言「拿到焦点后错误仍在、且确实在输入中」，再判颜色；前提不成立时报前提，不再混成颜色失败。
    func testErrorWinsOverFocus() async throws {
        try await openNickname()
        try nicknameActions.input(try SettingsVisualData.nickname("tooLong"))
        _ = try await frame("nickname.error")
        let image = try await focusField()
        XCTAssertNotNil(page?.controller?.nickname?.state.error, "前提：拿到焦点后错误仍在")
        XCTAssertTrue(has("nickname.error"), "前提：错误行仍在页面上")
        let edge = try leftEdge()
        let red = pixel(CouliColor.statusErrorText, dark: false)
        let active = pixel(CouliColor.token("border.active"), dark: false)
        XCTAssertGreaterThan(share(image, in: edge, near: red, tolerance: 20), 0.7, "有错误时取错误色")
        XCTAssertLessThan(share(image, in: edge, near: active, tolerance: 20), 0.2, "有错误时不取 border.active")
    }
}
