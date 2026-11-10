@testable import Couli
import DesignSystem
import Router
import SwiftUI
import UIKit
import XCTest

/// FU-IOS-NATIVE-TABBAR 进程内测试的公共部分：在窗口里找外壳的系统标签栏（SwiftUI TabView 背后的 UITabBarController），
/// 按 UIKit 的用户点击约定模拟点 Tab，取像素。真机点击另在 UITests/ShellSystemTabBarUITests。
@MainActor
enum ShellTabBarProbe {
    /// 窗口里外壳的 UITabBarController（先按视图控制器树找，找不到再从 UITabBar 顺响应链找）。
    static func controller(in window: UIWindow) -> UITabBarController? {
        func find(_ controller: UIViewController?) -> UITabBarController? {
            guard let controller else { return nil }
            if let tabs = controller as? UITabBarController {
                return tabs
            }
            for child in controller.children {
                if let found = find(child) {
                    return found
                }
            }
            return find(controller.presentedViewController)
        }
        if let found = find(window.rootViewController) {
            return found
        }
        var responder: UIResponder? = views(in: window).first { $0 is UITabBar }
        while let next = responder {
            if let tabs = next as? UITabBarController {
                return tabs
            }
            responder = next.next
        }
        return nil
    }

    static func views(in root: UIView) -> [UIView] {
        [root] + root.subviews.flatMap { views(in: $0) }
    }

    /// 标签栏显示着：没隐藏、不透明度 > 0、在窗口里且与窗口相交。
    static func isShowing(_ controller: UITabBarController, in window: UIWindow) -> Bool {
        let bar = controller.tabBar
        guard bar.window === window, !bar.isHidden, bar.alpha > 0.01 else { return false }
        if #available(iOS 18.0, *), controller.isTabBarHidden {
            return false
        }
        return bar.convert(bar.bounds, to: window).intersects(window.bounds)
    }

    /// 各 Tab 的标题（按顺序）。
    static func titles(_ controller: UITabBarController) -> [String] {
        if #available(iOS 18.0, *), !controller.tabs.isEmpty {
            return controller.tabs.map(\.title)
        }
        return (controller.tabBar.items ?? []).map { $0.title ?? "" }
    }

    /// 各 Tab 的图标（按顺序）。
    static func images(_ controller: UITabBarController) -> [UIImage?] {
        if #available(iOS 18.0, *), !controller.tabs.isEmpty {
            return controller.tabs.map(\.image)
        }
        return (controller.tabBar.items ?? []).map(\.image)
    }

    /// 当前选中的 Tab 序号（UIKit 侧，即屏幕上标签栏显示的选中项）。
    static func selectedIndex(_ controller: UITabBarController) -> Int? {
        if #available(iOS 18.0, *), !controller.tabs.isEmpty {
            return controller.selectedTab.flatMap { tab in controller.tabs.firstIndex { $0 === tab } }
        }
        let index = controller.selectedIndex
        return index == NSNotFound ? nil : index
    }

    /// 按 UIKit 的用户点击约定模拟点第 `index` 个 Tab：先问代理 shouldSelect，允许才切，再通知 didSelect
    /// （SwiftUI TabView 的选中绑定就是经这条代理路径收到用户点击的）。
    static func simulateUserSelect(_ index: Int, in controller: UITabBarController) {
        if #available(iOS 18.0, *), !controller.tabs.isEmpty {
            let tab = controller.tabs[index]
            let previous = controller.selectedTab
            guard controller.delegate?.tabBarController?(controller, shouldSelectTab: tab) ?? true else { return }
            controller.selectedTab = tab
            controller.delegate?.tabBarController?(controller, didSelectTab: tab, previousTab: previous)
            return
        }
        guard let target = controller.viewControllers?[index] else { return }
        guard controller.delegate?.tabBarController?(controller, shouldSelect: target) ?? true else { return }
        controller.selectedViewController = target
        controller.delegate?.tabBarController?(controller, didSelect: target)
    }

    /// 模拟点击后约 `seconds` 秒内每约 8ms 取一次 UIKit 侧选中序号（不含点击同一调用栈里的那一次读数）。
    static func selectionSamples(_ controller: UITabBarController, seconds: TimeInterval = 0.4) -> [Int?] {
        var samples: [Int?] = []
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.008))
            samples.append(selectedIndex(controller))
        }
        return samples
    }

    /// 窗口整图（drawHierarchy，App 宿主有窗口场景时拍到的是合成后的画面）。
    static func render(_ window: UIWindow) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
            _ = window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
    }

    /// 图中某区域（pt，scale 1）里与 `rgb`（0…255）每个通道相差不超过 `tolerance` 的像素数。
    static func count(_ image: UIImage, in rect: CGRect, near rgb: ShellRGB, tolerance: Int) -> Int {
        pixels(image, in: rect).filter { $0.isNear(rgb, tolerance: tolerance) }.count
    }

    /// 图中某区域里「系统蓝一类」的像素数（蓝通道明显高于红、且饱和）。
    static func countSystemBlue(_ image: UIImage, in rect: CGRect) -> Int {
        pixels(image, in: rect).filter { $0.blue >= 200 && $0.blue - $0.red >= 120 && (90...175).contains($0.green) }
            .count
    }

    /// 区域中心点的颜色（0…255）。
    static func center(_ image: UIImage, of rect: CGRect) -> ShellRGB? {
        pixels(image, in: CGRect(x: rect.midX - 1, y: rect.midY - 1, width: 2, height: 2)).first
    }

    private static func pixels(_ image: UIImage, in rect: CGRect) -> [ShellRGB] {
        guard let source = image.cgImage else { return [] }
        let width = source.width, height = source.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(data: &bytes, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return [] }
        context.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))
        let area = rect.integral.intersection(CGRect(x: 0, y: 0, width: width, height: height))
        guard !area.isNull, !area.isEmpty else { return [] }
        var found: [ShellRGB] = []
        for row in Int(area.minY)..<Int(area.maxY) {
            for column in Int(area.minX)..<Int(area.maxX) {
                let offset = (row * width + column) * 4
                found.append(ShellRGB(
                    red: Int(bytes[offset]),
                    green: Int(bytes[offset + 1]),
                    blue: Int(bytes[offset + 2])
                ))
            }
        }
        return found
    }

    /// 令牌颜色（0…255）；dark 为 true 时取深色值。
    static func token(_ path: String, dark: Bool = false) -> ShellRGB? {
        guard let rgb = dark ? TokenRGB(darkToken: path) : TokenRGB(token: path) else { return nil }
        return ShellRGB(red: Int((rgb.red * 255).rounded()), green: Int((rgb.green * 255).rounded()),
                        blue: Int((rgb.blue * 255).rounded()))
    }
}

/// 像素颜色（0…255）。
struct ShellRGB: Equatable, CustomStringConvertible {
    let red: Int
    let green: Int
    let blue: Int

    func isNear(_ other: ShellRGB, tolerance: Int) -> Bool {
        abs(red - other.red) <= tolerance && abs(green - other.green) <= tolerance && abs(blue - other.blue) <=
            tolerance
    }

    var description: String {
        "rgb(\(red), \(green), \(blue))"
    }
}

/// 只装外壳的测试台：Router 换成可控的 `root` 与记录点击的 `onSelect`；首页换成测试探针页（不进 Feature）。
/// 非首页 Tab 只在 `root` 指向它时才渲染路由页，测试台里 `root` 一直是首页，所以不需要各 Feature 的环境对象。
@MainActor
final class ShellTabHarness: ObservableObject {
    @Published var root = RouteDestination(route: RoutePolicy.home)
    var taps: [ShellTab] = []
    var probeFrame: CGRect = .zero
}

struct ShellTabHarnessView: View {
    @ObservedObject var harness: ShellTabHarness

    var body: some View {
        TabShellView(
            root: harness.root,
            onSelect: { harness.taps.append($0) },
            home: { _ in ShellTabProbePage(harness: harness) }
        )
    }
}

/// 首页位置的探针：一块用当前 tint 填充的方块（看页面内容取到的是不是品牌色），并记下自己在窗口里的位置。
struct ShellTabProbePage: View {
    let harness: ShellTabHarness

    var body: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(.tint)
                .frame(width: 80, height: 80)
                .background(GeometryReader { proxy in
                    Color.clear.onAppear { harness.probeFrame = proxy.frame(in: .global) }
                })
                .padding(.top, 120)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
