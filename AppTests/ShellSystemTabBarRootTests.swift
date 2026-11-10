import Config
@testable import Couli
import Foundation
import HomeCore
import Router
import SwiftUI
import UIKit
import XCTest

/// FU-IOS-NATIVE-TABBAR 进程内、完整 RootView（HomeVisualAppHost：真实 Router / AppRouting / 守卫 / 外壳 / 首页）：
/// - 选中跟随 Router：Router 切 Tab，标签栏选中随之切换；
/// - 守卫拦截：游客点「订单」压登录页、基本模式点「我的」补同意，Router 的 Tab 根不切，标签栏选中回到首页、不停在目标 Tab；
/// - 首页常驻：切走再回来同一个滚动容器、同一位置、同一个首页控制器；
/// - 首页末项可见可点（D10-831 必须同修）：滚到底时内容末端在标签栏上沿之上，命中落在首页内容里；内容铺到标签栏下方（不垫实色条）。
@MainActor
final class ShellSystemTabBarRootTests: HomeAppTestCase {
    private var window: UIWindow?

    override func setUpWithError() throws {
        try super.setUpWithError()
        Self.clearRouterRecords()
        AppColorBlockImages.install()
    }

    override func tearDown() {
        window?.isHidden = true
        window?.rootViewController = nil
        window = nil
        AppColorBlockImages.uninstall()
        Self.clearRouterRecords()
        super.tearDown()
    }

    /// v2：被拦用例（游客点订单、基本模式点我的）让 AppRouting 在 UserDefaults.standard 登记 pending_action
    /// （UserDefaultsPendingBackend.key）；同进程下一例冷启动会把它恢复出来（tabRoot 变成 Me，或渲染出宿主缺 AppOrders 的订单页而崩溃）。
    /// 每例前后清掉 App 命名空间下 Router 的本机记录，用例之间互不串扰（只清 router.*，不碰别的键）。
    private static func clearRouterRecords() {
        let defaults = UserDefaults.standard
        UserDefaultsPendingBackend(defaults: defaults).delete()
        let prefix = AppNamespace.userDefaultsPrefix + "router."
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix(prefix) {
            defaults.removeObject(forKey: key)
        }
    }

    // MARK: 选中跟随 Router

    func testSelectionFollowsRouter() async throws {
        let fixture = try products(account: "tabbar-member")
        let (_, controller) = try await mount(fixture)
        XCTAssertEqual(ShellTabBarProbe.selectedIndex(controller), 0)
        XCTAssertNotNil(fixture.routing.selectTab(.me), "前提：会员切「我的」放行")
        await waitUntil("Router 切到「我的」后标签栏没有跟着选中「我的」") {
            ShellTabBarProbe.selectedIndex(controller) == 3
        }
        XCTAssertNotNil(fixture.routing.selectTab(.home))
        await waitUntil("Router 切回首页后标签栏没有跟着选中首页") { ShellTabBarProbe.selectedIndex(controller) == 0 }
    }

    // MARK: 守卫拦截

    func testGuestTappingOrdersIsGuardedAndSelectionStaysHome() async throws {
        let fixture = make(account: nil)
        let (_, controller) = try await mount(fixture)
        ShellTabBarProbe.simulateUserSelect(2, in: controller)
        let samples = ShellTabBarProbe.selectionSamples(controller)
        await waitUntil("游客点「订单」应压登录页") { fixture.router.path.last?.route == RoutePolicy.login }
        XCTAssertEqual(fixture.router.tabRoot.route, RoutePolicy.home, "被拦时 Router 的 Tab 根不切")
        XCTAssertTrue(samples.allSatisfy { $0 == 0 }, "被拦后标签栏选中应始终是首页，不闪到「订单」：\(samples)")
        await settle()
        XCTAssertEqual(ShellTabBarProbe.selectedIndex(controller), 0, "绑定回原值")
    }

    func testBasicModeTappingMeRepromptsAndSelectionStaysHome() async throws {
        let fixture = make(account: nil, decision: "basic_mode")
        let (_, controller) = try await mount(fixture)
        XCTAssertFalse(fixture.privacy.isPrompting, "前提：基本模式冷启动不弹")
        ShellTabBarProbe.simulateUserSelect(3, in: controller)
        let samples = ShellTabBarProbe.selectionSamples(controller)
        await waitUntil("基本模式点「我的」应补同意（重新弹首启弹窗）") { fixture.privacy.isPrompting }
        XCTAssertEqual(fixture.router.tabRoot.route, RoutePolicy.home, "被拦时 Router 的 Tab 根不切")
        XCTAssertTrue(samples.allSatisfy { $0 == 0 }, "被拦后标签栏选中应始终是首页，不闪到「我的」：\(samples)")
    }

    // MARK: 首页常驻与滚动位置

    func testHomeRetainedWithScrollPositionAcrossTabs() async throws {
        let fixture = try products(account: "tabbar-member")
        let (canvas, _) = try await mount(fixture)
        let scroll = try XCTUnwrap(homeScroll(in: canvas), "首页没有可滚动的滚动容器")
        let controller = fixture.controller
        scroll.setContentOffset(CGPoint(x: 0, y: 300), animated: false)
        await settle()
        XCTAssertEqual(scroll.contentOffset.y, 300, accuracy: 1, "前提：首页滚到 300")
        XCTAssertNotNil(fixture.routing.selectTab(.me))
        await settle(40)
        XCTAssertNotNil(fixture.routing.selectTab(.home))
        await settle(40)
        XCTAssertTrue(scroll.window === canvas, "切回首页应是同一个滚动容器（首页没有重建）")
        XCTAssertEqual(scroll.contentOffset.y, 300, accuracy: 1, "切回首页滚动位置不变")
        XCTAssertTrue(fixture.controller === controller, "首页控制器没有重建")
    }

    // MARK: 首页末项可见可点、内容铺到标签栏下

    func testHomeLastItemAboveTabBarAndContentExtendsUnderIt() async throws {
        let fixture = try products(account: "tabbar-member")
        let (canvas, controller) = try await mount(fixture)
        XCTAssertTrue(ShellTabBarProbe.isShowing(controller, in: canvas), "系统标签栏应显示")
        let scroll = try XCTUnwrap(homeScroll(in: canvas), "首页没有可滚动的滚动容器")
        let frame = scroll.convert(scroll.bounds, to: canvas)
        XCTAssertEqual(frame.maxY, canvas.bounds.maxY, accuracy: 1,
                       "首页滚动容器应铺到窗口底（内容从玻璃标签栏下透出，不另垫实色条）：\(frame)")
        var end = CGFloat.zero
        for _ in 0..<12 {
            let maxOffset = scroll.contentSize.height + scroll.adjustedContentInset.bottom - scroll.bounds.height
            scroll.setContentOffset(CGPoint(x: 0, y: max(-scroll.adjustedContentInset.top, maxOffset)), animated: false)
            scroll.layoutIfNeeded()
            await settle()
            let now = scroll.convert(CGPoint(x: 0, y: scroll.contentSize.height), to: canvas).y
            if abs(now - end) < 0.5 {
                break
            }
            end = now
        }
        let barTop = controller.tabBar.convert(controller.tabBar.bounds, to: canvas).minY
        XCTAssertLessThanOrEqual(end, barTop + 0.5,
                                 "滚到底时首页内容末端（\(end)）应在标签栏上沿（\(barTop)）之上，末项不压在玻璃下")
        let point = CGPoint(x: canvas.bounds.midX, y: min(end, barTop) - 8)
        let hit = try XCTUnwrap(canvas.hitTest(point, with: nil), "末项位置没有可命中的视图")
        XCTAssertTrue(hit.isDescendant(of: scroll), "末项位置的点击应落在首页内容里：\(hit)")
        XCTAssertFalse(hit.isDescendant(of: controller.tabBar), "末项位置的点击不应落在标签栏上")
    }

    // MARK: 工具

    /// 有商品的首页（与 HomeVisualAppSnapshotTests 同一份 goldenPages main_v3），能滚动好几屏。
    private func products(account: String) throws -> HomeAppFixture {
        let pages = try XCTUnwrap(try HomeAppSamples.vectors()["goldenPages"] as? [String: Any])
        var page = try XCTUnwrap(pages["main_v3"] as? [String: Any])
        let responses = try XCTUnwrap(page.removeValue(forKey: "sectionItems") as? [String: Any])
        let replies = try responses.mapValues { try JSONSerialization.data(withJSONObject: $0) }
        let port = TestHomePort(page: page)
        port.set(items: { id, _ in .success(data: replies[id], traceId: nil, idempotencyKey: nil) })
        return make(account: account, port: port)
    }

    private func mount(_ fixture: HomeAppFixture) async throws -> (UIWindow, UITabBarController) {
        await fixture.launch()
        let root = HomeVisualAppHost.root(fixture, defaults: defaults, directory: storageRoot)
        let host = UIHostingController(rootView: root)
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let canvas = scene.map { UIWindow(windowScene: $0) } ?? UIWindow(frame: .zero)
        canvas.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        canvas.overrideUserInterfaceStyle = .light
        canvas.rootViewController = host
        canvas.makeKeyAndVisible()
        window = canvas
        host.view.layoutIfNeeded()
        await settle(40)
        await fixture.controller.whenIdle()
        await settle()
        let controller = try XCTUnwrap(ShellTabBarProbe.controller(in: canvas), "外壳里没有系统 TabView 的 UITabBarController")
        return (canvas, controller)
    }

    /// 首页的纵向滚动容器：窗口里可见、内容高于自身、面积最大的那个（不在标签栏里）。
    private func homeScroll(in canvas: UIWindow) -> UIScrollView? {
        ShellTabBarProbe.views(in: canvas).compactMap { $0 as? UIScrollView }
            .filter { scroll in
                scroll.window === canvas && !scroll.isHidden && scroll.alpha > 0.01
                    && scroll.contentSize.height > scroll.bounds.height + 1
                    && !ShellTabBarProbe.views(in: canvas).contains { $0 is UITabBar && scroll.isDescendant(of: $0) }
            }
            .max { $0.bounds.width * $0.bounds.height < $1.bounds.width * $1.bounds.height }
    }
}
