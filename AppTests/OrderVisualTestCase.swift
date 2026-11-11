@testable import Couli
import DesignSystem
import Foundation
import SwiftUI
import UIKit
import XCTest

/// APP-08v 订单视觉用例的公共底座：每个页面一个新的偏好套件与存储目录；网络 OrderVisualStub、商品图 OrderVisualImages。
@MainActor
class OrderVisualTestCase: XCTestCase {
    var suiteName = ""
    var defaults: UserDefaults!
    var host: OrderVisualHost?

    override func setUpWithError() throws {
        OrderVisualStub.reset()
        OrderVisualImages.install()
    }

    override func tearDown() async throws {
        host?.close()
        host = nil
        clean()
        OrderVisualImages.uninstall()
        OrderVisualStub.reset()
    }

    private func clean() {
        // 没建过套件时 suiteName 为空：拼出来的是整个临时目录，不能删（APP-06v 宿主问题 2）。
        guard !suiteName.isEmpty else { return }
        defaults?.removePersistentDomain(forName: suiteName)
        try? FileManager.default
            .removeItem(at: FileManager.default.temporaryDirectory.appendingPathComponent(suiteName))
    }

    func fresh(_ script: OrderVisualStub.Script) throws -> OrderVisualHost {
        host?.close()
        host = nil
        clean()
        OrderVisualImages.reset()
        suiteName = "order-visual-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let page = try OrderVisualHost(suiteName: suiteName, defaults: defaults, script: script)
        host = page
        return page
    }

    /// 脚本：自购 / 分享各一页；翻页游标回空页（末卡出现时生产执行器会自动翻页，回空页让页脚稳定，不挂菊花）。
    func listScript(self selfPage: String = "list_self", share: String = "list_share",
                    extra: [String: OrderVisualStub.Reply] = [:]) throws -> OrderVisualStub.Script {
        var pages: [String: OrderVisualStub.Reply] = try [
            "self": .data(OrderVisualData.page(selfPage)),
            "share": .data(OrderVisualData.page(share)),
        ]
        pages.merge(extra) { $1 }
        return OrderVisualStub.Script(pages: pages)
    }

    /// 打开列表并等稳定（有图的卡等商品图画出）。
    @discardableResult
    func openList(_ script: OrderVisualStub.Script, scope: String? = nil,
                  canvas: OrderVisualHost.Canvas = .init(), hidden: Bool = false, waitFor: String? = "order.card.A",
                  images: [String] = ["A", "C"], file: StaticString = #filePath,
                  line: UInt = #line) async throws -> (OrderVisualHost, UIImage) {
        let page = try fresh(script)
        page.setHidden(hidden)
        await page.showList(canvas, scope: scope)
        let image = await page.stable(file: file, line: line) { host, image in
            if let waitFor, host.probes[waitFor] == nil {
                return false
            }
            return images.allSatisfy { id in
                host.probes["order.card.\(id)"] == nil || host.thumbnailDrawn(image, id: id)
            }
        }
        return try (page, XCTUnwrap(image, "列表没有截到稳定画面", file: file, line: line))
    }

    // MARK: - 断言工具

    func rect(_ id: String, file: StaticString = #filePath, line: UInt = #line) throws -> CGRect {
        try XCTUnwrap(host?.probes[id], "缺测量 \(id)（§2 测量桥）", file: file, line: line).rect
    }

    func record(_ id: String, file: StaticString = #filePath,
                line: UInt = #line) throws -> CouliLayoutProbeRecord {
        try XCTUnwrap(host?.probes[id], "缺测量 \(id)（§2 测量桥）", file: file, line: line)
    }

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

    /// FU-IOS-NUM-WRAP #24（D10-1230 判据 1）：单号放不下时整段一行、在卡内横向滚动——竖向在卡内，横向完整在卡内或在卡内能横滑的滚动视图里。
    /// tests v2（#24 复核）：横滑时滚动视图可见框还必须竖向完整包住文字框（`DigitsRunJudge.visibility` → `scrollerClips`），
    /// 比行高矮、裁掉上下半截的横滑条判红。
    func assertInsideOrScrolled(_ id: String, _ outer: CGRect, width: CGFloat, _ message: String,
                                file: StaticString = #filePath, line: UInt = #line) throws {
        let item = try record(id, file: file, line: line)
        XCTAssertTrue(item.rect.minY >= outer.minY - 0.5 && item.rect.maxY <= outer.maxY + 0.5,
                      "\(message)：\(item.rect) 竖向不在 \(outer) 内", file: file, line: line)
        let tier = DigitsRunJudge.Tier(name: message, width: width, size: .large, dark: false)
        let windows = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows)
        let reports = windows.map { DigitsRunJudge.visibility(item, container: outer, window: $0, tier: tier) }
        XCTAssertTrue(reports.contains(where: \.isEmpty),
                      "\(message)：\(item.rect) 横向超出 \(outer) 且不在卡内横滑，或横滑条裁字（\(reports.flatMap(\.self).first ?? "")）",
                      file: file, line: line)
    }

    func assertDisjoint(_ lhs: CGRect, _ rhs: CGRect, _ message: String,
                        file: StaticString = #filePath, line: UInt = #line) {
        let overlap = lhs.insetBy(dx: 0.5, dy: 0.5).intersection(rhs.insetBy(dx: 0.5, dy: 0.5))
        XCTAssertTrue(overlap.isNull || overlap.isEmpty, "\(message)：\(lhs) 与 \(rhs) 重叠", file: file, line: line)
    }

    /// 命中区：≥ 44 × 44（iOS），且包住视觉框。
    func assertHit(_ hit: CGRect, covers visual: CGRect, _ message: String,
                   file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertGreaterThanOrEqual(hit.width, 43.5, "\(message)：命中区宽 \(hit.width) < 44", file: file, line: line)
        XCTAssertGreaterThanOrEqual(hit.height, 43.5, "\(message)：命中区高 \(hit.height) < 44", file: file, line: line)
        assertInside(visual, hit, "\(message)：视觉框在命中区内", file: file, line: line)
    }

    func sameRow(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        min(lhs.maxY, rhs.maxY) - max(lhs.minY, rhs.minY) > 1
    }

    /// 文字测量：设计字号（「大」档）与实际字号。
    func assertFont(_ id: String, base: CGFloat, _ message: String, file: StaticString = #filePath,
                    line: UInt = #line) throws {
        let item = try record(id, file: file, line: line)
        assertNear(item.baseFontSize, base, 0.5, "\(message)：设计字号", file: file, line: line)
    }

    /// 不可拆金额段：实际宽 ≥ 无约束自然宽（不截断、不省略、不缩字）、字号不小于设计字号、整段在容器内。
    func assertWholeAmount(_ id: String, inside container: CGRect, _ message: String,
                           file: StaticString = #filePath, line: UInt = #line) throws {
        let item = try record(id, file: file, line: line)
        XCTAssertGreaterThan(item.naturalWidth, 0, "\(message)：要报自然宽（CouliUnbreakableText 口径）", file: file,
                             line: line)
        XCTAssertGreaterThanOrEqual(item.rect.width + 0.5, item.naturalWidth,
                                    "\(message)：实际宽 \(item.rect.width) < 自然宽 \(item.naturalWidth)（被截断 / 缩字）",
                                    file: file, line: line)
        XCTAssertGreaterThanOrEqual(item.fontSize + 0.01, item.baseFontSize,
                                    "\(message)：字号 \(item.fontSize) 小于设计字号 \(item.baseFontSize)", file: file,
                                    line: line)
        assertInside(item.rect, container, "\(message)：整段在容器内（不越界、不被父裁切）", file: file, line: line)
    }

    // MARK: - 像素

    /// 区域内与背景色差异 > 40 的「墨迹」最左列（点坐标）；没有墨迹为 nil。
    func inkLeft(_ pixels: ProductVisualPixels, in rect: CGRect, background: ProductVisualPixels.RGB) -> CGFloat? {
        let scale = pixels.scale
        let xs = max(0, Int(rect.minX * scale))..<min(pixels.width, Int(rect.maxX * scale))
        let ys = max(0, Int(rect.minY * scale))..<min(pixels.height, Int(rect.maxY * scale))
        for column in xs where ys.contains(where: { !pixels.color(px: column, $0).near(background, tolerance: 40) }) {
            return CGFloat(column) / scale
        }
        return nil
    }

    /// v2（实现交回 T4 / 变异 M3）：金额段实际画出的字形要铺满它的测量框——测量框之外的父级裁切（`.frame(maxWidth:).clipped()`
    /// 挂在测量外层）只看框会漏，这里按截图墨迹核对：墨迹左右端都贴近测量框（容差 max(3, 字号 × 0.12)，即首尾字形的留白），
    /// 墨迹宽 ≥ 自然宽 − 2 × 容差。背景是金额所在卡片的底色。
    func assertAmountInkFillsFrame(_ id: String, image: UIImage, background: ProductVisualPixels.RGB,
                                   _ message: String, file: StaticString = #filePath, line: UInt = #line) throws {
        let item = try record(id, file: file, line: line)
        let pixels = ProductVisualPixels(image)
        let tolerance = max(3, item.fontSize * 0.12)
        // 横向多看一段：被裁掉的部分不会有墨迹，正常的也不该溢出框外
        let band = item.rect.insetBy(dx: -tolerance, dy: 0)
        let left = try XCTUnwrap(inkLeft(pixels, in: band, background: background), "\(message)：测量框内没有字形墨迹",
                                 file: file, line: line)
        let right = try XCTUnwrap(inkRight(pixels, in: band, background: background), file: file, line: line)
        XCTAssertLessThanOrEqual(left, item.rect.minX + tolerance,
                                 "\(message)：字形左端 \(left) 离测量框左缘 \(item.rect.minX) 太远（被裁切 / 错位）", file: file,
                                 line: line)
        XCTAssertGreaterThanOrEqual(right, item.rect.maxX - tolerance,
                                    "\(message)：字形右端 \(right) 没到测量框右缘 \(item.rect.maxX)（父级裁切截断了金额）",
                                    file: file, line: line)
        if item.naturalWidth > 0 {
            XCTAssertGreaterThanOrEqual(right - left, item.naturalWidth - 2 * tolerance,
                                        "\(message)：可见字形宽 \(right - left) < 自然宽 \(item.naturalWidth)", file: file,
                                        line: line)
        }
    }

    /// 区域内与背景色差异 > 40 的「墨迹」最右列（点坐标）；没有墨迹为 nil。
    func inkRight(_ pixels: ProductVisualPixels, in rect: CGRect,
                  background: ProductVisualPixels.RGB) -> CGFloat? {
        let scale = pixels.scale
        var best: Int?
        let xs = max(0, Int(rect.minX * scale))..<min(pixels.width, Int(rect.maxX * scale))
        let ys = max(0, Int(rect.minY * scale))..<min(pixels.height, Int(rect.maxY * scale))
        for column in xs.reversed() where ys.contains(where: {
            !pixels.color(px: column, $0).near(background, tolerance: 40)
        }) {
            best = column
            break
        }
        return best.map { CGFloat($0 + 1) / scale }
    }

    /// 区域内接近某颜色的像素数。
    func count(_ pixels: ProductVisualPixels, in rect: CGRect, near color: ProductVisualPixels.RGB,
               tolerance: Int = 10) -> Int {
        pixels.count(in: rect) { $0.near(color, tolerance: tolerance) }
    }

    /// 在相同背景上用同尺寸渲染参考 SF Symbols，判断 `rect` 里画的图标离哪个参考最近（只比「离谁近」，不依赖绝对阈值）。
    func nearestIcon(_ image: UIImage, in rect: CGRect, candidates: [String], background: Color,
                     dark: Bool) async -> String? {
        let size = rect.size
        let view = HStack(spacing: 20) {
            ForEach(candidates, id: \.self) { name in
                Image(systemName: name)
                    .font(.system(size: size.width * 0.8, weight: .regular))
                    .frame(width: size.width, height: size.height)
                    .foregroundColor(CouliColor.textPrimary)
                    .couliProbe("ref.\(name)", role: "icon")
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(background)
        let width = CGFloat(candidates.count) * (size.width + 20) + 40
        let (reference, probes) = await ProductVisualRender.standalone(
            view, size: CGSize(width: width, height: size.height + 40), dark: dark
        )
        let referencePixels = ProductVisualPixels(reference)
        let pagePixels = ProductVisualPixels(image)
        let bg = ProductVisualPixels.RGB(background, dark: dark)
        let target = ProductVisualIconProbe.ink(pagePixels, in: rect, background: bg)
        var best: (String, Int)?
        for name in candidates {
            guard let frame = probes["ref.\(name)"]?.rect else { continue }
            let ink = ProductVisualIconProbe.ink(referencePixels, in: frame, background: bg)
            let diff = ProductVisualIconProbe.difference(target, ink)
            if best.map({ diff < $0.1 }) ?? true {
                best = (name, diff)
            }
        }
        return best?.0
    }
}
