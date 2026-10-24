@testable import Couli
import CouliNetwork
import Foundation
import HomeCore
import SnapshotTesting
import SwiftUI
import UIKit
import XCTest

/// a 组整页：与画板同宽同高。测试源码不重画搜索、粘贴、价值卡、SDUI 或底栏。
@MainActor
final class HomeVisualAppSnapshotTests: HomeAppTestCase {
    private var window: UIWindow?
    private var previousDebugSetting: Any?

    override func setUpWithError() throws {
        try super.setUpWithError()
        previousDebugSetting = UserDefaults.standard.object(forKey: "CouliHideDebugInfo")
        UserDefaults.standard.set(true, forKey: "CouliHideDebugInfo")
        AppColorBlockImages.install()
    }

    override func tearDown() {
        window?.isHidden = true
        window?.rootViewController = nil
        window = nil
        UserDefaults.standard.set(previousDebugSetting, forKey: "CouliHideDebugInfo")
        AppColorBlockImages.uninstall()
        super.tearDown()
    }

    func testMainGuestDarkAndRankArtboards() async throws {
        for (name, guest, dark, rank, height) in [
            ("Main-v3", false, false, false, 2359), ("HomeGuest-v3", true, false, false, 2823),
            ("MainDark-v3", false, true, false, 1199), ("Main-v3-dark", false, true, false, 2359),
            ("HomeGuest-v3-dark", true, true, false, 2823), ("MainRankEntry-v3", false, false, true, 2359),
        ] {
            let fixture = try makeVisual(guest: guest, rank: rank)
            await fixture.launch()
            assertProducts(fixture)
            await shot(fixture, name: name, height: CGFloat(height), dark: dark)
        }
    }

    func testLargeTextAndBothLargeScreenIdentities() async throws {
        for width: CGFloat in [320, 390] {
            for dark in width == 390 ? [false, true] : [false] {
                let fixture = try makeVisual(guest: true)
                await fixture.launch()
                assertProducts(fixture)
                await shot(fixture, name: "font200-w\(Int(width))-\(dark ? "dark" : "light")", width: width,
                           height: 2823, dark: dark, size: .accessibility3)
            }
        }
        for basic in [false, true] {
            let fixture = try makeVisual(guest: basic, basic: basic)
            await fixture.launch()
            assertProducts(fixture)
            // 基本模式必须挂在 App 的窗口场景上截：不挂场景的独立 UIWindow 里，基本模式首页的商品图请求已应答、AsyncImage 已到
            // 「已加载」，但图层树里没有任何商品图层（测试 v5 诊断：基本模式 390 / 600 / 840 宽都是 0 像素；同一装配挂上场景后
            // 840 宽 11 万像素；游客 / 会员不挂场景也正常）。这是测试宿主装配问题，真实 App（窗口总在场景里）不受影响。
            await shot(fixture, name: basic ? "Basic-w840" : "Main-w840", width: 840, height: 1400, scene: basic)
        }
    }

    private func makeVisual(guest: Bool, basic: Bool = false, rank: Bool = false) throws -> HomeAppFixture {
        // 每张图都冷启动；同一身份不能读到上一张图写下的 LKG / 偏好。
        window?.isHidden = true
        window?.rootViewController = nil
        window = nil
        defaults.removePersistentDomain(forName: suiteName)
        if FileManager.default.fileExists(atPath: storageRoot.path) {
            try FileManager.default.removeItem(at: storageRoot)
        }
        suiteName = "home-visual-app-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        storageRoot = FileManager.default.temporaryDirectory.appendingPathComponent(suiteName)
        XCTAssertFalse(FileManager.default.fileExists(atPath: storageRoot.path))
        let pages = try XCTUnwrap(try HomeAppSamples.vectors()["goldenPages"] as? [String: Any])
        var page = try XCTUnwrap(pages[guest ? "guest_v3" : "main_v3"] as? [String: Any])
        let responses = try XCTUnwrap(page.removeValue(forKey: "sectionItems") as? [String: Any])
        if rank {
            var sections = try XCTUnwrap(page["sections"] as? [[String: Any]])
            var source = try XCTUnwrap(sections[0]["data_source"] as? [String: Any])
            var items = try XCTUnwrap(source["items"] as? [[String: Any]])
            items[8] = ["title": "热销榜", "icon": "https://img.example.test/rank.png", "action": ["route": "HotRankList"]]
            source["items"] = items; sections[0]["data_source"] = source; page["sections"] = sections
        }
        let replies = try responses.mapValues { try JSONSerialization.data(withJSONObject: $0) }
        let port = TestHomePort(page: page)
        port.set(items: { id, _ in .success(data: replies[id], traceId: nil, idempotencyKey: nil) })
        return make(account: guest ? nil : "visual-member", decision: basic ? "basic_mode" : "consented", port: port)
    }

    private func assertProducts(_ fixture: HomeAppFixture) {
        XCTAssertEqual(fixture.controller.state.source, .network)
        XCTAssertEqual(fixture.controller.state.section("scroll")?.items.count, 3)
        XCTAssertEqual(fixture.controller.state.section("grid")?.items.count, 2)
        XCTAssertEqual(fixture.controller.state.section("feed")?.items.count, 4)
    }

    private func shot(_ fixture: HomeAppFixture, name: String, width: CGFloat = 390, height: CGFloat,
                      dark: Bool = false, size: DynamicTypeSize = .large, scene: Bool = false,
                      file: StaticString = #filePath, testName: String = #function, line: UInt = #line) async {
        window?.isHidden = true
        window?.rootViewController = nil
        AppColorBlockImages.reset()
        let root = HomeVisualAppHost.root(fixture, defaults: defaults, directory: storageRoot)
            .environment(\.colorScheme, dark ? .dark : .light).environment(\.dynamicTypeSize, size)
        let host = UIHostingController(rootView: root)
        let canvas: UIWindow
        if scene {
            guard let windowScene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first
            else {
                XCTFail("App 宿主没有窗口场景，不能截基本模式", file: file, line: line)
                return
            }
            canvas = UIWindow(windowScene: windowScene)
        } else {
            canvas = UIWindow(frame: .zero)
        }
        canvas.frame = CGRect(x: 0, y: 0, width: width, height: height)
        canvas.overrideUserInterfaceStyle = dark ? .dark : .light
        canvas.rootViewController = host
        defer {
            canvas.isHidden = true
            canvas.rootViewController = nil
        }
        window = canvas
        canvas.makeKeyAndVisible()
        host.view.frame = canvas.bounds
        host.view.layoutIfNeeded()
        await AppColorBlockImages.settle(expect: "https://img.example.test/home-v3/0.png", file: file, line: line)
        guard let image = await renderedImage(in: canvas, file: file, line: line) else { return }
        XCTAssertEqual(image.size, CGSize(width: width, height: height), file: file, line: line)
        XCTAssertGreaterThanOrEqual(blueImagePixels(image), 2000,
                                    "真实页面必须画出商品测试位图，不能把空白窗口录成基准", file: file, line: line)
        XCTAssertTrue(AppColorBlockImages.served.contains("https://img.example.test/home-v3/0.png"),
                      "首个横滑商品没有请求，不能录空白页", file: file, line: line)
        withSnapshotTesting(record: ProcessInfo.processInfo
            .environment["COULI_RECORD_SNAPSHOTS"] == "1" ? .missing : .never) {
                assertSnapshot(of: image, as: .image(precision: 0.99, perceptualPrecision: 0.98), named: name,
                               file: file, testName: testName, line: line)
            }
    }

    /// 请求完成不代表 AsyncImage 已上屏；只有像素达标且连续两帧整图相同才可比对或录制。
    private func renderedImage(in canvas: UIWindow, file: StaticString, line: UInt) async -> UIImage? {
        let format = UIGraphicsImageRendererFormat(); format.scale = 3
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(8))
        var previousPNG: Data?
        var pixels = 0
        while clock.now < deadline {
            let image = UIGraphicsImageRenderer(bounds: canvas.bounds, format: format).image { context in
                canvas.layer.render(in: context.cgContext)
            }
            pixels = blueImagePixels(image)
            if pixels >= 2000, let png = image.pngData() {
                if png == previousPNG {
                    return image
                }
                previousPNG = png
            } else {
                previousPNG = nil
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        XCTFail("等待商品测试位图上屏超时（8 秒）：最后一帧 \(pixels) 像素，须 ≥2000 且连续两帧整图相同",
                file: file, line: line)
        return nil
    }

    private func blueImagePixels(_ image: UIImage) -> Int {
        guard let source = image.cgImage else { return 0 }
        var bytes = [UInt8](repeating: 0, count: source.width * source.height * 4)
        guard let context = CGContext(data: &bytes, width: source.width, height: source.height, bitsPerComponent: 8,
                                      bytesPerRow: source.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return 0 }
        context.draw(source, in: CGRect(x: 0, y: 0, width: source.width, height: source.height))
        return stride(from: 0, to: bytes.count, by: 4).filter {
            abs(Int(bytes[$0]) - 26) <= 8 && abs(Int(bytes[$0 + 1]) - 140) <= 8 && abs(Int(bytes[$0 + 2]) - 242) <= 8
        }.count
    }
}
