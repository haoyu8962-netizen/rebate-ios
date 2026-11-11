@testable import Couli
@testable import DesignSystem
import SwiftUI
import UIKit
import XCTest

/// FU-IOS-NUM-WRAP v4（评审 r1 S2-1 → 实现 r4：DS `BreakableText` 含金额段改走共用件）的像素部分：极端金额独占一行仍放不下时
/// 框内横滑，带截断提示——末端渐隐 + 指示器、从开头露出（`ScrollHintJudge` 同口径；组件没有测量钩子，指示器框按共用件几何取：
/// 横滑条可见框下方 3pt、高 3、等宽）；放得下的金额不横滑。结构部分（不撑出、从开头）另见 DesignSystemTests/DigitsBreakableScrollTests。
@MainActor
final class DigitsWrapBreakableTests: XCTestCase {
    private func mount(_ text: String, tier: BindPhoneLayoutCanvas.Tier) async -> BindPhoneLayoutCanvas {
        let view = BreakableText(text, style: .heading, weight: .couliBold)
            .foregroundColor(CouliColor.textPrimary)
            .frame(width: 200, alignment: .leading)
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(CouliColor.backgroundSurface)
        let canvas = BindPhoneLayoutCanvas(AnyView(view), tier: tier)
        await canvas.pump(rounds: 10)
        return canvas
    }

    private static func strips(_ window: UIWindow) -> [UIScrollView] {
        BindPhoneLayoutCanvas.all(window).compactMap { $0 as? UIScrollView }.filter {
            !($0 is UITextView) && $0.contentSize.width > $0.bounds.width + 1
        }
    }

    func testHugeAmountScrollsWithHint() async {
        let tier = BindPhoneLayoutCanvas.Tier(name: "390 + AX3", width: 390, size: .accessibility3)
        let canvas = await mount("¥98765432109876.54", tier: tier)
        defer { canvas.close() }
        guard let strip = Self.strips(canvas.window).first else {
            return XCTFail("独占一行仍放不下：要框内横滑")
        }
        let visible = strip.convert(strip.bounds, to: nil)
        XCTAssertLessThanOrEqual(visible.maxX, 24 + 200 + 0.5, "横滑条不撑出给它的 200 宽（\(visible)）")
        let text = strip.convert(CGRect(origin: .zero, size: strip.contentSize), to: nil)
        let bar = CGRect(x: visible.minX, y: visible.maxY + 3, width: visible.width, height: 3)
        let hint = CouliLayoutProbeRecord(id: "breakable.scrollHint", role: "scroll-hint", rect: bar)
        let problems = ScrollHintJudge.scrolled("BreakableText 极端金额", text: text, hint: hint, scroll: strip,
                                                image: DigitsWrapBindPendingTests.render(canvas.window))
        XCTAssertEqual(problems, [])
    }

    func testShortAmountDoesNotScroll() async {
        let tier = BindPhoneLayoutCanvas.Tier(name: "390 + AX3", width: 390, size: .accessibility3)
        let canvas = await mount("¥12.34", tier: tier)
        defer { canvas.close() }
        XCTAssertEqual(Self.strips(canvas.window).count, 0, "放得下的金额不横滑、没有提示")
    }
}
