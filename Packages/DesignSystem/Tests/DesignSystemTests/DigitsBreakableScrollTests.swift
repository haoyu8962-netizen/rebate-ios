@testable import DesignSystem
import SwiftUI
import UIKit
import XCTest

/// FU-IOS-NUM-WRAP v4（评审 r1 S2-1 → 实现 r4：`BreakableText` 含金额段改走共用件）：含金额的段放得下就一行、不横滑；
/// 独占一行仍放不下时框内横滑（带截断提示），**不撑出容器**（旧版 `fixedSize(horizontal: true)` 会撑出去）、不在数字中间断。
/// 进程内挂真窗口：判「横滑」= 有能横向滚动的系统滚动视图；判「不撑出」= 横滑条可见框不超过给它的宽；从开头露出。
@MainActor
final class DigitsBreakableScrollTests: XCTestCase {
    private func mount(_ text: String, width: CGFloat, size: DynamicTypeSize) async -> (UIWindow, UIView) {
        let root = BreakableText(text, style: .heading, weight: .couliBold)
            .foregroundColor(.black)
            .frame(width: width, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .environment(\.dynamicTypeSize, size)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Color.white)
        let host = UIHostingController(rootView: root)
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let window = scene.map { UIWindow(windowScene: $0) } ?? UIWindow()
        window.frame = CGRect(x: 0, y: 0, width: 400, height: 600)
        window.rootViewController = host
        window.makeKeyAndVisible()
        for _ in 0..<8 {
            window.layoutIfNeeded()
            try? await Task.sleep(for: .milliseconds(50))
        }
        return (window, host.view)
    }

    private func all(_ view: UIView) -> [UIView] {
        [view] + view.subviews.flatMap(all)
    }

    private func horizontalScrollers(_ window: UIWindow) -> [UIScrollView] {
        all(window).compactMap { $0 as? UIScrollView }.filter { $0.contentSize.width > $0.bounds.width + 1 }
    }

    func testShortAmountStaysOneLineWithoutScroll() async {
        let (window, _) = await mount("¥12.34", width: 200, size: .accessibility3)
        defer { window.isHidden = true }
        XCTAssertEqual(horizontalScrollers(window).count, 0, "放得下的金额不横滑、没有提示")
    }

    func testHugeAmountScrollsInsideWidthWithHint() async {
        let width: CGFloat = 200
        let (window, _) = await mount("¥98765432109876.54", width: width, size: .accessibility3)
        defer { window.isHidden = true }
        let strips = horizontalScrollers(window)
        XCTAssertEqual(strips.count, 1, "独占一行仍放不下：框内横滑")
        guard let strip = strips.first else { return }
        let visible = strip.convert(strip.bounds, to: nil)
        XCTAssertLessThanOrEqual(visible.maxX, width + 0.5, "横滑条不撑出给它的宽 \(width)（\(visible)）")
        XCTAssertGreaterThanOrEqual(visible.minX, -0.5)
        XCTAssertLessThanOrEqual(strip.contentOffset.x, 0.5, "从开头露出")
        // 渐隐与指示器的像素判在 AppTests/DigitsWrapBreakableTests（包测试宿主里截图整张黑，判不了像素）
    }
}
