@testable import DesignSystem
import SwiftUI
import XCTest

/// V1 接线回归：真实 mapper → 商品卡的徽标区域必须含对应平台的 14pt 包内原图。
/// 中文名固定、价格不可用；留白、标题 / 价格差异和卡片其他区域的图片不能替代徽标原图。
@MainActor
final class PlatformBadgeCardWiringTests: XCTestCase {
    private typealias Bitmap = PlatformIconRenderSupport.Bitmap
    private let scale: CGFloat = 3
    private let iconPoints: CGFloat = 14
    // 徽标先由 ImageRenderer 光栅化，再作为 Text 附件画进卡片，允许两次采样的抗锯齿误差。
    // 只在 42×42px 图标块内计算 RGBA 平均误差，不能被整卡大面积相同背景稀释。
    private let maximumIconError: Double = 3

    func testListAndAgentCardsPassThePlatformCodeThroughToTheirBadge() throws {
        for layout in [ProductCardLayout.list, .agent] {
            for scheme in [ColorScheme.light, .dark] {
                for code in PlatformIconTestFixtures.requiredCodes {
                    let actual = try render(code: code, layout: layout, scheme: scheme)
                    let expected = try referenceIcon(code: code, scheme: scheme)
                    assertOfficialIcon(in: actual, expected: expected, context: "\(layout)/\(scheme)/\(code)")
                }
            }
        }
    }

    func testWiringAssertionRejectsHidingOnlyTheCardIconWhileKeepingItsSpace() throws {
        for layout in [ProductCardLayout.list, .agent] {
            for scheme in [ColorScheme.light, .dark] {
                let background = try badgeBackground(scheme: scheme)
                for code in PlatformIconTestFixtures.requiredCodes {
                    let context = "只隐藏卡片图标/\(layout)/\(scheme)/\(code)"
                    let actual = try render(code: code, layout: layout, scheme: scheme)
                    let expected = try referenceIcon(code: code, scheme: scheme)
                    // 正例必须先过；负例不能把产品本身的失败收作预期失败。
                    assertOfficialIcon(in: actual, expected: expected, context: context)
                    let position = bestIconMatch(in: actual, expected: expected)
                    // 仅在内存中的卡片位图擦除图标，保留卡片尺寸、徽标留白和所有区域外像素。
                    // 不改 PlatformIcon / PlatformBadge，也不影响独立 Rendering 测试。
                    let hidden = replacingIcon(in: actual, at: position, with: background)
                    assertRejectedIcon(in: hidden, expected: expected, context: context)
                }
            }
        }
    }

    func testWiringAssertionRejectsTaobaoIconPassedToAJDCard() throws {
        for layout in [ProductCardLayout.list, .agent] {
            for scheme in [ColorScheme.light, .dark] {
                let context = "京东卡误传淘宝编码/\(layout)/\(scheme)"
                let expected = try referenceIcon(code: "jd", scheme: scheme)
                let actual = try render(code: "jd", layout: layout, scheme: scheme)
                assertOfficialIcon(in: actual, expected: expected, context: context)
                // mapper 仍读取 jd，只在交给真实 ProductCard 前把 platformCode 改成 taobao。
                let wrongPlatform = try render(code: "jd", layout: layout, scheme: scheme, badgeCode: "taobao")
                let taobao = try referenceIcon(code: "taobao", scheme: scheme)
                assertOfficialIcon(in: wrongPlatform, expected: taobao, context: "负例确实显示淘宝/\(context)")
                assertRejectedIcon(in: wrongPlatform, expected: expected, context: context)
            }
        }
    }

    private func render(
        code: String, layout: ProductCardLayout, scheme: ColorScheme, badgeCode: String? = nil
    ) throws -> Bitmap {
        var data = ProductCardMapper.map([
            "platform": code, "title": "短标题", "rebate_basis": "no_rebate",
            "availability": "on_sale", "cta": ["text_key": "test.buy"],
        ], texts: { key in
            key.hasPrefix("platform.") ? "测试平台" : "测试文案"
        }, nowMillis: 0).data
        XCTAssertTrue(data.priceUnavailable, "测试前提：不渲染平台相关的价格口径")
        XCTAssertEqual(data.platformCode, code, "mapper 必须保留原始平台编码")
        if let badgeCode {
            data.platformCode = badgeCode
        }
        return try PlatformIconRenderSupport.bitmap(PlatformIconRenderSupport.render(
            ProductCard(data, layout: layout, onBuy: {}).frame(width: 320), scheme: scheme, scale: scale
        ))
    }

    private func referenceIcon(code: String, scheme: ColorScheme) throws -> Bitmap {
        // 独立读 Bundle.module 的原 PNG；参照不经过待测 PlatformIcon / PlatformBadge / BadgedTitle。
        let source = try PlatformIconTestFixtures.image(code: code)
        let icon = try PlatformIconRenderSupport.bitmap(PlatformIconRenderSupport.render(
            Image(uiImage: source).renderingMode(.original).resizable().scaledToFit()
                .frame(width: iconPoints, height: iconPoints)
                .background(CouliColor.token("source.background")), scheme: scheme, scale: scale
        ))
        XCTAssertEqual(icon.width, 42)
        XCTAssertEqual(icon.height, 42)
        return icon
    }

    private struct IconMatch {
        let error: Double
        let xOffset: Int
        let yOffset: Int
    }

    private func bestIconMatch(in actual: Bitmap, expected: Bitmap) -> IconMatch {
        // 列表 / Agent 的标题位于「卡片内边距 + 商品图 + 间距」之后，图标距徽标左缘 4pt。
        // 横向只放宽 ±2 个物理像素；纵向限首行徽标，兼容 Text 附件的基线对齐。
        // 不扫描整卡，商品图、按钮或正文里的相似图不能让断言通过。
        let iconLeft = Int((CouliSpacing.s3 + CouliGuideMetric.listImage + CouliSpacing.s3 + CouliSpacing.s1) * scale)
        let firstRowTop = Int(CouliSpacing.s3 * scale) - 2
        let firstRowBottom = Int((CouliSpacing.s3 + CouliGuideMetric.badgeMinHeight) * scale)
        var best = IconMatch(error: .infinity, xOffset: iconLeft, yOffset: firstRowTop)
        for xOffset in (iconLeft - 2)...(iconLeft + 2) {
            for yOffset in firstRowTop...firstRowBottom {
                let error = actual.error(against: expected, xOffset: xOffset, yOffset: yOffset)
                if error < best.error {
                    best = IconMatch(error: error, xOffset: xOffset, yOffset: yOffset)
                }
            }
        }
        return best
    }

    private func assertOfficialIcon(
        in actual: Bitmap, expected: Bitmap, context: String,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        let match = bestIconMatch(in: actual, expected: expected)
        XCTAssertLessThanOrEqual(
            match.error, maximumIconError,
            "卡片徽标必须含对应平台原图：\(context)，14pt 块 RGBA 平均误差 \(match.error)/255，"
                + "最佳位置 (\(match.xOffset), \(match.yOffset))；隐藏、留白或传错平台都应失败",
            file: file, line: line
        )
    }

    private func assertRejectedIcon(in actual: Bitmap, expected: Bitmap, context: String) {
        let options = XCTExpectedFailure.Options()
        options.isStrict = true
        options.issueMatcher = { issue in
            issue.type == .assertionFailure && issue.compactDescription.contains("卡片徽标必须含对应平台原图")
        }
        // 使用正例的同一个断言；若退回「整卡有差异」或容差放到能接受错图，这里因没有预期失败而红。
        XCTExpectFailure(context, options: options) {
            self.assertOfficialIcon(in: actual, expected: expected, context: context)
        }
    }

    private func badgeBackground(scheme: ColorScheme) throws -> Bitmap {
        try PlatformIconRenderSupport.bitmap(PlatformIconRenderSupport.render(
            Rectangle().fill(CouliColor.token("source.background"))
                .frame(width: iconPoints, height: iconPoints), scheme: scheme, scale: scale
        ))
    }

    private func replacingIcon(in actual: Bitmap, at position: IconMatch, with replacement: Bitmap) -> Bitmap {
        var bytes = actual.bytes
        for row in 0..<replacement.height {
            let start = ((position.yOffset + row) * actual.width + position.xOffset) * 4
            let sourceStart = row * replacement.width * 4
            bytes.replaceSubrange(
                start..<(start + replacement.width * 4),
                with: replacement.bytes[sourceStart..<(sourceStart + replacement.width * 4)]
            )
        }
        return Bitmap(width: actual.width, height: actual.height, bytes: bytes)
    }
}
