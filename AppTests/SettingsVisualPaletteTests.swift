@testable import Couli
import DesignSystem
import Foundation
import SwiftUI
import UIKit
import XCTest

/// APP-12w-a 令牌（brief §2 第 12 条、§4.8、§9 第 3 条，G-S17）：SettingsDark / NotifySettingsDark 设计说明列的深色值逐项按截图像素核，遮罩浅深各查。
@MainActor
final class SettingsVisualPaletteTests: SettingsVisualTestCase {
    private typealias Judge = SettingsVisualJudge

    private func dark() -> Setup {
        Setup(canvas: .init(dark: true))
    }

    func testSettingsDarkValues() async throws {
        let (_, image) = try await open(dark(), waitFor: "settings.group.general")
        let card = try rect("settings.group.general")
        let canvas = CGRect(x: 2, y: card.midY - 8, width: 8, height: 16)
        XCTAssertGreaterThan(share(image, in: canvas, near: Judge.hex("#171513"), tolerance: 3), 0.9, "页底")
        let inside = CGRect(x: card.maxX - 12, y: card.minY + 6, width: 8, height: 8)
        XCTAssertGreaterThan(share(image, in: inside, near: Judge.hex("#24211E"), tolerance: 3), 0.9, "卡片")
        let title = try rect("settings.row.help.title")
        XCTAssertGreaterThan(count(image, in: title, near: Judge.hex("#F2EEE6")), 20, "主文字")
        let label = try rect("settings.group.general.title")
        XCTAssertGreaterThan(count(image, in: label, near: Judge.hex("#B5ACA2")), 10, "次文字")
        let line = try rect("settings.group.general.divider.0")
        XCTAssertGreaterThan(
            count(image, in: line.insetBy(dx: 10, dy: -1), near: Judge.hex("#3A3530"), tolerance: 8),
            10,
            "分隔线"
        )
        let logout = try rect("settings.logout.button")
        let fill = CGRect(x: logout.minX + 10, y: logout.midY - 4, width: 10, height: 8)
        XCTAssertGreaterThan(share(image, in: fill, near: Judge.hex("#24211E"), tolerance: 3), 0.9, "【退出登录】卡片底")
        let edge = CGRect(x: logout.minX - 0.5, y: logout.midY - 6, width: 2, height: 12)
        XCTAssertGreaterThan(count(image, in: edge, near: Judge.hex("#8C8278"), tolerance: 20), 10, "【退出登录】控件边")
    }

    func testNotifyDarkValues() async throws {
        let image = try await openNotify(dark(), waitFor: "notify.bar.text")
        let bar = try rect("notify.bar")
        let edge = CGRect(x: bar.minX + 2, y: bar.midY - 6, width: 6, height: 12)
        XCTAssertGreaterThan(share(image, in: edge, near: Judge.hex("#33290F"), tolerance: 3), 0.8, "警告底")
        XCTAssertGreaterThan(count(image, in: try rect("notify.bar.text"), near: Judge.hex("#E3B65C")), 20, "警告字")
        XCTAssertGreaterThan(count(image, in: try rect("notify.goSettings.link"), near: Judge.hex("#E3B65C")), 5, "链接")
        let toggle = try rect("notify.switch.control")
        XCTAssertGreaterThan(
            count(image, in: toggle, near: Judge.hex("#C44820"), tolerance: 12),
            100,
            "开关选中仍 control.checked"
        )
    }

    private func assertScrim(dark: Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        let ground = Judge.hex(dark ? "#171513" : "#F2EEE6")
        let expected = dark ? Judge.blend(Judge.hex("#000000"), opacity: 0x8C / 255, over: ground)
            : Judge.blend(Judge.hex("#28251F"), opacity: 0.4, over: ground)
        try await open(Setup(canvas: .init(dark: dark)), file: file, line: line)
        try actions.askLogout()
        let image = try await frame(file: file, line: line) { $0.controller?.state.dialog != nil }
        let margin = CGRect(x: 2, y: 300, width: 8, height: 40)
        XCTAssertGreaterThan(share(image, in: margin, near: expected, tolerance: 4), 0.9,
                             "遮罩 overlay.scrim（\(dark ? "深" : "浅")）", file: file, line: line)
    }

    /// G-S07：遮罩走令牌（iOS 现状已是 `CouliScrim`，加守卫）。
    func testScrimLight() async throws {
        try await assertScrim(dark: false)
    }

    func testScrimDark() async throws {
        try await assertScrim(dark: true)
    }

    /// 对比度：警告条文字 / 链接对警告底、次文字对卡片、链接色对页底与卡片、错误色对卡片，浅深各查（令牌换值时这里先红）。
    func testContrastPairs() {
        let pairs: [(name: String, colors: (Color, Color))] = [
            ("警告字对警告底", (CouliColor.statusWarningText, CouliColor.statusWarningBackground)),
            ("次文字对卡片", (CouliColor.textSecondary, CouliColor.backgroundSurface)),
            ("次文字对页底", (CouliColor.textSecondary, CouliColor.backgroundCanvas)),
            ("链接色对页底", (CouliColor.textLink, CouliColor.backgroundCanvas)),
            ("主文字对 muted", (CouliColor.textPrimary, CouliColor.backgroundMuted)),
            ("错误色对卡片", (CouliColor.statusErrorText, CouliColor.backgroundSurface)),
        ]
        for dark in [false, true] {
            for (name, colors) in pairs {
                let ratio = Judge.contrast(pixel(colors.0, dark: dark), pixel(colors.1, dark: dark))
                XCTAssertGreaterThanOrEqual(ratio, 4.5, "\(name)（\(dark ? "深" : "浅")）对比度 \(ratio)")
            }
        }
    }
}
