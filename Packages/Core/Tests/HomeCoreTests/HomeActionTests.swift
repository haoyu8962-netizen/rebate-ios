import CouliNetwork
import Foundation
import Generated
@testable import HomeCore
import Router
import XCTest

/// 卡片动作、列表键、读屏名与自动播放（G05、G06、G28；红线 1；cross-platform-lessons 第 1、14、24、29、30 条）。点击回调都取渲染时的票据。
@MainActor
final class HomeActionTests: HomeRigTestCase {
    /// 卡片点击：渲染时取出的票据带 RouteTarget 原样（含 ExternalPage 的 url 不做任何替换）；spm 只作旁路上下文，不塞进 params。
    func testTapsCarryServerTargetsVerbatimAndSpmOutsideParams() async throws {
        let controller = await show(try HomeVectors.golden("banner"))
        let items = try XCTUnwrap(controller.state.section("banner")?.items)
        XCTAssertEqual(items.count, 2)
        for item in items {
            controller.open(try XCTUnwrap(item.tap))
        }
        XCTAssertEqual(rig.opened.map(\.target.route), ["Search", "ExternalPage"])
        guard rig.opened.count == 2 else { return }
        XCTAssertEqual(rig.opened[0].target.params, ["q": .string("纸巾")])
        XCTAssertEqual(rig.opened[1].target.params, [
            "url": .string("https://x.example.com/a?b=1"), "title": .string("品牌活动说明"), "nav_style": .string("dark"),
        ])
        XCTAssertEqual(rig.opened.map(\.spm), ["home.banner.1", "home.banner.2"])
        XCTAssertTrue(rig.opened.allSatisfy { $0.target.params?["spm"] == nil })
    }

    /// 两个账号点同一张卡，得到的外链逐字相同（不拼任何个人数据，BR-ID-33）。
    func testExternalUrlIsIdenticalForDifferentAccounts() async throws {
        var urls: [JSONValue?] = []
        for identity in [HomeKit.memberA, HomeKit.memberB] {
            let controller = await show(try HomeVectors.golden("banner"), identity: identity)
            controller.open(try XCTUnwrap(controller.state.section("banner")?.items.last?.tap))
            urls.append(rig.opened.last?.target.params?["url"])
        }
        XCTAssertEqual(urls[0], .string("https://x.example.com/a?b=1"))
        XCTAssertEqual(urls[0], urls[1])
    }

    /// 带 js、url 而无 route 的条目动作不执行（条目丢掉、没有可点的票据）；未知路由照常交给 Router（由 Router 处理升级页）。
    func testScriptOnlyActionsAreNeverExecutableAndUnknownRoutesGoToRouter() async throws {
        let controller = await show(HomeKit.page(version: 46, [
            HomeKit.activity("bad", titles: ["测试坏动作"], action: ["js": "test_only", "url": "https://x.example.com"]),
            HomeKit.activity(
                "rank",
                titles: ["测试热销榜"],
                action: ["route": "HotRankList", "params": [:] as [String: Any]]
            ),
        ]))
        XCTAssertNil(controller.state.section("bad"), "坏动作条目丢完为空，整卡隐藏")
        controller.open(try XCTUnwrap(controller.state.section("rank")?.items.first?.tap))
        XCTAssertEqual(rig.opened.map(\.target.route), ["HotRankList"])
    }

    /// 商品卡点击进 ProductDetail，参数取服务端 ProductCard 的 platform / product_key / item_ref；首页卡片没有购买入口。
    func testProductCardOpensProductDetailWithServerParams() async throws {
        let controller = await show(try HomeVectors.golden("product_grid"))
        await controller.whenIdle()
        let item = try XCTUnwrap(controller.state.section("grid")?.items.first)
        controller.open(try XCTUnwrap(item.tap))
        XCTAssertEqual(rig.opened.last?.target.route, "ProductDetail")
        XCTAssertEqual(rig.opened.last?.target.params, [
            "platform": .string("taobao"), "product_key": .string("test:p0"), "item_ref": .string("v1.test.p0.sig"),
        ])
        XCTAssertEqual(rig.opened.last?.spm, "home.grid.1")
    }

    /// 替换内容后，旧渲染的点击票据被拒（共性第 1 条），新票据照常。
    func testStaleTapFromOldRenderIsRejectedAfterReplacement() async throws {
        try rig.seedLkg(HomeKit.page(version: 5, [HomeKit.activity("old", titles: ["测试旧"])]))
        let controller = rig.controller()
        await rig.start(controller)
        let stale = try XCTUnwrap(controller.state.section("old")?.items.first?.tap)
        rig.port?.setPage(HomeKit.ok(HomeKit.page(version: 6, [HomeKit.activity("new", titles: ["测试新"])])))
        controller.refresh(controller.state.render)
        await controller.whenIdle()
        controller.open(stale)
        XCTAssertTrue(rig.opened.isEmpty, "旧渲染的点击被执行了")
        controller.open(try XCTUnwrap(controller.state.section("new")?.items.first?.tap))
        XCTAssertEqual(rig.opened.count, 1)
    }

    /// 列表键在整页里唯一：服务端 id 与客户端自造的键不在同一命名空间（id 撞上内部键也不重复），重复商品 key 也能渲染。
    func testListKeysAreUniqueEvenWhenServerIdsCollideWithClientKeys() async throws {
        rig.port?.items = { _, _ in
            .now(HomeKit.ok([
                "items": [HomeKit.product(0, key: "dup"), HomeKit.product(1, key: "dup")],
                "next_cursor": NSNull(),
            ]))
        }
        let controller = await show(HomeKit.page(version: 47, [
            HomeKit.activity("feed", titles: ["测试一"]), HomeKit.activity("footer", titles: ["测试二"]),
            HomeKit.activity("disclaimer", titles: ["测试三"]), HomeKit.pool("scroll"),
        ]))
        await controller.whenIdle()
        let keys = controller.state.sections.map(\.key)
        XCTAssertEqual(Set(keys).count, keys.count, "卡片键重复：\(keys)")
        let scroll = try XCTUnwrap(controller.state.section("scroll"))
        XCTAssertEqual(scroll.items.count, 2)
        XCTAssertEqual(Set(scroll.items.map(\.id)).count, 2, "同 key 商品的条目键重复")
    }

    /// 只有图片的入口有读屏名：banner 有 alt 读 alt、没有读草稿表通用名；纯图片活动入口读通用名（共性第 30 条，G28）。
    func testImageOnlyEntriesHaveSpokenNames() async throws {
        let controller = await show(HomeKit.page(version: 48, [
            [
                "id": "banner", "type": "banner", "version": 1, "props": ["height_ratio": 0.4, "autoplay_ms": 0],
                "data_source": ["kind": "static", "items": [
                    ["image": "https://img.example.com/a.png", "alt": "测试活动甲", "action": ["route": "Help"]],
                    ["image": "https://img.example.com/b.png", "action": ["route": "Help"]],
                ]],
            ],
            [
                "id": "act", "type": "activity_entry", "version": 1, "props": [:] as [String: Any],
                "data_source": [
                    "kind": "static",
                    "items": [["image": "https://img.example.com/c.png", "action": ["route": "Help"]]],
                ],
            ],
        ]))
        let banner = try XCTUnwrap(controller.state.section("banner"))
        XCTAssertEqual(banner.items.first?.spokenName, "测试活动甲")
        let generic = try XCTUnwrap(banner.items.last?.spokenName)
        XCTAssertFalse(generic.isEmpty)
        XCTAssertFalse(generic.contains("https://"))
        let activity = try XCTUnwrap(controller.state.section("act")?.items.first?.spokenName)
        XCTAssertFalse(activity.isEmpty)
    }

    /// banner 自动轮播：autoplay_ms>0 且首页可见、读屏关闭时才播；切走 Tab（不可见）或读屏开启即停，回来恢复（WCAG 2.2.2）。
    /// 公告 scroll 模式同理：读屏开启时不自动滚动，全部条目可访问（共性第 14、29 条）；static 模式不滚动。
    func testAutoplayAndNoticeScrollPauseForVisibilityAndScreenReader() async {
        let controller = await show(HomeKit.page(version: 49, [
            HomeKit.banner(
                "banner",
                images: ["https://img.example.com/a.png", "https://img.example.com/b.png"],
                autoplay: 4000
            ),
            HomeKit.banner("still", images: ["https://img.example.com/c.png", "https://img.example.com/d.png"]),
            HomeKit.notice("scrolling", items: [HomeKit.noticeItem("n1"), HomeKit.noticeItem("n2")], mode: "scroll"),
            HomeKit.notice("fixed", items: [HomeKit.noticeItem("n3"), HomeKit.noticeItem("n4")]),
        ]))
        func playing() -> [Bool?] {
            [
                controller.state.section("banner")?.autoplay, controller.state.section("still")?.autoplay,
                controller.state.section("scrolling")?.autoplay, controller.state.section("fixed")?.autoplay,
            ]
        }
        XCTAssertEqual(playing(), [true, false, true, false])
        rig.signals.visible = false
        await controller.whenIdle()
        XCTAssertEqual(playing(), [false, false, false, false], "切走 Tab 要暂停")
        rig.signals.visible = true
        await controller.whenIdle()
        XCTAssertEqual(playing(), [true, false, true, false], "回来恢复")
        rig.signals.screenReader = true
        await controller.whenIdle()
        XCTAssertEqual(playing(), [false, false, false, false], "读屏开启要停")
        XCTAssertEqual(controller.state.section("scrolling")?.items.count, 2, "读屏开启时全部条目可访问")
        XCTAssertEqual(rig.port?.pageCalls.count, 1, "切 Tab 回来不重发拉取")
    }

    /// 合法 route 搭配 js / script / html / url 等字段：经生产点击路径只交出原样的 route 与 params（不多不少），没有别的副作用（红线 1）。
    func testValidRouteWithExecutableFieldsOnlyOpensTheRoute() async throws {
        let action: [String: Any] = [
            "route": "Search", "params": ["q": "纸巾"], "js": "test_only()", "script": "alert(1)", "html": "<b>t</b>",
            "url": "https://x.example.com", "deeplink": "test://r/Home", "expr": "{{user.phone}}",
        ]
        let controller = await show(HomeKit.page(
            version: 60,
            [HomeKit.activity("act", titles: ["测试入口"], action: action)]
        ))
        controller.open(try XCTUnwrap(controller.state.section("act")?.items.first?.tap))
        XCTAssertEqual(rig.opened.count, 1)
        XCTAssertEqual(rig.opened.first?.target, RouteTarget(route: "Search", params: ["q": .string("纸巾")]))
        XCTAssertTrue(rig.events.isEmpty)
    }

    /// 外链里带占位符（{uid}、{{phone}}、${device_id}）：原样交出，两个账号逐字相同，不做任何替换（BR-ID-33）。
    func testExternalUrlPlaceholdersAreNeverSubstituted() async throws {
        let url = "https://x.example.com/a?u={uid}&p={{phone}}&d=${device_id}&i={invite_code}"
        var opened: [JSONValue?] = []
        for identity in [HomeKit.memberA, HomeKit.memberB] {
            let controller = await show(HomeKit.page(version: 61, [
                HomeKit.activity("ext", titles: ["测试外链"], action: ["route": "ExternalPage", "params": ["url": url]]),
            ]), identity: identity)
            controller.open(try XCTUnwrap(controller.state.section("ext")?.items.first?.tap))
            opened.append(rig.opened.last?.target.params?["url"])
        }
        XCTAssertEqual(opened, [.string(url), .string(url)])
    }

    /// banner 图片加载失败：该帧显示占位且不可点（渲染出的票据作废）；成功的帧照常可点；旧渲染的图片结果不影响新渲染（brief §2 第 9 条）。
    func testFailedBannerImageIsPlaceholderAndNotTappable() async throws {
        let controller = await show(try HomeVectors.golden("banner"))
        let items = try XCTUnwrap(controller.state.section("banner")?.items)
        guard items.count == 2 else { return XCTFail("应有两帧") }
        let firstTap = try XCTUnwrap(items[0].tap)
        let secondTap = try XCTUnwrap(items[1].tap)
        controller.imageLoaded(try XCTUnwrap(items[0].imageTicket), ok: false)
        controller.imageLoaded(try XCTUnwrap(items[1].imageTicket), ok: true)
        let after = try XCTUnwrap(controller.state.section("banner")?.items)
        XCTAssertTrue(after[0].imageFailed)
        XCTAssertNil(after[0].tap, "失败的帧还能点")
        XCTAssertFalse(after[1].imageFailed)
        XCTAssertNotNil(after[1].tap)
        controller.open(firstTap)
        XCTAssertTrue(rig.opened.isEmpty, "图片失败前取到的票据仍执行了动作")
        controller.open(secondTap)
        XCTAssertEqual(rig.opened.count, 1)
        // 旧渲染的图片结果：下拉换成新渲染后，不影响新渲染的同一帧
        let staleTicket = try XCTUnwrap(after[1].imageTicket)
        rig.port?.setPage(HomeKit.ok(try HomeVectors.golden("banner")))
        controller.refresh(controller.state.render)
        await controller.whenIdle()
        controller.imageLoaded(staleTicket, ok: false)
        XCTAssertEqual(controller.state.section("banner")?.items.map(\.imageFailed), [false, false])
    }

    /// 整页行键：服务端 id 与客户端自造的行（信息流商品行、重试行、脚注行）撞名也不重复（共性第 24 条）。
    func testRowKeysStayUniqueWhenServerIdsCollideWithClientRows() async throws {
        rig.port?.items = { section, cursor in
            switch (section, cursor) {
            case ("feed", nil): .now(HomeKit.items(0..<4, next: "p2"))
            case ("feed", _): .now(HomeKit.failure(50001))
            default: .now(HomeKit.items(0..<2, next: nil))
            }
        }
        let ids = ["feed#0", "feed#1", "feed:0", "disclaimer", "footer", "retry", "feed_retry", "loading"]
        let controller = await show(HomeKit.page(version: 62, ids.map { HomeKit.activity($0, titles: ["测试\($0)"]) }
                + [HomeKit.pool("scroll"), HomeKit.feed()]))
        await controller.whenIdle()
        controller.loadMore(try XCTUnwrap(controller.state.section("feed")?.feed?.ticket))
        await controller.whenIdle()
        XCTAssertNotNil(controller.state.section("feed")?.feed?.failure, "前提：信息流有重试行")
        let keys = controller.state.rowKeys
        XCTAssertEqual(Set(keys).count, keys.count, "行键重复：\(keys)")
        // 9 张普通卡各一行 + 信息流 4 个商品行 + 1 个重试行（脚注行可有可无）
        XCTAssertGreaterThanOrEqual(keys.count, ids.count + 1 + 4 + 1)
        for section in controller.state.sections where section.type != "feed_infinite" {
            XCTAssertTrue(keys.contains(section.key), "\(section.id) 的行不在渲染行键里")
        }
    }
}
