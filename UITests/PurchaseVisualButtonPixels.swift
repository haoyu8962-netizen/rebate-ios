import XCTest

/// APP-06v-b 测试 b v2：主 / 次按钮外观判据（T1 取色时机、T2 截图板主次断言共用）。
///
/// 主按钮底色 = 令牌 brand.primary（浅、深两套都是 #C44820）；次按钮是白 / 深色底加描边，不会是品牌色。取样点在按钮内左缘 6pt、
/// 竖直居中（避开文字）。判据：各通道与品牌色相差 ≤ 12，不放宽。
enum PurchaseVisualButtonPixels {
    static let brand = [196, 72, 32]

    static func isBrand(_ color: [Int]) -> Bool {
        color.count == 3 && zip(color, brand).allSatisfy { abs($0 - $1) <= 12 }
    }

    /// 截图里按钮框内左缘 6pt、竖直居中处的颜色（框为屏幕点坐标，截图为整屏）。
    static func sample(_ image: UIImage, at frame: CGRect) -> [Int] {
        guard let cg = image.cgImage else { return [0, 0, 0] }
        let scale = CGFloat(cg.width) / max(image.size.width, 1)
        let column = Int((frame.minX + 6) * scale)
        let row = Int(frame.midY * scale)
        guard column >= 0, row >= 0, column < cg.width, row < cg.height else { return [0, 0, 0] }
        var pixel = [UInt8](repeating: 0, count: 4)
        let context = CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        context?.draw(cg, in: CGRect(x: -column, y: -(cg.height - 1 - row), width: cg.width, height: cg.height))
        return [Int(pixel[0]), Int(pixel[1]), Int(pixel[2])]
    }

    /// T1：弹窗经 0.2 秒淡入，元素一进无障碍树就能找到，此时取色会与遮罩混色。先等按钮可点，再每 0.1 秒整屏取样，
    /// 直到**连续两帧颜色完全相同**才返回（上限 3 秒；超时返回最后一次并记失败）——只等画面落定，判据不变。
    @MainActor
    static func stableFill(_ app: XCUIApplication, _ element: XCUIElement, file: StaticString = #filePath,
                           line: UInt = #line) -> [Int] {
        let hittable = Date().addingTimeInterval(5)
        while !element.isHittable, Date() < hittable {
            Thread.sleep(forTimeInterval: 0.05)
        }
        var previous: [Int]?
        var last = [0, 0, 0]
        let end = Date().addingTimeInterval(3)
        while Date() < end {
            Thread.sleep(forTimeInterval: 0.1)
            last = sample(app.screenshot().image, at: element.frame)
            if last == previous {
                return last
            }
            previous = last
        }
        XCTFail("按钮颜色 3 秒内没有稳定（最后 \(last)）", file: file, line: line)
        return last
    }
}
