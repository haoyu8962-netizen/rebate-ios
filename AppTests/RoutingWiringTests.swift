@testable import Couli
import Foundation
import Generated
import Router
import XCTest

/// App 侧路由接线（测试动作用 Debug 配置）。
@MainActor
final class RoutingWiringTests: XCTestCase {
    func testDebugRouteTableIncludesDebugOnlyRoutes() {
        XCTAssertTrue(AppRouting.isDebugBuild)
        for name in DebugOnlyRoutes.all.keys {
            XCTAssertNotNil(AppRouting.routeTable[name], name)
        }
    }

    func testDebugDeclaresOnlyTheTestSchemeAndParsesIt() throws {
        let info = try XCTUnwrap(Bundle.main.infoDictionary)
        let types = try XCTUnwrap(info["CFBundleURLTypes"] as? [[String: Any]])
        let schemes = types.flatMap { $0["CFBundleURLSchemes"] as? [String] ?? [] }
        XCTAssertEqual(schemes, AppRouting.deepLinkConfig.schemes)

        let config = AppRouting.deepLinkConfig
        let request = DeepLinkParser.parse(
            url: "couli-debug://r/Search?q=a",
            config: config,
            routes: AppRouting.routeTable
        )
        XCTAssertEqual(request?.route, "Search")
        XCTAssertEqual(request?.sourceKind, .deeplink)
    }

    func testAppVersionSatisfiesShippedRoutes() throws {
        let since = try XCTUnwrap(Routes.spec("Home")?.sinceIOS)
        let state = GuardState(
            privacyState: .consented,
            updateState: .ok,
            sessionState: .guest,
            environmentSettled: true,
            appVersion: AppRouting.appVersion,
            isDebugBuild: true
        )
        let decision = EntryGuard.decide(request: RouteRequest(route: "Home", from: .deeplink), state: state)
        XCTAssertEqual(decision.kind, .open, "本端版本 \(AppRouting.appVersion) 低于 since \(since)")
    }
}
