@testable import DesignSystem
import Generated
import SwiftUI
import UIKit
import XCTest

/// DS-02-iOS-1（brief §3.4、§3.5、§3.7）：深色值改读生成物 `DesignTokens.colorsDark`。被测对象是 `CouliColor.token()`、语义名与
/// `CouliScrim`，期望值用本文件自带的 #RRGGBB(AA) 解析（按 CSS 顺序 RGBA，不经 TokenRGB），换位或丢 alpha 都会红。
final class TokenDarkResolutionTests: XCTestCase {
    struct RGBA: Equatable, CustomStringConvertible {
        let red: Double
        let green: Double
        let blue: Double
        let alpha: Double

        var description: String {
            String(format: "rgba(%.0f, %.0f, %.0f, %.3f)", red * 255, green * 255, blue * 255, alpha)
        }

        func isClose(to other: RGBA) -> Bool {
            let limit = 1.0 / 255 + 1e-6
            return abs(red - other.red) <= limit && abs(green - other.green) <= limit
                && abs(blue - other.blue) <= limit && abs(alpha - other.alpha) <= limit
        }
    }

    /// 独立参照：CSS 顺序 #RRGGBB 或 #RRGGBBAA。
    static func expected(_ hex: String) -> RGBA? {
        let digits = Array(hex.dropFirst())
        guard hex.hasPrefix("#"), digits.count == 6 || digits.count == 8 else { return nil }
        func channel(_ index: Int) -> Double? {
            UInt8(String(digits[index * 2...index * 2 + 1]), radix: 16).map { Double($0) / 255 }
        }
        guard let red = channel(0), let green = channel(1), let blue = channel(2) else { return nil }
        let alpha = digits.count == 8 ? channel(3) : 1
        return alpha.map { RGBA(red: red, green: green, blue: blue, alpha: $0) }
    }

    static func resolve(_ color: Color, dark: Bool) -> RGBA {
        let trait = UITraitCollection(userInterfaceStyle: dark ? .dark : .light)
        let resolved = UIColor(color).resolvedColor(with: trait)
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        resolved.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        return RGBA(red: Double(red), green: Double(green), blue: Double(blue), alpha: Double(alpha))
    }

    private func assertResolves(
        _ color: Color, light: String, dark: String, _ context: String,
        file: StaticString = #filePath, line: UInt = #line
    ) throws {
        for (isDark, hex) in [(false, light), (true, dark)] {
            let want = try XCTUnwrap(Self.expected(hex), "\(context)：\(hex) 不是合法色值", file: file, line: line)
            let got = Self.resolve(color, dark: isDark)
            XCTAssertTrue(got.isClose(to: want), "\(context)（\(isDark ? "深" : "浅")）应为 \(hex) = \(want)，实际 \(got)",
                          file: file, line: line)
        }
    }

    private func tokenPair(_ path: String) throws -> (light: String, dark: String) {
        (try XCTUnwrap(DesignTokens.colors[path], "colors 缺 \(path)"),
         try XCTUnwrap(DesignTokens.colorsDark[path], "colorsDark 缺 \(path)"))
    }

    // MARK: - TokenRGB

    /// brief §3.7：8 位按 CSS 顺序 RGBA 读（#28251F66 → alpha 0.4），不换成 ARGB；6 位 alpha = 1；旧的非法输入仍为 nil。
    func testTokenRGBParsesEightDigitsInCSSOrder() throws {
        let scrim = try XCTUnwrap(TokenRGB(hex: "#28251F66"), "8 位色必须能解析")
        XCTAssertEqual(scrim.red, 0x28 / 255.0, accuracy: 1e-9, "R 取第 1–2 位")
        XCTAssertEqual(scrim.green, 0x25 / 255.0, accuracy: 1e-9)
        XCTAssertEqual(scrim.blue, 0x1F / 255.0, accuracy: 1e-9)
        XCTAssertEqual(scrim.alpha, 0x66 / 255.0, accuracy: 1e-9, "A 取末两位（0x66 / 255 = 0.4）")
        XCTAssertEqual(scrim.alpha, 0.4, accuracy: 1e-9)
        let black = try XCTUnwrap(TokenRGB(hex: "#0000008c"), "小写 8 位")
        XCTAssertEqual(black.red, 0)
        XCTAssertEqual(black.alpha, 0x8C / 255.0, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(TokenRGB(hex: "#C44820")).alpha, 1, "6 位不透明")
        XCTAssertNotEqual(TokenRGB(hex: "#28251F66"), TokenRGB(hex: "#28251F"), "alpha 参与相等比较")
        for bad in ["#FFF", "#GG0000", "#12345", "#1234567", "#123456789", "#GG000000", "", "#"] {
            XCTAssertNil(TokenRGB(hex: bad), "\(bad) 应解析失败")
        }
    }

    /// `color` / `uiColor` 带上 alpha（遮罩、主图浮层底都靠它）。
    func testTokenRGBColorsCarryAlpha() throws {
        let rgb = try XCTUnwrap(TokenRGB(hex: "#28251F66"))
        let want = try XCTUnwrap(Self.expected("#28251F66"))
        XCTAssertTrue(Self.resolve(rgb.color, dark: false).isClose(to: want), "color 丢了 alpha")
        XCTAssertTrue(Self.resolve(Color(rgb.uiColor), dark: false).isClose(to: want), "uiColor 丢了 alpha")
    }

    // MARK: - CouliColor.token

    /// brief §3.4：每一个颜色令牌经 `CouliColor.token(path)` 浅色 = colors、深色 = colorsDark（误差 ≤ 1/255，含 alpha）。
    func testEveryColorTokenResolvesPerAppearance() throws {
        XCTAssertGreaterThanOrEqual(DesignTokens.colors.count, 49)
        for path in DesignTokens.colors.keys.sorted() {
            let pair = try tokenPair(path)
            try assertResolves(CouliColor.token(path), light: pair.light, dark: pair.dark, "token(\(path))")
        }
    }

    /// 必须覆盖：文字、背景、品牌、错误、遮罩（含 alpha）、platform.tag.*、此前锁里缺浅色的 5 条（不得返回 .clear）。
    func testRequiredGroupsAreCoveredAndNeverClear() throws {
        let required = [
            "text.primary", "text.secondary", "background.canvas", "background.surface", "brand.primary",
            "brand.emphasis", "status.error.text", "status.error.background", "overlay.scrim", "overlay.on-image",
            "platform.tag.taobao", "platform.tag.tmall", "platform.tag.jd", "platform.tag.pdd",
            "border.active", "button.inverse.background", "button.inverse.text", "control.checked", "badge.background",
        ]
        for path in required {
            let pair = try tokenPair(path)
            try assertResolves(CouliColor.token(path), light: pair.light, dark: pair.dark, "token(\(path))")
            XCTAssertGreaterThan(Self.resolve(CouliColor.token(path), dark: true).alpha, 0.5, "\(path) 深色不得是 .clear")
        }
        // 浅深不同的点检（源：f088f04）：深色分支读错表会在这里红。
        try assertResolves(CouliColor.token("brand.emphasis"), light: "#A83B1F", dark: "#F0956B", "brand.emphasis")
        try assertResolves(CouliColor.token("border.active"), light: "#28251F", dark: "#F2EEE6", "border.active")
        try assertResolves(CouliColor.token("overlay.scrim"), light: "#28251F66", dark: "#0000008C", "overlay.scrim")
    }

    /// 语义名（三端对齐名）逐个对生成物；`usedPaths` 恰好是这些语义名的路径（TODO 删除后 status.*.background、border.active 并入）。
    func testSemanticNamesFollowGeneratedTables() throws {
        let semantic: [(Color, String)] = [
            (CouliColor.brandPrimary, "brand.primary"), (CouliColor.brandEmphasis, "brand.emphasis"),
            (CouliColor.brandSecondary, "brand.secondary"), (CouliColor.brandSubtle, "brand.subtle"),
            (CouliColor.backgroundCanvas, "background.canvas"), (CouliColor.backgroundSurface, "background.surface"),
            (CouliColor.backgroundMuted, "background.muted"), (
                CouliColor.backgroundPlaceholder,
                "background.placeholder"
            ),
            (CouliColor.textPrimary, "text.primary"), (CouliColor.textSecondary, "text.secondary"),
            (CouliColor.textInverse, "text.inverse"), (CouliColor.textLink, "text.link"),
            (CouliColor.priceText, "price.text"), (CouliColor.rebateText, "rebate.text"),
            (CouliColor.rebateBackground, "rebate.background"),
            (CouliColor.statusSuccessText, "status.success.text"), (
                CouliColor.statusWarningText,
                "status.warning.text"
            ),
            (CouliColor.statusErrorText, "status.error.text"),
            (CouliColor.statusSuccessBackground, "status.success.background"),
            (CouliColor.statusWarningBackground, "status.warning.background"),
            (CouliColor.borderSubtle, "border.subtle"), (CouliColor.borderControl, "border.control"),
            (CouliColor.borderActive, "border.active"), (CouliColor.focusRing, "focus.ring"),
        ]
        for (color, path) in semantic {
            let pair = try tokenPair(path)
            try assertResolves(color, light: pair.light, dark: pair.dark, "语义名 \(path)")
        }
        XCTAssertEqual(Set(CouliColor.usedPaths), Set(semantic.map(\.1)), "usedPaths 应恰为全部语义名的路径")
        XCTAssertEqual(CouliColor.usedPaths.count, Set(CouliColor.usedPaths).count, "usedPaths 不重复")
    }

    /// 颜色取用随外观切换更新（鸿蒙 R1 教训，brief §5-2）：同一个已存好的 Color 交替按浅 / 深解析，每次都跟着变。
    func testStoredColorsFollowAppearanceEveryTime() throws {
        let stored: [(Color, String)] = [
            (CouliColor.backgroundSurface, "background.surface"), (CouliColor.brandSubtle, "brand.subtle"),
            (CouliColor.token("text.primary"), "text.primary"), (CouliScrim.color, "overlay.scrim"),
        ]
        for (color, path) in stored {
            let pair = try tokenPair(path)
            XCTAssertNotEqual(pair.light, pair.dark, "\(path) 应浅深不同，才能证明随外观切换")
            for round in 0..<3 {
                try assertResolves(color, light: pair.light, dark: pair.dark, "\(path) 第 \(round + 1) 轮")
            }
        }
    }

    // MARK: - CouliScrim

    /// brief §3.5：遮罩读 overlay.scrim——浅色墨棕 alpha 0x66/255，深色纯黑 alpha 0x8C/255（不是深色主文字色）。
    func testScrimReadsOverlayScrimToken() throws {
        let pair = try tokenPair("overlay.scrim")
        try assertResolves(CouliScrim.color, light: pair.light, dark: pair.dark, "CouliScrim.color")
        let dark = Self.resolve(CouliScrim.color, dark: true)
        XCTAssertEqual(dark.red, 0, accuracy: 1e-6, "深色遮罩是黑，不是 text.primary 的深色值")
        XCTAssertEqual(dark.alpha, 0x8C / 255.0, accuracy: 1.0 / 255)
        let light = Self.resolve(CouliScrim.color, dark: false)
        XCTAssertEqual(light.red, 0x28 / 255.0, accuracy: 1.0 / 255)
        XCTAssertEqual(light.alpha, 0x66 / 255.0, accuracy: 1.0 / 255)
        XCTAssertEqual(CouliScrim.opacity, 0x66 / 255.0, accuracy: 1e-9, "公开名 opacity 保留，值由令牌 alpha 算出")
    }
}
