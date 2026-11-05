import ClientCore
@testable import Couli
import CouliNetwork
import Foundation
import HomeCore
import XCTest

/// Release 首页走契约接口（#24 test-change，FU-X-HOME-PAGE-API-ios / D10-643 改写；原口径「Release 不发 getPage / sections、
/// 工厂不来要端口」是 APP-11 红线 2 的旧口径，D10-604 ① 定为客户端接线缺口）：经生产工厂 `AppHome.make(variant: .release)` 装配，
/// 用本地传输记录器核对冷启动发 GET /v1/pages/home 与区块取数（listPageSectionItems），工厂仍不来要 Debug 端口、不用测试端口。
/// 测试不自行决定端口。
final class HomeAppReleaseTests: HomeAppTestCase {
    private func contractRequests() -> [WalletStubProtocol.Recorded] {
        WalletStubProtocol.requests.filter {
            ($0.path.hasPrefix("/v1/pages/") && !$0.path.hasSuffix("/preview")) || $0.path.contains("/sections/")
        }
    }

    func testReleaseAssemblyUsesContractOperationsWithoutDebugPort() async {
        let lookups = PortLookups()
        let port = TestHomePort()
        port.set(items: { _, _ in HomeAppSamples.products(["test:p1"]) })
        let page: [String: Any] = [
            "page_key": "home", "version": 70,
            "sections": [HomeAppSamples.activity("act", action: ["route": "Help"]), HomeAppSamples.pool],
        ]
        script.ok("GET /v1/pages/home", MeSamples.json(page))
        let fixture = make(account: nil, port: port, variant: .release, portLookups: lookups)
        await fixture.launch()
        fixture.clock.advance(0)
        await fixture.controller.whenIdle()
        let paths = contractRequests().map(\.path)
        XCTAssertEqual(paths.filter { $0 == "/v1/pages/home" }.count, 1, "Release 没发 getPage：\(paths)")
        XCTAssertEqual(paths.filter { $0.contains("/sections/") }.count, 1, "Release 没发区块取数：\(paths)")
        XCTAssertEqual(fixture.controller.state.source, .network)
        XCTAssertTrue(port.calls.isEmpty && port.itemCalls.isEmpty, "Release 用了测试端口")
        XCTAssertEqual(lookups.count, 0, "Release 变体的工厂来要了 Debug 端口")
    }

    /// 对照：Debug 变体的同一工厂接上端口并发出页面请求（证明记录器与端口能看到请求）。
    func testDebugAssemblyUsesThePort() async {
        let lookups = PortLookups()
        let fixture = make(variant: .debug, portLookups: lookups)
        await fixture.launch()
        XCTAssertGreaterThan(lookups.count, 0)
        XCTAssertEqual(fixture.port.calls.count, 1)
    }
}
