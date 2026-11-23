import DesignSystem
import SwiftUI
import UIKit
import XCTest

/// FU-IOS-LOGIN-LOGO（D10-2762）资源用例：应用图标式 Logo `CouliLogoVariant.appIcon`（图片集 logo-app-icon）。
/// 规格来源：规划仓库 design/app-icon——Any 外观 icon-default.svg（#C44820 满底 + 白主体），深色外观同一张（D10-2762：Login-v2 深色稿仍是狸橙底 + 白图形，画稿优先）；
/// 画布 1024 × 1024，宽高比 1。圆角由组件按变体裁剪，资源本身是满底方形，所以角上像素就是底色。
/// 对照：透明底主图形 `.mark` 的同一角是透明，证明两种变体确实是不同的图。
/// 圆角（独立评审 r1 S3）：`cornerRadiusRatio` 钉 12 / 56，组件渲染 56×56 后按 r=12 连续圆角取样，源码钉 style: .continuous。
/// a5ee63d 上 `.appIcon` 不存在，本文件编译即红（整个 AppTests 目标随之编译不过）。
final class LoginBrandLogoAssetTests: XCTestCase {
    private struct RGBA {
        let red: Int, green: Int, blue: Int, alpha: Int
    }

    /// 组件视图上的取样点（pt，左上为原点）与取这个点的理由。
    private struct CornerProbe {
        let ptX: Double, ptY: Double, why: String
    }

    private static let side = 64
    /// 组件渲染倍率：56pt × 4 = 224px，每像素 0.25pt，取样点按 pt 换算到像素（向下取整，像素覆盖 [pt, pt + 0.25]）。
    private static let viewScale = 4
    private static let viewSide = 56
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

    func testCornerRadiusRatioPinsTwelveOverFiftySix() throws {
        let ratio = try XCTUnwrap(CouliLogoVariant.appIcon.cornerRadiusRatio, "appIcon 要按比例裁圆角")
        XCTAssertEqual(ratio, 12.0 / 56.0, accuracy: 1e-9, "Login-v2 稿 app_icon(s=56, r=12)：圆角 = 12 / 56 边长")
        XCTAssertNil(CouliLogoVariant.mark.cornerRadiusRatio, "透明底主图形不裁圆角")
        XCTAssertNil(CouliLogoVariant.horizontal.cornerRadiusRatio, "横向组合不裁圆角")
    }

    /// 把 `CouliLogo(.appIcon).frame(width: 56, height: 56)` 渲染成位图，按 r=12 连续圆角（SwiftUI
    /// `RoundedRectangle(cornerRadius: 12, style: .continuous)`）的边界取样。资源本身是满底方形（见上面角上取色），
    /// 所以角上透明只可能来自组件的裁剪。
    ///
    /// 边界数据：在宿主（macOS）上用同一个 SwiftUI 形状、同为 4 倍栅格化量得——
    /// 对角线 (t, t) 在 r=10 / 11 / 12 / 13 / 14 时分别约从 t = 3.0 / 3.25 / 3.5 / 3.75 / 4.25 起进入形状；
    /// 上边沿 y≈0.5 一行在 r=12 时约从 x = 9.0 起不透明（像素 (9.0, 0.5) α≈248，抗锯齿边），r=13 约 9.5，r=14 约 10.0。
    /// 取样点都离 r=12 边界至少 0.5pt（2 个像素），留出抗锯齿余量；透明判 α ≤ 10，不透明判 #C44820 ±3、α≈255。
    /// 注：评审建议的 (5,5) 在 r=12 时其实在形状内（连续圆角对角线 3.5pt 起就不透明），这里改按实测边界取点，(5,5) 判不透明。
    /// 连续 / 普通圆角在 r=12、56 边长时栅格化差不到 1 个整像素，像素钉不住样式，样式另由下一条源码守卫钉。
    @MainActor
    func testAppIconLogoViewClipsTwelvePointContinuousCorner() throws {
        let bitmap = try renderLogoView()
        let transparent: [CornerProbe] = [
            CornerProbe(ptX: 0.5, ptY: 0.5, why: "最角上，有圆角就被裁掉（r=0 时这里是底色）"),
            CornerProbe(ptX: 3.0, ptY: 3.0, why: "对角线内侧，r=12 时 3.5pt 起才进形状；r=10 时这里已是底色"),
            CornerProbe(ptX: 7.5, ptY: 0.5, why: "上边沿，r=12 约 9pt 起才不透明；r=10 时满、r=11 时半透明"),
            CornerProbe(ptX: 0.5, ptY: 7.5, why: "左边沿，与上边沿对称"),
        ]
        for probe in transparent {
            let pixel = viewPixel(in: bitmap, ptX: probe.ptX, ptY: probe.ptY)
            XCTAssertLessThanOrEqual(pixel.alpha, 10,
                                     "(\(probe.ptX),\(probe.ptY)) 应被 r=12 圆角裁掉：\(probe.why)；实得 \(describe(pixel))")
        }
        let opaque: [CornerProbe] = [
            CornerProbe(ptX: 12.0, ptY: 12.0, why: "圆角圆心附近，必是底色"),
            CornerProbe(ptX: 5.0, ptY: 5.0, why: "对角线 3.5pt 内侧 1.5pt；r≥18 才会被裁"),
            CornerProbe(ptX: 9.5, ptY: 0.5, why: "上边沿，r=12 边界内约 0.5pt；r=13 时半透明、r≥14 时透明"),
            CornerProbe(ptX: 0.5, ptY: 9.5, why: "左边沿，与上边沿对称"),
        ]
        for probe in opaque {
            let pixel = viewPixel(in: bitmap, ptX: probe.ptX, ptY: probe.ptY)
            XCTAssertTrue(matches(pixel, Self.lightBackground),
                          "(\(probe.ptX),\(probe.ptY)) 应是 #C44820 底色：\(probe.why)；实得 \(describe(pixel))")
        }
    }

    /// 圆角样式：组件里按变体裁的是连续圆角（style: .continuous），不是普通圆角，也不是 `.cornerRadius(_:)`。去注释后匹配。
    func testLogoCornerShapeUsesContinuousStyle() throws {
        let file = try repositoryRoot()
            .appendingPathComponent("Packages/DesignSystem/Sources/DesignSystem/Components/CouliLogo.swift")
        let code = ShellSystemTabBarSourceTests.stripComments(try String(contentsOf: file, encoding: .utf8))
        XCTAssertNotNil(
            code.range(of: #"RoundedRectangle\(\s*cornerRadius:[^\n]*style:\s*\.continuous\s*\)"#,
                       options: .regularExpression),
            "CouliLogo 的圆角要用 RoundedRectangle(cornerRadius:style: .continuous)"
        )
        XCTAssertNil(code.range(of: #"\.circular\b"#, options: .regularExpression), "不得用普通圆角 .circular")
        XCTAssertNil(code.range(of: #"\.cornerRadius\("#, options: .regularExpression), "不得用 .cornerRadius(_:)（普通圆角）")
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

    /// 组件视图按 4 倍渲染，再画进 224×224 sRGB RGBA 位图（预乘 alpha；位图第 0 行是图的上边）。
    @MainActor
    private func renderLogoView() throws -> [UInt8] {
        let content = CouliLogo(.appIcon)
            .frame(width: CGFloat(Self.viewSide), height: CGFloat(Self.viewSide))
            .environment(\.colorScheme, .light)
        let renderer = ImageRenderer(content: content)
        renderer.scale = CGFloat(Self.viewScale)
        renderer.isOpaque = false
        let image = try XCTUnwrap(renderer.cgImage, "ImageRenderer 出不了 CouliLogo(.appIcon) 的图")
        let side = Self.viewSide * Self.viewScale
        XCTAssertEqual(image.width, side, "渲染宽应是 56pt × 4")
        XCTAssertEqual(image.height, side, "渲染高应是 56pt × 4")
        var bytes = [UInt8](repeating: 0, count: side * side * 4)
        let colorSpace = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        try bytes.withUnsafeMutableBytes { raw in
            let context = try XCTUnwrap(CGContext(
                data: raw.baseAddress, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ))
            context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
        }
        return bytes
    }

    /// 点 (ptX, ptY)（pt，左上为原点）所在的像素。
    private func viewPixel(in bytes: [UInt8], ptX: Double, ptY: Double) -> RGBA {
        let side = Self.viewSide * Self.viewScale
        let column = min(Int(ptX * Double(Self.viewScale)), side - 1)
        let row = min(Int(ptY * Double(Self.viewScale)), side - 1)
        let index = (row * side + column) * 4
        return RGBA(red: Int(bytes[index]), green: Int(bytes[index + 1]), blue: Int(bytes[index + 2]),
                    alpha: Int(bytes[index + 3]))
    }

    private func repositoryRoot() throws -> URL {
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while !FileManager.default.fileExists(atPath: directory.appendingPathComponent("contract.lock").path) {
            let parent = directory.deletingLastPathComponent()
            guard parent.path != directory.path else { throw XCTSkip("找不到仓库根（contract.lock）") }
            directory = parent
        }
        return directory
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
