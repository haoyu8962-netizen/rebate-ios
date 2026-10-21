@testable import DesignSystem
import SwiftUI
import XCTest

/// F-X-05a V1/V4/V5/V6。新接口见 tests-ios-handback.md §2；不写替代产品实现使测试假绿。
@MainActor
final class PlatformIconRenderingTests: XCTestCase {
    func testSizesAndOfficialPixelsAtBothSizesInLightAndDark() throws {
        XCTAssertEqual(PlatformIconSize.badge.points, 14)
        XCTAssertEqual(PlatformIconSize.grid.points, 44)
        for code in PlatformIconTestFixtures.requiredCodes {
            let source = try PlatformIconTestFixtures.image(code: code)
            for size in [PlatformIconSize.badge, .grid] {
                for scheme in [ColorScheme.light, .dark] {
                    let actual = try PlatformIconRenderSupport.render(
                        PlatformIcon(platformCode: code, size: size, remoteURL: nil), scheme: scheme
                    )
                    XCTAssertEqual(actual.size, CGSize(width: size.points, height: size.points))
                    let expected = try PlatformIconRenderSupport.render(
                        Image(uiImage: source).renderingMode(.original).resizable()
                            .scaledToFit().frame(width: size.points, height: size.points), scheme: scheme
                    )
                    try PlatformIconRenderSupport.assertSameImage(actual, expected)
                }
            }
        }
    }

    func testRemoteURLStillRendersBuiltinAndTintDoesNotRecolorIt() throws {
        let remote = try XCTUnwrap(URL(string: "https://platform-icon-test.invalid/never-load.png"))
        for code in PlatformIconTestFixtures.requiredCodes {
            for size in [PlatformIconSize.badge, .grid] {
                let builtin = try PlatformIconRenderSupport.render(PlatformIcon(platformCode: code, size: size))
                let remoteAndTinted = try PlatformIconRenderSupport.render(
                    PlatformIcon(platformCode: code, size: size, remoteURL: remote)
                        .foregroundStyle(.purple).tint(.green), scheme: .dark
                )
                try PlatformIconRenderSupport.assertSameImage(remoteAndTinted, builtin)
            }
        }
    }

    func testMissingAndUnknownCodesKeepTheExistingTextOnlyAppearance() throws {
        let codes = PlatformIconTestFixtures.missingCodes + ["future-shop", "", "__unknown__", "../taobao", "淘宝"]
        for code in codes {
            let name = code == "tmall" ? "天猫" : "测试平台"
            for scheme in [ColorScheme.light, .dark] {
                let actual = try PlatformIconRenderSupport.render(
                    PlatformBadge(name, platformCode: code), scheme: scheme
                )
                let expected = try PlatformIconRenderSupport.render(
                    PlatformIconRenderSupport.textBadge(name), scheme: scheme
                )
                try PlatformIconRenderSupport.assertSameImage(actual, expected)
            }
        }
        // 旧接口仍可调用；名称不是平台编码，不能根据中文名猜出素材。
        try PlatformIconRenderSupport.assertSameImage(
            PlatformIconRenderSupport.render(PlatformBadge("淘宝")),
            PlatformIconRenderSupport.render(PlatformIconRenderSupport.textBadge("淘宝"))
        )
    }

    func testBadgeContainsTheOfficial14PointImageOnTheLeftAndUsesSourceTokens() throws {
        for code in PlatformIconTestFixtures.requiredCodes {
            let name = try XCTUnwrap(PlatformIconTestFixtures.names[code])
            for scheme in [ColorScheme.light, .dark] {
                for typeSize in [DynamicTypeSize.large, .accessibility2] {
                    try assertBadge(code: code, name: name, scheme: scheme, typeSize: typeSize)
                }
            }
        }
    }

    private func assertBadge(code: String, name: String, scheme: ColorScheme, typeSize: DynamicTypeSize) throws {
        let source = try PlatformIconTestFixtures.image(code: code)
        let actual = try PlatformIconRenderSupport.render(
            PlatformBadge(name, platformCode: code), scheme: scheme, typeSize: typeSize
        )
        let textOnly = try PlatformIconRenderSupport.render(
            PlatformIconRenderSupport.textBadge(name), scheme: scheme, typeSize: typeSize
        )
        XCTAssertGreaterThanOrEqual(actual.size.width - textOnly.size.width, 14)
        XCTAssertLessThanOrEqual(actual.size.width - textOnly.size.width, 30, "不留多余占位")
        XCTAssertEqual(actual.size.height, textOnly.size.height, accuracy: 1)
        let bitmap = try PlatformIconRenderSupport.bitmap(actual)
        let icon = try PlatformIconRenderSupport.bitmap(PlatformIconRenderSupport.render(
            Image(uiImage: source).renderingMode(.original).resizable().scaledToFit()
                .frame(width: 14, height: 14).background(CouliColor.token("source.background")), scheme: scheme
        ))
        // 在左侧内边距范围找原图，允许间距 / 像素对齐的小差异，但不能放在文字右侧或改变图尺寸。
        let centerY = (bitmap.height - icon.height) / 2
        var bestError = Double.infinity
        for xOffset in 0...Int(CouliSpacing.s2 * 3 + 6) {
            for yOffset in (centerY - 2)...(centerY + 2) {
                bestError = min(bestError, bitmap.error(against: icon, xOffset: xOffset, yOffset: yOffset))
            }
        }
        XCTAssertLessThanOrEqual(bestError, 1, "\(code) 的 14pt 官方原图未出现在徽标左侧")
        for token in ["source.background", "source.border", "source.text"] {
            let swatch = try PlatformIconRenderSupport.bitmap(PlatformIconRenderSupport.render(
                Rectangle().fill(CouliColor.token(token)).frame(width: 1, height: 1), scheme: scheme
            ))
            XCTAssertGreaterThan(bitmap.countPixels(closeTo: Array(swatch.bytes.prefix(4))), 8, token)
        }
    }
}
