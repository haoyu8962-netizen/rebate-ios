@testable import Couli
import DesignSystem
import Foundation
import SwiftUI
import UIKit
import XCTest

/// APP-12v 判据自证（先正后反，APP-06v-a S2-2）：本组不碰「我的」页，只证明判据分得开，底版就绿。
@MainActor
final class MeVisualOracleTests: MeVisualTestCase {
    private func solid(_ color: UIColor) -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 390, height: 844)).image { context in
            color.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 390, height: 844))
        }
    }

    func testBlankImagesAreRejected() {
        XCTAssertFalse(WithdrawVisualRenderJudge.problems(solid(.black)).isEmpty, "全黑判红")
        XCTAssertFalse(WithdrawVisualRenderJudge.problems(solid(.white)).isEmpty, "纯白判红")
    }

    /// 文字截断判据：折够行数放行；被 lineLimit 压成一行、没报自然宽判红。
    func testTruncationJudge() {
        func item(_ rect: CGRect, natural: CGFloat) -> CouliLayoutProbeRecord {
            CouliLayoutProbeRecord(
                id: "t",
                role: "text",
                rect: rect,
                naturalWidth: natural,
                fontSize: 34,
                baseFontSize: 17
            )
        }
        XCTAssertFalse(MeVisualJudge.truncated(item(CGRect(x: 0, y: 0, width: 200, height: 41), natural: 180)), "单行放得下")
        XCTAssertFalse(
            MeVisualJudge.truncated(item(CGRect(x: 0, y: 0, width: 200, height: 123), natural: 540)),
            "三行放得下"
        )
        XCTAssertTrue(
            MeVisualJudge.truncated(item(CGRect(x: 0, y: 0, width: 200, height: 41), natural: 540)),
            "一行放不下三行"
        )
        XCTAssertTrue(MeVisualJudge.truncated(item(CGRect(x: 0, y: 0, width: 200, height: 41), natural: 0)), "没报自然宽不放行")
    }

    /// 轻提示绿对勾判据：成功勾有绿、无图标没有绿（同一个生产 `couliToast`）。
    func testToastGreenJudge() async {
        func shot(_ icon: CouliToastIcon) async -> Int {
            let view = ToastSample(message: CouliToastMessage("已复制邀请码", icon: icon))
                .frame(maxWidth: .infinity, maxHeight: .infinity).background(CouliColor.backgroundCanvas)
            let size = CGSize(width: 390, height: 200)
            let white = ProductVisualPixels.RGB(.white, dark: false)
            let (image, _) = await ProductVisualRender.standalone(view, size: size) { pixels in
                pixels.count(in: CGRect(origin: .zero, size: size)) { $0.near(white, tolerance: 6) } > 2000
            }
            return toastGreen(image)
        }
        let success = await shot(.success)
        let none = await shot(.none)
        XCTAssertGreaterThan(success, 10, "成功勾有绿")
        XCTAssertEqual(none, 0, "无图标没有绿")
    }

    /// 底色判据：muted 与页面底只差 3～4 个色阶，容差 2 分得开；警告底判不过。
    func testMutedShareJudge() async {
        func shot(_ color: Color) async -> Double {
            let size = CGSize(width: 40, height: 40)
            let (image, _) = await ProductVisualRender.standalone(color, size: size)
            return share(image, in: CGRect(x: 4, y: 4, width: 20, height: 20),
                         near: pixel(CouliColor.backgroundMuted, dark: false), tolerance: 2)
        }
        let muted = await shot(CouliColor.backgroundMuted)
        let canvas = await shot(CouliColor.backgroundCanvas)
        let warning = await shot(CouliColor.statusWarningText.opacity(0.1))
        XCTAssertGreaterThan(muted, 0.9, "muted 判过")
        XCTAssertLessThan(canvas, 0.1, "页面底判不过")
        XCTAssertLessThan(warning, 0.1, "警告底判不过（现状）")
    }

    /// 图标判据：同一判据分得开柱状图与趋势图（生产 CouliIconView 渲染）。
    func testBarChartNearestIcon() async throws {
        let candidates = ["chart.bar", "chart.line.uptrend.xyaxis"]
        for (icon, expected) in [(CouliIcon.barChart, "chart.bar"), (CouliIcon.trend, "chart.line.uptrend.xyaxis")] {
            let view = CouliIconView(icon).foregroundColor(CouliColor.textPrimary).couliProbe("icon", role: "icon")
                .padding(20).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(CouliColor.backgroundSurface)
            let ground = pixel(CouliColor.backgroundSurface, dark: false)
            let size = CGSize(width: 100, height: 100)
            let (image, records) = await WalletVisualRender.standalone(view, size: size) { pixels in
                pixels.count(in: CGRect(origin: .zero, size: size)) { !$0.near(ground, tolerance: 40) } > 20
            }
            let box = try XCTUnwrap(records["icon"]?.rect)
            let nearest = await nearestIcon(
                image,
                in: box,
                candidates: candidates,
                background: CouliColor.backgroundSurface,
                ink: CouliColor.textPrimary
            )
            XCTAssertEqual(nearest, expected)
        }
    }
}

/// 只挂一个常显轻提示（判据自证用）。
private struct ToastSample: View {
    @State var message: CouliToastMessage?

    var body: some View {
        Color.clear.couliToast($message, duration: 30)
    }
}
