@testable import DesignSystem
import UIKit
import XCTest

/// BRAND-01：Logo 资源在本包里能按浅 / 深取到，深色是反白版；取样点坐标按 SVG 原画布（viewBox）换算。
final class CouliLogoTests: XCTestCase {
    private struct RGBA: Equatable {
        let red: UInt8, green: UInt8, blue: UInt8, alpha: UInt8
    }

    private static let brand = RGBA(red: 0xC4, green: 0x48, blue: 0x20, alpha: 0xFF)
    private static let ink = RGBA(red: 0x28, green: 0x25, blue: 0x1F, alpha: 0xFF)
    private static let white = RGBA(red: 0xFF, green: 0xFF, blue: 0xFF, alpha: 0xFF)

    func testEveryVariantHasLightAndDarkImage() {
        for variant in CouliLogoVariant.allCases {
            for dark in [false, true] {
                let image = variant.uiImage(dark: dark)
                XCTAssertNotNil(image, "\(variant.assetName) dark=\(dark) 取不到")
                guard let image else { continue }
                XCTAssertEqual(image.size.width / image.size.height, variant.aspectRatio, accuracy: 0.01,
                               "\(variant.assetName) 宽高比应与 SVG 画布一致")
            }
        }
    }

    func testMarkIsBrandColorInLightAndInverseInDark() throws {
        // (55,150)、(120,90) 在图形主体内，(128,128) 是 C 形中间的透明处（256 画布）。
        let light = try render(.mark, dark: false)
        XCTAssertTrue(close(light.pixel(55, 150), Self.brand))
        XCTAssertTrue(close(light.pixel(120, 90), Self.brand))
        XCTAssertEqual(light.pixel(128, 128).alpha, 0)

        let dark = try render(.mark, dark: true)
        XCTAssertTrue(close(dark.pixel(55, 150), Self.white))
        XCTAssertTrue(close(dark.pixel(120, 90), Self.white))
        XCTAssertEqual(dark.pixel(128, 128).alpha, 0)
    }

    func testHorizontalWordmarkIsInkInLightAndInverseInDark() throws {
        // (55,150) 在图形内，(320,128) 在字标笔画内（580 × 256 画布）。
        let light = try render(.horizontal, dark: false)
        XCTAssertTrue(close(light.pixel(55, 150), Self.brand))
        XCTAssertTrue(close(light.pixel(320, 128), Self.ink))

        let dark = try render(.horizontal, dark: true)
        XCTAssertTrue(close(dark.pixel(55, 150), Self.white))
        XCTAssertTrue(close(dark.pixel(320, 128), Self.white))
    }

    // MARK: - 渲染与取样

    private struct Bitmap {
        let width: Int
        let bytes: [UInt8]

        func pixel(_ px: Int, _ py: Int) -> RGBA {
            let idx = (py * width + px) * 4
            return RGBA(red: bytes[idx], green: bytes[idx + 1], blue: bytes[idx + 2], alpha: bytes[idx + 3])
        }
    }

    /// 按原画布尺寸（1 倍）把对应外观的图画进 RGBA 位图。
    private func render(_ variant: CouliLogoVariant, dark: Bool) throws -> Bitmap {
        let image = try XCTUnwrap(variant.uiImage(dark: dark))
        let height = 256
        let width = Int((CGFloat(height) * variant.aspectRatio).rounded())
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let traits = UITraitCollection(userInterfaceStyle: dark ? .dark : .light)
        try bytes.withUnsafeMutableBytes { raw in
            let context = try XCTUnwrap(CGContext(
                data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ))
            context.translateBy(x: 0, y: CGFloat(height))
            context.scaleBy(x: 1, y: -1)
            traits.performAsCurrent {
                UIGraphicsPushContext(context)
                image.draw(in: CGRect(x: 0, y: 0, width: width, height: height))
                UIGraphicsPopContext()
            }
        }
        return Bitmap(width: width, bytes: bytes)
    }

    /// 抗锯齿与色彩管理允许的小偏差。
    private func close(_ lhs: RGBA, _ rhs: RGBA, tolerance: Int = 6) -> Bool {
        abs(Int(lhs.red) - Int(rhs.red)) <= tolerance && abs(Int(lhs.green) - Int(rhs.green)) <= tolerance
            && abs(Int(lhs.blue) - Int(rhs.blue)) <= tolerance && abs(Int(lhs.alpha) - Int(rhs.alpha)) <= tolerance
    }
}
