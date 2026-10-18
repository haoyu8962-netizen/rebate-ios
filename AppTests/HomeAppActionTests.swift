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

/// 首页卡片 / 弹窗动作到 Router、弹窗的阻挡与可见性、三个首页接口共享的 42901 闸门（AC-S1-81、AC-S1-131 ①、AC-HOME-08 的 App 部分；
/// cross-platform-lessons 第 4、18、21、22 条）。经生产 AppHome、真实 Router / ApiClient / AppUpdate。
final class HomeAppActionTests: HomeAppTestCase {
    private func page(_ version: Int, _ sections: [[String: Any]]) -> [String: Any] {
        ["page_key": "home", "version": version, "sections": sections]
    }

    /// 卡片打开 Search {q}、Search {platform}、ProductDetail、Notice {article_id}、ExternalPage {url, title, nav_style}：Router
    /// 收到的路由与参数
    /// 逐字相同（入口 in_app）；外链原样（含编码与片段）。
    func testCardTapsReachRouterVerbatim() async throws {
        let targets: [[String: Any]] = [
            ["route": "Search", "params": ["q": "纸巾"]],
            ["route": "Search", "params": ["platform": "jd"]],
            [
                "route": "ProductDetail",
                "params": ["platform": "taobao", "product_key": "test:p1", "item_ref": "v1.test.p1.sig"],
            ],
            ["route": "Notice", "params": ["article_id": "test_notice_main"]],
            ["route": "ExternalPage", "params": [
                "url": "https://x.example.com/a?z=%2f&a=hello+world#part", "title": "品牌活动说明", "nav_style": "dark",
            ]],
        ]
        let port = TestHomePort(page: page(
            35,
            targets.enumerated().map { HomeAppSamples.activity("t\($0.offset)", action: $0.element) }
        ))
        let fixture = make(port: port)
        await fixture.launch()
        for (index, target) in targets.enumerated() {
            fixture.router.path = []
            let tap = try XCTUnwrap(fixture.controller.state.section("t\(index)")?.items.first?.tap)
            fixture.controller.open(tap)
            let top = try XCTUnwrap(fixture.router.path.last, "\(target) 没有打开")
            XCTAssertEqual(top.route, target["route"] as? String)
            let expected = try XCTUnwrap(target["params"] as? [String: Any]).compactMapValues { JSONValue(any: $0) }
            XCTAssertEqual(top.params, expected, "\(target)")
            XCTAssertEqual(fixture.router.lastDecision?.kind, .open)
        }
    }

    /// 两个账号点同一张外链卡，Router 收到的 url 逐字相同（不拼任何个人数据）。
    func testExternalPageUrlIdenticalAcrossAccounts() async throws {
        let action: [String: Any] = ["route": "ExternalPage", "params": ["url": "https://x.example.com/a?b=1"]]
        let port = TestHomePort(page: page(36, [HomeAppSamples.activity("ext", action: action)]))
        let fixture = make(port: port)
        await fixture.launch()
        fixture.controller.open(try XCTUnwrap(fixture.controller.state.section("ext")?.items.first?.tap))
        let first = fixture.router.path.last?.params["url"]
        fixture.router.path = []
        try fixture.switchAccount(to: "user-b")
        await fixture.waitForController(account: "user-b", level: .member)
        await fixture.controller.whenIdle()
        fixture.controller.open(try XCTUnwrap(fixture.controller.state.section("ext")?.items.first?.tap))
        XCTAssertEqual(first, .string("https://x.example.com/a?b=1"))
        XCTAssertEqual(fixture.router.path.last?.params["url"], first)
    }

    /// 未知路由 HotRankList（服务端比客户端新）→ Router 的「请升级 App」页；不崩溃。
    func testUnknownRouteOpensUpgradePrompt() async throws {
        let port = TestHomePort(page: page(37, [HomeAppSamples.activity("rank", action: ["route": "HotRankList"])]))
        let fixture = make(port: port)
        await fixture.launch()
        fixture.controller.open(try XCTUnwrap(fixture.controller.state.section("rank")?.items.first?.tap))
        XCTAssertEqual(fixture.router.lastDecision?.kind, .upgrade)
        XCTAssertTrue(fixture.router.path.last?.isUpgradePrompt ?? false)
    }

    /// 游客点弹窗图片打开 AuthSheet {platform: taobao}：经 Router（in_app），游客走已有 pending_action 去登录。
    func testGuestPopupImageOpensAuthSheetThroughLogin() async throws {
        let port = TestHomePort(page: page(38, [HomeAppSamples.popup()]))
        let fixture = make(account: nil, port: port)
        await fixture.launch()
        let popup = try XCTUnwrap(fixture.controller.state.popup)
        fixture.controller.popupShown(popup.ticket)
        fixture.controller.tapPopup(popup.ticket)
        XCTAssertNil(fixture.controller.state.popup)
        XCTAssertEqual(fixture.router.lastDecision?.kind, .requireLogin)
        XCTAssertEqual(fixture.router.path.last?.route, RoutePolicy.login)
    }

    /// 可选更新提示（MainUpdatePrompt）在时不弹；点【暂不更新】后若仍满足条件才弹（阻挡项来自真实 AppUpdate，共性第 21 条）。
    func testPopupWaitsForUpdatePromptAndShowsAfterDismiss() async {
        let port = TestHomePort(page: page(39, [HomeAppSamples.popup()]))
        let fixture = make(update: StubUpdateChecker(.success(UpdateFixtures.recommend)), port: port)
        await waitUntil("前提：可选更新提示在显示") { fixture.update.showsPrompt }
        await fixture.launch()
        XCTAssertNil(fixture.controller.state.popup, "更新提示在时弹了")
        fixture.update.dismissPrompt()
        await waitUntil("更新提示结束后没有弹") { fixture.controller.state.popup != nil }
    }

    /// 图片就绪前首页被别的页面盖住（Router 推入 Search）：不弹；回到首页才弹（可见性来自真实 Router 栈，共性第 18、22 条）。
    func testPopupWaitsWhileAnotherPageCoversHome() async {
        let port = TestHomePort(page: page(40, [HomeAppSamples.popup()]))
        let fixture = make(port: port)
        fixture.images.hold("https://img.example.com/popup.png")
        fixture.home.tabAppeared()
        await waitUntil("弹窗图片加载没挂到替身上") { fixture.images.waiting("https://img.example.com/popup.png") }
        fixture.open("Search")
        XCTAssertEqual(fixture.router.path.last?.route, "Search")
        fixture.images.release("https://img.example.com/popup.png")
        await fixture.controller.whenIdle()
        XCTAssertNil(fixture.controller.state.popup, "首页被盖住时弹了")
        fixture.router.path = []
        await waitUntil("回到首页没有弹") { fixture.controller.state.popup != nil }
    }

    /// 弹窗还没真正显示时会话失效：旧控制器的弹窗立即关闭、不计数。
    func testSessionEndWhilePopupPendingClosesWithoutCount() async throws {
        let port = TestHomePort(page: page(41, [HomeAppSamples.popup()]))
        let fixture = make(port: port)
        await fixture.launch()
        let old = fixture.controller
        let popup = try XCTUnwrap(old.state.popup)
        fixture.endSession()
        await fixture.waitForController(account: nil, level: .guest)
        XCTAssertNil(old.state.popup)
        old.popupShown(popup.ticket)
        XCTAssertEqual(fixture.storage.prefs.shownToday(sectionId: "popup", nowMs: fixture.clock.now), 0)
    }

    /// listArticles 收到 42901：写入共享闸门；禁用期内下拉的页面请求在发送前被拦。
    func testListArticles42901GatesPageRequestsAtExecutionLayer() async {
        script.fail("GET /v1/articles", 42901, headers: ["Retry-After": "30"])
        script.install()
        let port = TestHomePort(page: page(42, [
            [
                "id": "nb",
                "type": "notice_bar",
                "version": 1,
                "props": [:] as [String: Any],
                "data_source": ["kind": "api"],
            ],
            HomeAppSamples.activity("act", action: ["route": "Help"]),
        ]))
        let fixture = make(port: port)
        await fixture.launch()
        await fixture.controller.whenIdle()
        XCTAssertTrue(fixture.home.gate.active)
        let before = port.calls.count
        fixture.controller.refresh(fixture.controller.state.render)
        await fixture.controller.whenIdle()
        XCTAssertEqual(port.calls.count, before, "禁用期内页面请求被发出")
        XCTAssertEqual(fixture.controller.state.toast?.message, DefaultTexts.text("error.42901"))
    }

    /// 打开挂起 → 切 Tab → 打开完成（真实顺序，共性第 22 条）：图片就绪时首页已不在选中的 Tab，不弹；切回首页才弹。
    func testPopupImageArrivingAfterTabSwitchWaitsForHomeTab() async {
        let port = TestHomePort(page: page(44, [HomeAppSamples.popup()]))
        let fixture = make(port: port)
        fixture.images.hold("https://img.example.com/popup.png")
        fixture.home.tabAppeared()
        await waitUntil("弹窗图片加载没挂到替身上") { fixture.images.waiting("https://img.example.com/popup.png") }
        _ = fixture.routing.selectTab(.orders)
        XCTAssertNotEqual(fixture.router.tabRoot.route, "Home", "前提：已切到订单 Tab")
        fixture.images.release("https://img.example.com/popup.png")
        await fixture.controller.whenIdle()
        XCTAssertNil(fixture.controller.state.popup, "首页不在选中的 Tab 时弹了")
        _ = fixture.routing.selectTab(.home)
        await waitUntil("切回首页没有弹") { fixture.controller.state.popup != nil }
    }

    /// 强更检查没有结果时是只读状态（OPEN_READONLY），不是基本模式：首页仍按真实身份（会员）请求、弹窗规则不按基本模式（共性第 7 条）。
    func testUpdateUnknownReadonlyIsNotBasicMode() async {
        let port = TestHomePort(page: page(45, [HomeAppSamples.activity("act", action: ["route": "Help"])]))
        let fixture = make(update: StubUpdateChecker(nil), port: port)
        await fixture.launch()
        XCTAssertEqual(fixture.controller.identity.level, .member)
        XCTAssertEqual(port.calls.first?.anonymous, false)
        XCTAssertEqual(fixture.controller.state.sectionIds, ["act"])
    }
}
