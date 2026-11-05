@testable import Couli
import Foundation
import Generated
import Router
import SwiftUI
import XCTest

/// FU-X-HOME-PAGE-API-ios P1（取 B，编排 11-04 11:24；D10-613 只钉 InviteBackfill / InviteLink）：新锁 00deded0ef6f 把两条路由登记为
/// since.ios 1.0.0，但 iOS 没有页面。经 Router（App 内动作、`couli-debug://r/InviteLink?code=…` 深链）打开时一律落到升级提示
/// （`route.upgradePrompt`），不得落到显示英文路由名的 `RoutePlaceholderView`（`route.placeholder.name`，Release 也编入）。
/// 有页面的原生路由与 h5 照常。对应安卓 r01–r06、鸿蒙 r1 S2-01。
final class HomePageApiP1RouteTests: HomeAppTestCase {
    /// 等 Router 栈出现新的一页（深链经启动队列，异步交给 Router）。
    private func newDestination(_ fixture: HomeAppFixture, after count: Int) async -> RouteDestination? {
        let deadline = Date().addingTimeInterval(5)
        while fixture.router.path.count <= count, Date() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return fixture.router.path.count > count ? fixture.router.path.last : nil
    }

    /// 路由视图表给出的页面里实际构造了哪个视图：沿 Mirror 走值（_ConditionalContent 只保存走到的分支、AnyView 保存被包的视图），
    /// 按叶子类型名精确比对 `UpgradePromptView` / `RoutePlaceholderView`（进程内无障碍树不暴露这两个标识，不能靠查标识）。
    private func rendered(_ destination: RouteDestination) -> (upgrade: Bool, placeholder: Bool) {
        let names = Self.typeNames(RouteViewRegistry.view(for: destination))
        // 私有类型的名字是「(UpgradePromptView in _…)」；泛型容器（_ConditionalContent<…>、AnyViewStorage<…>）不算
        let built: (String) -> Bool = { leaf in names.contains { $0 == leaf || $0.hasPrefix("(\(leaf) in ") } }
        return (built("UpgradePromptView"), built("RoutePlaceholderView"))
    }

    static func typeNames(_ value: Any, depth: Int = 0) -> Set<String> {
        var names: Set<String> = [String(describing: type(of: value))]
        guard depth < 24 else { return names }
        for child in Mirror(reflecting: value).children {
            names.formUnion(typeNames(child.value, depth: depth + 1))
        }
        return names
    }

    /// 升级提示：要么 Router 给的就是无路由名的升级页，要么路由视图表把它画成升级提示；绝不能出现占位页。
    private func assertUpgrade(_ destination: RouteDestination?, _ label: String) async throws {
        let destination = try XCTUnwrap(destination, "\(label) 没有打开任何页面")
        if destination.route == nil {
            return
        }
        let shown = rendered(destination)
        XCTAssertFalse(shown.placeholder, "\(label) 落到了英文占位页 route.placeholder.name")
        XCTAssertTrue(shown.upgrade, "\(label) 不是升级提示")
    }

    /// r01 前提：两条路由在新锁表里、since.ios 是 1.0.0（升锁前红属预期）。
    func testBothRoutesAreRegisteredAsShipped() {
        for name in ["InviteLink", "InviteBackfill"] {
            XCTAssertEqual(Routes.spec(name)?.sinceIOS, "1.0.0", name)
        }
    }

    /// r02 App 内打开 InviteBackfill（已绑手机的会员）→ 升级提示，不进占位页。
    func testInAppInviteBackfillShowsUpgradePrompt() async throws {
        let fixture = make()
        let before = fixture.router.path.count
        fixture.open("InviteBackfill", params: ["source": .string("me")])
        try await assertUpgrade(newDestination(fixture, after: before), "InviteBackfill")
    }

    /// r03 深链 couli-debug://r/InviteLink?code=AB12CD → 升级提示，不进占位页。
    func testDeepLinkInviteLinkShowsUpgradePrompt() async throws {
        let fixture = make()
        let before = fixture.router.path.count
        fixture.routing.handle(url: try XCTUnwrap(URL(string: "couli-debug://r/InviteLink?code=AB12CD")))
        try await assertUpgrade(newDestination(fixture, after: before), "InviteLink 深链")
    }

    /// r04 对照：有页面的原生路由 Search 照常打开（不被一起拦成升级提示）。
    func testNativeRouteWithPageStillOpens() async throws {
        let fixture = make()
        let before = fixture.router.path.count
        fixture.open("Search")
        let opened = await newDestination(fixture, after: before)
        let destination = try XCTUnwrap(opened)
        XCTAssertEqual(destination.route, "Search")
        XCTAssertNotNil(RouteViewRegistry.builders["Search"])
        let shown = rendered(destination)
        XCTAssertFalse(shown.upgrade || shown.placeholder, "Search 被画成了升级提示或占位页")
    }

    /// r05 对照：h5 路由 Help 照常打开。
    func testH5RouteStillOpens() async throws {
        let fixture = make()
        let before = fixture.router.path.count
        fixture.open("Help")
        let opened = await newDestination(fixture, after: before)
        let destination = try XCTUnwrap(opened)
        XCTAssertNotNil(destination.route, "Help 被拦成了升级提示")
        let shown = rendered(destination)
        XCTAssertFalse(shown.upgrade || shown.placeholder, "Help 被画成了升级提示或占位页")
    }

    /// r06 对照：since 为 null 的新路由 Favorites 仍是升级提示。
    func testUnshippedNewRouteStaysUpgrade() async throws {
        let fixture = make()
        let before = fixture.router.path.count
        fixture.open("Favorites")
        try await assertUpgrade(newDestination(fixture, after: before), "Favorites")
    }
}
