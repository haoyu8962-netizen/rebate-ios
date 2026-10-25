@testable import Couli
import DesignSystem
import SwiftUI
import UIKit
import XCTest

/// 判据自证（不依赖本任务的新实现，当前即应全绿）：正式用例用的像素判据对「正确写法」放行、对「错误写法」拦下。
/// 错误写法取自现状（生产 `ProductHeroImage` 仍是铺满裁切、比例 1.5）与 Android 评审抓过的问题（只蒙层不去色、入账行画 i）。
@MainActor
final class ProductVisualOracleTests: ProductVisualTestCase {
    private func render(_ view: some View, size: CGSize, until ready: (ProductVisualPixels) -> Bool = { _ in true })
        async -> (UIImage, ProductVisualProbes) {
        await ProductVisualRender.standalone(view, size: size, until: ready)
    }

    private var stripes: UIImage {
        UIImage(data: ProductVisualImages.stripes()) ?? UIImage()
    }

    private var placeholder: ProductVisualPixels.RGB {
        .init(CouliColor.backgroundPlaceholder, dark: false)
    }

    /// 正确写法（contain + 占位底）放行；同一判据拦下现状生产头图（铺满裁切）。
    func testContainJudgeAcceptsContainAndRejectsCurrentFillHero() async throws {
        let contain = ZStack {
            CouliColor.backgroundPlaceholder
            Image(uiImage: stripes).resizable().scaledToFit()
        }
        .frame(width: 358, height: 264).couliProbe("oracle.hero", role: "hero")
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        let (good, goodProbes) = await render(contain, size: CGSize(width: 390, height: 400))
        let goodHero = try goodProbes.rect("oracle.hero")
        XCTAssertEqual(ProductVisualJudge.containProblems(ProductVisualPixels(good), hero: goodHero,
                                                          placeholder: placeholder), [], "正确写法应通过")

        let current = ProductHeroImage(url: URL(string: "https://img.example.test/product-v/milk.png"),
                                       accessibilityLabel: "x")
            .frame(width: 358).couliProbe("oracle.hero", role: "hero")
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        let (bad, badProbes) = await render(current, size: CGSize(width: 390, height: 400)) { pixels in
            pixels.count(in: CGRect(x: 0, y: 0, width: 390, height: 400), step: 6) { $0.isStripe } > 2000
        }
        let badHero = try badProbes.rect("oracle.hero")
        let problems = ProductVisualJudge.containProblems(ProductVisualPixels(bad), hero: badHero,
                                                          placeholder: placeholder)
        XCTAssertFalse(problems.isEmpty, "现状铺满裁切的头图必须被判据拦下")
        XCTAssertNotEqual(badHero.height, 358 * ProductVisualLayoutTests.heroRatio, accuracy: 1,
                          "现状头图比例 1.5，与画板 358 × 264 不同（正式用例的比例断言能拦）")
        print("ORACLE contain 拦下现状：\(problems)")
    }

    /// 去色判据：饱和度 0 放行；只盖半透明灰蒙层（Android 评审提过的错误写法）拦下。
    func testDesaturationJudgeRejectsOverlayOnly() async {
        let rect = CGRect(x: 0, y: 0, width: 358, height: 264)
        func box(_ saturation: Double, veil: Bool) -> some View {
            ZStack {
                CouliColor.backgroundPlaceholder
                Image(uiImage: stripes).resizable().scaledToFit().saturation(saturation)
                if veil {
                    Color.gray.opacity(0.5)
                }
            }
            .frame(width: rect.width, height: rect.height)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        let size = CGSize(width: 390, height: 300)
        let gray = await ProductVisualPixels(render(box(0, veil: false), size: size).0)
        XCTAssertLessThanOrEqual(ProductVisualJudge.saturatedCount(gray, in: rect.insetBy(dx: 2, dy: 2)), 30, "去色通过")
        let veiled = await ProductVisualPixels(render(box(1, veil: true), size: size).0)
        XCTAssertGreaterThan(ProductVisualJudge.saturatedCount(veiled, in: rect.insetBy(dx: 2, dy: 2)), 5000,
                             "只加蒙层仍有彩色，必须被拦下")
    }

    /// 图标判据：钟表与 i 各自离自己的参考更近（入账行画成 i 会被拦）。
    func testIconJudgeSeparatesClockFromInfo() async throws {
        let size = CGSize(width: 16, height: 16)
        for (icon, other) in [(CouliIcon.clock, CouliIcon.info), (.info, .clock)] {
            let view = ZStack {
                CouliColor.backgroundMuted
                CouliIconView(icon, size: 16).foregroundColor(CouliColor.textSecondary)
            }
            .frame(width: 16, height: 16).couliProbe("oracle.icon", role: "icon")
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            let (image, probes) = await render(view, size: CGSize(width: 60, height: 60))
            let rect = try probes.rect("oracle.icon")
            let background = ProductVisualPixels.RGB(CouliColor.backgroundMuted, dark: false)
            let actual = ProductVisualIconProbe.ink(ProductVisualPixels(image), in: rect, background: background)
            let refs = await ProductVisualIconProbe.references(size: size, dark: false)
            let same = ProductVisualIconProbe.difference(actual, refs[icon] ?? [])
            let different = ProductVisualIconProbe.difference(actual, refs[other] ?? [])
            XCTAssertLessThan(same, different, "\(icon) 应离自己的参考更近：同 \(same)，异 \(different)")
        }
    }
}
