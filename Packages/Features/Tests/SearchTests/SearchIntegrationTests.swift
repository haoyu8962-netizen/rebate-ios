import CouliNetwork
import Foundation
import ProductSearch
@testable import Search
import XCTest

/// 不理会取消、由测试决定何时回答的网络端口：验证执行器自己对迟到响应的复核（即使传输层没能取消）。
final class ManualSearchApi: SearchApi, @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [(call: ApiCall, resume: CheckedContinuation<ApiResult, Never>)] = []
    private(set) var validity: [@Sendable () -> Bool] = []

    func send(_ call: ApiCall, isValid: @escaping @Sendable () -> Bool) async -> ApiResult {
        await withCheckedContinuation { continuation in
            lock.withLock {
                pending.append((call, continuation))
                validity.append(isValid)
            }
        }
    }

    var count: Int {
        lock.withLock { pending.count }
    }

    func call(_ index: Int) -> ApiCall {
        lock.withLock { pending[index].call }
    }

    func isValid(_ index: Int) -> Bool {
        let check = lock.withLock { validity[index] }
        return check()
    }

    /// 回答第 index 个请求（不论它是否已被作废、取消）。
    func respond(_ index: Int, _ envelope: String) {
        let continuation = lock.withLock { pending[index].resume }
        let object = (try? JSONSerialization.jsonObject(with: Data(envelope.utf8))) as? [String: Any] ?? [:]
        let code = object["code"] as? Int ?? 0
        let data = object["data"].flatMap { try? JSONSerialization.data(withJSONObject: $0) }
        let trace = object["trace_id"] as? String
        if code == 0 {
            continuation.resume(returning: .success(data: data, traceId: trace, idempotencyKey: nil))
        } else {
            var effect = ErrorEffect(code: code, kind: code == 42901 ? .disableButton : .genericError)
            effect.disableMillis = code == 42901 ? 200 : nil
            continuation.resume(returning: .failure(
                code: code, msg: "", data: data, traceId: trace, effect: effect, idempotencyKey: nil
            ))
        }
    }
}

@MainActor
final class SearchIntegrationTests: XCTestCase {
    private func page(_ keys: [String], platform: String = "taobao", more: Bool = false) -> String {
        SearchFixtures.envelope(0, data: SearchFixtures.page(keys.map {
            SearchFixtures.card($0, platform: platform)
        }, more: more))
    }

    private func query(_ api: ManualSearchApi, _ index: Int) -> String {
        api.call(index).query ?? ""
    }

    // MARK: - 迟到响应

    func testNewKeywordInvalidatesOldRequestAndLateResponseIsDropped() async {
        let api = ManualSearchApi()
        let controller = SearchController(api: api, config: FakeSearchConfig())
        controller.open(query: nil, platform: nil)
        controller.submit("milk")
        await eventually { api.count == 1 }
        controller.submit("paper")
        await eventually { api.count == 2 }
        XCTAssertFalse(api.isValid(0), "新请求一开始旧请求就失效")
        XCTAssertTrue(api.isValid(1))
        api.respond(1, page(["tb:new"]))
        await eventually { controller.snapshot.phase == .content }
        api.respond(0, page(["tb:old"]))
        await settle()
        XCTAssertEqual(controller.snapshot.items.first?["product_key"] as? String, "tb:new")
        XCTAssertEqual(controller.snapshot.keyword, "paper")
    }

    func testTabSortFilterChangesInvalidateImmediately() async {
        let api = ManualSearchApi()
        let controller = SearchController(api: api, config: FakeSearchConfig())
        controller.open(query: "milk", platform: "taobao")
        await eventually { api.count == 1 }
        XCTAssertTrue(controller.selectTab("jd"))
        await eventually { api.count == 2 }
        XCTAssertTrue(query(api, 1).contains("platform=jd"))
        XCTAssertTrue(controller.selectSort("final_price_asc"))
        await eventually { api.count == 3 }
        XCTAssertTrue(controller.setFilters(hasCoupon: true, minFen: 1000, maxFen: 2000))
        await eventually { api.count == 4 }
        XCTAssertTrue(query(api, 3).contains("has_coupon=true"))
        XCTAssertTrue(query(api, 3).contains("price_min_fen=1000"))
        XCTAssertTrue(query(api, 3).contains("sort=final_price_asc"))
        XCTAssertEqual((0..<3).map { api.isValid($0) }, [false, false, false])
        for index in 0..<3 {
            api.respond(index, page(["tb:stale\(index)"]))
        }
        await settle()
        XCTAssertEqual(controller.snapshot.phase, .loading, "旧条件的响应都不展示")
        api.respond(3, page(["tb:latest"]))
        await eventually { controller.snapshot.phase == .content }
        XCTAssertEqual(controller.snapshot.items.count, 1)
        XCTAssertFalse(controller.setFilters(hasCoupon: false, minFen: 0, maxFen: nil), "BR-PRICE-15：0 不合法")
    }

    func testLeaveDiscardsLateResponses() async {
        let api = ManualSearchApi()
        let controller = SearchController(api: api, config: FakeSearchConfig())
        controller.open(query: "milk", platform: nil)
        await eventually { api.count == 1 }
        controller.leave()
        XCTAssertFalse(api.isValid(0))
        api.respond(0, page(["tb:late"]))
        await settle()
        XCTAssertEqual(controller.snapshot.phase, .loading)
        XCTAssertNil(controller.snapshot.shownSeq)
        XCTAssertFalse(controller.submit("again"), "离开后不再发请求")
    }

    func testLoadMoreLateResponseDroppedAfterNewSearch() async {
        let api = ManualSearchApi()
        let controller = SearchController(api: api, config: FakeSearchConfig())
        controller.open(query: "milk", platform: nil)
        await eventually { api.count == 1 }
        api.respond(0, page(["tb:a"], more: true))
        await eventually { controller.snapshot.phase == .content }
        XCTAssertTrue(controller.loadMore())
        await eventually { api.count == 2 }
        XCTAssertTrue(query(api, 1).contains("cursor=c2"))
        controller.submit("other")
        await eventually { api.count == 3 }
        api.respond(1, page(["tb:p2"]))
        await settle()
        XCTAssertEqual(controller.snapshot.phase, .loading)
        XCTAssertTrue(controller.snapshot.items.isEmpty)
    }

    func testTransportCancelledOnNewRequest() async {
        SearchStubProtocol.install { recorded in
            recorded.query["q"] == "slow" ? .hold("slow") : SearchFixtures.ok(SearchFixtures.page(
                [SearchFixtures.card("tb:fast")], more: false
            ))
        }
        let controller = SearchController(api: makeSearchClient(), config: FakeSearchConfig())
        controller.open(query: "slow", platform: nil)
        await eventually { SearchStubProtocol.isHeld("slow") }
        controller.submit("fast")
        await eventually { SearchStubProtocol.wasStopped("slow") }
        await eventually { controller.snapshot.phase == .content }
        XCTAssertEqual(controller.snapshot.items.first?["product_key"] as? String, "tb:fast")
    }

    // MARK: - 平台 Tab 与 search_disabled

    func testOffPlatformNotShown() {
        let config = FakeSearchConfig()
        config.current = ["taobao": "on", "jd": "off", "pdd": "future"]
        let controller = SearchController(api: ManualSearchApi(), config: config)
        controller.open(query: nil, platform: "jd")
        XCTAssertEqual(controller.snapshot.tabs, ["taobao"])
        XCTAssertEqual(controller.snapshot.platform, "taobao", "路由参数指定的平台关闭时回落")
    }

    func testSearchDisabledFirstPageHidesTabRefreshesConfigAndFallsBack() async {
        let api = ManualSearchApi()
        let config = FakeSearchConfig()
        let controller = SearchController(api: api, config: config)
        controller.open(query: "milk", platform: "jd")
        await eventually { api.count == 1 }
        api.respond(0, SearchFixtures.envelope(50304, data: SearchFixtures.disabled))
        await eventually { api.count == 2 }
        XCTAssertEqual(config.freshRequests, 1)
        XCTAssertFalse(controller.snapshot.tabs.contains("jd"))
        XCTAssertEqual(controller.snapshot.platform, "taobao")
        XCTAssertTrue(query(api, 1).contains("platform=taobao"))
        XCTAssertEqual(controller.snapshot.notice?.textKey, "error.50304.search_disabled")
        XCTAssertNotEqual(controller.snapshot.phase, .error, "不给重试")
    }

    func testSearchDisabledOnSecondPage() async {
        let api = ManualSearchApi()
        let config = FakeSearchConfig()
        let controller = SearchController(api: api, config: config)
        controller.open(query: "milk", platform: "jd")
        await eventually { api.count == 1 }
        api.respond(0, page(["jd:a"], platform: "jd", more: true))
        await eventually { controller.snapshot.phase == .content }
        controller.loadMore()
        await eventually { api.count == 2 }
        api.respond(1, SearchFixtures.envelope(50304, data: SearchFixtures.disabled))
        await eventually { api.count == 3 }
        XCTAssertEqual(config.freshRequests, 1)
        XCTAssertFalse(controller.snapshot.tabs.contains("jd"))
        XCTAssertNil(controller.snapshot.loadMoreError, "不给翻页重试")
        XCTAssertTrue(query(api, 2).contains("platform=taobao"))
    }

    func testDisabledPlatformReopensOnlyAfterConfirmedFreshConfig() async {
        let api = ManualSearchApi()
        let config = FakeSearchConfig()
        let controller = SearchController(api: api, config: config)
        controller.open(query: "milk", platform: "jd")
        await eventually { api.count == 1 }
        let markBefore = config.issuedFetchId
        api.respond(0, SearchFixtures.envelope(50304, data: SearchFixtures.disabled))
        await eventually { api.count == 2 }
        // 禁用前已在途的旧拉取（编号不大于分界）确认 on：不提前恢复。
        config.confirm(id: markBefore, status: ["taobao": "on", "jd": "on", "pdd": "on"])
        XCTAssertFalse(controller.snapshot.tabs.contains("jd"))
        // 分界之后的拉取被确认（200 或 304）且明确为 on：恢复，但不自动切过去（不循环，共性 18）。
        config.confirm(id: config.issuedFetchId, status: ["taobao": "on", "jd": "on", "pdd": "on"])
        XCTAssertTrue(controller.snapshot.tabs.contains("jd"))
        XCTAssertEqual(controller.snapshot.platform, "taobao")
        XCTAssertEqual(api.count, 2)
    }

    func testNoAutomaticLoopWhenConfigDisagrees() async {
        let api = ManualSearchApi()
        let config = FakeSearchConfig()
        config.current = ["jd": "on"]
        let controller = SearchController(api: api, config: config)
        controller.open(query: "milk", platform: nil)
        await eventually { api.count == 1 }
        api.respond(0, SearchFixtures.envelope(50304, data: SearchFixtures.disabled))
        await eventually { controller.snapshot.phase == .unavailable }
        // 配置（304）仍说 jd 为 on：Tab 恢复，但本轮不再自动搜它。
        config.confirm(id: config.issuedFetchId, status: ["jd": "on"])
        await settle()
        XCTAssertEqual(controller.snapshot.tabs, ["jd"])
        XCTAssertEqual(api.count, 1, "不自动循环")
        XCTAssertTrue(controller.selectTab("jd"), "下一次由用户触发")
        await eventually { api.count == 2 }
    }

    // MARK: - 限流、错误文案

    func testRateLimitBlocksEntriesAndDefersConfigFallback() async {
        let api = ManualSearchApi()
        let config = FakeSearchConfig()
        let clock = SearchClock()
        let controller = SearchController(api: api, config: config, clock: { clock.now })
        controller.open(query: "milk", platform: "jd")
        await eventually { api.count == 1 }
        api.respond(0, SearchFixtures.envelope(42901, data: "{}"))
        await eventually { controller.snapshot.phase == .error }
        XCTAssertTrue(controller.snapshot.blocked)
        XCTAssertFalse(controller.retry())
        XCTAssertFalse(controller.submit("x"))
        XCTAssertFalse(controller.selectTab("taobao"))
        // 配置关闭当前平台：Tab 立即更新，但限流结束前不发回落搜索（共性 11）。
        config.confirm(id: 1, status: ["taobao": "on", "jd": "off"])
        XCTAssertEqual(controller.snapshot.tabs, ["taobao"])
        await settle()
        XCTAssertEqual(api.count, 1)
        clock.advance(1000)
        await eventually { api.count == 2 }
        XCTAssertTrue(query(api, 1).contains("platform=taobao"))
    }

    func testTrace6AlwaysShownEvenWithoutPlaceholder() {
        let texts = TestTexts()
        let disabled = SearchResultView(
            stateRaw: "error", textKey: "error.50304.search_disabled", code: 50304, platform: "jd",
            traceId: SearchFixtures.trace
        )
        XCTAssertEqual(SearchErrorText.text(disabled, texts: texts, currentPlatform: nil), "jd off（123456）")
        let server = SearchResultView(stateRaw: "error", textKey: "error.50401", code: 50401, traceId: "x-abcdef")
        XCTAssertEqual(SearchErrorText.text(server, texts: texts, currentPlatform: nil), "oops（abcdef）", "不重复")
        let noTrace = SearchResultView(stateRaw: "error", textKey: "error.50401", code: 50401, traceId: "")
        XCTAssertEqual(SearchErrorText.text(noTrace, texts: texts, currentPlatform: nil), "oops")
    }

    func testLoadMoreFailureKeepsItemsWithTrace() async {
        let api = ManualSearchApi()
        let controller = SearchController(api: api, config: FakeSearchConfig())
        controller.open(query: "milk", platform: nil)
        await eventually { api.count == 1 }
        api.respond(0, page(["tb:a"], more: true))
        await eventually { controller.snapshot.phase == .content }
        controller.loadMore()
        await eventually { api.count == 2 }
        api.respond(1, SearchFixtures.envelope(50401, data: "{}"))
        await eventually { controller.snapshot.loadMoreError != nil }
        XCTAssertEqual(controller.snapshot.items.count, 1)
        XCTAssertEqual(controller.snapshot.loadMoreError?.traceId, SearchFixtures.trace)
        XCTAssertTrue(controller.retry())
        await eventually { api.count == 3 }
    }

    func testStaleResultRaisesNotice() async {
        let api = ManualSearchApi()
        let controller = SearchController(api: api, config: FakeSearchConfig())
        controller.open(query: "milk", platform: nil)
        await eventually { api.count == 1 }
        let card = SearchFixtures.card("tb:s", stale: true)
        api.respond(0, SearchFixtures.envelope(0, data: SearchFixtures.page([card], more: false)))
        await eventually { controller.snapshot.phase == .content }
        XCTAssertTrue(controller.snapshot.stale)
    }

    func testFooterKeepsRebateEstimate() {
        let normal = ["disclaimer_keys": ["price_basis"], "rebate_basis": "normal", "rebate_max_fen": 269,
                      "price_fen": 1, "coupon_fen": 0, "final_price_fen": 1] as [String: Any]
        let general = ["disclaimer_keys": ["price_basis.general"], "rebate_basis": "no_rebate"] as [String: Any]
        XCTAssertEqual(SearchDisclaimers.footerKeys([normal, general]), ["price_basis.general", "rebate_estimate"])
    }
}

/// 测试用文案（不含中文以外的依赖；error.trace_suffix 与 App 草稿同一形状）。
struct TestTexts: SearchTexts {
    let table = [
        "error.50304.search_disabled": "{platform_name} off",
        "error.50401": "oops（{trace6}）",
        "error.50001": "oops（{trace6}）",
        "error.trace_suffix": "（{trace6}）",
        "platform.jd": "jd",
    ]
    let fallbacks = ["error.50401": "oops"]

    func text(_ key: String) -> String {
        table[key] ?? ""
    }

    func format(_ key: String, _ vars: [String: String]) -> String {
        var result = table[key] ?? ""
        for (name, value) in vars where !value.isEmpty {
            result = result.replacingOccurrences(of: "{\(name)}", with: value)
        }
        return result.contains("{") ? fallbacks[key] ?? "" : result
    }
}
