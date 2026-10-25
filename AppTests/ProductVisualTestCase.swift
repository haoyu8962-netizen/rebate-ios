@testable import Couli
import DesignSystem
import Foundation
import SwiftUI
import UIKit
import XCTest

/// APP-06v-a 结构 / 几何 / 像素用例的公共底座：每个页面一个新的偏好套件与存储目录；图片由 `ProductVisualImages` 本机回答。
@MainActor
class ProductVisualTestCase: XCTestCase {
    var suiteName = ""
    var defaults: UserDefaults!
    var host: ProductVisualHost?

    override func setUpWithError() throws {
        AppStubProtocol.reset()
        ProductVisualImages.install()
    }

    override func tearDown() async throws {
        host?.close()
        host = nil
        clean()
        ProductVisualImages.uninstall()
        AppStubProtocol.reset()
    }

    private func clean() {
        // 没建过套件时 suiteName 为空：拼出来的就是整个临时目录，删掉会让 URLSession / AsyncImage 之后再也拿不到图。
        guard !suiteName.isEmpty else { return }
        defaults?.removePersistentDomain(forName: suiteName)
        try? FileManager.default
            .removeItem(at: FileManager.default.temporaryDirectory.appendingPathComponent(suiteName))
    }

    private func fresh() throws {
        host?.close()
        host = nil
        AppStubProtocol.reset()
        clean()
        suiteName = "product-visual-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    }

    /// 用一张 visualCards 卡打开详情、挂窗口并等稳定；返回页面与截图。
    @discardableResult
    func open(_ id: String, statuses: [String: String] = [:], canvas: ProductVisualHost.Canvas = .init(),
              file: StaticString = #filePath, line: UInt = #line) async throws -> (ProductVisualHost, UIImage) {
        try await open(card: ProductVisualCards.screenshotCard(id), statuses: statuses, canvas: canvas, file: file,
                       line: line)
    }

    /// 用一张（测试内派生的）卡打开详情。`expectImage` 为 false 时不等商品图上屏（失败占位用例）。
    @discardableResult
    func open(card: [String: Any], statuses: [String: String] = [:], canvas: ProductVisualHost.Canvas = .init(),
              expectImage: Bool = true, file: StaticString = #filePath,
              line: UInt = #line) async throws -> (ProductVisualHost, UIImage) {
        try fresh()
        let page = try ProductVisualHost(suiteName: suiteName, defaults: defaults, card: card, statuses: statuses)
        host = page
        await page.show(canvas)
        let image = await page.stableImage(expectImage: expectImage, file: file, line: line)
        return try (page, XCTUnwrap(image, "\(card["product_key"] ?? "")：没有截到稳定画面", file: file, line: line))
    }

    /// getProduct 回错误或挂起（页面级状态）。
    @discardableResult
    func openState(_ reply: ProductVisualHost.Reply, canvas: ProductVisualHost.Canvas = .init(),
                   file: StaticString = #filePath, line: UInt = #line) async throws -> (ProductVisualHost, UIImage) {
        try fresh()
        let page = try ProductVisualHost(suiteName: suiteName, defaults: defaults, platform: "taobao",
                                         productKey: "tb:visual-milk", reply: reply)
        host = page
        await page.show(canvas)
        let image = await page.stableImage(expectImage: false, file: file, line: line)
        return try (page, XCTUnwrap(image, file: file, line: line))
    }

    // MARK: - 断言工具

    func assertNear(_ actual: CGFloat, _ expected: CGFloat, _ tolerance: CGFloat, _ message: String,
                    file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertLessThanOrEqual(abs(actual - expected), tolerance,
                                 "\(message)：实际 \(actual)，期望 \(expected) ± \(tolerance)", file: file, line: line)
    }

    func assertInside(_ inner: CGRect, _ outer: CGRect, _ message: String, slack: CGFloat = 0.5,
                      file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(outer.insetBy(dx: -slack, dy: -slack).contains(inner),
                      "\(message)：\(inner) 不在 \(outer) 内", file: file, line: line)
    }

    /// 两个框不重叠（允许 0.5 的取整误差）。
    func assertDisjoint(_ lhs: CGRect, _ rhs: CGRect, _ message: String,
                        file: StaticString = #filePath, line: UInt = #line) {
        let overlap = lhs.insetBy(dx: 0.5, dy: 0.5).intersection(rhs.insetBy(dx: 0.5, dy: 0.5))
        XCTAssertTrue(overlap.isNull || overlap.isEmpty, "\(message)：\(lhs) 与 \(rhs) 重叠", file: file, line: line)
    }

    /// 两个框纵向是否有交叠（同一行）。
    func sameRow(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        min(lhs.maxY, rhs.maxY) - max(lhs.minY, rhs.minY) > 1
    }
}

/// 图标墨迹比对：从页面截图里裁出图标框，与同尺寸、同前景 / 背景色的参考图标（生产 `CouliIconView`）逐像素比较墨迹轮廓。
/// 只比「离哪个参考更近」，不依赖绝对阈值：入账行画成 i 时离 i 近、离钟表远，能被拦下。
@MainActor
enum ProductVisualIconProbe {
    static func ink(_ pixels: ProductVisualPixels, in rect: CGRect,
                    background: ProductVisualPixels.RGB) -> [[Bool]] {
        let scale = pixels.scale
        let xs = Int(rect.minX * scale)..<Int(rect.maxX * scale)
        let ys = Int(rect.minY * scale)..<Int(rect.maxY * scale)
        return ys.map { row in xs.map { column in !pixels.color(px: column, row).near(background, tolerance: 40) } }
    }

    /// 参考图标（钟表、i）：与页面同一渲染管线（宿主窗口 + drawHierarchy）、同尺寸、口径块同色（次文字色画在次要底上）。
    static func references(size: CGSize, dark: Bool) async -> [CouliIcon: [[Bool]]] {
        let icons: [CouliIcon] = [.clock, .info]
        let view = HStack(spacing: 20) {
            ForEach(icons, id: \.self) { icon in
                CouliIconView(icon, size: size.width).foregroundColor(CouliColor.textSecondary)
                    .frame(width: size.width, height: size.height).couliProbe("ref.\(icon.rawValue)", role: "icon")
            }
        }
        .padding(20).background(CouliColor.backgroundMuted)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).background(CouliColor.backgroundMuted)
        let (image, probes) = await ProductVisualRender.standalone(
            view,
            size: CGSize(width: 200, height: 100),
            dark: dark
        )
        let pixels = ProductVisualPixels(image)
        let background = ProductVisualPixels.RGB(CouliColor.backgroundMuted, dark: dark)
        var result: [CouliIcon: [[Bool]]] = [:]
        for icon in icons {
            if let rect = probes["ref.\(icon.rawValue)"]?.rect {
                result[icon] = ink(pixels, in: rect, background: background)
            }
        }
        return result
    }

    /// 允许 ±1 物理像素位移时的最少不一致像素数。
    static func difference(_ lhs: [[Bool]], _ rhs: [[Bool]]) -> Int {
        let height = min(lhs.count, rhs.count)
        guard height > 2, let lw = lhs.first?.count, let rw = rhs.first?.count else { return Int.max }
        let width = min(lw, rw)
        var best = Int.max
        for dy in -1...1 {
            for dx in -1...1 {
                var diff = 0
                for row in 1..<(height - 1) {
                    for column in 1..<(width - 1) where lhs[row][column] != rhs[row + dy][column + dx] {
                        diff += 1
                    }
                }
                best = min(best, diff)
            }
        }
        return best
    }
}

/// 像素判据（正式用例与 ProductVisualOracleTests 自证共用同一份）。
enum ProductVisualJudge {
    /// 400 × 120 三段测试位图放进头图框后「完整显示（contain）+ 占位底留边」的问题清单；空 = 通过。
    static func containProblems(_ pixels: ProductVisualPixels, hero: CGRect,
                                placeholder: ProductVisualPixels.RGB) -> [String] {
        var problems: [String] = []
        // 宽图完整显示：图高 = 框宽 × 0.3，上下各留约 78 的占位底
        let band = (hero.height - hero.width * 0.3) / 2
        if band <= 40 {
            problems.append("框高宽比不足以留出上下占位带（band=\(band)）")
        }
        for top in [hero.minY + band / 2, hero.maxY - band / 2] {
            let sample = pixels.color(at: CGPoint(x: hero.midX, y: top))
            if !sample.near(placeholder, tolerance: 6) {
                problems.append("y=\(Int(top)) 不是占位底：\(sample)，令牌 \(placeholder)")
            }
        }
        let samples: [(name: String, color: ProductVisualPixels.RGB)] = [
            ("左缘红段", .init(red: 230, green: 40, blue: 40)),
            ("中间绿段", .init(red: 40, green: 170, blue: 60)),
            ("右缘蓝段", .init(red: 30, green: 90, blue: 230)),
        ]
        for (index, column) in [hero.minX + 4, hero.midX, hero.maxX - 4].enumerated() {
            let sample = pixels.color(at: CGPoint(x: column, y: hero.midY))
            if !sample.near(samples[index].color, tolerance: 24) {
                problems.append("\(samples[index].name)缺失（被裁切或拉伸）：\(sample)")
            }
        }
        return problems
    }

    /// 区域内饱和度 > 0.15 的像素数（下架去色后应接近 0）。
    static func saturatedCount(_ pixels: ProductVisualPixels, in rect: CGRect) -> Int {
        pixels.count(in: rect) { $0.saturation > 0.15 }
    }
}
