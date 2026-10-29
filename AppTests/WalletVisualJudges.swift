@testable import Couli
import DesignSystem
import Foundation
import SwiftUI
import UIKit
import XCTest

/// 段内折行金额的像素判据（正式用例与 `WalletVisualOracleTests` 自证共用同一份；评审 r1 S1-2）：
/// 1. 按空白像素行把测量框切成文字行；
/// 2. 每行按空白像素列数出字形块：全部行的字形块合计必须等于金额的字数（中间缺一位、行尾裁掉一位都会少一块）；
/// 3. 每行按自己的字形块数取出对应的那段文字，用同一字体（系统字体、等宽数字、粗体——主卡大数的字重、同字号）在同底色上画参考，
///    这一行的可见字形宽与参考字形宽之差不超过 max(3, 字号 × 0.12)（逐行比，不累加）。
@MainActor
enum WalletWrappedAmountJudge {
    static func problems(image: UIImage, rect: CGRect, text: String, fontSize: CGFloat,
                         background: ProductVisualPixels.RGB) async -> [String] {
        let weight = Font.Weight.bold
        let pixels = ProductVisualPixels(image)
        let glyphs = Array(text.filter { !$0.isWhitespace })
        let lines = rows(pixels, rect: rect, background: background)
        var problems: [String] = []
        if lines.isEmpty {
            return ["测量框内没有字形墨迹"]
        }
        let counts = lines.map { blobs(pixels, row: $0, background: background).count }
        if counts.reduce(0, +) != glyphs.count {
            problems.append("字形块合计 \(counts.reduce(0, +)) ≠ 字数 \(glyphs.count)（各行 \(counts)，有字被裁掉或缺字）")
            return problems
        }
        let tolerance = max(3, fontSize * 0.12)
        var start = 0
        for (index, row) in lines.enumerated() {
            let chunk = String(glyphs[start..<(start + counts[index])])
            start += counts[index]
            let spans = blobs(pixels, row: row, background: background)
            guard let first = spans.first, let last = spans.last else { continue }
            let shown = last.upperBound - first.lowerBound
            let reference = await referenceInkWidth(chunk, fontSize: fontSize, weight: weight)
            if abs(shown - reference) > tolerance {
                problems.append("第 \(index + 1) 行「\(chunk)」可见字形宽 \(shown) 与参考 \(reference) 相差超过 \(tolerance)")
            }
        }
        return problems
    }

    /// 按空白像素行切出的文字行（点坐标框）。
    private static func rows(_ pixels: ProductVisualPixels, rect: CGRect,
                             background: ProductVisualPixels.RGB) -> [CGRect] {
        let scale = pixels.scale
        let xs = max(0, Int(rect.minX * scale))..<min(pixels.width, Int(rect.maxX * scale))
        let ys = max(0, Int(rect.minY * scale))..<min(pixels.height, Int(rect.maxY * scale))
        let inked = ys.map { row in xs.contains { !pixels.color(px: $0, row).near(background, tolerance: 40) } }
        var result: [CGRect] = []
        var start: Int?
        for (offset, ink) in (inked + [false]).enumerated() {
            if ink, start == nil {
                start = offset
            } else if !ink, let top = start {
                let minY = CGFloat(ys.lowerBound + top) / scale
                let maxY = CGFloat(ys.lowerBound + offset) / scale
                result.append(CGRect(x: rect.minX, y: minY, width: rect.width, height: maxY - minY))
                start = nil
            }
        }
        return result
    }

    /// 一行里按空白像素列分开的字形块（点坐标的左右范围）。
    private static func blobs(_ pixels: ProductVisualPixels, row: CGRect,
                              background: ProductVisualPixels.RGB) -> [Range<CGFloat>] {
        let scale = pixels.scale
        let xs = max(0, Int(row.minX * scale))..<min(pixels.width, Int(row.maxX * scale))
        let ys = max(0, Int(row.minY * scale))..<min(pixels.height, Int(row.maxY * scale))
        var result: [Range<CGFloat>] = []
        var start: Int?
        for column in Array(xs) + [xs.upperBound] {
            let ink = xs.contains(column) && ys
                .contains { !pixels.color(px: column, $0).near(background, tolerance: 40) }
            if ink, start == nil {
                start = column
            } else if !ink, let left = start {
                result.append((CGFloat(left) / scale)..<(CGFloat(column) / scale))
                start = nil
            }
        }
        return result
    }

    /// 同字体同字号的参考文字画在狸橙底上的可见字形宽（单行）。
    private static func referenceInkWidth(_ text: String, fontSize: CGFloat, weight: Font.Weight) async -> CGFloat {
        let solid = CouliColor.token("rebate.solid.background")
        let background = ProductVisualPixels.RGB(solid, dark: false)
        let view = Text(verbatim: text).font(Font.system(size: fontSize, weight: weight).monospacedDigit())
            .foregroundColor(.white).fixedSize().padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).background(solid)
        let size = CGSize(width: fontSize * CGFloat(text.count) + 80, height: fontSize * 2 + 40)
        let (image, _) = await WalletVisualRender.standalone(view, size: size) { pixels in
            pixels.count(in: CGRect(origin: .zero, size: size)) { !$0.near(background, tolerance: 40) } > 50
        }
        let pixels = ProductVisualPixels(image)
        let row = CGRect(origin: .zero, size: size)
        let spans = blobs(pixels, row: row, background: background)
        guard let first = spans.first, let last = spans.last else { return 0 }
        return last.upperBound - first.lowerBound
    }
}
