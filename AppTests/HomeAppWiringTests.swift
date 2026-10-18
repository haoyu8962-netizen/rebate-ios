import ClientCore
import Config
@testable import Couli
import CouliNetwork
import Foundation
import Generated
import HomeCore
import Privacy
import Router
import SwiftUI
import XCTest

/// 首页的 App 接线（brief §0「请求归属与世代」「会话换代清空」「缓存与清理」「Retry-After」「路由名」；§2 第 19 条的「迟到与作废」「基本模式」
/// 「清理」「AC-S1-81 / AC-S1-131 ① / 动作」「AC-HOME-08」的 App 部分；cross-platform-lessons 第 3、7、8、16、18、21、22、26、33 条；
/// F-X-17、F-X-19、G31）。全部经生产 AppHome、真实 Router / ApiClient / 隐私闸门 / 清理注册表，按钮回调取渲染时的票据。
final class HomeAppWiringTests: HomeAppTestCase {
    private func page(_ version: Int, _ sections: [[String: Any]]) -> [String: Any] {
        ["page_key": "home", "version": version, "sections": sections]
    }

    // MARK: - 冷启动与分区

    /// 已登录冷启动：首页控制器的固定身份是「当前环境 + 会员 A + 登录世代」，网络版显示并写进 A 的作用域。
    func testMemberColdStartShowsNetworkPageAndWritesMemberScope() async {
        let fixture = make()
        await fixture.launch()
        let identity = fixture.controller.identity
        XCTAssertEqual(identity.env, "test")
        XCTAssertEqual(identity.level, .member)
        XCTAssertEqual(identity.userId, "user-a")
        XCTAssertNotNil(identity.loginEpoch)
        XCTAssertTrue(identity.known)
        XCTAssertEqual(fixture.controller.state.source, .network)
        XCTAssertEqual(fixture.controller.state.sectionIds, ["net"])
        XCTAssertEqual(fixture.lkgVersion(identity), 2)
        XCTAssertEqual(fixture.port.calls.first?.owner?.account, "user-a")
        XCTAssertEqual(fixture.port.calls.first?.anonymous, false)
    }

    // MARK: - 换代（brief §0：A 已登录 → A 失效 → 登录 B → 回首页）

    /// A 的冷启动拉取在途时换登 B：同步重建为 B 的控制器（新作用域的 LKG → 包内默认），不出现 A 的卡；A 的响应不写 B 的 LKG、不改 B 的屏。
    func testAccountSwitchRebuildsAndLateResponseOfANeverReachesB() async throws {
        let port = TestHomePort()
        port.set(byOwner: { call in
            let who = call.owner?.account == "user-b" ? "b_people" : "a_people"
            return TestHomePort.page(version: call.owner?.account == "user-b" ? 21 : 11, ids: [who])
        })
        let fixture = make(port: port)
        port.hold()
        fixture.home.tabAppeared()
        await waitUntil("A 的请求没发出") { port.calls.count == 1 }
        let identityA = fixture.controller.identity
        let controllerA = fixture.controller
        try fixture.switchAccount(to: "user-b")
        await fixture.waitForController(account: "user-b", level: .member)
        XCTAssertFalse(controllerA === fixture.controller, "要按新身份重建，不是只刷新展示")
        XCTAssertFalse(fixture.controller.state.sectionIds.contains("a_people"))
        port.release()
        await controllerA.whenIdle()
        await fixture.controller.whenIdle()
        fixture.clock.advance(1500)
        await fixture.controller.whenIdle()
        XCTAssertEqual(fixture.controller.state.sectionIds, ["b_people"], "B 显示 B 的人群卡")
        XCTAssertEqual(fixture.lkgVersion(fixture.controller.identity), 21, "B 的 LKG 是 B 的页")
        XCTAssertNil(fixture.lkgVersion(identityA), "A 的迟到响应写了 LKG")
        XCTAssertTrue(controllerA.state.sections.isEmpty, "旧控制器不再显示")
    }

    /// 退出登录 / 会话失效：只清旧账号作用域的 LKG；公告关闭记录与弹窗计数是设备级，不清。
    func testSessionEndClearsOldScopeLkgButKeepsDeviceRecords() async throws {
        let port = TestHomePort(page: page(30, [HomeAppSamples.notice("nb", item: "n1")]))
        let fixture = make(port: port)
        await fixture.launch()
        let identityA = fixture.controller.identity
        XCTAssertEqual(fixture.lkgVersion(identityA), 30)
        fixture.controller.closeNotice(try XCTUnwrap(fixture.controller.state.section("nb")?.items.first?.close))
        fixture.endSession()
        await fixture.waitForController(account: nil, level: .guest)
        XCTAssertNil(fixture.lkgVersion(identityA), "旧账号作用域的 LKG 要清")
        XCTAssertFalse(fixture.storage.prefs.closedKeys().isEmpty, "关闭记录是设备级，登出不清")
    }

    /// 同账号重新登录换了登录世代：旧世代的 LKG 读不回、并被清掉（F-X-17、F-HM-35）。
    func testSameAccountReloginWithNewEpochNeverShowsOldEpochLkg() async throws {
        let fixture = make()
        await fixture.launch()
        let first = fixture.controller.identity
        XCTAssertEqual(fixture.lkgVersion(first), 2)
        fixture.port.hold()
        try fixture.switchAccount(to: "user-a")
        await waitUntil("同账号重登没有重建") { fixture.controller.identity.loginEpoch != first.loginEpoch }
        XCTAssertNotEqual(fixture.controller.state.source, .lkg, "新世代显示了旧世代的 LKG")
        XCTAssertNil(fixture.lkgVersion(first))
        fixture.port.release()
        await fixture.controller.whenIdle()
    }

    /// 身份暂时未知（Keychain 一时读不出）：不当成游客重建、不清 LKG，页面保持；恢复后确认还是 A，不换控制器（F-X-19）。
    /// 故障按读取位置遍历两种形态（「仅第 n 次失败」与「第 n 次起一直失败」），窗口 = 一次会话变化通知（同步出口）。
    func testTemporarilyUnknownIdentityOnlyDefersAtEveryReadPosition() async {
        for persistent in [false, true] {
            var position = 1
            while true {
                let fixture = make()
                await fixture.launch()
                let controller = fixture.controller
                let identity = controller.identity
                let before = fixture.store.reads
                if persistent {
                    fixture.store.failReads(fromNth: position)
                } else {
                    fixture.store.failRead(nth: position)
                }
                fixture.routing.sessionStateChanged(resumePending: false)
                let windowReads = fixture.store.reads - before
                fixture.store.disarm()
                let label = "\(persistent ? "持续" : "仅一次")#\(position)"
                if position == 1 {
                    XCTAssertGreaterThan(windowReads, 0, "前提：会话变化通知里有身份读取")
                }
                XCTAssertTrue(fixture.controller === controller, "\(label)：身份暂时未知时重建了首页")
                XCTAssertEqual(fixture.controller.state.sectionIds, ["net"], label)
                XCTAssertEqual(fixture.lkgVersion(identity), 2, "\(label)：暂时未知时删了 LKG")
                // 恢复后确认（回前台）：还是同一身份，不重建
                AppScenePhases.apply(.active, AppScenePhases.Targets(routing: fixture.routing, home: fixture.home))
                XCTAssertTrue(fixture.controller === controller, "\(label)：确认还是同一身份却重建了")
                XCTAssertTrue(fixture.controller.identity.known, label)
                if windowReads < position {
                    break
                }
                position += 1
                guard position <= 20 else {
                    XCTFail("读取位置覆盖未完成")
                    break
                }
            }
        }
    }

    /// 下拉刷新在途时撤回同意：响应丢弃，进入基本模式首页（匿名请求、basic 分区）；首页本机数据全部清空。
    func testWithdrawDuringPullDropsResponseAndShowsBasicHome() async throws {
        let port = TestHomePort(page: page(31, [HomeAppSamples.notice("nb", item: "n1")]))
        let fixture = make(port: port)
        await fixture.launch()
        let identityA = fixture.controller.identity
        let controllerA = fixture.controller
        controllerA.closeNotice(try XCTUnwrap(controllerA.state.section("nb")?.items.first?.close))
        port.hold()
        port.set(page(32, [HomeAppSamples.activity("late_pull", action: ["route": "Help"])]))
        controllerA.refresh(controllerA.state.render)
        await waitUntil("下拉请求没发出") { port.calls.count == 2 }
        fixture.privacy.withdraw()
        await fixture.waitForController(account: nil, level: .basic)
        port.release()
        await controllerA.whenIdle()
        await fixture.controller.whenIdle()
        fixture.clock.advance(1500)
        await fixture.controller.whenIdle()
        XCTAssertFalse(controllerA.state.sectionIds.contains("late_pull"))
        XCTAssertNil(fixture.lkgVersion(identityA))
        XCTAssertTrue(fixture.storage.prefs.closedKeys().isEmpty, "撤回同意清关闭记录")
        XCTAssertTrue(port.calls.last?.anonymous ?? false, "基本模式首页匿名请求")
        XCTAssertEqual(fixture.lkgVersion(HomeIdentity(env: "test", level: .basic, userId: nil, loginEpoch: nil)), 32)
    }

    /// 切换环境：首页本机数据全部清空；控制器按新环境重建。
    func testEnvironmentSwitchClearsAllHomeDataAndRebuilds() async throws {
        let port = TestHomePort(page: page(33, [HomeAppSamples.notice("nb", item: "n1")]))
        let fixture = make(port: port)
        await fixture.launch()
        let identityA = fixture.controller.identity
        fixture.controller.closeNotice(try XCTUnwrap(fixture.controller.state.section("nb")?.items.first?.close))
        try fixture.environment.switchTo(.staging)
        await waitUntil("切换环境没有重建") { fixture.home.controller.identity.env == "staging" }
        XCTAssertNil(fixture.lkgVersion(identityA))
        XCTAssertTrue(fixture.storage.prefs.closedKeys().isEmpty)
    }

    // MARK: - 基本模式（BR-ID-11，G25，红线 6）

    /// 基本模式：首页请求匿名，listArticles 不带 Authorization、X-Device-Id、签名；不发埋点（含 sdui_card_error）、不弹 popup。
    func testBasicModeIsAnonymousWithoutEventsOrPopup() async throws {
        let mixed =
            try XCTUnwrap((try HomeAppSamples
                    .vectors()["goldenPages"] as? [String: Any])?["mixed_bad"] as? [String: Any])
        var sections = try XCTUnwrap(mixed["sections"] as? [[String: Any]])
        sections.append([
            "id": "nb",
            "type": "notice_bar",
            "version": 1,
            "props": [:] as [String: Any],
            "data_source": ["kind": "api"],
        ])
        sections.append(HomeAppSamples.popup())
        let port = TestHomePort(page: page(34, sections))
        let fixture = make(account: nil, decision: "basic_mode", port: port)
        await fixture.launch()
        XCTAssertEqual(fixture.controller.identity.level, .basic)
        XCTAssertTrue(port.calls.allSatisfy(\.anonymous))
        let articles = requests("GET", "/v1/articles")
        XCTAssertEqual(articles.count, 1)
        for request in articles {
            XCTAssertNil(request.header("Authorization"))
            XCTAssertNil(request.header("X-Device-Id"))
            XCTAssertNil(request.header("X-Sign"))
            XCTAssertEqual(request.query, "category=notice")
        }
        XCTAssertTrue(fixture.events.events.isEmpty, "基本模式发了埋点：\(fixture.events.events)")
        XCTAssertNil(fixture.controller.state.popup)
    }

    // MARK: - 诊断信息（G31）、置灰（G27）

    /// 诊断信息的「首页版本」取当前显示的页面（版本 + 来源级别），不再借用 h5_release.version；没有显示中的页面整行省略。
    func testDiagnosticsHomeVersionFollowsDisplayedPage() async {
        let meCase = MeAppFixture.make(suiteName: suiteName + ".me", defaults: defaults)
        let port = TestHomePort()
        port.hold()
        let fixture = make(port: port)
        fixture.home.connect(me: meCase.me)
        fixture.home.tabAppeared()
        await waitUntil("首页请求没发出") { port.calls.count == 1 }
        XCTAssertNil(meCase.me.diagnosticsFields()["home_version"], "没有显示中的页面要省略")
        port.release()
        await fixture.controller.whenIdle()
        XCTAssertEqual(meCase.me.diagnosticsFields()["home_version"] as? String, "2 (network)")
    }

    /// ui.grayscale：配置变化即时应用与移除（true → false 都跟；只作用于首页根视图，见快照、接线检查与禁止项检查 F5）。
    func testGrayscaleFollowsConfigFlagLive() async throws {
        var config = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(MeSamples.config.utf8)) as? [String: Any])
        var features = config["features"] as? [String: Any] ?? [:]
        var flags = features["flags"] as? [String: Any] ?? [:]
        flags["ui.grayscale"] = true
        features["flags"] = flags
        config["features"] = features
        script.ok("GET /v1/config", MeSamples.json(config))
        script.install()
        let fixture = make()
        XCTAssertFalse(fixture.home.grayscale)
        fixture.config.startIfSettled(.settled)
        await waitUntil("配置下发置灰后首页没有即时置灰") { fixture.home.grayscale }
        // 解除：配置改回 false 后即时移除（不是一置灰就永久置灰）；作用范围由 check-home-forbidden.py F5 守（只在首页根视图）
        flags["ui.grayscale"] = false
        features["flags"] = flags
        config["features"] = features
        script.ok("GET /v1/config", MeSamples.json(config))
        script.install()
        fixture.config.requestFresh()
        await waitUntil("配置改回后首页没有解除置灰") { !fixture.home.grayscale }
    }
}
