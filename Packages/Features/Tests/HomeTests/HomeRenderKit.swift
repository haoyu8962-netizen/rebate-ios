import SwiftUI
import UIKit
import XCTest

/// 截图里的图片一律换成本机色块（第 4 版 T3；与 Android 测试注入色块同一做法）：商品图、banner、弹窗图都走
/// `ProductRemoteImage`（系统 AsyncImage → URLSession.shared）。这里在进程内拦下 URLSession.shared 的**全部**请求并逐条记录
/// （第 5 版 T-04）：图片主机按地址回一张固定颜色的 PNG，其余地址一律记为「意外请求」并以断网失败回答——不发任何真实网络请求，
/// 用例可断言没有意外请求。
final class HomeColorBlockImages: URLProtocol, @unchecked Sendable {
    /// 样例里出现的图片主机（golden 向量与 Main 组合页用 img.example.com，本机假服务用 img.example.invalid）。
    static let hosts: Set<String> = ["img.example.com", "img.example.invalid", "img.example.test"]
    private static let lock = NSLock()
    private nonisolated(unsafe) static var started = 0
    private nonisolated(unsafe) static var finished = 0
    private nonisolated(unsafe) static var urls: [String] = []
    private nonisolated(unsafe) static var strays: [String] = []

    /// 饱和度高、两两分得清、与品牌色（#A83B1F / #C44820）离得远的色块。
    static let palette: [HomeRGB] = [
        HomeRGB(26, 140, 242), HomeRGB(38, 191, 77), HomeRGB(204, 38, 179), HomeRGB(242, 204, 26),
        HomeRGB(26, 191, 204), HomeRGB(115, 77, 230), HomeRGB(128, 230, 26), HomeRGB(242, 115, 179),
    ]

    /// 第 6 版（T-04 / T-06）：样例里同屏出现的图片各占一种颜色，按图片分别核对「自己的色块画出来了」；其余地址按哈希取色
    /// （同一地址永远同一种颜色，截图确定）。
    static let fixed: [String: HomeRGB] = [
        "https://img.example.com/banner-a.png": palette[0], "https://img.example.com/banner-b.png": palette[1],
        "https://img.example.com/p/0.png": palette[2], "https://img.example.com/p/1.png": palette[3],
        "https://img.example.com/p/2.png": palette[4], "https://img.example.com/p/3.png": palette[5],
        "https://img.example.com/popup.png": palette[6], "https://img.example.com/good-a.png": palette[7],
    ]

    static func install() {
        lock.withLock {
            started = 0
            finished = 0
            urls = []
            strays = []
        }
        URLProtocol.registerClass(HomeColorBlockImages.self)
    }

    static func uninstall() {
        URLProtocol.unregisterClass(HomeColorBlockImages.self)
    }

    /// 已回答的图片地址（按请求顺序）。
    static var served: [String] {
        lock.withLock { urls }
    }

    /// 图片主机以外的请求（应为空）。
    static var unexpected: [String] {
        lock.withLock { strays }
    }

    static var settled: (started: Int, finished: Int) {
        lock.withLock { (started, finished) }
    }

    override static func canInit(with request: URLRequest) -> Bool {
        request.url != nil
    }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let url = request.url?.absoluteString ?? ""
        guard let host = request.url?.host, Self.hosts.contains(host) else {
            Self.lock.withLock { Self.strays.append(url) }
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        }
        Self.lock.withLock {
            Self.started += 1
            Self.urls.append(url)
        }
        let png = Self.png(for: url)
        let response = HTTPURLResponse(
            url: request.url ?? URL(fileURLWithPath: "/"), statusCode: 200, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "image/png", "Content-Length": "\(png.count)"]
        )
        if let response {
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        }
        client?.urlProtocol(self, didLoad: png)
        client?.urlProtocolDidFinishLoading(self)
        Self.lock.withLock { Self.finished += 1 }
    }

    override func stopLoading() {}

    /// 某个地址回答的色块颜色（RGB 字节）。
    static func color(for url: String) -> HomeRGB {
        fixed[url] ?? palette[url.utf8.reduce(0) { ($0 &* 31 &+ Int($1)) & 0xFFFF } % palette.count]
    }

    static func png(for url: String) -> Data {
        let rgb = color(for: url)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: 24, height: 24), format: format).pngData { context in
            UIColor(
                red: CGFloat(rgb.red) / 255, green: CGFloat(rgb.green) / 255, blue: CGFloat(rgb.blue) / 255, alpha: 1
            ).setFill()
            context.fill(CGRect(x: 0, y: 0, width: 24, height: 24))
        }
    }
}

/// 一张应当显示出来的图片：地址（色块颜色由地址决定），以及它应出现的竖向范围（pt；nil 表示整张画布）。
struct HomeImageExpectation: CustomStringConvertible {
    let url: String
    var minY: CGFloat = 0
    var maxY: CGFloat?

    var description: String {
        "\(url.split(separator: "/").suffix(2).joined(separator: "/"))@\(Int(minY))~\(maxY.map { "\(Int($0))" } ?? "底")"
    }
}

/// 截图：把视图放进真实窗口（UIWindow + UIHostingController），等图片请求结算、**本屏每一张预期图片各自的色块**都画出来后，
/// 按图层渲染成位图（@3x）。本包测试没有宿主 App，`drawHierarchy` 拿不到画面；置灰由 UI 测试经真实 RootView 整屏截图验。
/// 第 6 版（T-06）：不再「任一色块出现即结束」——逐张等预期图片（可限定竖向范围），图片先后、迟到都等到上限（8 秒墙钟）才判失败；
/// 截图前轮播固定在第一帧（SnapshotSignals 报读屏开启，生产规则「读屏时不自动轮播」），等待跨过轮播间隔也不会换帧。
/// 定稿（编排 2026-10-18 19:3x 裁定①）：golden 截图（比对与录制）用「稳定等待」——图片请求结算后，等到连续两帧完全一致或 2 秒
/// 超时再截，比对容差 ≤1% 像素（见 HomeGoldenSnapshotTests.snap）；不再逐块等可见图片、不再按 90% 到位与 8 秒上限判定。
/// 分块呈现、渐显这类时序差异不作红绿依据（F-IOS 跟进）。非截图比对的渲染（逐区段、色块区段检查）仍逐张等点名图片，8 秒上限。
@MainActor
enum HomeShot {
    /// 一张预期图片在画面上至少要有这么多像素是它自己的色块（@3x 像素；最小的首屏图片也有数万像素）。
    static let minimumPixels = 2000

    /// `expect`：这一屏应当显示的图片。非空时每一张都要在 8 秒内画出自己的色块，等不到判失败（报出缺哪张），不带着占位截图。
    /// `stable`：截图比对用的稳定等待——连续两帧一致或 2 秒超时就截，不再按点名图片等到 8 秒；点名图片在截下的这一帧上核对。
    static func capture(
        _ view: some View, width: CGFloat = 390, height: CGFloat = 1600, size: DynamicTypeSize = .large,
        expect: [HomeImageExpectation], stable: Bool = false, colorScheme: ColorScheme = .light,
        file: StaticString = #filePath, line: UInt = #line
    ) async -> UIImage {
        let root = AnyView(view
            .frame(width: width, height: height)
            .environment(\.dynamicTypeSize, size)
            .environment(\.colorScheme, colorScheme))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: width, height: height))
        let host = UIHostingController(rootView: root)
        window.overrideUserInterfaceStyle = colorScheme == .dark ? .dark : .light
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.frame = window.bounds
        host.view.layoutIfNeeded()
        if await !settle() {
            let now = HomeColorBlockImages.settled
            XCTFail(
                "截图前图片请求没有在 8 秒内结算（已请求 \(now.started)，已完成 \(now.finished)）", file: file, line: line
            )
        }
        var image = render(window)
        var counts = HomePixelScan.counts(expect, in: image)
        if stable {
            // 稳定等待（裁定①）：连续两帧逐像素一致，或 2 秒墙钟超时
            let deadline = Date().addingTimeInterval(2)
            var previous = pixels(image)
            while Date() < deadline {
                try? await Task.sleep(for: .milliseconds(100))
                image = render(window)
                let now = pixels(image)
                if now == previous {
                    break
                }
                previous = now
            }
            counts = HomePixelScan.counts(expect, in: image)
        } else {
            // 逐张等调用方点名的预期图片（各自的色块，可限定竖向范围），墙钟 8 秒
            let deadline = Date().addingTimeInterval(8)
            while counts.contains(where: { $0 < minimumPixels }), Date() < deadline {
                try? await Task.sleep(for: .milliseconds(200))
                image = render(window)
                counts = HomePixelScan.counts(expect, in: image)
            }
        }
        let missing = zip(expect, counts).filter { $0.1 < minimumPixels }.map { "\($0.0)=\($0.1)px" }
        if !missing.isEmpty {
            XCTFail("这一屏应显示的图片没有画出自己的色块（图片没有显示）：\(missing)", file: file, line: line)
        }
        window.isHidden = true
        window.rootViewController = nil
        return image
    }

    private static func pixels(_ image: UIImage) -> [UInt8] {
        image.cgImage.map(HomePixelScan.rgba) ?? []
    }

    private static func render(_ window: UIWindow) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 3
        return UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { context in
            window.layer.render(in: context.cgContext)
        }
    }

    /// 等到图片请求全部结算、且 0.4 秒内没有新请求，再给界面 0.3 秒应用结果。8 秒内做不到返回 false。
    /// （「图片已显示」另由画面上每张预期图片自己的色块证明。）
    private static func settle() async -> Bool {
        var last = -1
        var quiet = 0
        for _ in 0..<80 {
            try? await Task.sleep(for: .milliseconds(100))
            let now = HomeColorBlockImages.settled
            if now.started == now.finished, now.started == last {
                quiet += 1
                if quiet >= 4 {
                    try? await Task.sleep(for: .milliseconds(300))
                    return true
                }
            } else {
                quiet = 0
            }
            last = now.started
        }
        return false
    }
}

/// 位图逐行扫描（第 4 版，截图比对 T2 / P1）：以画面左上角（页面内边距处）为底色，与底色差超过阈值的像素算「有内容」。
struct HomePixelScan {
    /// 底色以外有内容的最上、最下一行（pt）；整张都是底色时为 nil。
    let contentTop: CGFloat?
    let contentBottom: CGFloat?
    /// 最上与最下内容行之间，连续全是底色的最长一段（pt）。只画出部分区段时，中间会留大片空白。
    let longestInnerBlank: CGFloat
    /// 缩小后按 4 位量化的不同颜色数。
    let distinctColors: Int
    /// 像素 max(R,G,B) - min(R,G,B) 的最大值（0 = 完全无彩色）。
    let maxChroma: Int

    init(_ image: UIImage, step: Int = 1) {
        guard let cgImage = image.cgImage else {
            contentTop = nil; contentBottom = nil; longestInnerBlank = 0; distinctColors = 0; maxChroma = 0
            return
        }
        let width = cgImage.width, height = cgImage.height
        let pixels = Self.rgba(cgImage)
        let scale = CGFloat(height) / max(1, image.size.height)
        let probe = (min(width - 1, Int(4 * scale)) + min(height - 1, Int(4 * scale)) * width) * 4
        let background = (Int(pixels[probe]), Int(pixels[probe + 1]), Int(pixels[probe + 2]))
        var top: Int?
        var bottom: Int?
        var blank = 0
        var longest = 0
        var colors = Set<UInt32>()
        var chroma = 0
        for row in 0..<height {
            var content = false
            for column in stride(from: 0, to: width, by: step) {
                let index = (row * width + column) * 4
                let red = Int(pixels[index]), green = Int(pixels[index + 1]), blue = Int(pixels[index + 2])
                if abs(red - background.0) > 6 || abs(green - background.1) > 6 || abs(blue - background.2) > 6 {
                    content = true
                }
                chroma = max(chroma, max(red, green, blue) - min(red, green, blue))
                if row % 8 == 0, column % 8 == 0 {
                    colors.insert(UInt32(red >> 4) << 8 | UInt32(green >> 4) << 4 | UInt32(blue >> 4))
                }
            }
            if content {
                if top == nil {
                    top = row
                }
                if bottom != nil {
                    longest = max(longest, blank)
                }
                bottom = row
                blank = 0
            } else if top != nil {
                blank += 1
            }
        }
        contentTop = top.map { CGFloat($0) / scale }
        contentBottom = bottom.map { CGFloat($0 + 1) / scale }
        longestInnerBlank = CGFloat(longest) / scale
        distinctColors = colors.count
        maxChroma = chroma
    }

    /// 位图解成 RGBA 字节（每像素 4 字节，行优先）。
    static func rgba(_ cgImage: CGImage) -> [UInt8] {
        let width = cgImage.width, height = cgImage.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        pixels.withUnsafeMutableBytes { buffer in
            if let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) {
                context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            }
        }
        return pixels
    }

    /// 每张预期图片在各自竖向范围内的色块像素数（@3x 像素；隔行隔列抽样，×4 折算）。
    static func counts(_ expect: [HomeImageExpectation], in image: UIImage) -> [Int] {
        guard let cgImage = image.cgImage else { return expect.map { _ in 0 } }
        let pixels = rgba(cgImage)
        let width = cgImage.width, height = cgImage.height
        let scale = CGFloat(height) / max(1, image.size.height)
        return expect.map { item in
            let color = HomeColorBlockImages.color(for: item.url)
            let red = Int(color.red), green = Int(color.green), blue = Int(color.blue)
            let top = max(0, Int(item.minY * scale))
            let bottom = min(height, item.maxY.map { Int($0 * scale) } ?? height)
            var total = 0
            for row in stride(from: top, to: bottom, by: 2) {
                for column in stride(from: 0, to: width, by: 2) {
                    let index = (row * width + column) * 4
                    if abs(Int(pixels[index]) - red) <= 6, abs(Int(pixels[index + 1]) - green) <= 6,
                       abs(Int(pixels[index + 2]) - blue) <= 6 {
                        total += 4
                    }
                }
            }
            return total
        }
    }
}

/// 一个 RGB 颜色（字节）。
struct HomeRGB: Equatable {
    let red: UInt8
    let green: UInt8
    let blue: UInt8

    init(_ red: UInt8, _ green: UInt8, _ blue: UInt8) {
        self.red = red
        self.green = green
        self.blue = blue
    }
}
