@testable import DesignSystem
import Generated
import SwiftUI
import UIKit
import XCTest

/// DS-02-iOS-1（brief §3.6、§3.9）：组件尺寸改读 `DesignTokens.component`，待令牌的 5 项钉现值；
/// 提交 D：阴影按外观取 `shadowsDark`、卡内白底按钮 `.inverse` 读 button.inverse.*（深色与安卓、鸿蒙一致）。
@MainActor
final class TokenMetricShadowTests: XCTestCase {
    private typealias Render = PlatformIconRenderSupport
    private typealias RGBA = TokenDarkResolutionTests.RGBA

    // MARK: - 组件尺寸

    /// 原「设计稿尺寸」枚举里有令牌的 7 项进 CouliComponentMetric（名字不变），值 = 令牌且与迁移前相同。
    func testComponentMetricsReadGeneratedTable() throws {
        let rows: [(CGFloat, (path: String, before: CGFloat))] = [
            (CouliComponentMetric.iconSmall, ("icon.small", 14)),
            (CouliComponentMetric.iconInline, ("icon.inline", 16)),
            (CouliComponentMetric.iconMedium, ("icon.medium", 20)),
            (CouliComponentMetric.tagMinHeight, ("tag.min-height", 22)),
            (CouliComponentMetric.badgeMinHeight, ("platform-badge.min-height", 20)),
            (CouliComponentMetric.listImage, ("image.list", 96)),
            (CouliComponentMetric.gridCellMinHeight, ("grid-cell.min-height", 72)),
            (CouliComponentMetric.buttonMinHeight, ("button.min-height", 48)),
            (CouliComponentMetric.controlBorderWidth, ("control.border-width", 1)),
            (CouliComponentMetric.iconDefault, ("icon.default", 24)),
        ]
        for (actual, (path, before)) in rows {
            let token = try XCTUnwrap(DesignTokens.component[path], "component 缺 \(path)")
            XCTAssertEqual(actual, CGFloat(token), "CouliComponentMetric ← component.\(path)")
            XCTAssertEqual(actual, before, "\(path) 迁移前后同值（快照 0 变化）")
        }
    }

    /// 令牌里还没有的 5 项（待 DSX-02 v0.6.0）：字面值钉住，防迁移时改值。
    func testPendingTokenMetricsKeepCurrentValues() {
        XCTAssertEqual(CouliPendingTokenMetric.tagPaddingVertical, 2)
        XCTAssertEqual(CouliPendingTokenMetric.gridImageAspect, 132.0 / 157.0, accuracy: 1e-12)
        XCTAssertEqual(CouliPendingTokenMetric.emptyIllustration, 96)
        XCTAssertEqual(CouliPendingTokenMetric.emptyIcon, 32)
        XCTAssertEqual(CouliPendingTokenMetric.sheetHandleWidth, 36)
        XCTAssertEqual(CouliPendingTokenMetric.sheetHandleHeight, 4)
    }

    // MARK: - 阴影（提交 D）

    /// 与直接用令牌层画出的参照图逐像素相同：浅色取 shadows、深色取 shadowsDark。另验参照确有区分力（深色图 ≠ 浅色层参照）。
    func testCouliShadowPicksLayersByAppearance() throws {
        for shadow in [CouliShadow.card, .floating] {
            for scheme in [ColorScheme.light, .dark] {
                let table = scheme == .dark ? DesignTokens.shadowsDark : DesignTokens.shadows
                let layers = try XCTUnwrap(table[shadow.rawValue], "\(shadow.rawValue) 缺层")
                let actual = try Render.bitmap(Render.render(
                    sample { $0.couliShadow(shadow) },
                    scheme: scheme,
                    scale: 2
                ))
                let expected = try Render.bitmap(Render.render(
                    sample { reference($0, layers) },
                    scheme: scheme,
                    scale: 2
                ))
                XCTAssertEqual(differing(actual, expected), 0, "\(shadow.rawValue)（\(scheme)）应等于令牌层参照")
                if scheme == .dark {
                    let lightLayers = try XCTUnwrap(DesignTokens.shadows[shadow.rawValue])
                    let wrong = try Render.bitmap(Render.render(
                        sample { reference($0, lightLayers) },
                        scheme: .dark,
                        scale: 2
                    ))
                    XCTAssertGreaterThan(differing(actual, wrong), 50, "\(shadow.rawValue)：深色不能沿用浅色阴影层")
                }
            }
        }
    }

    private func sample(_ decorate: (AnyView) -> some View) -> some View {
        let card = AnyView(RoundedRectangle(cornerRadius: CouliRadius.card).fill(CouliColor.backgroundSurface)
            .frame(width: 80, height: 48))
        return decorate(card)
            .frame(width: 160, height: 128)
            .background(CouliColor.backgroundCanvas)
    }

    private func reference(_ view: AnyView, _ layers: [DesignTokens.ShadowLayer]) -> AnyView {
        layers.reduce(view) { view, layer in
            let rgb = TokenDarkResolutionTests.expected(layer.color) ?? RGBA(red: 0, green: 0, blue: 0, alpha: 0)
            return AnyView(view.shadow(
                color: Color(.sRGB, red: rgb.red, green: rgb.green, blue: rgb.blue, opacity: layer.opacity),
                radius: CGFloat(layer.blur) / 2, x: CGFloat(layer.x), y: CGFloat(layer.y)
            ))
        }
    }

    private func differing(_ lhs: Render.Bitmap, _ rhs: Render.Bitmap, tolerance: Int = 2) -> Int {
        guard lhs.width == rhs.width, lhs.height == rhs.height else { return Int.max }
        return stride(from: 0, to: lhs.bytes.count, by: 4).filter { index in
            (0..<4).contains { abs(Int(lhs.bytes[index + $0]) - Int(rhs.bytes[index + $0])) > tolerance }
        }.count
    }

    // MARK: - 卡内白底按钮 .inverse（提交 D，计划 ③ / 验收 ④）

    /// 可点：前景 button.inverse.text、背景 button.inverse.background（深色白底 #A83B1F 字，与另两端一致），对比度 ≥ 4.5；
    /// 置灰：前景 button.primary.disabled.text（浅色与原 textSecondary 同值；深色与钱包现画板 #A39A90 一致）。
    func testInverseForegroundReadsButtonInverseTokens() throws {
        typealias Resolved = TokenDarkResolutionTests
        for dark in [false, true] {
            let table = dark ? DesignTokens.colorsDark : DesignTokens.colors
            let text = try XCTUnwrap(table["button.inverse.text"])
            let background = try XCTUnwrap(table["button.inverse.background"])
            let disabledText = try XCTUnwrap(table["button.primary.disabled.text"])
            let enabled = Resolved.resolve(
                CouliButtonStyle.foreground(kind: .inverse, enabled: true, pressed: false),
                dark: dark
            )
            let disabled = Resolved.resolve(CouliButtonStyle.foreground(kind: .inverse, enabled: false, pressed: false),
                                            dark: dark)
            XCTAssertTrue(enabled.isClose(to: try XCTUnwrap(Resolved.expected(text))), "inverse 字（\(dark)）应为 \(text)")
            XCTAssertTrue(disabled.isClose(to: try XCTUnwrap(Resolved.expected(disabledText))),
                          "inverse 置灰字（\(dark)）应为 \(disabledText)")
            let ratio = contrast(enabled, try XCTUnwrap(Resolved.expected(background)))
            XCTAssertGreaterThanOrEqual(ratio, 4.5, "inverse 字 / 底对比度（\(dark)）\(ratio)")
        }
    }

    /// 深色外观下把按钮放在狸橙卡上渲染：底是 button.inverse.background（白），不再是深色 surface；字有 #A83B1F 墨迹。
    func testInverseButtonRendersWhiteOnBrandCardInDark() throws {
        let view = CouliButton("提现", kind: .inverse, action: {})
            .fixedSize()
            .padding(CouliSpacing.s4)
            .background(CouliColor.brandPrimary)
        let bitmap = try Render.bitmap(Render.render(view, scheme: .dark, scale: 2))
        let white = try rgb8(XCTUnwrap(DesignTokens.colorsDark["button.inverse.background"]))
        let ink = try rgb8(XCTUnwrap(DesignTokens.colorsDark["button.inverse.text"]))
        let oldSurface = try rgb8(XCTUnwrap(DesignTokens.colorsDark["background.surface"]))
        let total = bitmap.width * bitmap.height
        XCTAssertGreaterThan(Double(bitmap.countPixels(closeTo: white)) / Double(total), 0.2, "深色下按钮底应为白")
        XCTAssertGreaterThan(bitmap.countPixels(closeTo: ink), 10, "深色下按钮字应为 button.inverse.text")
        XCTAssertLessThan(bitmap.countPixels(closeTo: oldSurface), 10, "不得再取深色 surface 当底")
    }

    private func rgb8(_ hex: String) throws -> [UInt8] {
        let rgb = try XCTUnwrap(TokenDarkResolutionTests.expected(hex))
        return [rgb.red, rgb.green, rgb.blue].map { UInt8(($0 * 255).rounded()) } + [255]
    }

    private func contrast(_ lhs: RGBA, _ rhs: RGBA) -> Double {
        func luminance(_ color: RGBA) -> Double {
            func linear(_ value: Double) -> Double {
                value <= 0.039_28 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * linear(color.red) + 0.7152 * linear(color.green) + 0.0722 * linear(color.blue)
        }
        let pair = [luminance(lhs), luminance(rhs)].sorted()
        return (pair[1] + 0.05) / (pair[0] + 0.05)
    }
}
