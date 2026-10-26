@testable import Couli
import DesignSystem
import Foundation
import OrderCore
import SwiftUI
import UIKit
import Vision
import XCTest

/// APP-08v-a 测试 v5（D10-362 ②-2，评审 r2 S2-1）：新用户首单前的空态——自购页「无订单 + 有待跟单卡」。
///
/// 判据（D10-362 ② 原文「【去首页逛逛】在首屏可见」；D10-366（修订 D10-364）只改 320 × AX3 一条参数，见下）：**390 宽默认字号**下
/// 页面刚打开、不滚动时，【去首页逛逛】整块在首屏可视区内且可点击：
/// - 首屏可视区 = 标题栏之下到「画布底 − 主屏指示条 − 底部 Tab 49」（本宿主不画外壳 Tab，按真机外壳高度扣掉）；
/// - 按钮按截图找（实心主按钮底色的一段连续行，高 ≥ 44），整段在可视区内，且没有被别的东西盖住（按钮中线上整段都是按钮底色）；
/// - 空态没有被惰性列表建出来（不在首屏，`orders.empty` 不上报）同样判失败；
/// - 另外核对居中口径（评审 r2 S2-1）：剩余区域放得下空态时，空态在「待跟单卡区之下到可视区底 − 24」里上下居中；
/// - 待跟单卡在空态上方，且整张在首屏（不滚动时卡底 ≤ 可视区底）。
/// 两条参数都按「按钮底 = 空态框底 − 当前档位的下内边距」认按钮（完整 / 去插图两档 32，最紧一档 12）。
///
/// **D10-366（编排裁定，已知差异；修订 D10-364）**：320 宽 × AX3 下 1 张待跟单卡比整个可视区还高（到按钮约 950 点），
/// 这一条参数改判：
/// 1. 连续滚动：列表滚动视图每次往下滚固定距离（画布高 × `dragRatio`），**最多 `maxDrags` 次**，按钮整块进可视区（标题栏底 ～ 可视区底）
///    就停；按钮高 ≥ 44。真点回首页见 UI 用例 `OrderListVisualReviewR2UITests.testFirstOrderEmptyHomeButtonAX3ScrollsThenTap`。
/// 2. 待跟单卡内容不截断（像素判据）：每一屏截图（含滚动前首屏）用 Vision 文字识别读出可视区的文字，合起来要能完整读到卡内全部文字
///    （标题、说明、通知行文案与按钮），一个字都不能少；任一屏识别出省略号（…、...、⋯）即判失败。读屏文本判据在 UI 用例里。
/// 3. 这一档不再判「卡整张在首屏」；「卡在空态上方」照判。
/// 390 默认字号与 iPhone 17 真点两条不变。
///
/// 条件：390 × 844（安全区顶 54 / 底 34）默认字号；320 × 568（iPhone SE 放大显示：顶 20 / 底 0）AX3。待跟单卡 1 张
/// （新用户第一次去下单回来，只有一张）。真点见 UI 用例 `OrderListVisualReviewR2UITests.testFirstOrderEmptyHomeButtonTappableOnFirstScreen`。
@MainActor
final class OrderListVisualReviewR2Tests: OrderVisualTestCase {
    private let tabBar: CGFloat = 49
    /// D10-366：320 × AX3 每次滚动的固定距离 = 画布高 × 0.4（与 UI 用例每次 0.75 → 0.35 的慢拖同一比例；320 × 568 下 227.2 点）。
    private let dragRatio: CGFloat = 0.4
    /// D10-366：最多滚这么多次（6 × 227.2 = 1363 点，够到约 950 点处的按钮）。
    private let maxDrags = 6

    /// 判据：首屏（不滚动）可见，或 D10-366 的「连续滚动到按钮」。
    private enum Rule {
        case firstScreen
        case scrollToButton
    }

    /// 一张未关闭的待跟单卡（淘宝；跳转时刻在固定时钟 10:30 之前），与 DebugFakeOrders 的 pending 场景同形。
    private let track: [String: Any] = [
        "link_id": "lnk-tb-01", "attempt_id": "att-tb-01", "platform": "taobao",
        "jumped_at": "2026-10-12T09:00:00+08:00", "show_claim_entry": false, "dismissed": false,
    ]

    func testFirstOrderEmptyHomeButtonOnFirstScreen390Default() async throws {
        let canvas = OrderVisualHost.Canvas(width: 390, height: 844, size: .large, top: 54, bottom: 34 + tabBar)
        try await check(canvas, name: "390×844 默认字号", rule: .firstScreen, bottomInset: CouliSpacing.s8)
    }

    /// D10-366：已知差异（编排裁定接受），只这一条参数改判「连续滚动（≤ 6 次）到按钮 + 卡内文字不截断」；按钮按最紧一档（下内边距 12）认。
    func testFirstOrderEmptyHomeButtonOnFirstScreen320AX3() async throws {
        let canvas = OrderVisualHost.Canvas(width: 320, height: 568, size: .accessibility3, top: 20, bottom: tabBar)
        try await check(canvas, name: "320×568 AX3", rule: .scrollToButton, bottomInset: CouliSpacing.s3)
    }

    private func check(_ canvas: OrderVisualHost.Canvas, name: String, rule: Rule,
                       bottomInset: CGFloat) async throws {
        var script = try listScript()
        script.pages["self"] = try .data(OrderVisualData.page("list_self_empty"))
        script.pendingTracks = [track]
        let page = try fresh(script)
        await page.showList(canvas)
        // 就绪：生产执行器到空态、待跟单卡已到；空态是否在首屏由下面判（不把它当就绪条件，免得「没建出来」被当成没稳定）
        let shot = await page.stable { host, _ in
            host.orders.listConfig?.controller.snapshot.phase == .empty
                && host.orders.listConfig?.pendingTrack?.state.cards.count == 1
                && host.probes["orders.filter.month"] != nil
        }
        let image = try XCTUnwrap(shot, "\(name)：页面没有稳定")
        let header = try rect("orders.filter.month").maxY
        let content = try rect("orders.content")
        let visibleBottom = canvas.height - canvas.bottom
        let pixels = ProductVisualPixels(image)

        // 前提：待跟单卡画在头部之下（卡片是 surface 白底、页面是 canvas 底）。往下一直找到空态顶（没建出空态时到画布底），
        // 卡伸到可视区底之外也找得到——下面据此判「整张在首屏」
        let limit = page.probes["orders.empty"].map { min($0.rect.minY, canvas.height) } ?? canvas.height
        let cardsBottom = lastRow(pixels, column: content.midX, from: header, to: limit,
                                  color: ProductVisualPixels.RGB(CouliColor.backgroundSurface, dark: false))
        let pendingBottom = try XCTUnwrap(cardsBottom, "\(name)：前提：首屏头部之下画出了待跟单卡（白底卡片）")
        if let empty = page.probes["orders.empty"]?.rect {
            XCTAssertLessThanOrEqual(pendingBottom, empty.minY + 0.5,
                                     "\(name)：待跟单卡在空态上方（卡底 \(pendingBottom) / 空态顶 \(empty.minY)）")
        }
        if rule == .scrollToButton {
            // D10-366 ③：这一档不判「卡整张在首屏」
            try await checkScrollToButton(page, canvas: canvas, name: name, firstShot: image, bottomInset: bottomInset)
            return
        }
        XCTAssertLessThanOrEqual(pendingBottom, visibleBottom + 0.5,
                                 "\(name)：待跟单卡整张在首屏（卡底 \(pendingBottom) / 可视区底 \(visibleBottom)）")

        guard let empty = page.probes["orders.empty"]?.rect else {
            XCTFail("\(name)：【去首页逛逛】不在首屏——空态没有进入可视区（惰性列表没建出来）；头部底 \(header)，" +
                "待跟单卡底 \(pendingBottom)，可视区底 \(visibleBottom)")
            return
        }
        guard let button = findButton(pixels, empty: empty, canvas: canvas, bottomInset: bottomInset,
                                      name: "\(name)（首屏）")
        else { return }
        XCTAssertGreaterThanOrEqual(button.minY, pendingBottom, "\(name)：按钮在待跟单卡之下，没有被卡片盖住")
        XCTAssertLessThanOrEqual(
            button.maxY,
            visibleBottom + 0.5,
            "\(name)：【去首页逛逛】整块在首屏可视区内（按钮 \(button.minY)–\(button.maxY) / 可视区底 \(visibleBottom)；" +
                "空态 \(empty)；待跟单卡底 \(pendingBottom)）"
        )

        assertCentered(empty, below: pendingBottom, visibleBottom: visibleBottom, name: name)
    }

    /// D10-366（320 × AX3，已知差异）：从首屏开始，每次把列表滚动视图往下滚固定距离（画布高 × `dragRatio`，到底为止），最多 `maxDrags` 次，
    /// 按钮整块进可视区（标题栏底 ～ 可视区底）即停；每一屏都读一遍可视区文字，最后核卡内文字完整、没有省略号。
    private func checkScrollToButton(_ page: OrderVisualHost, canvas: OrderVisualHost.Canvas, name: String,
                                     firstShot: UIImage, bottomInset: CGFloat) async throws {
        let visibleBottom = canvas.height - canvas.bottom
        let titleBottom = try rect("orders.titleRow").maxY
        let expected = try cardTexts(page)
        let window = try XCTUnwrap(page.window, "\(name)：没有窗口")
        let scroller = try XCTUnwrap(Self.listScrollView(in: window), "\(name)：订单列表没有可滚动的滚动视图")
        let region = CGRect(x: 0, y: titleBottom, width: canvas.width, height: visibleBottom - titleBottom)
        var image = firstShot
        var lines: [String] = []
        var drags = 0
        while true {
            lines += CardTextReader.lines(image, region: region)
            if let empty = page.probes["orders.empty"]?.rect,
               let button = buttonRun(ProductVisualPixels(image), empty: empty, canvas: canvas),
               button.minY >= titleBottom - 0.5, button.maxY <= visibleBottom + 0.5 {
                break
            }
            guard drags < maxDrags else { break }
            let maxOffset = max(0, scroller.contentSize.height - scroller.bounds.height
                + scroller.adjustedContentInset.bottom)
            let target = min(scroller.contentOffset.y + canvas.height * dragRatio, maxOffset)
            scroller.setContentOffset(CGPoint(x: scroller.contentOffset.x, y: target), animated: false)
            drags += 1
            let shot = await page.stable()
            image = try XCTUnwrap(shot, "\(name)：第 \(drags) 次滚动后页面没有稳定")
        }
        let place = "\(name)（滚 \(drags) 次、偏移 \(scroller.contentOffset.y) 后）"
        guard let empty = page.probes["orders.empty"]?.rect else {
            XCTFail("\(place)：滚满 \(maxDrags) 次空态仍没建出来（列表内容高 \(scroller.contentSize.height)）")
            return
        }
        if let button = findButton(ProductVisualPixels(image), empty: empty, canvas: canvas, bottomInset: bottomInset,
                                   name: place) {
            let span = "按钮 \(button.minY)–\(button.maxY)"
            XCTAssertGreaterThanOrEqual(button.minY, titleBottom - 0.5,
                                        "\(place)：【去首页逛逛】上缘在标题栏之下（\(span) / 标题栏底 \(titleBottom)）")
            XCTAssertLessThanOrEqual(button.maxY, visibleBottom + 0.5,
                                     "\(place)：【去首页逛逛】整块在可视区内（\(span) / 可视区底 \(visibleBottom)）")
        }
        // D10-366 ②（像素判据）：滚动过程中完整读到卡内全部文字，不出现省略号
        let read = lines.joined(separator: " | ")
        for text in expected {
            let missing = CardTextReader.missing(text, in: lines)
            XCTAssertTrue(missing.isEmpty, "\(name)：待跟单卡文字「\(text)」没有完整读到，缺「\(missing)」（识别结果：\(read)）")
        }
        let cut = lines.filter(CardTextReader.hasEllipsis)
        XCTAssertTrue(cut.isEmpty, "\(name)：滚动过程中出现省略号（文字被截断）：\(cut)")
    }

    /// 卡内应出现的全部文字（取生产文案字典：标题、说明（平台名代入）；有通知行时再加通知行文案与【开启通知】）。
    private func cardTexts(_ page: OrderVisualHost) throws -> [String] {
        let config = try XCTUnwrap(page.orders.listConfig, "没有列表配置")
        let card = try XCTUnwrap(config.pendingTrack?.state.cards.first, "没有待跟单卡")
        let texts = config.texts
        var result = [
            texts.text("pending_track_card.title"),
            texts.format("pending_track_card.desc", ["platform_name": texts.text("platform." + card.platform)]),
        ]
        if card.notificationRow {
            result += [texts.text("perm.push.card_hint"), texts.text("perm.push.cta")]
        }
        return result
    }

    /// 按截图找【去首页逛逛】的实际画面：空态框内自下而上第一段连续的「这一行至少 24 个点是主按钮底色」的像素行（按钮文字在中间，
    /// 两侧内边距各 ≥ 16，所以不按单列找、也不按比例找）。按钮是空态框里最后一块，其下是当前档位的下内边距（完整 / 去插图 32，
    /// 最紧 12），据此核对找到的就是按钮；另核高 ≥ 44。
    private func findButton(_ pixels: ProductVisualPixels, empty: CGRect, canvas: OrderVisualHost.Canvas,
                            bottomInset: CGFloat, name: String) -> CGRect? {
        let (bottom, top) = buttonEdges(pixels, empty: empty, canvas: canvas)
        guard let buttonBottom = bottom, let buttonTop = top else {
            XCTFail("\(name)：【去首页逛逛】没有完整画出——空态 \(empty)，可视区底 \(canvas.height - canvas.bottom)" +
                "（画布底 \(canvas.height)；按钮底色在空态框内\(bottom == nil ? "一行也没有" : "没找到上缘")）")
            return nil
        }
        let button = CGRect(x: empty.minX, y: buttonTop, width: empty.width, height: buttonBottom - buttonTop)
        XCTAssertGreaterThanOrEqual(button.height, 43.5, "\(name)：【去首页逛逛】可点区域 ≥ 44（实测 \(button.height)）")
        assertNear(button.maxY, empty.maxY - bottomInset, 2,
                   "\(name)：找到的是【去首页逛逛】本身（按钮底 = 空态框底 − 当前档位下内边距 \(bottomInset)）")
        return button
    }

    /// 空态框内按钮底色那一段的（下缘，上缘）。
    private func buttonEdges(_ pixels: ProductVisualPixels, empty: CGRect,
                             canvas: OrderVisualHost.Canvas) -> (CGFloat?, CGFloat?) {
        let fill = ProductVisualPixels.RGB(CouliColor.token("button.primary.default.background"), dark: false)
        return lowestRun(pixels, span: empty.minX..<empty.maxX, from: min(empty.maxY, canvas.height), to: empty.minY,
                         color: fill)
    }

    /// 不断言的找按钮（连续滚动时判「出现了没有」用）：上下缘都找到且高 ≥ 44 才算。
    private func buttonRun(_ pixels: ProductVisualPixels, empty: CGRect, canvas: OrderVisualHost.Canvas) -> CGRect? {
        let (bottom, top) = buttonEdges(pixels, empty: empty, canvas: canvas)
        guard let bottom, let top, bottom - top >= 43.5 else { return nil }
        return CGRect(x: empty.minX, y: top, width: empty.width, height: bottom - top)
    }

    /// 订单列表的滚动视图：竖向、面积最大的那个（排除横滑胶囊等小滚动区）。
    static func listScrollView(in root: UIView) -> UIScrollView? {
        var found: [UIScrollView] = []
        func walk(_ view: UIView) {
            if let scroll = view as? UIScrollView, !scroll.isHidden, scroll.window != nil,
               scroll.contentSize.height > scroll.contentSize.width / 4 {
                found.append(scroll)
            }
            view.subviews.forEach(walk)
        }
        walk(root)
        return found.max { lhs, rhs in
            lhs.bounds.width * lhs.bounds.height < rhs.bounds.width * rhs.bounds.height
        }
    }

    /// 居中口径（评审 r2 S2-1）：剩余区域放得下空态时，在扣掉待跟单卡区（卡 + 其下 12）后的区域里上下居中；放不下时紧接。
    private func assertCentered(_ empty: CGRect, below pendingBottom: CGFloat, visibleBottom: CGFloat, name: String) {
        let areaTop = pendingBottom + CouliSpacing.s3
        let areaBottom = visibleBottom - CouliSpacing.s6
        if areaBottom - areaTop >= empty.height + 1 {
            let above = empty.minY - areaTop
            let below = areaBottom - empty.maxY
            assertNear(above, below, 2, "\(name)：空态在扣掉待跟单卡区后的区域里上下居中（上 \(above) / 下 \(below)）")
        } else {
            assertNear(empty.minY, areaTop, 2, "\(name)：放不下时空态紧接待跟单卡区，不多出空白")
        }
    }

    /// 竖线 column 上 [from, to) 内最后一个接近 color 的像素行的下缘。
    private func lastRow(_ pixels: ProductVisualPixels, column: CGFloat, from: CGFloat, to: CGFloat,
                         color: ProductVisualPixels.RGB) -> CGFloat? {
        let step = 1 / pixels.scale
        var found: CGFloat?
        var row = from
        while row < to {
            if pixels.color(at: CGPoint(x: column, y: row)).near(color, tolerance: 3) {
                found = row + step
            }
            row += step
        }
        return found
    }

    /// 横向 span 内，自 from 往上到 to，第一段连续「这一行至少 24 个点接近 color」的行：（下缘，上缘）；没找到上缘时上缘为 nil。
    private func lowestRun(_ pixels: ProductVisualPixels, span: Range<CGFloat>, from: CGFloat, to: CGFloat,
                           color: ProductVisualPixels.RGB) -> (CGFloat?, CGFloat?) {
        let step = 1 / pixels.scale
        let columns = Array(stride(from: span.lowerBound + 0.5, to: span.upperBound, by: 1))
        var bottom: CGFloat?
        var scan = from - step
        while scan >= to {
            let matched = columns.filter { pixels.color(at: CGPoint(x: $0, y: scan)).near(color, tolerance: 3) }.count
            let hit = matched >= 24
            if hit, bottom == nil {
                bottom = scan + step
            } else if !hit, bottom != nil {
                return (bottom, scan + step)
            }
            scan -= step
        }
        return (bottom, nil)
    }
}

/// 按截图读文字（Vision 文字识别，简体中文，不做语言纠正）：D10-366 ②「待跟单卡内容不截断」的像素判据。
enum CardTextReader {
    /// 图上 region（点坐标）内识别出的各行文字。
    static func lines(_ image: UIImage, region: CGRect) -> [String] {
        guard let cgImage = image.cgImage else { return [] }
        let scale = image.scale
        let bounds = CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height)
        let crop = CGRect(x: region.minX * scale, y: region.minY * scale, width: region.width * scale,
                          height: region.height * scale).integral.intersection(bounds)
        guard !crop.isEmpty, let part = cgImage.cropping(to: crop) else { return [] }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["zh-Hans"]
        request.usesLanguageCorrection = false
        try? VNImageRequestHandler(cgImage: part).perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
    }

    /// 只留文字与数字（标点、空白不比）。
    static func normalized(_ text: String) -> [Character] {
        text.filter { $0.isLetter || $0.isNumber }.map(\.self)
    }

    /// text 里没被任何识别行覆盖到的字（按原顺序拼起来；空 = 全部读到）。覆盖：整行（规范化后）出现在 text 里即覆盖那几处；
    /// 否则行内连续 ≥ 3 个字出现在 text 里才覆盖（容忍识别行前后带进的图标等杂字，又不让两个字的常见词跨文案凑数）。
    static func missing(_ text: String, in lines: [String]) -> String {
        let target = normalized(text)
        var covered = Array(repeating: false, count: target.count)
        func mark(_ piece: ArraySlice<Character>) -> Bool {
            guard !piece.isEmpty, piece.count <= target.count else { return false }
            var hit = false
            for start in 0...(target.count - piece.count)
                where target[start..<(start + piece.count)].elementsEqual(piece) {
                (start..<(start + piece.count)).forEach { covered[$0] = true }
                hit = true
            }
            return hit
        }
        for line in lines {
            let chars = normalized(line)
            if mark(chars[...]) {
                continue
            }
            var index = 0
            while index < chars.count {
                var length = chars.count - index
                while length >= 3, !mark(chars[index..<(index + length)]) {
                    length -= 1
                }
                index += length >= 3 ? length : 1
            }
        }
        return String(zip(target, covered).filter { !$0.1 }.map(\.0))
    }

    static func hasEllipsis(_ line: String) -> Bool {
        line.contains("…") || line.contains("...") || line.contains("⋯")
    }
}
