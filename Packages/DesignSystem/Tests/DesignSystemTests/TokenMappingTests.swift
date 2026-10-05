@testable import DesignSystem
import Generated
import XCTest

final class TokenMappingTests: XCTestCase {
    func testHexConversion() throws {
        let rgb = try XCTUnwrap(TokenRGB(hex: "#C44820"))
        XCTAssertEqual(rgb.red, 196.0 / 255, accuracy: 1e-9)
        XCTAssertEqual(rgb.green, 72.0 / 255, accuracy: 1e-9)
        XCTAssertEqual(rgb.blue, 32.0 / 255, accuracy: 1e-9)
        XCTAssertEqual(TokenRGB(hex: "#ffffff"), TokenRGB(hex: "#FFFFFF"))
        XCTAssertNil(TokenRGB(hex: "#FFF"))
        XCTAssertNil(TokenRGB(hex: "#GG0000"))
    }

    func testSemanticColorsResolveFromTokens() throws {
        for path in CouliColor.usedPaths {
            let hex = try XCTUnwrap(DesignTokens.colors[path], "missing token \(path)")
            XCTAssertEqual(TokenRGB(token: path), TokenRGB(hex: hex), path)
        }
        XCTAssertNil(TokenRGB(token: "no.such.token"))
    }

    func testSpacingAndRadiusMatchTokens() {
        XCTAssertEqual(CouliSpacing.s0, 0)
        XCTAssertEqual(CouliSpacing.s4, CGFloat(DesignTokens.spacing["4"] ?? -1))
        XCTAssertEqual(CouliSpacing.s16, CGFloat(DesignTokens.spacing["16"] ?? -1))
        XCTAssertEqual(CouliRadius.card, CGFloat(DesignTokens.radius["card"] ?? -1))
        XCTAssertEqual(CouliHitTarget.minimum, CGFloat(DesignTokens.interactionTarget["ios"] ?? -1))
        XCTAssertGreaterThanOrEqual(CouliHitTarget.minimum, 44)
    }

    func testTextStylesUseTokenSizesInAscendingOrder() {
        let sizes = CouliTextStyle.allCases.map(\.baseSize)
        XCTAssertEqual(sizes, CouliTextStyle.allCases.map { CGFloat(DesignTokens.fontSize[$0.rawValue] ?? -1) })
        XCTAssertEqual(sizes, sizes.sorted())
        XCTAssertEqual(Set(sizes).count, sizes.count)
    }
}
