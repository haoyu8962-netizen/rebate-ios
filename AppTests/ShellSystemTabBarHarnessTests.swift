@testable import Couli
import DesignSystem
import Router
import SwiftUI
import UIKit
import XCTest

/// FU-IOS-NATIVE-TABBAR 进程内：只装外壳（ShellTabHarness），不进 Feature。
/// - 系统标签栏显示着，4 项文字取 ShellDraftTexts、图标是 SF Symbols；
/// - 选中只跟随 `root`：模拟用户点别的 Tab 时 set 走 onSelect（记一次），`root` 不变时 UIKit 侧选中回到首页、不在目标 Tab 停留；
/// - 品牌色只作用于标签栏：选中项是品牌色、不是系统蓝；首页位置探针块取到的 tint 仍是系统默认色（D10-831 ①）。
@MainActor
final class ShellSystemTabBarHarnessTests: XCTestCase {
    private var window: UIWindow?

    override func tearDown() {
        window?.isHidden = true
        window?.rootViewController = nil
        window = nil
        super.tearDown()
    }

    private func mount(_ harness: ShellTabHarness, dark: Bool = false) async throws -> (UIWindow, UITabBarController) {
        let host = UIHostingController(rootView: ShellTabHarnessView(harness: harness))
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let canvas = scene.map { UIWindow(windowScene: $0) } ?? UIWindow(frame: .zero)
        canvas.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        canvas.overrideUserInterfaceStyle = dark ? .dark : .light
        canvas.rootViewController = host
        canvas.makeKeyAndVisible()
        window = canvas
        host.view.layoutIfNeeded()
        await settle()
        let controller = try XCTUnwrap(ShellTabBarProbe.controller(in: canvas), "外壳里没有系统 TabView 的 UITabBarController")
        return (canvas, controller)
    }

    func testSystemTabBarShowsDraftTitlesAndSymbolIcons() async throws {
        let (canvas, controller) = try await mount(ShellTabHarness())
        XCTAssertTrue(
            ShellTabBarProbe.isShowing(controller, in: canvas),
            "系统标签栏应显示（不再 .toolbar(.hidden, for: .tabBar)）"
        )
        XCTAssertEqual(ShellTabBarProbe.titles(controller), [
            ShellDraftTexts.tabHome, ShellDraftTexts.tabAgent, ShellDraftTexts.tabOrders, ShellDraftTexts.tabMe,
        ], "标签文字取 ShellDraftTexts 的 Tab 文案，顺序首页 / AI 助手 / 订单 / 我的")
        let images = ShellTabBarProbe.images(controller)
        XCTAssertEqual(images.count, 4)
        // v2：iOS 26 把 SF Symbol doc.text 改名 text.document（系统给出 text.document.fill；产品传的仍是 doc.text，系统按别名解析），
        // 按运行系统取对应名，不写死旧名。
        var orders = "doc.text"
        if #available(iOS 26.0, *) {
            orders = "text.document"
        }
        for (index, name) in ["house", "bubble.left", orders, "person"].enumerated() where index < images.count {
            let image = try XCTUnwrap(images[index], "第 \(index + 1) 项没有图标")
            XCTAssertTrue(image.isSymbolImage, "第 \(index + 1) 项图标应是 SF Symbols")
            XCTAssertTrue(String(describing: image).contains(name), "第 \(index + 1) 项应是 \(name)：\(image)")
        }
        XCTAssertEqual(ShellTabBarProbe.selectedIndex(controller), 0, "root 是首页时选中首页")
    }

    /// 方案 T3 的进程内一半：被拦（root 不变）时绑定回原值、不停在目标 Tab。
    /// 判据：点「订单」后 onSelect 恰好收到一次 .orders；点击之后每一帧（约 8ms 取一次、共 0.4 秒）UIKit 侧选中都是首页。
    /// 若 iOS 26 实测闪一帧（第一帧读数是目标 Tab），按方案 §1.2 退路（被拦时触发外壳重算、不动 TabView 身份）修，不放宽本判据。
    func testBlockedSelectionBouncesBackWithoutLandingOnTarget() async throws {
        let harness = ShellTabHarness()
        let (_, controller) = try await mount(harness)
        XCTAssertEqual(ShellTabBarProbe.selectedIndex(controller), 0)
        ShellTabBarProbe.simulateUserSelect(2, in: controller)
        let samples = ShellTabBarProbe.selectionSamples(controller)
        XCTAssertEqual(harness.taps, [.orders], "点 Tab 时选中绑定的 set 走 onSelect（过守卫），恰好一次")
        XCTAssertEqual(harness.root.route, RoutePolicy.home, "测试台不放行，root 不变")
        XCTAssertFalse(samples.isEmpty)
        XCTAssertTrue(samples.allSatisfy { $0 == 0 }, "被拦后 UIKit 侧选中应始终是首页，不闪到 / 停在「订单」：\(samples)")
    }

    /// 品牌色只在标签栏（D10-831 ①）：选中项（首页）像素里有品牌主色、没有系统蓝；页面内容上的 tint 不是品牌色。浅 / 深各一次。
    func testBrandTintOnlyOnTabBar() async throws {
        for dark in [false, true] {
            window?.isHidden = true
            window = nil
            let harness = ShellTabHarness()
            let (canvas, controller) = try await mount(harness, dark: dark)
            XCTAssertTrue(ShellTabBarProbe.isShowing(controller, in: canvas), "系统标签栏应显示")
            let image = ShellTabBarProbe.render(canvas)
            let bar = controller.tabBar.convert(controller.tabBar.bounds, to: canvas)
            let brand = try XCTUnwrap(ShellTabBarProbe.token("brand.primary", dark: dark))
            let brandPixels = ShellTabBarProbe.count(image, in: bar, near: brand, tolerance: 28)
            let bluePixels = ShellTabBarProbe.countSystemBlue(image, in: bar)
            let mode = dark ? "深色" : "浅色"
            XCTAssertGreaterThanOrEqual(
                brandPixels,
                10,
                "\(mode)：选中项应是品牌主色（tint=\(String(describing: controller.tabBar.tintColor))）"
            )
            XCTAssertLessThan(bluePixels, 10, "\(mode)：标签栏里不应出现系统蓝选中色（\(bluePixels) 像素）")

            let probe = harness.probeFrame
            XCTAssertFalse(probe.isEmpty, "探针块没有上屏")
            let color = try XCTUnwrap(ShellTabBarProbe.center(image, of: probe), "取不到探针块颜色")
            XCTAssertFalse(
                color.isNear(brand, tolerance: 40),
                "\(mode)：页面内容的 tint 不应是品牌色（本单只改标签栏，全局 tint 另开单）：\(color)"
            )
            XCTAssertGreaterThanOrEqual(color.blue - color.red, 120, "\(mode)：页面内容的 tint 应仍是系统默认蓝：\(color)")
        }
    }
}
