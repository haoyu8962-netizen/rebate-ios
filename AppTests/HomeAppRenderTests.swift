@testable import Couli
import Foundation
import HomeCore
import Router
import SwiftUI
import UIKit
import XCTest

/// 首页真实渲染的像素检查（第 4 版，截图比对后）。App 宿主有窗口场景，`drawHierarchy` 拍到的是屏幕上真正合成的画面，用它验：
/// - P1：Release 无端口时的包内默认页（金刚区 + 双入口）两张卡都画出来：比只放第一张卡的同一页，画面下沿要往下长。
/// 置灰（T1）第 5 版移到 UI 测试（第 6 版起在 HomeGrayscaleUITests）：经真实 RootView 整屏截图，覆盖搜索入口、剪贴板卡等 SDUI 之外的固定区与
/// 基本模式页（评审 r4 T-01：不在测试里另拼首页组合）。
/// 图片一律由本机色块回答（AppColorBlockImages），不走真实网络。
@MainActor
final class HomeAppRenderTests: HomeAppTestCase {
    private var window: UIWindow?

    override func setUpWithError() throws {
        try super.setUpWithError()
        AppColorBlockImages.install()
    }

    override func tearDown() {
        window?.isHidden = true
        window?.rootViewController = nil
        window = nil
        AppColorBlockImages.uninstall()
        super.tearDown()
    }

    // MARK: - P1 包内默认页每张卡都画出来

    func testBundledDefaultPageInReleaseDrawsBothCards() async throws {
        let sections = try Self.bundledSections()
        XCTAssertGreaterThanOrEqual(sections.count, 2, "前提：包内默认页至少两张区段卡")
        // 参照：同一页只放第一张卡（Debug 端口回答）
        let firstOnly = make(
            account: nil,
            port: TestHomePort(page: ["page_key": "home", "version": 3, "sections": [sections[0]]])
        )
        let reference = try await shoot(firstOnly)
        XCTAssertEqual(firstOnly.controller.state.sections.count, 1, "前提：参照页只有第一张卡")
        window?.isHidden = true
        window = nil

        // 真实装配：Release 变体、没有端口 → 包内默认页（换一份本机数据目录，不让参照页写下的 LKG 顶替包内默认页）
        try? FileManager.default.removeItem(at: storageRoot)
        storageRoot = FileManager.default.temporaryDirectory.appendingPathComponent("home-app-\(UUID().uuidString)")
        let release = make(account: nil, variant: .release)
        let shot = try await shoot(release)
        XCTAssertEqual(release.controller.state.source, .bundled, "前提：Release 无端口显示包内默认页")
        XCTAssertEqual(release.controller.state.sections.count, sections.count, "前提：包内默认页每张卡都可见")
        XCTAssertGreaterThanOrEqual(
            shot.bottom, reference.bottom + 40,
            "包内默认页只画出了第一张卡（内容下沿 \(Int(shot.bottom))pt，只放第一张卡时 \(Int(reference.bottom))pt）"
        )
        XCTAssertLessThanOrEqual(shot.blank, 48, "包内默认页内容中间有 \(Int(shot.blank))pt 整段空白")
    }

    // MARK: - 工具

    private static func bundledSections() throws -> [[String: Any]] {
        let data = try XCTUnwrap(HomeBundled.data())
        let page = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try XCTUnwrap(page["sections"] as? [[String: Any]])
    }

    private struct Shot {
        let chroma: Int
        let colors: Int
        let bottom: CGFloat
        let blank: CGFloat
    }

    /// 把路由表里的首页视图放进真实窗口，冷启动结算、图片结算后 drawHierarchy 截屏。`reuse` 为 true 时沿用已放好的窗口。
    private func shoot(_ fixture: HomeAppFixture, reuse: Bool = false) async throws -> Shot {
        if !reuse || window == nil {
            // 冷启动（与首页 Tab 出现同一入口）并结算，再放进窗口
            await fixture.launch()
            let home = fixture.home
            let root = HomeRouteHost(home: home)
            let host = UIHostingController(rootView: root)
            let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
            let window = scene.map { UIWindow(windowScene: $0) } ?? UIWindow(frame: CGRect(
                x: 0,
                y: 0,
                width: 390,
                height: 844
            ))
            window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
            window.overrideUserInterfaceStyle = .light
            window.rootViewController = host
            window.isHidden = false
            host.view.layoutIfNeeded()
            self.window = window
        }
        await fixture.controller.whenIdle()
        fixture.clock.advance(0)
        await fixture.controller.whenIdle()
        await AppColorBlockImages.settle()
        let window = try XCTUnwrap(window)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        let image = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
            _ = window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        return Self.scan(image)
    }

    /// 逐行扫描：底色取左上角页面内边距处；返回最大色差、颜色数、内容下沿与内容中间最长的整段底色（pt）。
    private static func scan(_ image: UIImage) -> Shot {
        guard let cgImage = image.cgImage else { return Shot(chroma: 0, colors: 0, bottom: 0, blank: 0) }
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
        let scale = CGFloat(height) / max(1, image.size.height)
        let probe = (Int(6 * scale) + Int(6 * scale) * width) * 4
        let background = (Int(pixels[probe]), Int(pixels[probe + 1]), Int(pixels[probe + 2]))
        var chroma = 0, top: Int?, bottom: Int?, blank = 0, longest = 0
        var colors = Set<UInt32>()
        for row in 0..<height {
            var content = false
            for column in stride(from: 0, to: width, by: 2) {
                let index = (row * width + column) * 4
                let red = Int(pixels[index]), green = Int(pixels[index + 1]), blue = Int(pixels[index + 2])
                chroma = max(chroma, max(red, green, blue) - min(red, green, blue))
                if abs(red - background.0) > 6 || abs(green - background.1) > 6 || abs(blue - background.2) > 6 {
                    content = true
                }
                if row % 8 == 0, column % 8 == 0 {
                    colors.insert(UInt32(red >> 4) << 8 | UInt32(green >> 4) << 4 | UInt32(blue >> 4))
                }
            }
            if content {
                top = top ?? row
                if bottom != nil {
                    longest = max(longest, blank)
                }
                bottom = row
                blank = 0
            } else if top != nil {
                blank += 1
            }
        }
        return Shot(
            chroma: chroma, colors: colors.count, bottom: CGFloat((bottom ?? 0) + 1) / scale,
            blank: CGFloat(longest) / scale
        )
    }
}

/// 路由表里的首页视图（RouteViewRegistry "Home"），带 AppHome 环境对象。
private struct HomeRouteHost: View {
    @ObservedObject var home: AppHome
    var body: some View {
        HomeRouteView(destination: RouteDestination(route: "Home")).environmentObject(home)
    }
}

/// 首页图片的本机色块（第 4 版 T3）：只拦图片主机（img.example.com / img.example.invalid），按地址回固定颜色的 PNG，
/// 其余请求不碰（契约接口仍由 WalletStubProtocol 回答）。
final class AppColorBlockImages: URLProtocol, @unchecked Sendable {
    static let hosts: Set<String> = ["img.example.com", "img.example.invalid", "img.example.test"]
    private static let lock = NSLock()
    private nonisolated(unsafe) static var started = 0
    private nonisolated(unsafe) static var finished = 0
    private nonisolated(unsafe) static var urls: [String] = []
    private nonisolated(unsafe) static var generation = 0

    static func install() {
        reset()
        URLProtocol.registerClass(AppColorBlockImages.self)
    }

    /// 每张图开始前清零；旧窗口尚未结束的请求不能给新窗口充数。
    static func reset() {
        lock.withLock {
            generation += 1
            started = 0
            finished = 0
            urls = []
        }
    }

    static func uninstall() {
        URLProtocol.unregisterClass(AppColorBlockImages.self)
    }

    static var served: [String] {
        lock.withLock { urls }
    }

    /// 指定图片必须在本轮完成，所有请求结算且静止 0.4 秒后，再给界面 0.3 秒（上限 8 秒）。
    @MainActor
    static func settle(expect url: String? = nil, file: StaticString = #filePath, line: UInt = #line) async {
        var last = -1
        var quiet = 0
        for _ in 0..<80 {
            try? await Task.sleep(nanoseconds: 100_000_000)
            let now = lock.withLock { (started, finished, url.map { urls.contains($0) } ?? true) }
            if now.0 == now.1, now.0 == last, now.2 {
                quiet += 1
                if quiet >= 4 {
                    try? await Task.sleep(nanoseconds: 300_000_000)
                    if lock.withLock({ started == now.0 && finished == now.1 }) {
                        return
                    }
                    quiet = 0
                }
            } else {
                quiet = 0
            }
            last = now.0
        }
        XCTFail("图片请求未完成或未稳定：\(url ?? "全部本机图片")", file: file, line: line)
    }

    override static func canInit(with request: URLRequest) -> Bool {
        request.url?.host.map(hosts.contains) ?? false
    }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let generation = Self.lock.withLock {
            Self.started += 1
            return Self.generation
        }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let png = UIGraphicsImageRenderer(size: CGSize(width: 24, height: 24), format: format).pngData { context in
            UIColor(red: 0.10, green: 0.55, blue: 0.95, alpha: 1).setFill()
            context.fill(CGRect(x: 0, y: 0, width: 24, height: 24))
        }
        if let url = request.url,
           let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                          headerFields: ["Content-Type": "image/png"]) {
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        }
        client?.urlProtocol(self, didLoad: png)
        client?.urlProtocolDidFinishLoading(self)
        Self.lock.withLock {
            guard generation == Self.generation else { return }
            Self.finished += 1
            Self.urls.append(request.url?.absoluteString ?? "")
        }
    }

    override func stopLoading() {}
}
