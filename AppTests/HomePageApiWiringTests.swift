@testable import Couli
import CouliNetwork
import Foundation
import HomeCore
import Router
import XCTest

/// FU-X-HOME-PAGE-API-ios 装配（brief §2.2 第 2 条、§3「装配」「CI 断言 (a)」；D10-643）：经生产工厂 `AppHome.make` 装配，
/// 真实 ApiClient → 本地 WalletStubProtocol。Release 变体的端口非空、冷启动发 getPage("home") 与区块取数；Debug / Staging
/// 不带假参数时同样走生产端口，带假参数（Debug 端口来源给出端口）时走假端口；每次装配现判。对应安卓 s01–s08、w02。
final class HomePageApiWiringTests: HomeAppTestCase {
    /// ops 07:14 回读的 staging home v1。
    private static let homeV1 = MeSamples.json([
        "page_key": "home", "version": 1,
        "sections": [
            [
                "id": "demo-today", "type": "product_scroll", "version": 1, "props": ["title": "演示 · 今日推荐"],
                "data_source": ["kind": "product_pool", "limit": 10, "pool_id": "01a1a33a-f20f-7c9d-84c7-28db459b845f"],
            ] as [String: Any],
            [
                "id": "demo-grid", "type": "product_grid", "version": 1,
                "props": ["title": "演示 · 精选好物", "columns": 2],
                "data_source": ["kind": "product_pool", "limit": 20, "pool_id": "01a1a33a-f20f-7c9d-84c7-28db459b845f"],
            ] as [String: Any],
        ],
    ])

    private static func productsJson(_ keys: [String]) -> String {
        if case let .success(data?, _, _) = HomeAppSamples.products(keys) {
            return String(bytes: data, encoding: .utf8) ?? "{}"
        }
        return "{}"
    }

    private static let pagePath = "/v1/pages/home"
    private static let todayPath = "/v1/pages/home/sections/demo-today/items"
    private static let gridPath = "/v1/pages/home/sections/demo-grid/items"

    override func setUpWithError() throws {
        try super.setUpWithError()
        script.ok("GET \(Self.pagePath)", Self.homeV1)
        script.ok("GET \(Self.todayPath)", Self.productsJson(["test:t1", "test:t2"]))
        script.ok("GET \(Self.gridPath)", Self.productsJson(["test:g1"]))
    }

    private var homeRequests: [WalletStubProtocol.Recorded] {
        WalletStubProtocol.requests.filter { $0.path.hasPrefix("/v1/pages/home") && !$0.path.hasSuffix("/preview") }
    }

    private func settle(_ fixture: HomeAppFixture) async {
        await fixture.launch()
        fixture.clock.advance(0)
        await fixture.controller.whenIdle()
    }

    private func assertContractRequests(_ label: String, file: StaticString = #filePath, line: UInt = #line) {
        let requests = homeRequests
        XCTAssertEqual(
            requests.filter { $0.path == Self.pagePath }.count,
            1,
            "\(label)：getPage 应发 1 次",
            file: file,
            line: line
        )
        XCTAssertEqual(
            Set(requests.filter { $0.path != Self.pagePath }.map(\.path)), [Self.todayPath, Self.gridPath],
            "\(label)：两个区块各取数一次", file: file, line: line
        )
        XCTAssertEqual(requests.count, 3, "\(label)：\(requests.map(\.path))", file: file, line: line)
        for request in requests {
            XCTAssertEqual(request.method, "GET", file: file, line: line)
            XCTAssertEqual(request.query, "", "\(label)：不带 kind / limit / 频道参数", file: file, line: line)
            XCTAssertEqual(request.body, "", file: file, line: line)
            XCTAssertNil(request.header("X-Sign"), file: file, line: line)
            XCTAssertNil(request.header("Idempotency-Key"), file: file, line: line)
        }
    }

    /// s05 / CI 断言 (a)：Release 变体的端口非空——冷启动发 GET /v1/pages/home 与两个区块的 listPageSectionItems，演示首页上屏；
    /// 工厂不来要 Debug 端口。
    func testReleaseAssemblySendsGetPageAndSectionItems() async {
        let lookups = PortLookups()
        let fixture = make(variant: .release, portLookups: lookups)
        await settle(fixture)
        assertContractRequests("Release")
        XCTAssertEqual(lookups.count, 0, "Release 变体的工厂来要了 Debug 端口")
        XCTAssertTrue(fixture.port.calls.isEmpty, "Release 用了测试端口")
        XCTAssertEqual(fixture.controller.state.source, .network)
        XCTAssertEqual(fixture.controller.state.sectionIds, ["demo-today", "demo-grid"])
        XCTAssertEqual(
            fixture.controller.state.section("demo-today")?.items.compactMap(\.product?.productKey), [
                "test:t1",
                "test:t2",
            ]
        )
    }

    /// s06 会员请求带 Bearer 与 X-Device-Id（契约：按设备分桶读灰度版本）。
    func testMemberRequestsCarryCredentials() async {
        let fixture = make(variant: .release)
        await settle(fixture)
        XCTAssertFalse(homeRequests.isEmpty)
        for request in homeRequests {
            XCTAssertEqual(request.header("Authorization"), "Bearer at-user-a", request.path)
            XCTAssertNotNil(request.header("X-Device-Id"), request.path)
        }
    }

    /// s07 基本模式三个请求都发出，都不带 Authorization / X-Device-Id。
    func testBasicModeRequestsAreAnonymous() async {
        let fixture = make(account: nil, decision: "basic_mode", variant: .release)
        await settle(fixture)
        assertContractRequests("基本模式")
        for request in homeRequests {
            XCTAssertNil(request.header("Authorization"), request.path)
            XCTAssertNil(request.header("X-Device-Id"), request.path)
        }
    }

    /// s08 服务端 30701：只取页不取卡、不强更、不提示、不进整页失败；1.5 秒后包内默认。
    func testPage30701FallsBackWithoutForceUpdate() async {
        script.fail("GET \(Self.pagePath)", 30701)
        let fixture = make(variant: .release)
        await settle(fixture)
        XCTAssertEqual(homeRequests.map(\.path), [Self.pagePath])
        XCTAssertNil(fixture.controller.state.toast)
        XCTAssertNil(fixture.controller.state.loadFailed)
        fixture.clock.advance(1500)
        await fixture.controller.whenIdle()
        XCTAssertEqual(fixture.controller.state.source, .bundled)
        XCTAssertFalse(fixture.router.path.contains { $0.route == RoutePolicy.forceUpdate }, "30701 进了强更")
    }

    /// s01 Debug / Staging 不带假参数（Debug 端口来源给不出端口）：走生产端口，发真实请求。
    func testDebugWithoutFakeArgumentsUsesTheProductionPort() async {
        let lookups = PortLookups()
        let fixture = make(variant: .debug, portLookups: lookups, debugPortProvided: { false })
        await settle(fixture)
        XCTAssertEqual(lookups.count, 1, "Debug 装配要来问一次 Debug 端口来源")
        assertContractRequests("Debug 无假参数")
        XCTAssertTrue(fixture.port.calls.isEmpty)
    }

    /// s02 带假参数（-CouliFakeLoginServer / -CouliHomeVisual，Debug 端口来源给出端口）：走假端口，生产端口一次不发。
    func testDebugWithFakeArgumentsUsesTheFakePort() async {
        let fixture = make(variant: .debug)
        await settle(fixture)
        XCTAssertEqual(fixture.port.calls.count, 1)
        XCTAssertTrue(homeRequests.isEmpty, "带假参数时不得再发真实请求：\(homeRequests.map(\.path))")
    }

    /// s03 每次装配现判：同一个来源先给假端口、再给不出，第二次装配就改走生产端口（不在第一次装配时缓存）。
    func testEveryAssemblyDecidesAgain() async {
        let provide = PortToggle()
        let lookups = PortLookups()
        let first = make(variant: .debug, portLookups: lookups, debugPortProvided: { provide.on })
        await settle(first)
        XCTAssertEqual(first.port.calls.count, 1)
        XCTAssertTrue(homeRequests.isEmpty)
        provide.on = false
        try? FileManager.default.removeItem(at: storageRoot)
        let second = make(variant: .debug, portLookups: lookups, debugPortProvided: { provide.on })
        await settle(second)
        XCTAssertEqual(lookups.count, 2)
        XCTAssertTrue(second.port.calls.isEmpty, "第二次装配仍用了假端口")
        assertContractRequests("第二次装配")
    }

    /// 假服务只看启动参数（-CouliFakeLoginServer），不留偏好：不带参数时 CouliApp 的 Debug 端口来源给不出端口。
    func testFakeHomeNeedsTheLaunchArgument() {
        XCTAssertNil(DebugFakeHome.port(arguments: ["Couli"], environment: { .staging }))
        XCTAssertNotNil(DebugFakeHome.port(arguments: ["Couli", DebugFakeLoginServer.launchArgument],
                                           environment: { .staging }))
    }
}

/// Debug 端口来源这次给不给端口（测试里翻转）。
@MainActor
final class PortToggle {
    var on = true
}
