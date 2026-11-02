@testable import Couli
import DesignSystem
import Foundation
import SwiftUI
import UIKit
import XCTest

/// APP-12w-a 判据自证（先正后反，APP-06v-a S2-2）：本组不碰设置页，只证明判据分得开，底版就绿。
@MainActor
final class SettingsVisualOracleTests: SettingsVisualTestCase {
    private typealias Judge = SettingsVisualJudge

    /// 居中判据：同一行字，居中判过、靠左判不过（现状 CouliDialog 默认靠左）。
    func testCenteredJudge() async throws {
        func ink(_ alignment: Alignment) async throws -> Bool {
            let size = CGSize(width: 300, height: 60)
            let view = Text(verbatim: "确定退出登录？").font(.system(size: 17, weight: .semibold))
                .foregroundColor(.black).padding(.horizontal, 20)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment).background(Color.white)
            let (image, _) = await ProductVisualRender.standalone(view, size: size)
            let pixels = ProductVisualPixels(image)
            let white = Judge.hex("#FFFFFF")
            let box = CGRect(origin: .zero, size: size)
            let left = try XCTUnwrap(inkLeft(pixels, in: box, background: white))
            let right = try XCTUnwrap(inkRight(pixels, in: box, background: white))
            return Judge.centered(inkLeft: left, inkRight: right, in: box)
        }
        let centered = try await ink(.center)
        let leading = try await ink(.leading)
        XCTAssertTrue(centered, "居中判过")
        XCTAssertFalse(leading, "靠左判不过")
    }

    /// 遮罩混合：令牌遮罩判过，系统 dim（黑 20%）判不过。
    func testScrimBlendJudge() {
        let ground = Judge.hex("#F2EEE6")
        let token = Judge.blend(Judge.hex("#28251F"), opacity: 0.4, over: ground)
        XCTAssertTrue(pixelNear(token, Judge.hex("#A19E96"), 3), "rgba(40,37,31,.4) 盖在页底 ≈ #A19E96")
        let system = Judge.blend(Judge.hex("#000000"), opacity: 0.2, over: ground)
        XCTAssertFalse(pixelNear(system, token, 4), "系统 dim 判不过")
    }

    private func pixelNear(_ lhs: ProductVisualPixels.RGB, _ rhs: ProductVisualPixels.RGB, _ tolerance: Int) -> Bool {
        lhs.near(rhs, tolerance: tolerance)
    }

    /// 底色判据：status.warning 底判过；现状 10% 警告字色判不过（区别只有几个色阶，容差 3 分得开）。
    func testWarningFillJudge() async {
        func shot(_ color: Color) async -> Double {
            let size = CGSize(width: 40, height: 40)
            let (image, _) = await ProductVisualRender.standalone(
                ZStack { CouliColor.backgroundCanvas
                    color
                }, size: size
            )
            return share(image, in: CGRect(x: 4, y: 4, width: 20, height: 20),
                         near: pixel(CouliColor.statusWarningBackground, dark: false), tolerance: 3)
        }
        let token = await shot(CouliColor.statusWarningBackground)
        let current = await shot(CouliColor.statusWarningText.opacity(0.1))
        XCTAssertGreaterThan(token, 0.9, "令牌底判过")
        XCTAssertLessThan(current, 0.1, "现状判不过")
    }

    /// 描边判据（v2）：真次按钮判红（上百像素），同尺寸列表行 + 箭头判 0。
    func testOutlineJudge() async throws {
        let size = CGSize(width: 390, height: 120)
        let button = CouliButton("用户协议", kind: .secondary, fillsWidth: true) {}
            .couliProbe("box", role: "button").padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity).background(CouliColor.backgroundSurface)
        // `ProductVisualRender.standalone` 关窗后测量被清掉，这里用保留记录的钱包版
        let ground = pixel(CouliColor.backgroundSurface, dark: false)
        let ready: (ProductVisualPixels) -> Bool = { pixels in
            pixels.count(in: CGRect(origin: .zero, size: size)) { !$0.near(ground, tolerance: 40) } > 20
        }
        let (outlined, outlinedRecords) = await WalletVisualRender.standalone(button, size: size, until: ready)
        let row = HStack {
            Text(verbatim: "用户协议").font(.system(size: 17)).foregroundColor(CouliColor.textPrimary)
            Spacer()
            CouliIconView(.chevron).foregroundColor(CouliColor.textSecondary).couliProbe("chevron", role: "icon")
        }
        .frame(height: 44).couliProbe("box", role: "row").padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity).background(CouliColor.backgroundSurface)
        let (plain, plainRecords) = await WalletVisualRender.standalone(row, size: size, until: ready)
        let box = try XCTUnwrap(outlinedRecords["box"]?.rect)
        XCTAssertGreaterThan(outlineInk(outlined, box, right: box.maxX - 22), 100, "真描边判红")
        let line = try XCTUnwrap(plainRecords["box"]?.rect)
        let chevron = try XCTUnwrap(plainRecords["chevron"]?.rect)
        XCTAssertEqual(outlineInk(plain, line, right: chevron.minX - 2), 0, "列表行判 0")
    }

    /// 全黑 / 纯白判红（基准比对前一道）。
    func testBlankImagesAreRejected() {
        func solid(_ color: UIColor) -> UIImage {
            UIGraphicsImageRenderer(size: CGSize(width: 390, height: 844)).image { context in
                color.setFill()
                context.fill(CGRect(x: 0, y: 0, width: 390, height: 844))
            }
        }
        XCTAssertFalse(WithdrawVisualRenderJudge.problems(solid(.black)).isEmpty, "全黑判红")
        XCTAssertFalse(WithdrawVisualRenderJudge.problems(solid(.white)).isEmpty, "纯白判红")
    }
}
