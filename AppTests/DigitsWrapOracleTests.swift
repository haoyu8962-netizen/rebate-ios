@testable import Couli
import DesignSystem
import SwiftUI
import UIKit
import XCTest

/// tests v2（#24 复核 FAIL 的反例）判据自检：
/// - 横滑条（系统 UIScrollView）比字矮、把大数上下半截裁掉时，`DigitsRunJudge.scrollerClips` / `visibility` 必须判红，条高够时判绿
///   （钱包 `assertWrappedAmount`、订单 `assertInsideOrScrolled`、本单全部数字用例共用）；
/// - 横滑条被外层固定高度裁掉下半截（裁切不在滚动视图本身）时，`assertWrappedAmount` 用的像素核字（`DigitsRunJudge.inkRows`：
///   可见墨迹恰一行、墨迹高 ≥ 0.6 倍字号）必须判红，没被裁时判绿。
@MainActor
final class DigitsWrapOracleTests: XCTestCase {
    private static let digits = "¥9876543210.98"
    private static let card = CGRect(x: 0, y: 0, width: 320, height: 300)

    private struct Strip {
        let window: UIWindow
        let scroll: UIScrollView
        let record: CouliLayoutProbeRecord
    }

    private func window(_ host: UIViewController) -> UIWindow {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let window = scene.map { UIWindow(windowScene: $0) } ?? UIWindow()
        window.frame = Self.card
        window.rootViewController = host
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        return window
    }

    /// UIKit 横滑条：条在 (0, 100)，宽 200、高 `height`；内容是 40pt 大数一行。
    private func strip(height: CGFloat) -> Strip {
        let root = UIView(frame: Self.card)
        root.backgroundColor = .white
        let scroll = UIScrollView(frame: CGRect(x: 0, y: 100, width: 200, height: height))
        let label = UILabel()
        label.font = .monospacedDigitSystemFont(ofSize: 40, weight: .bold)
        label.text = Self.digits
        label.sizeToFit()
        scroll.addSubview(label)
        scroll.contentSize = label.bounds.size
        root.addSubview(scroll)
        let controller = UIViewController()
        controller.view = root
        let win = window(controller)
        let rect = label.convert(label.bounds, to: nil)
        let record = CouliLayoutProbeRecord(id: "oracle.digits", role: "text", text: Self.digits, rect: rect,
                                            fontSize: 40, baseFontSize: 40)
        return Strip(window: win, scroll: scroll, record: record)
    }

    func testShortScrollStripIsRedTallIsGreen() {
        let tier = DigitsRunJudge.Tier(name: "oracle", width: 320, size: .large, dark: false)
        let shortStrip = strip(height: 20)
        let (short, shortScroll, shortRecord) = (shortStrip.window, shortStrip.scroll, shortStrip.record)
        XCTAssertGreaterThan(shortRecord.rect.height, 30, "前提：字比横滑条高")
        XCTAssertGreaterThan(shortRecord.rect.width, Self.card.width, "前提：字比容器宽，真要横滑")
        XCTAssertFalse(DigitsRunJudge.scrollerClips(shortScroll, rect: shortRecord.rect).isEmpty, "比字矮的横滑条要判红")
        XCTAssertFalse(DigitsRunJudge.visibility(shortRecord, container: Self.card, window: short, tier: tier).isEmpty,
                       "visibility 也要判红")
        short.isHidden = true
        let tallStrip = strip(height: 60)
        let (tall, tallScroll, tallRecord) = (tallStrip.window, tallStrip.scroll, tallStrip.record)
        XCTAssertEqual(DigitsRunJudge.scrollerClips(tallScroll, rect: tallRecord.rect), [])
        XCTAssertEqual(DigitsRunJudge.visibility(tallRecord, container: Self.card, window: tall, tier: tier), [])
        tall.isHidden = true
    }

    /// tests v3（评审 r1 S2-4）：条高 36、字 40pt（文字框约 48 高）、文字中线落在条内——`visibility` 要找到这条横滑条，
    /// 并经 `scrollerClips` 判红（不是走「找不到横滑条」那条路）。
    func testMidlineInsideShortStripIsRedThroughScrollerClips() {
        let tier = DigitsRunJudge.Tier(name: "oracle", width: 320, size: .large, dark: false)
        let strip = strip(height: 36)
        defer { strip.window.isHidden = true }
        let rect = strip.record.rect
        XCTAssertTrue(rect.midY > 100 && rect.midY < 136, "前提：文字中线在条内（\(rect)）")
        XCTAssertGreaterThan(rect.height, 36, "前提：字比条高")
        let found = DigitsRunJudge.horizontalScroller(around: rect, inside: Self.card, window: strip.window)
        XCTAssertTrue(found === strip.scroll, "visibility 要找到这条横滑条")
        let problems = DigitsRunJudge.visibility(strip.record, container: Self.card, window: strip.window, tier: tier)
        XCTAssertEqual(problems.count, 1)
        XCTAssertTrue(problems.first?.contains("竖向没完整包住") == true, "经 scrollerClips 判红：\(problems)")
    }

    /// SwiftUI 横滑条外再套固定高度并裁切：可见墨迹被裁成矮条，像素核字判红；不裁时判绿。
    func testClippedInkBandIsRed() async {
        func render(clip: Bool) async -> (UIImage, CGRect) {
            let text = Text(verbatim: Self.digits).font(.system(size: 40, weight: .bold).monospacedDigit())
                .foregroundColor(.black).fixedSize()
            let strip = ScrollView(.horizontal, showsIndicators: false) { text }
                .frame(width: 200, height: clip ? 18 : 60).clipped()
            let view = strip.frame(maxWidth: .infinity, maxHeight: .infinity).background(Color.white)
            // 生产同款独立宿主（WalletVisualRender.standalone：等到画出墨迹再截）；整张图找墨迹，不按算出来的坐标取
            let (image, _) = await WalletVisualRender.standalone(view, size: Self.card.size) { pixels in
                pixels.count(in: Self.card) { $0.red < 80 && $0.green < 80 && $0.blue < 80 } > 50
            }
            return (image, Self.card)
        }
        let white = ProductVisualPixels.RGB(red: 255, green: 255, blue: 255)
        let (cut, cutArea) = await render(clip: true)
        let cutRows = DigitsRunJudge.inkRows(
            ProductVisualPixels(cut),
            in: cutArea,
            background: white
        )
        XCTAssertFalse(cutRows.isEmpty, "前提：裁切后仍有可见墨迹")
        XCTAssertTrue(cutRows.allSatisfy { $0.upperBound - $0.lowerBound < 40 * 0.6 }, "被裁的墨迹高不够一个数字：\(cutRows)")
        let (whole, wholeArea) = await render(clip: false)
        let rows = DigitsRunJudge.inkRows(ProductVisualPixels(whole), in: wholeArea, background: white)
        XCTAssertEqual(rows.count, 1, "没裁时恰一行：\(rows)")
        XCTAssertGreaterThanOrEqual(
            (rows.first?.upperBound ?? 0) - (rows.first?.lowerBound ?? 0),
            40 * 0.6,
            "没裁时墨迹高够一个数字"
        )
    }
}
