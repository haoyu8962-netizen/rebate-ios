import UIKit
import XCTest

/// 首页 UI 测试的启动（第 5 版 T-02，第 6 版挪出共用）：每次启动都带 `-CouliHomeTestReset 1`，App 在首页读本机数据之前清掉首页
/// LKG 与偏好并发信号；本机假服务回答页面时发「回答了哪一页」。
@MainActor
enum HomeUILaunch {
    /// 带重置启动完整功能首页，等「首页本机数据已清」与「假服务回答了 `page`」两个信号。
    static func home(page: String, extra: [String] = []) -> XCUIApplication {
        let reset = DarwinSignal(HomeUITestSignalNames.homeReset)
        let served = DarwinSignal(HomeUITestSignalNames.homePagePrefix + page)
        let app = XCUIApplication()
        app.launchArguments += [
            "-CouliPrivacyPreset", "consented", "-CouliFakeLoginServer", "-CouliUpdateReset", "1",
            "-CouliHideDebugInfo", "1", "-CouliFakeHome", page, "-CouliHomeTestReset", "1",
        ] + extra
        app.launch()
        XCTAssertTrue(
            ShellTabBar.bar(app).waitForExistence(timeout: 30), "没有进入 Tab 外壳"
        )
        UIWait.until("App 启动前清掉首页 LKG 与偏好（-CouliHomeTestReset）", ceiling: 20) { reset.count >= 1 }
        UIWait.until("本机假服务回答首页页面 \(page)", ceiling: 20) { served.count >= 1 }
        return app
    }

    /// 基本模式首页（BasicModeHomeView）。
    static func basic(gray: Bool) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += [
            "-CouliPrivacyPreset", "basic", "-CouliFakeLoginServer", "-CouliUpdateReset", "1",
            "-CouliHideDebugInfo", "1", "-CouliHomeTestReset", "1",
        ] + (gray ? ["-CouliFakeFlags", "ui.grayscale=true"] : [])
        app.launch()
        XCTAssertTrue(
            ShellTabBar.bar(app).waitForExistence(timeout: 30), "没有进入 Tab 外壳"
        )
        return app
    }

    static func labeled(_ app: XCUIApplication, _ text: String) -> XCUIElementQuery {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", text))
    }
}

/// 首页的几块区域（pt，屏幕坐标）。
@MainActor
enum HomeAreas {
    /// 首页区域：状态栏以下、Tab 栏以上（状态栏与 Tab 栏不在首页根里，不参与置灰）。
    static func home(_ app: XCUIApplication) -> CGRect {
        let window = app.windows.firstMatch.frame
        let tabBar = ShellTabBar.bar(app).frame
        let top: CGFloat = 70
        let bottom = tabBar.isEmpty ? window.maxY : tabBar.minY
        return CGRect(x: 0, y: top, width: window.width, height: max(0, bottom - top - 1))
    }

    /// SDUI 之外的固定区：首页搜索入口与剪贴板卡。
    static func fixed(_ app: XCUIApplication) -> CGRect {
        let search = app.descendants(matching: .any)["home.search"].firstMatch.frame
        let card = app.descendants(matching: .any)["clipboard.homeCard"].firstMatch.frame
        return card.isEmpty ? search : search.union(card)
    }

    /// SDUI 内容区：固定区以下到首页区域底部。
    static func sdui(_ app: XCUIApplication) -> CGRect {
        let home = home(app)
        let fixed = fixed(app)
        let top = fixed.isEmpty ? home.minY : max(home.minY, fixed.maxY + 1)
        return CGRect(x: home.minX, y: top, width: home.width, height: max(0, home.maxY - top))
    }
}

/// 一块区域的像素统计：最大色差及其位置（pt）、置灰后允许的上限；第 6 版（T-05）加「画面上有内容」的量——
/// `ink`：亮度与这块区域主色调（出现最多的亮度档）差超过 16 的像素占比；`spread`：亮度标准差。首页变空白（只剩底色）时两者都接近 0；
/// 置灰只去颜色、不动亮度结构，两者与彩色时相当。
struct RegionStats: CustomStringConvertible {
    let most: Int
    let at: CGPoint
    let limit: Int
    let ink: Double
    let spread: Double

    var gray: Bool {
        most <= limit
    }

    var description: String {
        String(format: "色差 %d（上限 %d，在 %.0f,%.0f），内容占比 %.3f，亮度标准差 %.1f", most, limit, at.x, at.y, ink, spread)
    }
}

/// 整屏截图一次，按区域统计（同一张图里比较各区域）。截图失败或区域为空直接判失败（不返回能「满足上限」的哨兵值）。
@MainActor
struct HomeScreenShot {
    let image: CGImage
    let scale: CGFloat
    /// Tab 外壳底色：状态栏以下、首页内容以上的左边缘（外壳 backgroundCanvas 铺满安全区，首页根盖不到这里）。
    let canvas: [Int]

    init?(file: StaticString = #filePath, line: UInt = #line) {
        let shot = XCUIScreen.main.screenshot().image
        guard let cgImage = shot.cgImage, shot.size.width > 0 else {
            XCTFail("整屏截图失败", file: file, line: line)
            return nil
        }
        image = cgImage
        scale = CGFloat(cgImage.width) / shot.size.width
        let probe = Self.pixels(cgImage, CGRect(x: 6 * scale, y: 50 * scale, width: 1, height: 1).integral)
        canvas = probe.map { [Int($0.rgb[0]), Int($0.rgb[1]), Int($0.rgb[2])] } ?? [-100, -100, -100]
    }

    /// 某块区域的统计；区域为空、裁不出来判失败并返回 nil。
    func stats(
        _ rect: CGRect, _ name: String, report: Bool = true, file: StaticString = #filePath, line: UInt = #line
    ) -> RegionStats? {
        let crop = CGRect(
            x: rect.minX * scale,
            y: rect.minY * scale,
            width: rect.width * scale,
            height: rect.height * scale
        )
        .integral.intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard !rect.isEmpty, !crop.isEmpty, let sampled = Self.pixels(image, crop), !sampled.rgb.isEmpty else {
            if report {
                XCTFail("\(name)：区域为空或截图裁不出来（\(rect)），不能判定", file: file, line: line)
            }
            return nil
        }
        var most = 0
        var at = 0
        var histogram = [Int](repeating: 0, count: 256)
        let rgb = sampled.rgb
        var lumas: [Int] = []
        lumas.reserveCapacity(rgb.count / 3)
        for index in 0..<(rgb.count / 3) {
            let red = Int(rgb[index * 3]), green = Int(rgb[index * 3 + 1]), blue = Int(rgb[index * 3 + 2])
            let luma = (red * 299 + green * 587 + blue * 114) / 1000
            histogram[luma] += 1
            lumas.append(luma)
            // 首页根透明处露出的是 Tab 外壳的底色（外壳不在首页根里，不参与置灰），不算首页的彩色
            if abs(red - canvas[0]) <= 3, abs(green - canvas[1]) <= 3, abs(blue - canvas[2]) <= 3 {
                continue
            }
            let value = max(red, green, blue) - min(red, green, blue)
            if value > most {
                most = value
                at = index
            }
        }
        let mode = histogram.indices.max { histogram[$0] < histogram[$1] } ?? 0
        let inked = lumas.count { abs($0 - mode) > 16 }
        let mean = Double(lumas.reduce(0, +)) / Double(lumas.count)
        let variance = lumas.reduce(0.0) { $0 + (Double($1) - mean) * (Double($1) - mean) } / Double(lumas.count)
        let width = max(1, sampled.width)
        let point = CGPoint(
            x: (crop.minX + CGFloat(at % width * 2)) / scale,
            y: (crop.minY + CGFloat(at / width * 2)) / scale
        )
        // 置灰后允许的上限：6，或外壳底色自身的色差（灰色文字与外壳底色交界的抗锯齿像素是两者的混合，色差不超过底色）
        let limit = max(6, (canvas.max() ?? 0) - (canvas.min() ?? 0))
        return RegionStats(
            most: most, at: point, limit: limit, ink: Double(inked) / Double(lumas.count), spread: variance.squareRoot()
        )
    }

    /// 区域的像素（RGB 连排；隔行隔列抽样）与抽样后的每行像素数。
    private static func pixels(_ image: CGImage, _ crop: CGRect) -> (rgb: [UInt8], width: Int)? {
        guard let part = image.cropping(to: crop) else { return nil }
        let width = part.width, height = part.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        bytes.withUnsafeMutableBytes { buffer in
            if let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) {
                context.draw(part, in: CGRect(x: 0, y: 0, width: width, height: height))
            }
        }
        var result: [UInt8] = []
        result.reserveCapacity(width * height)
        var sampledWidth = 0
        for row in stride(from: 0, to: height, by: 2) {
            sampledWidth = 0
            for column in stride(from: 0, to: width, by: 2) {
                let index = (row * width + column) * 4
                result.append(bytes[index])
                result.append(bytes[index + 1])
                result.append(bytes[index + 2])
                sampledWidth += 1
            }
        }
        return (result, sampledWidth)
    }
}

/// 与 App 侧 DebugHomeUITestSupport 同名的信号。
enum HomeUITestSignalNames {
    static let homeReset = "com.couli.app.debug.uitest.home-reset"
    static let homePagePrefix = "com.couli.app.debug.uitest.home-page."
    /// 同一进程内改配置开关（第 6 版 T-07）：发 `fakeFlagPrefix + "ui.grayscale=true"` / `=false`。
    static let fakeFlagPrefix = "com.couli.app.debug.uitest.fake-flag."
    /// 本机假服务回答了一次配置。
    static let configServed = "com.couli.app.debug.uitest.config-served"

    static func post(_ name: String) {
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(), CFNotificationName(name as CFString), nil, nil, true
        )
    }
}
