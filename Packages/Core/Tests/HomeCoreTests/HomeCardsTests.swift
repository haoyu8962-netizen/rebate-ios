import CouliNetwork
import Foundation
import Generated
@testable import HomeCore
import Router
import XCTest

/// 渲染器的卡片层（AC-HOME-03、05、06；G05–G09、G12、G13、G20–G22；cross-platform-lessons 第 6、14、24、25、29、30、34、35 条）。
/// 经生产 `HomeController`，从页面配置一路看到 UI 模型（`HomeUiState.sections`）与点击回调（渲染时取出的 `HomeTap`）。
@MainActor
final class HomeCardsTests: HomeRigTestCase {
    // MARK: - AC-HOME-05：单卡隔离与 sdui_card_error

    /// 未知 type、缺 version、version=2、缺必填 props、坏动作、重复 id、坏条目各一张：其余卡正常显示；
    /// sdui_card_error 只为 dropped 的几张各发一次，字段只有四项，不含链接与文案；未知 type、坏条目不发。
    func testMixedBadPageKeepsGoodCardsAndReportsOnlyDroppedOnce() async throws {
        let mixed = try HomeVectors.golden("mixed_bad")
        let controller = await show(mixed)
        XCTAssertEqual(controller.state.sectionIds, ["good_a", "good_b"], "坏条目丢完为空的卡隐藏，其余按顺序显示")
        let errors = rig.cardErrors
        let reasons = errors.compactMap { event -> String? in
            if case let .string(reason)? = event.fields["reason"] {
                return reason
            }
            return nil
        }
        XCTAssertEqual(
            reasons.sorted(), ["bad_action", "duplicate_id", "missing_field", "missing_version", "unsupported_version"]
        )
        for event in errors {
            XCTAssertEqual(event.page, "Home")
            XCTAssertTrue(Set(event.fields.keys).isSubset(of: ["type", "version", "page_version", "reason"]))
            XCTAssertEqual(event.fields["page_version"], .integer(13))
            let dump = String(describing: event)
            XCTAssertFalse(dump.contains("https://") || dump.contains("测试"), "事件里不得有链接与文案：\(dump)")
        }
        // 同一进程内同一（page_version, section id, reason）只发一次：再冷启动同一页不再发
        let again = rig.controller()
        await rig.start(again)
        XCTAssertEqual(rig.cardErrors.count, 5)
    }

    /// 基本模式与预览不发 sdui_card_error（G20、G24 ⑥、G25）。
    func testBasicModeAndPreviewSendNoCardErrors() async throws {
        let mixed = try HomeVectors.golden("mixed_bad")
        _ = await show(mixed, identity: HomeKit.basic)
        XCTAssertTrue(rig.events.isEmpty, "基本模式发了事件：\(rig.events)")
        let preview = rig.controller(HomeKit.memberA, preview: true)
        preview.showDraft(HomeVectors.data(mixed))
        await preview.whenIdle()
        XCTAssertTrue(rig.events.isEmpty, "预览发了事件")
        XCTAssertEqual(preview.state.dropped.map(\.reason).sorted(), [
            "bad_action", "duplicate_id", "missing_field", "missing_version", "unsupported_version",
        ], "预览页底列出被丢弃的卡与原因")
    }

    // MARK: - AC-HOME-06：门槛只比 ≥，condition 不求值

    /// 本端门槛低于 / 等于 / 高于当前版本三张卡，只显示前两张；带各种 condition 的卡照常显示。
    func testMinAppVersionKeepsLowerAndEqualAndConditionIsNeverEvaluated() async throws {
        let controller = await show(try HomeVectors.golden("min_app_version"))
        XCTAssertEqual(controller.state.sectionIds, ["lower", "equal"])
        XCTAssertTrue(rig.cardErrors.isEmpty, "门槛不满足是 skipped，不记事件")
        let conditions: [Any] = [
            ["login": "no", "has_parent": "yes", "union_authorized": "yes", "has_order": "no"], false,
            "test_not_an_expression", [1, false], NSNull(),
        ]
        let page = HomeKit.page(version: 31, conditions.enumerated().map { index, condition in
            HomeKit.banner("cond\(index)", condition: condition)
        })
        let shown = await show(page, identity: HomeKit.guest)
        XCTAssertEqual(shown.state.sectionIds, ["cond0", "cond1", "cond2", "cond3", "cond4"])
    }

    // MARK: - AC-HOME-03：推广角标、顺序、空数据源

    /// 八种卡型的 ad_label 都一路传到 UI 模型：非 null 字符串原样（含空串）、null 无角标；先核对卡型齐全再逐卡断言（G22，共性第 25 条）。
    func testAdLabelReachesAllEightCardTypesVerbatim() async throws {
        for value in [" 推广Ａ " as Any, "" as Any, NSNull() as Any] {
            let expected = value as? String
            let controller = await show(HomeKit.page(version: 40, eightCards(adLabel: value)))
            await controller.whenIdle()
            let types = controller.state.sections.map(\.type)
            XCTAssertEqual(Set(types), [
                "banner", "icon_grid", "product_scroll", "product_grid", "activity_entry", "notice_bar",
                "feed_infinite",
            ], "卡型不齐：\(types)")
            XCTAssertEqual(types.count, 7)
            for section in controller.state.sections {
                XCTAssertFalse(section.items.isEmpty, "\(section.id) 没有条目")
                for item in section.items {
                    XCTAssertEqual(
                        item.adLabel,
                        expected,
                        "\(section.type) 的推广标识没有原样传到 UI（\(String(describing: value))）"
                    )
                }
            }
            let popup = try XCTUnwrap(controller.state.popup, "前提：弹窗出现")
            XCTAssertEqual(popup.adLabel, expected, "弹窗的推广标识没有原样传到 UI（\(String(describing: value))）")
        }
    }

    /// 条目级 ad_label 优先于卡片级（金刚区格、弹窗 items[0]）。
    func testItemLevelAdLabelWins() async {
        var icons = eightCards(adLabel: "推广")[1]
        icons["data_source"] = ["kind": "static", "items": [
            ["icon": "https://img.example.com/i.png", "title": "测试格", "action": ["route": "Help"]],
            [
                "icon": "https://img.example.com/j.png",
                "title": "测试格二",
                "ad_label": "测试条目标识",
                "action": ["route": "Help"],
            ],
        ]]
        var popup = HomeKit.popup()
        popup["ad_label"] = "推广"
        popup["data_source"] = ["kind": "static", "items": [["action": ["route": "Help"], "ad_label": "测试弹窗标识"]]]
        let controller = await show(HomeKit.page(version: 42, [icons, popup]))
        XCTAssertEqual(controller.state.section("icons")?.items.map(\.adLabel), ["推广", "测试条目标识"])
        XCTAssertEqual(controller.state.popup?.adLabel, "测试弹窗标识")
    }

    private func eightCards(adLabel: Any) -> [[String: Any]] {
        var sections: [[String: Any]] = [
            HomeKit.banner("banner"),
            [
                "id": "icons", "type": "icon_grid", "version": 1, "props": ["columns": 4],
                "data_source": ["kind": "static", "items": [
                    ["icon": "https://img.example.com/i.png", "title": "测试格", "action": ["route": "Help"]],
                ]],
            ],
            HomeKit.pool("scroll"), HomeKit.pool("grid", type: "product_grid"),
            HomeKit.activity("act", titles: ["测试入口"]), HomeKit.notice("nb", items: [HomeKit.noticeItem("n1")]),
            HomeKit.feed(), HomeKit.popup(),
        ]
        for index in sections.indices {
            sections[index]["ad_label"] = adLabel
        }
        return sections
    }

    /// 卡片与商品按服务端顺序渲染（不重排、不过滤、不补数）；某个数据源返回空 → 只隐藏这一张。
    func testServerOrderIsKeptAndEmptySourceHidesOnlyThatCard() async {
        rig.port?.items = { section, _ in
            switch section {
            case "empty": .now(HomeKit.items(0..<0, next: nil))
            default: .now(HomeKit.ok(["items": [5, 1, 3].map { HomeKit.product($0) }, "next_cursor": NSNull()]))
            }
        }
        let controller = await show(HomeKit.page(version: 42, [
            HomeKit.pool("scroll"), HomeKit.pool("empty", type: "product_grid"),
            HomeKit.activity("act", titles: ["测试二", "测试一"]),
        ]))
        await controller.whenIdle()
        XCTAssertEqual(controller.state.sectionIds, ["scroll", "act"])
        XCTAssertEqual(
            controller.state.section("scroll")?.items.compactMap(\.product?.productKey), [
                "test:p5",
                "test:p1",
                "test:p3",
            ]
        )
        XCTAssertEqual(controller.state.section("act")?.items.compactMap(\.title), ["测试二", "测试一"])
        XCTAssertEqual(Set(rig.port?.itemCalls ?? []), ["scroll|", "empty|"], "每个数据源首屏只请求一次")
        XCTAssertTrue(rig.cardErrors.isEmpty, "空数据源不记事件")
    }

    /// golden empty_source：三张空卡全部隐藏（不显示空壳）。
    func testEmptyStaticSourcesAreHidden() async throws {
        let controller = await show(try HomeVectors.golden("empty_source"))
        XCTAssertTrue(controller.state.sections.isEmpty)
    }

    /// Release（没有端口）：商品池、物料信息流按「没有数据」整卡隐藏；静态卡照常（G03）。
    func testWithoutPortPoolAndFeedCardsAreHidden() async throws {
        let rig = HomeRig(port: nil)
        defer { rig.tearDown() }
        try rig.seedLkg(HomeKit.page(version: 43, [
            HomeKit.pool("scroll"), HomeKit.feed(), HomeKit.activity("act", titles: ["测试入口"]),
        ]))
        let controller = rig.controller()
        await rig.start(controller)
        XCTAssertEqual(controller.state.source, .lkg)
        XCTAssertEqual(controller.state.sectionIds, ["act"])
    }

    /// 商品池首屏失败：按「没有数据」整卡隐藏、不提示（brief、H23、A28 裁定），失败码与 trace 留在卡片状态里（共性第 35 条）。
    func testPoolFailureHidesCardSilentlyButKeepsTheActualFailure() async throws {
        rig.port?.items = { _, _ in .now(HomeKit.failure(50002, trace: "trace-test-POOL01")) }
        let controller = await show(HomeKit.page(version: 44, [
            HomeKit.pool("scroll"), HomeKit.activity("act", titles: ["测试入口"]),
        ]))
        await controller.whenIdle()
        XCTAssertEqual(controller.state.sectionIds, ["act"])
        XCTAssertNil(controller.state.toast)
        let failure = try XCTUnwrap(controller.state.sectionErrors["scroll"])
        XCTAssertEqual(failure.code, 50002)
        XCTAssertEqual(failure.traceId, "trace-test-POOL01")
    }

    /// 「不过滤」（BR-PRICE-08 无返利过滤在服务端）：横滑、网格两种商品池都混排契约合法的零返利与正返利商品，数量、顺序、商品标识完整保留（评审 T-23）。
    func testZeroRebateProductsAreNeverFilteredFromPools() async {
        rig.port?.items = { _, _ in .now(HomeKit.mixedRebateItems(next: nil)) }
        let controller = await show(HomeKit.page(
            version: 43,
            [HomeKit.pool("scroll"), HomeKit.pool("grid", type: "product_grid")]
        ))
        await controller.whenIdle()
        for id in ["scroll", "grid"] {
            let keys = controller.state.section(id)?.items.compactMap(\.product?.productKey)
            XCTAssertEqual(keys, HomeKit.mixedRebateKeys, "\(id) 过滤或重排了商品")
        }
    }
}
