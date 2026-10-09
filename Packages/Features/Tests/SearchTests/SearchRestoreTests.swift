import DesignSystem
import Foundation
import ProductSearch
@testable import Search
import XCTest

/// APP-06a 第 2 轮：进程回收恢复（共性 20）、无平台立即进入不可搜（共性 19、26）、比价区间卡说明键（共性 25）、
/// 常驻说明区高度（共性 21）、商品图地址（共性 22）。
@MainActor
final class SearchRestoreTests: XCTestCase {
    private func cards(_ keys: [String], more: Bool) -> String {
        SearchFixtures.envelope(0, data: SearchFixtures.page(keys.map { SearchFixtures.card($0) }, more: more))
    }

    private func makePage(_ api: SearchApi, config: FakeSearchConfig, restored: SearchPageState? = nil,
                          query: String? = nil) -> SearchPageConfig {
        SearchPageConfig(
            controller: SearchController(api: api, config: config), history: SearchHistory(), texts: TestTexts(),
            initialQuery: query, initialPlatform: nil, restored: restored
        )
    }

    // MARK: - 共性 20：进程被回收后从持久化的页面状态恢复

    func testProcessDeathRestoresConditionsDraftsSheetAndScroll() async throws {
        // 第一个进程：搜索、换 Tab / 排序 / 筛选、翻到第二页、滚到第 4 张卡、填了没提交的价格草稿。
        let api = ManualSearchApi()
        let config = FakeSearchConfig()
        let first = makePage(api, config: config, query: "milk")
        var saved: [SearchPageState] = []
        first.onStateChange = { saved.append($0) }
        first.start()
        await eventually { api.count == 1 }
        XCTAssertTrue(first.controller.selectTab("jd"))
        await eventually { api.count == 2 }
        XCTAssertTrue(first.controller.selectSort("final_price_asc"))
        await eventually { api.count == 3 }
        XCTAssertTrue(first.controller.setFilters(hasCoupon: true, minFen: 1000, maxFen: nil))
        await eventually { api.count == 4 }
        api.respond(3, cards(["jd:a", "jd:b"], more: true))
        await eventually { first.controller.snapshot.phase == .content }
        XCTAssertTrue(first.controller.loadMore())
        await eventually { api.count == 5 }
        api.respond(4, cards(["jd:c", "jd:d"], more: true))
        await eventually { first.controller.snapshot.items.count == 4 }
        first.input = "milk tea"
        first.priceDraftMin = "10"
        first.priceDraftMax = "50"
        first.showsPriceSheet = true
        first.scrollAnchor = 3
        await eventually { saved.last?.scrollAnchor == 3 }
        // 页面状态只经编码后的数据跨进程：旧执行器、旧配置对象都不再存在。
        let data = try XCTUnwrap(saved.last?.encoded())
        first.controller.leave()
        try await assertRestoredInNewProcess(data)
    }

    private func assertRestoredInNewProcess(_ data: Data) async throws {
        // 第二个进程：先恢复条件，再按条件加载结果，锚点卡没加载到时自动翻页，最后恢复位置。
        let api2 = ManualSearchApi()
        let restored = try XCTUnwrap(SearchPageState.decode(data))
        let second = makePage(api2, config: FakeSearchConfig(), restored: restored)
        XCTAssertFalse(second.start(), "恢复的页面不把焦点放到输入框")
        XCTAssertEqual(second.input, "milk tea")
        XCTAssertEqual(second.priceDraftMin, "10")
        XCTAssertEqual(second.priceDraftMax, "50")
        XCTAssertTrue(second.showsPriceSheet)
        let snapshot = second.controller.snapshot
        XCTAssertEqual(snapshot.keyword, "milk")
        XCTAssertEqual(snapshot.platform, "jd")
        XCTAssertEqual(snapshot.sort, "final_price_asc")
        XCTAssertTrue(snapshot.hasCoupon)
        XCTAssertEqual(snapshot.priceMinFen, 1000)
        XCTAssertNil(snapshot.priceMaxFen)
        await eventually { api2.count == 1 }
        let query = api2.call(0).query ?? ""
        for part in ["q=milk", "platform=jd", "sort=final_price_asc", "has_coupon=true", "price_min_fen=1000"] {
            XCTAssertTrue(query.contains(part), "恢复后的第一次请求带上保存的条件：\(part)")
        }
        let round = second.controller.snapshot.queryRound
        XCTAssertEqual(
            second.restoreTarget, SearchScrollTarget(round: round, index: 3, offset: 0), "恢复目标绑定恢复发起的那一轮查询"
        )
        api2.respond(0, cards(["jd:a", "jd:b"], more: true))
        await eventually { api2.count == 2 }
        XCTAssertTrue((api2.call(1).query ?? "").contains("cursor=c2"), "锚点在第二页：自动翻页")
        api2.respond(1, cards(["jd:c", "jd:d"], more: true))
        await eventually { second.controller.snapshot.items.count == 4 }
        XCTAssertEqual(second.restoreTarget?.index, 3, "加载到锚点：目标留给列表上的恢复任务执行")
        second.endRestore(try XCTUnwrap(second.restoreTarget))
        XCTAssertNil(second.restoreTarget, "任务结束后清掉，只恢复一次")
        await settle()
        XCTAssertEqual(api2.count, 2, "够数后不再自动翻页")
    }

    func testRestoreFallsBackWhenSavedPlatformClosedAndUserQueryCancelsScroll() async {
        let config = FakeSearchConfig()
        config.current = ["taobao": "on", "jd": "off", "pdd": "on"]
        let api = ManualSearchApi()
        let state = SearchPageState(
            conditions: SearchConditions(keyword: "milk", platform: "jd"), input: "milk", scrollAnchor: 0
        )
        let page = makePage(api, config: config, restored: state)
        page.start()
        XCTAssertEqual(page.controller.snapshot.platform, "taobao", "保存的平台已关闭：按可用平台回落")
        await eventually { api.count == 1 }
        XCTAssertTrue(page.controller.submit("paper"), "用户开始新查询")
        await eventually { api.count == 2 }
        api.respond(1, cards(["tb:p"], more: false))
        await eventually { page.controller.snapshot.phase == .content }
        XCTAssertNil(page.restoreTarget, "新一轮查询不再恢复旧位置")
    }

    func testRestoreWithoutKeywordKeepsDraftAndIdle() {
        let page = makePage(ManualSearchApi(), config: FakeSearchConfig(),
                            restored: SearchPageState(input: "half typed"))
        page.start()
        XCTAssertEqual(page.input, "half typed")
        XCTAssertEqual(page.controller.snapshot.phase, .idle)
        XCTAssertNil(SearchPageState.decode(Data("not json".utf8)), "解不出来按新页面打开")
    }

    // MARK: - 共性 19、26：没有可搜索平台时立即进入 unavailable

    func testOpenWithoutKeywordAndNoPlatformIsUnavailableImmediately() {
        let config = FakeSearchConfig()
        config.current = ["taobao": "off", "jd": "off", "pdd": "off"]
        let api = ManualSearchApi()
        let controller = SearchController(api: api, config: config)
        controller.open(query: nil, platform: nil)
        XCTAssertEqual(controller.snapshot.phase, .unavailable)
        XCTAssertEqual(api.count, 0)
    }

    func testIdleConfigClosesAllPlatformsThenReopens() {
        let config = FakeSearchConfig()
        let controller = SearchController(api: ManualSearchApi(), config: config)
        controller.open(query: nil, platform: nil)
        XCTAssertEqual(controller.snapshot.phase, .idle)
        config.confirm(id: 2, status: ["taobao": "off", "jd": "off", "pdd": "off"])
        XCTAssertEqual(controller.snapshot.phase, .unavailable, "输入态时全部关闭：立即无可搜索平台")
        XCTAssertNil(controller.snapshot.platform)
        config.confirm(id: 3, status: ["taobao": "off", "jd": "on", "pdd": "off"])
        XCTAssertEqual(controller.snapshot.phase, .idle, "平台恢复：回到输入态")
        XCTAssertEqual(controller.snapshot.platform, "jd")
    }

    func testRateLimitedAllClosedStillUnavailableImmediately() async {
        let config = FakeSearchConfig()
        let api = ManualSearchApi()
        let controller = SearchController(api: api, config: config)
        controller.open(query: "milk", platform: nil)
        await eventually { api.count == 1 }
        api.respond(0, SearchFixtures.envelope(42901, data: "{}"))
        await eventually { controller.snapshot.blocked }
        config.confirm(id: 2, status: ["taobao": "off", "jd": "off", "pdd": "off"])
        XCTAssertEqual(controller.snapshot.phase, .unavailable, "限流只挡发送，不挡状态更新")
        XCTAssertEqual(api.count, 1)
    }

    // MARK: - 共性 25：纯比价区间卡只用 rebate_compare

    func testCompareOnlyCardsDoNotAddRebateEstimate() {
        let compare = [
            "disclaimer_keys": ["price_basis", "rebate_compare"], "rebate_basis": "price_compare_risk",
            "rebate_max_fen": 99, "price_fen": 1234, "coupon_fen": 0, "final_price_fen": 1234,
        ] as [String: Any]
        XCTAssertEqual(SearchDisclaimers.footerKeys([compare, compare]), ["price_basis", "rebate_compare"])
        let normal = ["disclaimer_keys": ["price_basis"], "rebate_basis": "normal", "rebate_max_fen": 269,
                      "price_fen": 1, "coupon_fen": 0, "final_price_fen": 1] as [String: Any]
        XCTAssertEqual(
            SearchDisclaimers.footerKeys([compare, normal]), ["price_basis", "rebate_compare", "rebate_estimate"],
            "混排时普通返利卡的说明照常兜底"
        )
    }

    // MARK: - 共性 21：常驻说明区高度只由屏宽与字号决定

    func testFooterHeightDependsOnlyOnWidthAndFontSize() {
        let regular = SearchLayout.footerHeight(width: 390, lineHeight: 18)
        XCTAssertEqual(regular, SearchLayout.footerHeight(width: 430, lineHeight: 18))
        XCTAssertGreaterThan(SearchLayout.footerHeight(width: 320, lineHeight: 18), regular, "窄屏多留一行")
        XCTAssertGreaterThan(SearchLayout.footerHeight(width: 390, lineHeight: 36), regular, "字号变大区高随之变大")
        XCTAssertEqual(SearchLayout.footerHeight(width: 390, lineHeight: 200), SearchLayout.footerMaxHeight, "封顶")
    }

    // MARK: - 共性 22：商品图地址

    func testImageSourceAcceptsOnlyHttpsUrls() {
        XCTAssertEqual(ProductImageSource.url("https://img.example.invalid/p.png")?.host, "img.example.invalid")
        XCTAssertNil(ProductImageSource.url(nil))
        XCTAssertNil(ProductImageSource.url(NSNull()))
        XCTAssertNil(ProductImageSource.url(""))
        XCTAssertNil(ProductImageSource.url("http://img.example.invalid/p.png"))
        XCTAssertNil(ProductImageSource.url("/relative.png"))
    }
}
