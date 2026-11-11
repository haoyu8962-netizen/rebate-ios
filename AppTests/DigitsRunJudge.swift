@testable import Couli
import DesignSystem
import Foundation
import SwiftUI
import UIKit
import XCTest

/// FU-IOS-NUM-WRAP（D10-1230 判据 1，QA-11）：订单号、金额、手机号 / 脱敏账号、流水号这类数字串，任何字号和宽度下都不在中间断开；
/// 放不下时整段换到下一行、改上下排，或在框内横向滚动；不缩字硬塞。进程内按生产组件上报的测量（`CouliLayoutProbeRecord`）判：
///
/// 1. **数字段整段**：记录文字里每个数字段（连续的数字 / `.` / `,` / `*`，连同紧挨着的前缀 `¥`、正负号）按记录字号量单行宽，
///    必须 ≤ 文字实际框宽 + 1。多行文字的框宽 = 最宽一行；数字段若被拆到两行，最宽一行一定比它窄（折到下一行整段放得下时不算断）。
///    记录带自然宽（`naturalWidth`）时按「自然宽 ÷ 本判据量的整串宽」修正字重差（限 0.85–1.25）。
/// 2. **单行不截不缩**：框高 < 1.8 倍行高（单行）时，框宽 + 1 ≥ 整串单行宽（没截断、没被 minimumScaleFactor 一类缩窄）。
/// 3. **字号真放大**：辅助字号档（AX1 起）实际字号 > 设计字号 × 1.3；任何档实际字号 ≥ 设计字号。
/// 4. **看得见**：文字框横向完整落在容器（卡片 / 输入框）内；不在时必须在一个能横向滚动的系统滚动视图里
///    （可见框在容器内、与文字同一行高度、内容宽 ≥ 文字框宽）——「框内横滑」的进程内证据。
@MainActor
enum DigitsRunJudge {
    struct Tier {
        let name: String
        let width: CGFloat
        let size: DynamicTypeSize
        let dark: Bool

        var accessibility: Bool {
            size.isAccessibilitySize
        }
    }

    /// 四档（同 FU-IOS-BINDPHONE-LAYOUT）：正常 / 200% / 320 宽 + 200% / AXXXL；浅深各至少一档（200% 390 档用深色）。
    /// 「200%」取本仓库 font200 截图同一档 `accessibility3`（约 235%，QA-11 审出数字断行的就是这一档，覆盖 200%）。
    static let tiers: [Tier] = [
        Tier(name: "正常 390 浅", width: 390, size: .large, dark: false),
        Tier(name: "200%（AX3）390 深", width: 390, size: .accessibility3, dark: true),
        Tier(name: "320 宽 + 200%（AX3）浅", width: 320, size: .accessibility3, dark: false),
        Tier(name: "AXXXL（AX5）390 浅", width: 390, size: .accessibility5, dark: false),
    ]

    // MARK: - 数字段

    /// 文字里的数字段（含紧挨着的 `¥` / 正负号前缀；`*` 算在段内：脱敏账号「138****5678」整段）。
    static func runs(_ text: String) -> [String] {
        var result: [String] = []
        var current = ""
        var prefix = ""
        func flush() {
            if current.contains(where: \.isNumber) {
                result.append(prefix + current)
            }
            current = ""
            prefix = ""
        }
        for character in text {
            if character.isNumber || (!current.isEmpty && ".,*".contains(character))
                || (current.isEmpty && character == "*") {
                current.append(character)
            } else {
                flush()
                if "¥￥-−+".contains(character) {
                    prefix = String(character)
                }
            }
        }
        flush()
        return result
    }

    static func font(_ size: CGFloat, weight: UIFont.Weight) -> UIFont {
        UIFont.monospacedDigitSystemFont(ofSize: size, weight: weight)
    }

    static func width(_ text: String, size: CGFloat, weight: UIFont.Weight) -> CGFloat {
        (text as NSString).size(withAttributes: [.font: font(size, weight: weight)]).width
    }

    /// 单行行高：系统字体与苹方（中文回落）取大。
    static func lineHeight(_ size: CGFloat, weight: UIFont.Weight = .regular) -> CGFloat {
        let system = font(size, weight: weight).lineHeight
        let pingfang = UIFont(name: "PingFangSC-Regular", size: size)?.lineHeight ?? system
        return max(system, pingfang)
    }

    // MARK: - 判据

    /// 一条数字记录的全部问题（空 = 通过）。`weight`：组件实际字重（量宽用）；`container`：卡片 / 输入框的框（窗口坐标）。
    static func problems(_ item: CouliLayoutProbeRecord, weight: UIFont.Weight = .regular, container: CGRect,
                         window: UIWindow?, tier: Tier) -> [String] {
        var found: [String] = []
        let label = "\(item.id)「\(item.text)」"
        let runs = runs(item.text)
        if runs.isEmpty {
            found.append("\(label)：测量文字里没有数字段（测量桥上报的不是数字本身）")
        }
        guard item.fontSize > 0 else {
            return found + ["\(label)：没有上报字号"]
        }
        let measured = width(item.text, size: item.fontSize, weight: weight)
        var factor: CGFloat = 1
        if item.naturalWidth > 0, measured > 0 {
            factor = min(max(item.naturalWidth / measured, 0.85), 1.25)
        }
        for run in runs {
            let need = width(run, size: item.fontSize, weight: weight) * factor
            if need > item.rect.width + 1 {
                found.append("\(label)：数字段「\(run)」单行要 \(fmt(need))pt，文字框最宽一行只有 \(fmt(item.rect.width))pt"
                    + "——被拆成多行或被截 / 缩（框 \(item.rect)）")
            }
        }
        let line = lineHeight(item.fontSize, weight: weight)
        if item.rect.height < line * 1.8, item.rect.width + 1 < measured * factor {
            found.append("\(label)：单行框宽 \(fmt(item.rect.width)) < 整串单行宽 \(fmt(measured * factor))（被截断或缩字）")
        }
        if item.baseFontSize > 0 {
            if item.fontSize + 0.01 < item.baseFontSize {
                found.append("\(label)：字号 \(fmt(item.fontSize)) 小于设计字号 \(fmt(item.baseFontSize))（缩字）")
            }
            if tier.accessibility, item.fontSize <= item.baseFontSize * 1.3 {
                found.append("\(label)：\(tier.name) 字号只有 \(fmt(item.fontSize))（设计 \(fmt(item.baseFontSize))），没有真放大")
            }
        }
        found += visibility(item, container: container, window: window, tier: tier)
        return found
    }

    /// 判据 4：横向完整在容器内，或在容器内一个能横向滚动的系统滚动视图里。
    static func visibility(_ item: CouliLayoutProbeRecord, container: CGRect, window: UIWindow?,
                           tier: Tier) -> [String] {
        let rect = item.rect
        // tests v2：竖向也要完整在容器内（横滑条撑高后压出卡底 / 被卡裁掉下半截）
        if rect.minY < container.minY - 0.5 || rect.maxY > container.maxY + 0.5 {
            return ["\(item.id)「\(item.text)」：文字框 \(rect) 竖向不在容器 \(container) 内（越出 / 被裁）"]
        }
        let fits = rect.minX >= container.minX - 0.5 && rect.maxX <= container.maxX + 0.5
            && rect.minX >= -0.5 && rect.maxX <= tier.width + 0.5
        if fits {
            return []
        }
        if let scroll = horizontalScroller(around: rect, inside: container, window: window) {
            // tests v2（#24 复核反例）：横滑条可见框必须竖向完整包住文字框——比行高矮的横滑条会把数字上下半截裁掉
            return scrollerClips(scroll, rect: rect).map { "\(item.id)「\(item.text)」：\($0)" }
        }
        return ["\(item.id)「\(item.text)」：文字框 \(rect) 横向超出容器 \(container)，也不在容器内可横向滚动的滚动视图里"
            + "（放不下只能整段换行、上下排或框内横滑）"]
    }

    /// 横滑条竖向裁字：可见框（窗口坐标）没有竖向完整包住文字框（±0.5）时给出问题。
    static func scrollerClips(_ scroll: UIScrollView, rect: CGRect) -> [String] {
        let visible = scroll.convert(scroll.bounds, to: nil)
        if rect.minY >= visible.minY - 0.5, rect.maxY <= visible.maxY + 0.5 {
            return []
        }
        return ["横滑条可见框 \(visible) 竖向没完整包住文字框 \(rect)（数字上下被裁）"]
    }

    /// 区域内按空白像素行切出的墨迹行（点坐标的上下范围；与背景差 > 40 算墨迹）。
    static func inkRows(_ pixels: ProductVisualPixels, in rect: CGRect,
                        background: ProductVisualPixels.RGB) -> [ClosedRange<CGFloat>] {
        let scale = pixels.scale
        let xs = max(0, Int(rect.minX * scale))..<min(pixels.width, Int(rect.maxX * scale))
        let ys = max(0, Int(rect.minY * scale))..<min(pixels.height, Int(rect.maxY * scale))
        guard !xs.isEmpty, !ys.isEmpty else { return [] }
        var result: [ClosedRange<CGFloat>] = []
        var start: Int?
        for row in Array(ys) + [ys.upperBound] {
            let ink = ys.contains(row) && xs.contains { !pixels.color(px: $0, row).near(background, tolerance: 40) }
            if ink, start == nil {
                start = row
            } else if !ink, let top = start {
                result.append((CGFloat(top) / scale)...(CGFloat(row) / scale))
                start = nil
            }
        }
        return result
    }

    /// 容器内、与 `rect` 同一高度带、内容宽 ≥ 文字框宽、确实能横向滚动的系统滚动视图（`UITextView` 除外）。
    static func horizontalScroller(around rect: CGRect, inside container: CGRect, window: UIWindow?) -> UIScrollView? {
        guard let window else { return nil }
        var found: UIScrollView?
        func walk(_ view: UIView) {
            if found != nil {
                return
            }
            if let scroll = view as? UIScrollView, !(view is UITextView), !scroll.isHidden {
                let visible = scroll.convert(scroll.bounds, to: nil)
                if scroll.contentSize.width > scroll.bounds.width + 1, scroll.contentSize.width + 1 >= rect.width,
                   visible.minX >= container.minX - 0.5, visible.maxX <= container.maxX + 0.5,
                   rect.midY >= visible.minY - 0.5, rect.midY <= visible.maxY + 0.5,
                   // tests v3（评审 r1 S2-5）：文字框中点要落在这条滚动视图的内容里，免得拿到同一高度带里别的横滑条
                   Self.contains(scroll, point: CGPoint(x: rect.midX, y: rect.midY)) {
                    found = scroll
                    return
                }
            }
            view.subviews.forEach(walk)
        }
        walk(window)
        return found
    }

    /// 窗口坐标的点是否落在滚动视图的内容范围（0…contentSize）里。
    static func contains(_ scroll: UIScrollView, point: CGPoint) -> Bool {
        let local = scroll.convert(point, from: nil)
        return local.x >= -0.5 && local.x <= scroll.contentSize.width + 0.5
            && local.y >= -0.5 && local.y <= max(scroll.contentSize.height, scroll.bounds.height) + 0.5
    }

    // MARK: - 输入框（金额输入不撑成多行）

    /// 框里的系统输入控件（窗口坐标与 `box` 相交）。
    static func inputs(in box: CGRect, window: UIWindow?) -> (fields: [UITextField], areas: [UITextView]) {
        var fields: [UITextField] = []
        var areas: [UITextView] = []
        func walk(_ view: UIView) {
            let frame = view.convert(view.bounds, to: nil)
            if frame.intersects(box.insetBy(dx: 1, dy: 1)), !view.isHidden {
                if let field = view as? UITextField {
                    fields.append(field)
                } else if let area = view as? UITextView, area.isEditable {
                    areas.append(area)
                }
            }
            view.subviews.forEach(walk)
        }
        if let window {
            walk(window)
        }
        return (fields, areas)
    }

    static func fmt(_ value: CGFloat) -> String {
        String(format: "%.1f", value)
    }
}

/// ADAPT-CHECK ①（D10-1223 按钮口径，FU-IOS-BINDPHONE-LAYOUT 同口径）：光秃文字按钮在大字号下——
/// - 命中区一律 ≥ 44 × 44 且包住字；
/// - 字**折成多行**或**离开它所属的那一行**（换到下一行 / 框下）时，必须有明确按钮外观：字左或右 1–12pt 内有一列，
///   在字竖直中段（20%–80%）≥ 90% 的点与周围底色（字外 18–30pt 一圈的众数色）最大通道差 > 24（描边或底色都算；光字两侧是底色，不算）。
@MainActor
enum TextButtonJudge {
    static func problems(label item: CouliLayoutProbeRecord, hit: CGRect, anchorRow: CGRect, image: UIImage,
                         name: String) -> [String] {
        let label = item.rect
        var found: [String] = []
        if hit.width < 43.5 || hit.height < 43.5 {
            found.append("\(name)：命中区 \(hit.size) 小于 44 × 44")
        }
        if !hit.insetBy(dx: -0.5, dy: -0.5).contains(label) {
            found.append("\(name)：命中区 \(hit) 没包住字 \(label)")
        }
        let wrapped = label.height >= DigitsRunJudge.lineHeight(item.fontSize) * 1.8
        let detached = label.midY < anchorRow.minY - 0.5 || label.midY > anchorRow.maxY + 0.5
        guard wrapped || detached else { return found }
        let pixels = ProductVisualPixels(image)
        let background = surrounding(pixels, around: label)
        if !hasEdge(pixels, label: label, background: background) {
            found.append("\(name)：\(wrapped ? "字折成多行" : "换到了所属行之外")（字 \(label)，所属行 \(anchorRow)），"
                + "但两侧 1–12pt 内没有描边或底色（底色 \(background)）——仍是光秃文字，不像按钮")
        }
        return found
    }

    /// 字外 18–30pt 一圈的众数色（按 8 级量化）。
    static func surrounding(_ pixels: ProductVisualPixels, around label: CGRect) -> ProductVisualPixels.RGB {
        var counts: [Int: (Int, ProductVisualPixels.RGB)] = [:]
        let outer = label.insetBy(dx: -30, dy: -30)
        let inner = label.insetBy(dx: -18, dy: -18)
        var row = outer.minY
        while row < outer.maxY {
            var column = outer.minX
            while column < outer.maxX {
                let point = CGPoint(x: column, y: row)
                if !inner.contains(point), column >= 0, row >= 0 {
                    let color = pixels.color(at: point)
                    let key = (color.red / 8) << 10 | (color.green / 8) << 5 | (color.blue / 8)
                    let old = counts[key]?.0 ?? 0
                    counts[key] = (old + 1, color)
                }
                column += 2
            }
            row += 2
        }
        return counts.values.max { $0.0 < $1.0 }?.1 ?? ProductVisualPixels.RGB(red: 255, green: 255, blue: 255)
    }

    static func hasEdge(_ pixels: ProductVisualPixels, label: CGRect, background: ProductVisualPixels.RGB) -> Bool {
        let top = label.minY + label.height * 0.2
        let bottom = label.maxY - label.height * 0.2
        let step = 1 / pixels.scale
        func columnIsEdge(_ column: CGFloat) -> Bool {
            var total = 0
            var differ = 0
            var row = top
            while row <= bottom {
                let color = pixels.color(at: CGPoint(x: column, y: row))
                let delta = max(abs(color.red - background.red), abs(color.green - background.green),
                                abs(color.blue - background.blue))
                total += 1
                if delta > 24 {
                    differ += 1
                }
                row += step
            }
            return total > 0 && Double(differ) >= Double(total) * 0.9
        }
        var offset: CGFloat = 1
        while offset <= 12 {
            if columnIsEdge(label.minX - offset) || columnIsEdge(label.maxX + offset) {
                return true
            }
            offset += step
        }
        return false
    }
}
