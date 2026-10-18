import ClientCore
@testable import Couli
import CouliNetwork
import Foundation
import HomeCore
import XCTest

/// Release 首页不发契约外请求（红线 2，G02、G03；评审 T-12）：经生产工厂 `AppHome.make(variant: .release)` 装配，用本地传输记录器
/// 核对冷启动、下拉、数据源加载都不发待定 operation（GET /v1/pages/home、/sections/…/items），工厂也不来要 Debug 端口；首页显示
/// LKG / 包内默认，商品池与物料信息流卡隐藏。测试不自行决定端口为空。
final class HomeAppReleaseTests: HomeAppTestCase {
    private func pendingRequests() -> [WalletStubProtocol.Recorded] {
        WalletStubProtocol.requests.filter {
            ($0.path.hasPrefix("/v1/pages/") && !$0.path.hasSuffix("/preview")) || $0.path.contains("/sections/")
        }
    }

    func testReleaseAssemblyNeverSendsPendingOperations() async throws {
        let lookups = PortLookups()
        let port = TestHomePort()
        port.set(items: { _, _ in HomeAppSamples.products(["test:p1"]) })
        // 游客（作用域跨「重启」稳定；会员的分区还含每次登录新生成的登录世代）
        let fixture = make(account: nil, port: port, variant: .release, portLookups: lookups)
        // 冷启动：没有 LKG → 包内默认
        await fixture.launch()
        // 「不等 1.5 秒」：时钟保持原时刻，只执行到点（零延时）的排程并等结算（零延时排程是允许的写法，评审 T-21）
        fixture.clock.advance(0)
        await fixture.controller.whenIdle()
        XCTAssertEqual(fixture.controller.state.source, .bundled)
        XCTAssertEqual(fixture.controller.state.sectionIds, ["default_icons", "default_activities"])
        // 有 LKG（含商品池、信息流）：显示 LKG，两种数据源卡隐藏
        let key = try XCTUnwrap(fixture.controller.identity.lkgScope)
        let page: [String: Any] = [
            "page_key": "home", "version": 70,
            "sections": [HomeAppSamples.activity("act", action: ["route": "Help"]), HomeAppSamples.pool, [
                "id": "feed", "type": "feed_infinite", "version": 1,
                "data_source": ["kind": "union_material", "platforms": ["taobao"]],
            ] as [String: Any]],
        ]
        let data = try JSONSerialization.data(withJSONObject: page)
        XCTAssertTrue(fixture.storage.lkg.write(key, data, ticket: fixture.storage.lkg.ticket()))
        let restarted = make(account: nil, port: port, variant: .release, portLookups: lookups)
        await restarted.launch()
        restarted.clock.advance(0)
        await restarted.controller.whenIdle()
        XCTAssertEqual(restarted.controller.state.source, .lkg)
        XCTAssertEqual(restarted.controller.state.sectionIds, ["act"], "Release 下商品池 / 信息流卡要隐藏")
        // 下拉：只结束动画
        restarted.controller.refresh(restarted.controller.state.render)
        await restarted.controller.whenIdle()
        XCTAssertFalse(restarted.controller.state.refreshing)
        XCTAssertTrue(pendingRequests().isEmpty, "Release 发了待定 operation：\(pendingRequests().map(\.path))")
        XCTAssertTrue(port.calls.isEmpty && port.itemCalls.isEmpty, "Release 用了端口")
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
