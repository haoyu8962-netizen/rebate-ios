@testable import Couli
import DesignSystem
import Foundation
import SwiftUI
import UIKit
import Wallet
import WalletCore
import XCTest

/// APP-09v-a 钱包视觉用例的公共底座：每个页面一个新的偏好套件与缓存目录；网络是生产 WalletStubProtocol + WalletScript。
@MainActor
class WalletVisualTestCase: XCTestCase {
    var suiteName = ""
    var defaults: UserDefaults!
    var host: WalletVisualHost?
    let texts = WalletDraftTexts()

    override func setUpWithError() throws {
        WalletStubProtocol.reset()
    }

    override func tearDown() async throws {
        host?.close()
        host = nil
        clean()
        WalletStubProtocol.reset()
    }

    private func clean() {
        // 没建过套件时 suiteName 为空：拼出来的是整个临时目录，不能删（APP-06v 宿主问题 2）。
        guard !suiteName.isEmpty else { return }
        defaults?.removePersistentDomain(forName: suiteName)
        try? FileManager.default
            .removeItem(at: FileManager.default.temporaryDirectory.appendingPathComponent(suiteName))
    }

    func fresh() throws -> WalletVisualHost {
        host?.close()
        host = nil
        WalletStubProtocol.reset()
        clean()
        suiteName = "wallet-visual-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let script = WalletScript()
        script.install()
        let page = WalletVisualHost(suiteName: suiteName, defaults: defaults, script: script)
        host = page
        return page
    }

    /// 用 visualWallet 的一份摘要打开钱包并等稳定（就绪 = 执行器到 content 且 `waitFor` 测量已上报）。
    @discardableResult
    func openWallet(_ summary: String, canvas: WalletVisualHost.Canvas = .init(), hidden: Bool = false,
                    earnings: Bool = false, waitFor: String? = "wallet.hero", file: StaticString = #filePath,
                    line: UInt = #line) async throws -> (WalletVisualHost, UIImage) {
        let page = try fresh()
        try WalletVisualScript.summary(page.script, summary)
        page.setHidden(hidden)
        if earnings {
            await page.showWalletWithEarnings(canvas)
        } else {
            try await page.showWallet(canvas)
        }
        let image = await page.stable(file: file, line: line) { host in
            host.controller?.state.phase == .content && (waitFor.map { host.probes[$0] != nil } ?? true)
        }
        return try (page, XCTUnwrap(image, "钱包没有截到稳定画面", file: file, line: line))
    }

    /// 断网 + 缓存（WalletStale）。
    @discardableResult
    func openStale(_ summary: String = "normal", canvas: WalletVisualHost.Canvas = .init(),
                   waitFor: String? = "wallet.stale", file: StaticString = #filePath,
                   line: UInt = #line) async throws -> (WalletVisualHost, UIImage) {
        let page = try fresh()
        try await page.prepareStale(summary: summary, canvas, file: file, line: line)
        let image = await page.stable(file: file, line: line) { host in
            host.controller?.state.staleAt != nil && (waitFor.map { host.probes[$0] != nil } ?? true)
        }
        return try (page, XCTUnwrap(image, file: file, line: line))
    }

    // MARK: - 测量

    func rect(_ id: String, file: StaticString = #filePath, line: UInt = #line) throws -> CGRect {
        try XCTUnwrap(host?.probes[id], "缺测量 \(id)（§2 测量桥）", file: file, line: line).rect
    }

    func record(_ id: String, file: StaticString = #filePath,
                line: UInt = #line) throws -> CouliLayoutProbeRecord {
        try XCTUnwrap(host?.probes[id], "缺测量 \(id)（§2 测量桥）", file: file, line: line)
    }

    /// 测量上报的显示文字。
    func text(_ id: String, file: StaticString = #filePath, line: UInt = #line) throws -> String {
        try record(id, file: file, line: line).text
    }

    /// 全部测量里显示的文字（资金红线：原值 / 推算值不能出现在任何位置）。
    var allTexts: [String] {
        host?.probes.records.values.map(\.text).filter { !$0.isEmpty } ?? []
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

    func assertDisjoint(_ lhs: CGRect, _ rhs: CGRect, _ message: String,
                        file: StaticString = #filePath, line: UInt = #line) {
        let overlap = lhs.insetBy(dx: 0.5, dy: 0.5).intersection(rhs.insetBy(dx: 0.5, dy: 0.5))
        XCTAssertTrue(overlap.isNull || overlap.isEmpty, "\(message)：\(lhs) 与 \(rhs) 重叠", file: file, line: line)
    }

    /// 命中区：≥ 44 × 44（iOS），且包住视觉框。
    func assertHit(_ hitID: String, covers visualID: String, _ message: String,
                   file: StaticString = #filePath, line: UInt = #line) throws {
        let hit = try rect(hitID, file: file, line: line)
        let visual = try rect(visualID, file: file, line: line)
        XCTAssertGreaterThanOrEqual(hit.width, 43.5, "\(message)：命中区宽 \(hit.width) < 44", file: file, line: line)
        XCTAssertGreaterThanOrEqual(hit.height, 43.5, "\(message)：命中区高 \(hit.height) < 44", file: file, line: line)
        assertInside(visual, hit, "\(message)：视觉框在命中区内", file: file, line: line)
    }

    /// 文字设计字号（「大」档）。
    func assertBase(_ id: String, _ base: CGFloat, _ message: String, file: StaticString = #filePath,
                    line: UInt = #line) throws {
        let item = try record(id, file: file, line: line)
        assertNear(item.baseFontSize, base, 0.5, "\(message)：设计字号", file: file, line: line)
    }

    /// 不可拆金额段（CouliUnbreakableText 口径）：实际宽 ≥ 无约束自然宽（不截断、不省略、不缩字）、字号不小于设计字号、整段在容器内。
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

    func pixel(_ color: Color, dark: Bool) -> ProductVisualPixels.RGB {
        ProductVisualPixels.RGB(color, dark: dark)
    }

    /// 区域内接近某颜色的像素占比（0…1）。
    func share(_ image: UIImage, in rect: CGRect, near color: ProductVisualPixels.RGB, tolerance: Int = 10) -> Double {
        let pixels = ProductVisualPixels(image)
        let total = pixels.count(in: rect) { _ in true }
        guard total > 0 else { return 0 }
        return Double(pixels.count(in: rect) { $0.near(color, tolerance: tolerance) }) / Double(total)
    }

    /// 区域内接近某颜色的像素数（墨迹颜色判断用）。
    func count(_ image: UIImage, in rect: CGRect, near color: ProductVisualPixels.RGB, tolerance: Int = 24) -> Int {
        ProductVisualPixels(image).count(in: rect) { $0.near(color, tolerance: tolerance) }
    }

    /// 区域内与背景色差异 > 40 的「墨迹」最左列（点坐标）。
    func inkLeft(_ pixels: ProductVisualPixels, in rect: CGRect, background: ProductVisualPixels.RGB) -> CGFloat? {
        let scale = pixels.scale
        let xs = max(0, Int(rect.minX * scale))..<min(pixels.width, Int(rect.maxX * scale))
        let ys = max(0, Int(rect.minY * scale))..<min(pixels.height, Int(rect.maxY * scale))
        for column in xs where ys.contains(where: { !pixels.color(px: column, $0).near(background, tolerance: 40) }) {
            return CGFloat(column) / scale
        }
        return nil
    }

    /// 区域内与背景色差异 > 40 的「墨迹」最右列（点坐标）。
    func inkRight(_ pixels: ProductVisualPixels, in rect: CGRect, background: ProductVisualPixels.RGB) -> CGFloat? {
        let scale = pixels.scale
        let xs = max(0, Int(rect.minX * scale))..<min(pixels.width, Int(rect.maxX * scale))
        let ys = max(0, Int(rect.minY * scale))..<min(pixels.height, Int(rect.maxY * scale))
        for column in xs.reversed() where ys.contains(where: {
            !pixels.color(px: column, $0).near(background, tolerance: 40)
        }) {
            return CGFloat(column + 1) / scale
        }
        return nil
    }

    /// 金额段实际画出的字形铺满测量框（APP-08v 测试 v2 / 变异 M3：只看框会漏掉测量外层的父级裁切）：墨迹左右端贴近测量框
    /// （容差 max(3, 字号 × 0.25)：等宽数字里「1」的字形右侧留白实测约 0.2 字号；被裁掉一半的金额仍远超容差），可见墨迹宽 ≥ 自然宽 − 2 × 容差。`background` 是金额所在底色。
    func assertAmountInkFillsFrame(_ id: String, image: UIImage, background: ProductVisualPixels.RGB,
                                   _ message: String, file: StaticString = #filePath, line: UInt = #line) throws {
        let item = try record(id, file: file, line: line)
        let pixels = ProductVisualPixels(image)
        let tolerance = max(3, item.fontSize * 0.25)
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

    /// 在相同背景上用同尺寸渲染参考 SF Symbols，判断 `rect` 里画的图标离哪个参考最近（只比「离谁近」，不依赖绝对阈值）。
    /// 浅色外观（参考图标与页面同一外观；深色图标不在本组判据范围）。
    func nearestIcon(_ image: UIImage, in rect: CGRect, candidates: [String], background: Color,
                     ink: Color) async -> String? {
        let dark = false
        let size = rect.size
        let view = HStack(spacing: 20) {
            ForEach(candidates, id: \.self) { name in
                Image(systemName: name)
                    .resizable()
                    .scaledToFit()
                    .frame(width: size.width, height: size.height)
                    .foregroundColor(ink)
                    .couliProbe("ref.\(name)", role: "icon")
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(background)
        let width = CGFloat(candidates.count) * (size.width + 20) + 40
        let bg = ProductVisualPixels.RGB(background, dark: dark)
        let (reference, probes) = await WalletVisualRender.standalone(
            view, size: CGSize(width: width, height: size.height + 40)
        ) { pixels in
            pixels.count(in: CGRect(x: 0, y: 0, width: width, height: size.height + 40)) { !$0.near(bg, tolerance: 40) }
                > 20 * candidates.count
        }
        let referencePixels = ProductVisualPixels(reference)
        let pagePixels = ProductVisualPixels(image)
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

    func sameRow(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        min(lhs.maxY, rhs.maxY) - max(lhs.minY, rhs.minY) > 1
    }

    /// 钱包页摘要以外的请求（rules、getMe、写请求）——钱包页只读，不预取 rules（G-W02）、不取 getMe（G-W03）。
    var nonSummaryRequests: [String] {
        WalletStubProtocol.requests.filter { $0.path != "/v1/wallet/summary" }.map { "\($0.method) \($0.path)" }
    }

    var summaryRequests: Int {
        WalletStubProtocol.requests("GET", "/v1/wallet/summary").count
    }
}

/// 判据参考图的独立渲染（浅色、字号「大」）：与 `ProductVisualRender.standalone` 同一宿主场景与截图管线，但测量接收方**忽略「消失」**，
/// 并在拆窗之前取走记录——拆窗时各视图的 onDisappear 会把记录删光（v1 首轮实测：ForEach 里的参考图标记录为空）。
@MainActor
enum WalletVisualRender {
    static func standalone(_ view: some View, size: CGSize,
                           until ready: (ProductVisualPixels) -> Bool) async
        -> (UIImage, [String: CouliLayoutProbeRecord]) {
        var records: [String: CouliLayoutProbeRecord] = [:]
        let probe = CouliLayoutProbe(report: { records[$0.id] = $0 }, remove: { _ in })
        let root = view.environment(\.couliLayoutProbe, probe).environment(\.colorScheme, .light)
            .environment(\.dynamicTypeSize, .large)
        let host = UIHostingController(rootView: root)
        if #available(iOS 16.4, *) {
            host.safeAreaRegions = []
        }
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let window = scene.map { UIWindow(windowScene: $0) } ?? UIWindow()
        window.frame = CGRect(origin: .zero, size: size)
        window.overrideUserInterfaceStyle = .light
        window.windowLevel = .alert + 2
        window.rootViewController = host
        window.makeKeyAndVisible()
        var image = UIImage()
        for _ in 0..<20 {
            try? await Task.sleep(for: .milliseconds(300))
            image = ProductVisualRender.image(window)
            if ready(ProductVisualPixels(image)) {
                break
            }
        }
        let taken = records
        window.isHidden = true
        window.rootViewController = nil
        return (image, taken)
    }
}

/// a v2 / v3（实现交回 T2、评审 r1 S1-2）的「放不下时」金额判据（放在扩展里：类体长度上限）。
/// FU-IOS-NUM-WRAP（D10-1230 判据 1，#24 改）：旧口径「单段放不下时段内折行」作废——数字串任何字号宽度都不在中间断，
/// 放不下时整段一行、在容器内横向滚动。名字沿用，调用方不变。
/// tests v2（#24 复核 FAIL 后修正，只可更严）：只去掉与「整段一行、框内横滑」真冲突的横向在容器内与「字形块数 = 全部字数」，
/// 其余加回——竖向在容器内；横滑条可见框竖向完整包住文字框；可见部分像素核字（恰一行墨迹、墨迹高够一个数字、
/// 从框左缘起一直铺到横滑条可见右缘，没有被裁掉上下半截、开头或末端没缺字）。
/// 注意：只核墨迹两端与行数，可见区中间漏掉一个字形查不出来（tests v3 按评审 r1 S2-3 如实写明）。
extension WalletVisualTestCase {
    func assertWrappedAmount(_ id: String, inside container: CGRect, image: UIImage,
                             background: ProductVisualPixels.RGB, _ message: String, file: StaticString = #filePath,
                             line: UInt = #line) async throws {
        let item = try record(id, file: file, line: line)
        XCTAssertGreaterThan(item.naturalWidth, 0, "\(message)：要报自然宽", file: file, line: line)
        XCTAssertGreaterThanOrEqual(item.fontSize + 0.01, item.baseFontSize, "\(message)：字号不缩", file: file, line: line)
        XCTAssertGreaterThanOrEqual(item.rect.width + 0.5, item.naturalWidth,
                                    "\(message)：整段一行（实际宽 \(item.rect.width) < 自然宽 \(item.naturalWidth)）",
                                    file: file, line: line)
        XCTAssertTrue(item.rect.minY >= container.minY - 0.5 && item.rect.maxY <= container.maxY + 0.5,
                      "\(message)：文字框 \(item.rect) 竖向不在容器 \(container) 内（越出 / 被裁）", file: file, line: line)
        let windows = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows)
        let found = windows.lazy.compactMap {
            DigitsRunJudge.horizontalScroller(around: item.rect, inside: container, window: $0)
        }.first
        let scroller = try XCTUnwrap(found, "\(message)：放不下时要在容器 \(container) 内横向滚动（框 \(item.rect)）",
                                     file: file, line: line)
        let clipped = DigitsRunJudge.scrollerClips(scroller, rect: item.rect)
        XCTAssertEqual(clipped, [], "\(message)", file: file, line: line)
        // 可见部分：文字框 ∩ 横滑条可见框 ∩ 容器（截图与测量同为窗口坐标）
        let visible = item.rect.intersection(scroller.convert(scroller.bounds, to: nil)).intersection(container)
        XCTAssertFalse(visible.isNull || visible.width < 1, "\(message)：文字框在横滑条里不可见（\(item.rect)）",
                       file: file, line: line)
        guard !visible.isNull, visible.width >= 1 else { return }
        let pixels = ProductVisualPixels(image)
        let rows = DigitsRunJudge.inkRows(pixels, in: visible, background: background)
        XCTAssertEqual(rows.count, 1, "\(message)：可见部分应恰一行墨迹（\(rows)，框 \(visible)）", file: file, line: line)
        if let row = rows.first {
            XCTAssertGreaterThanOrEqual(row.upperBound - row.lowerBound, item.fontSize * 0.6,
                                        "\(message)：墨迹高 \(row.upperBound - row.lowerBound) 不够一个数字（字号 \(item.fontSize)），"
                                            + "上下半截被裁", file: file, line: line)
        }
        let tolerance = max(3, item.fontSize * 0.5)
        let left = try XCTUnwrap(inkLeft(pixels, in: visible, background: background),
                                 "\(message)：可见部分没有字形墨迹", file: file, line: line)
        let right = try XCTUnwrap(inkRight(pixels, in: visible, background: background), file: file, line: line)
        XCTAssertLessThanOrEqual(left, item.rect.minX + tolerance, "\(message)：字形左端 \(left) 离文字框左缘太远（缺字 / 错位）",
                                 file: file, line: line)
        XCTAssertGreaterThanOrEqual(right, visible.maxX - tolerance,
                                    "\(message)：字形右端 \(right) 没铺到可见右缘 \(visible.maxX)（横滑内容缺字）", file: file,
                                    line: line)
    }
}
