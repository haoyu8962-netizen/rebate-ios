@testable import Couli
import DesignSystem
import Foundation
import UIKit

/// FU-IOS-NUM-WRAP v4（D10-1265，三端同口径）：放不下的数字串框内横滑时**必须**有截断提示，放得下时**没有**。
/// 判「横滑」：文字框所在的容器里有一条能横向滚动的系统滚动视图包着它（`DigitsRunJudge.horizontalScroller`）。
/// - 横滑时：①起始在开头（`contentOffset.x ≈ 0`、文字左缘 = 可见左缘）；②有测量 `<probe>.scrollHint`（指示器轨道），
///   横向 = 横滑条可见宽，在文字下方 0–4.5pt，高 2–4；③像素：末端渐隐——可见右缘 4pt 内墨迹最大对比 ≤ 往里 20–36pt 的 55%；
///   ④像素：指示器看得见，滑块（对比 ≥ 轨道最大对比 60% 的列）宽 ≥ 6、比轨道窄，且从轨道左端起（在开头）。
///   底色取文字与指示器之间那条缝的众数色。
/// - 不横滑时：不准有 `<probe>.scrollHint`。
@MainActor
enum ScrollHintJudge {
    /// 一张截图与它所在的窗口（测量、截图都是窗口坐标）。
    struct Shot {
        let image: UIImage
        let window: UIWindow?
    }

    struct Outcome {
        let scrolled: Bool
        let problems: [String]
    }

    static func judge(_ name: String, text: CGRect, hint: CouliLayoutProbeRecord?, container: CGRect,
                      shot: Shot) -> Outcome {
        guard let scroll = DigitsRunJudge.horizontalScroller(around: text, inside: container, window: shot.window)
        else {
            let extra = hint.map { ["\(name)：放得下（没有横滑）却有截断提示 \($0.rect)"] } ?? []
            return Outcome(scrolled: false, problems: extra)
        }
        return Outcome(scrolled: true,
                       problems: scrolled(name, text: text, hint: hint, scroll: scroll, image: shot.image))
    }

    static func scrolled(_ name: String, text: CGRect, hint: CouliLayoutProbeRecord?, scroll: UIScrollView,
                         image: UIImage) -> [String] {
        var found: [String] = []
        let visible = scroll.convert(scroll.bounds, to: nil)
        if scroll.contentOffset.x > 0.5 || abs(text.minX - visible.minX) > 1 {
            found.append("\(name)：横滑起始不在开头（contentOffset \(scroll.contentOffset.x)，字左缘 \(text.minX)，"
                + "可见左缘 \(visible.minX)）")
        }
        guard let hint else { return found + ["\(name)：横滑却没有截断提示（缺测量 scrollHint）"] }
        let bar = hint.rect
        if abs(bar.width - visible.width) > 1 || abs(bar.minX - visible.minX) > 1 {
            found.append("\(name)：指示器轨道 \(bar) 横向不等于横滑条可见框 \(visible)")
        }
        if bar.height < 2 || bar.height > 4 {
            found.append("\(name)：指示器高 \(bar.height) 不是 3 左右")
        }
        let gap = bar.minY - text.maxY
        if gap < -0.5 || gap > 4.5 {
            found.append("\(name)：指示器不在文字下方 0–4.5pt（间距 \(gap)）")
        }
        let pixels = ProductVisualPixels(image)
        if CGFloat(pixels.height) / pixels.scale < bar.maxY || CGFloat(pixels.width) / pixels.scale < bar.maxX {
            return found + ["\(name)：截图（\(image.size)）没包住指示器 \(bar)，量不了像素"]
        }
        let seam = CGRect(x: visible.minX + 2, y: min(text.maxY, bar.minY - 1) + 0.25, width: max(1, visible.width - 4),
                          height: max(0.75, gap - 0.5))
        let background = mode(pixels, in: seam)
        found += fade(name, pixels: pixels, text: text, visible: visible, background: background)
        let expected = max(visible.width * visible.width / max(scroll.contentSize.width, 1), 12)
        found += indicator(name, pixels: pixels, bar: bar, background: background, thumb: expected)
        return found
    }

    /// 末端渐隐：可见右缘 4pt 内的最大对比明显低于往里 20–36pt（那里不在渐隐区，是实字）。
    static func fade(_ name: String, pixels: ProductVisualPixels, text: CGRect, visible: CGRect,
                     background: ProductVisualPixels.RGB) -> [String] {
        let band = text.intersection(visible)
        guard !band.isNull, band.width > 40 else { return ["\(name)：可见文字带太窄（\(band)），量不了渐隐"] }
        let tail = maxContrast(pixels, in: CGRect(x: band.maxX - 4.5, y: band.minY, width: 4, height: band.height),
                               background: background)
        let inner = maxContrast(pixels, in: CGRect(x: band.maxX - 36, y: band.minY, width: 16, height: band.height),
                                background: background)
        if inner < 60 {
            return ["\(name)：末端往里 20–36pt 取不到实墨迹（对比 \(inner)，底色 \(background)）"]
        }
        if Double(tail) > Double(inner) * 0.55 {
            return ["\(name)：末端没有渐隐——右缘 4pt 内墨迹对比 \(tail)，往里 20–36pt 是 \(inner)（底色 \(background)）"]
        }
        return []
    }

    /// 指示器：轨道里按列取最大对比；滑块列 = 对比 ≥ 最大值 60%，宽 = 可见比例（可见宽² ÷ 内容宽，最小 12）±3、从轨道左端起。
    static func indicator(_ name: String, pixels: ProductVisualPixels, bar: CGRect,
                          background: ProductVisualPixels.RGB, thumb expected: CGFloat) -> [String] {
        let scale = pixels.scale
        let xs = max(0, Int(bar.minX * scale))..<min(pixels.width, Int(bar.maxX * scale))
        let ys = max(0, Int((bar.minY + 0.5) * scale))..<min(pixels.height, Int((bar.maxY - 0.5) * scale))
        guard !xs.isEmpty, !ys.isEmpty else { return ["\(name)：指示器框 \(bar) 在截图外"] }
        let columns = xs.map { column in ys.map { contrast(pixels.color(px: column, $0), background) }.max() ?? 0 }
        let peak = columns.max() ?? 0
        if peak < 20 {
            return ["\(name)：指示器看不见（轨道内最大对比 \(peak)，底色 \(background)）"]
        }
        let thumb = columns.enumerated().filter { Double($0.element) >= Double(peak) * 0.6 }.map(\.offset)
        var found: [String] = []
        let width = CGFloat(thumb.count) / scale
        if abs(width - expected) > 3 {
            found.append("\(name)：滑块宽 \(width) 不是按可见比例的 \(expected)（轨道 \(bar.width)）")
        }
        if let first = thumb.first, CGFloat(first) / scale > 2 {
            found.append("\(name)：滑块不在轨道左端（离左端 \(CGFloat(first) / scale)pt）——起始没在开头")
        }
        return found
    }

    static func contrast(_ color: ProductVisualPixels.RGB, _ background: ProductVisualPixels.RGB) -> Int {
        max(abs(color.red - background.red), abs(color.green - background.green), abs(color.blue - background.blue))
    }

    static func maxContrast(_ pixels: ProductVisualPixels, in rect: CGRect,
                            background: ProductVisualPixels.RGB) -> Int {
        let scale = pixels.scale
        let xs = max(0, Int(rect.minX * scale))..<min(pixels.width, Int(rect.maxX * scale))
        let ys = max(0, Int(rect.minY * scale))..<min(pixels.height, Int(rect.maxY * scale))
        var best = 0
        for column in xs {
            for row in ys {
                best = max(best, contrast(pixels.color(px: column, row), background))
            }
        }
        return best
    }

    /// 区域众数色（8 级量化）。
    static func mode(_ pixels: ProductVisualPixels, in rect: CGRect) -> ProductVisualPixels.RGB {
        let scale = pixels.scale
        let xs = max(0, Int(rect.minX * scale))..<min(pixels.width, Int(rect.maxX * scale))
        let ys = max(0, Int(rect.minY * scale))..<min(
            pixels.height,
            max(Int(rect.minY * scale) + 1, Int(rect.maxY * scale))
        )
        var counts: [Int: (Int, ProductVisualPixels.RGB)] = [:]
        for column in xs {
            for row in ys {
                let color = pixels.color(px: column, row)
                let key = (color.red / 8) << 10 | (color.green / 8) << 5 | (color.blue / 8)
                counts[key] = ((counts[key]?.0 ?? 0) + 1, color)
            }
        }
        return counts.values.max { $0.0 < $1.0 }?.1 ?? ProductVisualPixels.RGB(red: 255, green: 255, blue: 255)
    }

    /// 容器里能横向滚动的系统滚动视图（没有文字测量的横滑字，如提现金额框未聚焦时的横滑显示），取第一条。
    static func scroller(inside container: CGRect, window: UIWindow?) -> UIScrollView? {
        guard let window else { return nil }
        func all(_ view: UIView) -> [UIView] {
            [view] + view.subviews.flatMap(all)
        }
        return all(window).compactMap { $0 as? UIScrollView }.first { scroll in
            let visible = scroll.convert(scroll.bounds, to: nil)
            return !(scroll is UITextView) && !scroll.isHidden && scroll.contentSize.width > scroll.bounds.width + 1
                && visible.minX >= container.minX - 0.5 && visible.maxX <= container.maxX + 0.5
                && visible.minY >= container.minY - 0.5 && visible.maxY <= container.maxY + 0.5
        }
    }
}
