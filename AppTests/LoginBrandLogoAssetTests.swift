import DesignSystem
import UIKit
import XCTest

/// FU-IOS-LOGIN-LOGO（D10-2762）资源用例：应用图标式 Logo `CouliLogoVariant.appIcon`（图片集 logo-app-icon）。
/// 规格来源：规划仓库 design/app-icon——Any 外观 icon-default.svg（#C44820 满底 + 白主体），深色外观同一张（D10-2762：Login-v2 深色稿仍是狸橙底 + 白图形，画稿优先）；
/// 画布 1024 × 1024，宽高比 1。圆角由组件按变体裁剪，资源本身是满底方形，所以角上像素就是底色。
/// 对照：透明底主图形 `.mark` 的同一角是透明，证明两种变体确实是不同的图。
/// a5ee63d 上 `.appIcon` 不存在，本文件编译即红（整个 AppTests 目标随之编译不过）。
final class LoginBrandLogoAssetTests: XCTestCase {
    private struct RGBA {
        let red: Int, green: Int, blue: Int, alpha: Int
    }

    private static let side = 64
    private static let lightBackground = RGBA(red: 0xC4, green: 0x48, blue: 0x20, alpha: 0xFF)

    func testAppIconVariantContract() {
        XCTAssertEqual(CouliLogoVariant.appIcon.rawValue, "logo-app-icon")
        XCTAssertEqual(CouliLogoVariant.appIcon.assetName, "logo-app-icon")
        XCTAssertEqual(CouliLogoVariant.appIcon.aspectRatio, 1, accuracy: 0.0001)
        XCTAssertTrue(CouliLogoVariant.allCases.contains(.appIcon), "新变体要进 allCases，包内逐变体取图用例才覆盖得到")
    }

    func testAppIconHasSquareLightAndDarkImages() {
        for dark in [false, true] {
            let image = CouliLogoVariant.appIcon.uiImage(dark: dark)
            XCTAssertNotNil(image, "logo-app-icon dark=\(dark) 取不到")
            guard let image else { continue }
            XCTAssertGreaterThan(image.size.height, 0)
            XCTAssertEqual(image.size.width / max(image.size.height, 1), 1, accuracy: 0.01,
                           "logo-app-icon dark=\(dark) 应是方形（画布 1024 × 1024）")
        }
    }

    func testAppIconLightCornerIsBrandBackground() throws {
        let corner = try cornerSamples(.appIcon, dark: false)
        for (point, pixel) in corner {
            XCTAssertTrue(matches(pixel, Self.lightBackground),
                          "浅色 logo-app-icon 在 \(point) 应是 #C44820 满底，实得 \(describe(pixel))")
        }
    }

    func testAppIconDarkCornerStaysBrandBackground() throws {
        let corner = try cornerSamples(.appIcon, dark: true)
        for (point, pixel) in corner {
            XCTAssertTrue(matches(pixel, Self.lightBackground),
                          "深色 logo-app-icon 在 \(point) 仍应是 #C44820 满底（Login-v2 深色稿同浅色），实得 \(describe(pixel))")
        }
    }

    func testMarkLightCornerIsTransparentUnlikeAppIcon() throws {
        let corner = try cornerSamples(.mark, dark: false)
        for (point, pixel) in corner {
            XCTAssertLessThanOrEqual(pixel.alpha, 3, "透明底 logo-mark 在 \(point) 应透明，实得 \(describe(pixel))")
        }
    }

    // MARK: - 渲染与取样

    /// 左上角 (2,2) 附近 3 个点；64×64 位图上这里离 SVG 主体很远，只落在满底（或透明底）上。
    private func cornerSamples(_ variant: CouliLogoVariant, dark: Bool) throws -> [(String, RGBA)] {
        let bitmap = try renderBitmap(variant, dark: dark)
        return [(2, 2), (3, 2), (2, 3)].map { point in
            ("(\(point.0),\(point.1))", pixel(in: bitmap, px: point.0, py: point.1))
        }
    }

    /// 把对应外观的图画进 64×64 sRGB RGBA 位图（1 倍，预乘 alpha）。
    private func renderBitmap(_ variant: CouliLogoVariant, dark: Bool) throws -> [UInt8] {
        let image = try XCTUnwrap(variant.uiImage(dark: dark), "\(variant.assetName) dark=\(dark) 取不到")
        let side = Self.side
        var bytes = [UInt8](repeating: 0, count: side * side * 4)
        let colorSpace = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let traits = UITraitCollection(userInterfaceStyle: dark ? .dark : .light)
        try bytes.withUnsafeMutableBytes { raw in
            let context = try XCTUnwrap(CGContext(
                data: raw.baseAddress, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ))
            context.translateBy(x: 0, y: CGFloat(side))
            context.scaleBy(x: 1, y: -1)
            traits.performAsCurrent {
                UIGraphicsPushContext(context)
                image.draw(in: CGRect(x: 0, y: 0, width: side, height: side))
                UIGraphicsPopContext()
            }
        }
        return bytes
    }

    private func pixel(in bytes: [UInt8], px: Int, py: Int) -> RGBA {
        let index = (py * Self.side + px) * 4
        return RGBA(red: Int(bytes[index]), green: Int(bytes[index + 1]), blue: Int(bytes[index + 2]),
                    alpha: Int(bytes[index + 3]))
    }

    /// 容差 ±3（色彩管理与矢量栅格化的小偏差）。满底处 alpha 应为 255，预乘与否不影响取值。
    private func matches(_ lhs: RGBA, _ rhs: RGBA, tolerance: Int = 3) -> Bool {
        abs(lhs.red - rhs.red) <= tolerance && abs(lhs.green - rhs.green) <= tolerance
            && abs(lhs.blue - rhs.blue) <= tolerance && abs(lhs.alpha - rhs.alpha) <= tolerance
    }

    private func describe(_ pixel: RGBA) -> String {
        String(format: "#%02X%02X%02X α%d", pixel.red, pixel.green, pixel.blue, pixel.alpha)
    }
}
