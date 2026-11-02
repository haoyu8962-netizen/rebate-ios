@testable import Couli
import DesignSystem
import Foundation
import SwiftUI
import UIKit
import XCTest

/// 深色与令牌（brief §2 第 18 条、§4.8，G-P22）：三张深色稿按设计说明值逐项取像素；遮罩浅深；对比度重点对。
@MainActor
final class PrivacyVisualPaletteTests: PrivacyVisualTestCase {
    private typealias Judge = SettingsVisualJudge

    private func dark(_ height: CGFloat = 1200) -> Canvas {
        Canvas(height: height, dark: true)
    }

    /// PrivacyCenterDark：页底 #171513、卡 #24211E、主 / 次文字、分隔线 #3A3530、开关 #C44820、【撤回同意】卡片底 + 控件边 #8C8278。
    func testPrivacyDarkValues() async throws {
        let image = try await openPrivacy(Scene(canvas: dark()), waitFor: "privacy.withdraw.button")
        let card = try rect("privacy.docs")
        assertFill(image, CGRect(x: 2, y: card.midY - 8, width: 8, height: 16), Judge.hex("#171513"), "页底")
        assertFill(image, CGRect(x: card.maxX - 24, y: card.minY + 2, width: 8, height: 2), Judge.hex("#24211E"), "卡片")
        let title = try rect("privacy.row.collect.title")
        XCTAssertGreaterThan(count(image, in: title, near: Judge.hex("#F2EEE6")), 20, "主文字")
        let heading = try rect("privacy.permissions.title")
        XCTAssertGreaterThan(count(image, in: heading, near: Judge.hex("#B5ACA2")), 10, "次文字")
        let line = try rect("privacy.docs.divider.0")
        XCTAssertGreaterThan(
            count(image, in: line.insetBy(dx: 10, dy: -1), near: Judge.hex("#3A3530"), tolerance: 8),
            10,
            "分隔线"
        )
        let toggle = try rect("privacy.personalization.control")
        XCTAssertGreaterThan(count(image, in: toggle, near: Judge.hex("#C44820"), tolerance: 12), 100, "开关选中")
        let button = try rect("privacy.withdraw.button")
        assertFill(image, CGRect(x: button.minX + 10, y: button.midY - 4, width: 10, height: 8), Judge.hex("#24211E"),
                   "【撤回同意】卡片底")
        let edge = CGRect(x: button.minX - 0.5, y: button.midY - 6, width: 2, height: 12)
        XCTAssertGreaterThan(count(image, in: edge, near: Judge.hex("#8C8278"), tolerance: 20), 10, "控件边")
    }

    /// AboutDark：图标按图片处理（深色下同一品牌色块），公示卡按令牌。
    func testAboutDarkValues() async throws {
        let image = try await openAbout(canvas: Canvas(height: 900, dark: true), waitFor: "about.filing.card")
        let icon = try rect("about.icon")
        assertFill(image, CGRect(x: icon.minX + 20, y: icon.minY + 2, width: 40, height: 6), Judge.hex("#C44820"),
                   "图标不随深色变", tolerance: 8)
        let card = try rect("about.filing.card")
        assertFill(image, CGRect(x: card.maxX - 12, y: card.minY + 4, width: 8, height: 6), Judge.hex("#24211E"), "卡片")
        XCTAssertGreaterThan(count(image, in: try rect("about.filing.text"), near: Judge.hex("#F2EEE6")), 20, "正文主文字")
    }

    /// CsWechatMissingDark：半屏 #24211E（系统 `.sheet` 默认底不是令牌，页面要自己铺）、图标块 #2F2B27 / #B5ACA2、提示条 #2F2B27 / #F2EEE6。
    func testCsDarkValues() async throws {
        let image = try await openCs("cs_wechat_missing", canvas: Canvas(height: 620, dark: true, top: 0),
                                     waitFor: "cs.safety.text")
        let panel = try rect("cs.panel")
        assertFill(image, CGRect(x: panel.minX + 2, y: panel.minY + 40, width: 8, height: 16), Judge.hex("#24211E"),
                   "半屏底（令牌，不是系统底）")
        let badge = try rect("cs.badge")
        let top = CGRect(x: badge.minX + 20, y: badge.minY + 3, width: 16, height: 6)
        assertFill(image, top, Judge.hex("#2F2B27"), "图标块")
        XCTAssertGreaterThan(count(image, in: try rect("cs.badge.icon"), near: Judge.hex("#B5ACA2")), 10, "图标次文字色")
        let bar = try rect("cs.safety.bar")
        assertFill(image, CGRect(x: bar.maxX - 10, y: bar.midY - 5, width: 6, height: 10), Judge.hex("#2F2B27"), "提示条")
        XCTAssertGreaterThan(count(image, in: try rect("cs.safety.text"), near: Judge.hex("#F2EEE6")), 20, "提示文字")
    }

    /// 打不开半屏深色（无稿）：警告块 #33290F / #E3B65C。
    func testCsOpenFailedDark() async throws {
        let image = try await openCs("cs_open_failed", canvas: Canvas(height: 620, dark: true, top: 0),
                                     waitFor: "cs.badge.icon")
        let badge = try rect("cs.badge")
        let top = CGRect(x: badge.minX + 20, y: badge.minY + 3, width: 16, height: 6)
        assertFill(image, top, Judge.hex("#33290F"), "警告块")
        XCTAssertGreaterThan(count(image, in: try rect("cs.badge.icon"), near: Judge.hex("#E3B65C")), 10, "警告图标")
    }

    private func assertScrim(dark: Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        let ground = Judge.hex(dark ? "#171513" : "#F2EEE6")
        let expected = dark ? Judge.blend(Judge.hex("#000000"), opacity: 0x8C / 255, over: ground)
            : Judge.blend(Judge.hex("#28251F"), opacity: 0.4, over: ground)
        try await openPrivacy(Scene(canvas: Canvas(height: 1200, dark: dark)), file: file, line: line)
        try askWithdraw(file: file, line: line)
        let image = try await privacyFrame(file: file, line: line)
        assertFill(image, CGRect(x: 2, y: 300, width: 8, height: 40), expected, "遮罩 overlay.scrim", tolerance: 4,
                   file: file, line: line)
    }

    func testDialogScrimLight() async throws {
        try await assertScrim(dark: false)
    }

    func testDialogScrimDark() async throws {
        try await assertScrim(dark: true)
    }

    /// 对比度：警告块、次文字对卡片、链接色对半屏底，浅深各查。
    func testContrastPairs() {
        let pairs: [(name: String, colors: (Color, Color))] = [
            ("警告字对警告底", (CouliColor.statusWarningText, CouliColor.statusWarningBackground)),
            ("次文字对卡片", (CouliColor.textSecondary, CouliColor.backgroundSurface)),
            ("次文字对 muted", (CouliColor.textSecondary, CouliColor.backgroundMuted)),
            ("主文字对 muted", (CouliColor.textPrimary, CouliColor.backgroundMuted)),
            ("链接对卡片", (CouliColor.textLink, CouliColor.backgroundSurface)),
        ]
        for (name, colors) in pairs {
            for dark in [false, true] {
                let value = Judge.contrast(pixel(colors.0, dark: dark), pixel(colors.1, dark: dark))
                XCTAssertGreaterThanOrEqual(value, 4.5, "\(name)（\(dark ? "深" : "浅")）")
            }
        }
    }
}
