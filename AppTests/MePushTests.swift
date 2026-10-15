@testable import Couli
import CouliNetwork
import Foundation
import MeCore
import Push
import Router
import XCTest

/// 推送令牌上报（AC-S1-76 客户端部分，G17、G18）：经真实 ApiClient 与 AppMe 的会话跟踪。
@MainActor
final class MePushTests: MeTestCase {
    private var reports: [WalletStubProtocol.Recorded] {
        requests("POST", "/v1/devices/push-token")
    }

    private func supported(_ fixture: MeAppFixture) async {
        await waitUntil("强更检查没结果") { fixture.me.updateRaw() == "supported" }
        fixture.me.syncIdentity()
    }

    /// 已登录冷启动上报一次（等版本检查不低于）；provider=mobpush；令牌值不进诊断信息。
    func testColdStartReportsOnce() async throws {
        let fixture = make(pushToken: "cold")
        await supported(fixture)
        await waitUntil("冷启动没上报") { self.reports.count == 1 }
        let body = try XCTUnwrap(reports.first).json
        XCTAssertEqual(body["provider"] as? String, "mobpush")
        XCTAssertEqual(body["token"] as? String, "cold")
        await waitUntil("已上报没记") { fixture.me.push.reportedThisRun }
        XCTAssertFalse(fixture.me.diagnosticsFields().values.contains { "\($0)".contains("cold") }, "令牌不进诊断")
        await settle()
        XCTAssertEqual(reports.count, 1)
    }

    /// 登录成功后用新会话上报一次；在途时令牌变化 → 结束后再报一次最新值，同一时刻只一条。
    func testLoginSuccessThenTokenChangeInFlight() async throws {
        let fixture = make(account: nil, pushToken: "t1")
        await supported(fixture)
        script.on("POST /v1/devices/push-token", .hold)
        try fixture.loginCompleted(as: "user-b")
        await waitUntil("登录成功没上报") { self.reports.count == 1 }
        XCTAssertEqual(reports[0].header("Authorization"), "Bearer at-user-b", "用新会话")
        fixture.push.change("t2")
        fixture.push.change("t3")
        await settle()
        XCTAssertEqual(reports.count, 1, "同一时刻只一条")
        script.ok("POST /v1/devices/push-token", "{}")
        WalletStubProtocol.release(try XCTUnwrap(WalletStubProtocol.heldIds.first),
                                   with: .envelope(code: 0, data: "{}", headers: [:]))
        await waitUntil("没补报最新值") { self.reports.count == 2 }
        XCTAssertEqual(reports[1].json["token"] as? String, "t3", "只发最新值")
    }

    /// A 会话在途上报时换登 B：A 的响应不改任何状态，B 登录后用 B 的会话上报。
    func testSwitchWhileInFlight() async throws {
        script.on("POST /v1/devices/push-token", .hold)
        let fixture = make(pushToken: "t1")
        await supported(fixture)
        await waitUntil("A 没上报") { self.reports.count == 1 }
        let held = try XCTUnwrap(WalletStubProtocol.heldIds.first)
        script.ok("POST /v1/devices/push-token", "{}")
        try fixture.loginCompleted(as: "user-b")
        await waitUntil("B 没上报") { self.reports.count == 2 }
        XCTAssertEqual(reports[1].header("Authorization"), "Bearer at-user-b")
        WalletStubProtocol.release(held, with: .envelope(code: 0, data: "{}", headers: [:]))
        await settle()
        XCTAssertEqual(reports.count, 2, "A 的响应不触发补报")
    }

    /// 退出、基本模式、deletion_only、没有令牌（Release）都不上报。
    func testNoReportCases() async {
        // 基本模式不发强更检查（routerStatus 按 unknown），冷启动不会放行；这里同步一次再等
        let basic = make(decision: "basic_mode", pushToken: "t1")
        basic.me.syncIdentity()
        let restricted = make(scope: "deletion_only", pushToken: "t1")
        await supported(restricted)
        let release = make(pushToken: nil)
        await supported(release)
        await settle(30)
        XCTAssertTrue(reports.isEmpty, "基本模式 / 受限会话 / 无令牌 0 次上报")
    }

    /// 10405（后台上报）交给已有分流进强更，不另弹提示、不重发。
    func testReport10405GoesToForceUpdate() async {
        script.fail("POST /v1/devices/push-token", 10405, data: "{\"min_supported_version\":\"99.0.0\"}")
        let fixture = make(pushToken: "t1")
        await supported(fixture)
        await waitUntil("没进强更") { fixture.router.isOnForceUpdate }
        await settle()
        XCTAssertEqual(reports.count, 1, "不重发")
    }
}
