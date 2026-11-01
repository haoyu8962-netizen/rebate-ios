@testable import Couli
import DesignSystem
import Foundation
import SwiftUI
import UIKit
import XCTest

/// APP-12v 令牌（brief §2.13、§4.8）：页面底 / 卡片 / 主卡 / 【提现】白底浅深各查；深色主卡与卡内白底按钮不变；对比度按 03 §10.5（主卡白字对狸橙、
/// 引导条链接色对 muted 底重点查）。颜色按截图像素核对令牌，不看源码。
@MainActor
final class MeVisualPaletteTests: MeVisualTestCase {
    private func assertPalette(dark: Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        let (_, image) = try await open(
            Setup(canvas: .init(dark: dark)),
            waitFor: "me.hero.withdraw",
            file: file,
            line: line
        )
        let hero = try rect("me.hero", file: file, line: line)
        let identity = try rect("me.identity", file: file, line: line)
        let canvas = CGRect(x: 2, y: identity.midY - 8, width: 10, height: 16)
        XCTAssertGreaterThan(
            share(image, in: canvas, near: pixel(CouliColor.backgroundCanvas, dark: dark), tolerance: 3),
            0.9,
            "页面底",
            file: file,
            line: line
        )
        let inside = CGRect(x: identity.maxX - 20, y: identity.minY + 6, width: 12, height: 8)
        XCTAssertGreaterThan(
            share(image, in: inside, near: pixel(CouliColor.backgroundSurface, dark: dark), tolerance: 3),
            0.9,
            "卡片底",
            file: file,
            line: line
        )
        let solid = pixel(CouliColor.token("rebate.solid.background"), dark: dark)
        let edge = CGRect(x: hero.minX + 4, y: hero.midY - 8, width: 10, height: 16)
        XCTAssertGreaterThan(share(image, in: edge, near: solid, tolerance: 4), 0.9, "主卡狸橙实底", file: file, line: line)
        let button = try rect("me.hero.withdraw", file: file, line: line)
        let fill = CGRect(x: button.minX + 10, y: button.midY - 4, width: 10, height: 8)
        XCTAssertGreaterThan(
            share(image, in: fill, near: pixel(CouliColor.token("rebate.solid.text"), dark: dark),
                  tolerance: 4),
            0.9,
            "【提现】白底",
            file: file,
            line: line
        )
        let amount = try rect("me.hero.amount", file: file, line: line)
        XCTAssertGreaterThan(
            count(image, in: amount, near: pixel(CouliColor.token("rebate.solid.text"), dark: dark)),
            40,
            "大数白字",
            file: file,
            line: line
        )
        let name = try rect("me.nickname", file: file, line: line)
        XCTAssertGreaterThan(count(image, in: name, near: pixel(CouliColor.textPrimary, dark: dark)), 20, "昵称主文字色",
                             file: file, line: line)
    }

    func testPaletteLight() async throws {
        try await assertPalette(dark: false)
    }

    /// MeDark：主卡狸橙与卡内白底按钮按令牌不变，其余跟 dark 令牌。
    func testPaletteDark() async throws {
        try await assertPalette(dark: true)
    }

    /// 深色引导条：muted 底（#36312C）、链接色走 dark 令牌。
    func testGuideBarDark() async throws {
        let (_, image) = try await open(Setup(canvas: .init(dark: true), hidden: true, guide: true),
                                        waitFor: "me.guideBar.cta")
        let bar = try rect("me.guideBar")
        let edge = CGRect(x: bar.minX + 2, y: bar.midY - 8, width: 6, height: 16)
        XCTAssertGreaterThan(
            share(image, in: edge, near: pixel(CouliColor.backgroundMuted, dark: true), tolerance: 3),
            0.8
        )
        XCTAssertGreaterThan(
            count(image, in: try rect("me.guideBar.cta"), near: pixel(CouliColor.textLink, dark: true)),
            20
        )
    }

    /// 对比度：令牌组合本身，浅深各查（现状已符合、加守卫：令牌换值时这里先红）。
    func testContrastPairs() {
        let pairs: [(name: String, colors: (Color, Color))] = [
            ("主卡白字对狸橙", (CouliColor.token("rebate.solid.text"), CouliColor.token("rebate.solid.background"))),
            ("引导条链接色对 muted", (CouliColor.textLink, CouliColor.backgroundMuted)),
            ("引导条正文对 muted", (CouliColor.textPrimary, CouliColor.backgroundMuted)),
            ("次文字对卡片", (CouliColor.textSecondary, CouliColor.backgroundSurface)),
            ("复制图标对卡片", (CouliColor.textLink, CouliColor.backgroundSurface)),
        ]
        for dark in [false, true] {
            for (name, colors) in pairs {
                let ratio = Self.contrast(pixel(colors.0, dark: dark), pixel(colors.1, dark: dark))
                XCTAssertGreaterThanOrEqual(ratio, 4.5, "\(name)（\(dark ? "深" : "浅")）对比度 \(ratio)")
            }
        }
    }

    private static func contrast(_ lhs: ProductVisualPixels.RGB, _ rhs: ProductVisualPixels.RGB) -> Double {
        func luminance(_ color: ProductVisualPixels.RGB) -> Double {
            func channel(_ value: Int) -> Double {
                let unit = Double(value) / 255
                return unit <= 0.04045 ? unit / 12.92 : pow((unit + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * channel(color.red) + 0.7152 * channel(color.green) + 0.0722 * channel(color.blue)
        }
        let values = [luminance(lhs), luminance(rhs)].sorted()
        return (values[1] + 0.05) / (values[0] + 0.05)
    }
}
