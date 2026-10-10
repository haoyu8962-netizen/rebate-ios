import CouliNetwork
import OrderCore
import XCTest

/// 订单列表执行器（真实 ApiClient + 本地假服务）：AC-S1-103 / 106①、AC-S1-73、TECH-20、迟到与作废、42901 共享、刷新与翻页（共性第 2、7、8、13、
/// 16、27 条）。
@MainActor
final class OrderListTests: XCTestCase {
    private var env = FakeOrderEnv()

    override func setUp() async throws {
        env = FakeOrderEnv()
    }

    private func make(
        _ client: ApiClient = makeOrdersClient(), gate: OrderRateGate = OrderRateGate(), cache: OrderCacheStore? = nil,
        scope: String? = nil
    ) -> OrderListController {
        OrderListController(api: client, gate: gate, env: env, cache: cache, scope: scope)
    }

    private func listQueries() -> [[String: String]] {
        OrdersStub.requests("/v1/orders").map(\.query)
    }

    // MARK: - AC-S1-103 / 106①

    func testGroupPlatformMonthAndSearchOnlySendServerParams() async {
        OrdersStub.install { _ in OrderFixtures.ok(OrderFixtures.page([OrderFixtures.row("o1")])) }
        let list = make()
        list.start()
        await eventually { list.snapshot.phase == .content }
        XCTAssertEqual(listQueries().last, ["scope": "self"])

        list.setGroup("estimating")
        await eventually { list.snapshot.phase == .content }
        XCTAssertEqual(listQueries().last, ["scope": "self", "status_group": "estimating"], "分组只传 status_group")
        XCTAssertNil(listQueries().last?["display_status"])

        list.setGroup("all")
        list.setPlatform("taobao")
        list.setMonth("2026-10")
        await eventually { list.snapshot.phase == .content }
        XCTAssertEqual(listQueries().last, ["scope": "self", "platform": "taobao", "paid_month": "2026-10"])

        let before = listQueries().count
        for (index, keyword) in ["3712345678901234567", "3712345678", "纸巾"].enumerated() {
            list.updateSearchText(keyword)
            XCTAssertEqual(listQueries().count, before + index, "键入不发请求（提交才搜，G11）")
            list.submitSearch()
            await eventually { list.snapshot.phase == .content }
            XCTAssertEqual(listQueries().last?["q"], keyword)
        }
        XCTAssertEqual(listQueries().count, before + 3, "完整单号、前 10 位、标题词各发 1 次 q")
        XCTAssertEqual(list.snapshot.items.map(\.orderId), ["o1"], "结果只按假服务返回显示（客户端不过滤）")
    }

    func testSwitchScopeResetsGroupAndClearsConditionsAndSearchText() async {
        OrdersStub.install { _ in OrderFixtures.ok(OrderFixtures.page([OrderFixtures.row("o1")])) }
        let list = make()
        list.start()
        list.setGroup("credited")
        list.setPlatform("jd")
        list.updateSearchText("纸巾")
        list.submitSearch()
        await eventually { list.snapshot.phase == .content }
        list.setScope("share")
        await eventually { list.snapshot.phase == .content }
        XCTAssertEqual(listQueries().last, ["scope": "share"], "切子 Tab 后分组为「全部」、其余条件清空")
        XCTAssertEqual(list.snapshot.searchText, "", "搜索框一并清空")
    }

    func testRouteScopeShareOpensShareTab() async {
        OrdersStub.install { _ in OrderFixtures.ok(OrderFixtures.page([])) }
        let list = make(scope: "share")
        list.start()
        await eventually { list.snapshot.phase == .empty }
        XCTAssertEqual(listQueries().last, ["scope": "share"])
    }

    func testSearchInputLimitedTo40Scalars() {
        let list = make()
        list.updateSearchText(String(repeating: "1", count: 45))
        XCTAssertEqual(list.snapshot.searchText.unicodeScalars.count, 40)
    }

    // MARK: - AC-S1-73

    func testEarliestVisibleDateShownOnlyWhenPresent() async {
        OrdersStub.install { _ in
            OrderFixtures.ok(OrderFixtures.page([OrderFixtures.row("o1")], earliest: "2025-10-01"))
        }
        let list = make()
        list.start()
        await eventually { list.snapshot.phase == .content }
        XCTAssertEqual(list.snapshot.earliestVisibleDate, "2025-10-01")
        OrdersStub.install { _ in OrderFixtures.ok(OrderFixtures.page([OrderFixtures.row("o1")])) }
        list.refresh()
        await eventually { !list.snapshot.refreshing }
        XCTAssertNil(list.snapshot.earliestVisibleDate)
    }

    // MARK: - 迟到与作废

    func testLateResponseOfOldRoundIsDiscarded() async {
        OrdersStub.install { request in
            request.query["status_group"] == nil ? .hold("first")
                : OrderFixtures.ok(OrderFixtures.page([OrderFixtures.row("credited")]))
        }
        let list = make()
        list.start()
        await eventually { OrdersStub.isHeld("first") }
        list.setGroup("credited")
        await eventually { list.snapshot.phase == .content }
        OrdersStub.release("first", with: OrderFixtures.ok(OrderFixtures.page([OrderFixtures.row("old")])))
        await settle()
        XCTAssertEqual(list.snapshot.items.map(\.orderId), ["credited"], "旧轮次的响应不覆盖新结果")
    }

    func testLeaveCancelsInFlightAndIgnoresResponse() async {
        OrdersStub.install { _ in .hold("first") }
        let list = make()
        list.start()
        await eventually { OrdersStub.isHeld("first") }
        list.leave()
        XCTAssertEqual(list.inFlight, 0)
        OrdersStub.release("first", with: OrderFixtures.ok(OrderFixtures.page([OrderFixtures.row("late")])))
        await settle()
        XCTAssertTrue(list.snapshot.items.isEmpty)
    }

    // MARK: - 翻页与刷新（共性第 7、8 条）

    func testPagingAndRefreshFailureKeepsItemsAndCursorWithTrace6Toast() async {
        OrdersStub.install { request in
            request.query["cursor"] == nil
                ? OrderFixtures.ok(OrderFixtures.page([OrderFixtures.row("o1")], next: "c2"))
                : .hold("page2")
        }
        let list = make()
        list.start()
        await eventually { list.snapshot.phase == .content }
        XCTAssertTrue(list.loadMore())
        await eventually { OrdersStub.isHeld("page2") }
        XCTAssertTrue(list.snapshot.loadingMore)
        OrdersStub.install { _ in OrderFixtures.fail(50301) }
        XCTAssertTrue(list.refresh())
        XCTAssertFalse(list.snapshot.loadingMore, "刷新开新轮次时清掉旧轮次的 loadingMore")
        await eventually { !list.snapshot.refreshing }
        XCTAssertEqual(list.snapshot.items.map(\.orderId), ["o1"], "刷新失败保留旧列表")
        XCTAssertEqual(list.snapshot.nextCursor, "c2", "刷新失败恢复对应游标，还能继续翻页")
        XCTAssertTrue(list.snapshot.canLoadMore)
        let toast = try? XCTUnwrap(list.snapshot.toast)
        XCTAssertEqual(toast?.message(OrderDraftTexts()).hasSuffix("（123456）"), true,
                       "轻提示经统一错误消息带 trace6（50301 文案没有占位符也追加，共性第 16 条）")
    }

    func testPageErrorKeepsItemsAndShowsTrace6() async throws {
        OrdersStub.install { request in
            request.query["cursor"] == nil
                ? OrderFixtures.ok(OrderFixtures.page([OrderFixtures.row("o1")], next: "c2"))
                : OrderFixtures.fail(50001)
        }
        let list = make()
        list.start()
        await eventually { list.snapshot.phase == .content }
        list.loadMore()
        await eventually { list.snapshot.pageError != nil }
        XCTAssertEqual(list.snapshot.items.count, 1)
        let message = OrderErrorAction.message(OrderDraftTexts(), try XCTUnwrap(list.snapshot.pageError))
        XCTAssertTrue(message.contains("123456"))
        XCTAssertEqual(OrdersStub.requests("/v1/orders").last?.query["cursor"], "c2", "翻页带上一页的 next_cursor")
    }

    // MARK: - 42901 共享（共性第 2、13、27 条）

    func testRateLimitSharedAcrossControllersAndBlocksEntries() async {
        let clock = OrdersClock()
        let gate = OrderRateGate(clock: { clock.now })
        OrdersStub.install { _ in OrderFixtures.fail(42901, headers: ["Retry-After": "7"]) }
        let list = make(gate: gate)
        list.start()
        await eventually { list.snapshot.phase == .error }
        XCTAssertEqual(list.snapshot.error?.actionRaw, OrderErrorKind.retryAfter)
        XCTAssertTrue(gate.active)
        XCTAssertFalse(list.setGroup("credited"), "禁用期内筛选不提交")
        XCTAssertFalse(list.refresh())
        XCTAssertFalse(list.retry())
        let sent = OrdersStub.requests.count
        let second = make(gate: gate)
        second.start()
        await settle()
        XCTAssertEqual(OrdersStub.requests.count, sent, "重进页面不能绕过：执行层不发")
        XCTAssertEqual(second.snapshot.error?.textKey, "error.42901")
        clock.advance(7001)
        XCTAssertFalse(gate.active)
        OrdersStub.install { _ in OrderFixtures.ok(OrderFixtures.page([])) }
        XCTAssertTrue(second.retry())
        await eventually { second.snapshot.phase == .empty }
    }

    func testSendGateBlocksAutomaticRetryButNotInFlightResponse() async {
        let clock = OrdersClock()
        let gate = OrderRateGate(clock: { clock.now })
        var first = true
        OrdersStub.install { _ in
            if first {
                first = false
                // 第一次传输失败（读接口会自动重试 1 次）；在重试写出前进入禁用期
                Task { @MainActor in gate.start(5000) }
                return .offline
            }
            return OrderFixtures.ok(OrderFixtures.page([]))
        }
        let client = makeOrdersClient()
        let result = await client.send(
            ApiCall(operationId: "listOrders", query: "scope=self"), isValid: { true }, sendAllowed: gate.sendAllowed
        )
        XCTAssertEqual(result, .localReject(reason: LocalRejectReason.sendBlocked), "自动重试在写出前被发送前闸门拦下")
        XCTAssertEqual(OrdersStub.requests.count, 1)

        // 已写出的请求不因禁用期被丢弃（闸门不进归属）
        clock.advance(6000)
        OrdersStub.install { _ in .hold("written") }
        let task = Task { @MainActor in
            await client.send(ApiCall(operationId: "listOrders", query: "scope=self"), isValid: { true },
                              sendAllowed: gate.sendAllowed)
        }
        await eventually { OrdersStub.isHeld("written") }
        gate.start(5000)
        OrdersStub.release("written", with: OrderFixtures.ok(OrderFixtures.page([])))
        let written = await task.value
        if case .success = written {} else {
            XCTFail("已写出的请求照常收到成功响应：\(written)")
        }
    }
}

/// 错误正文（带 trace6）。
@MainActor
func errorText(_ view: OrderErrorView?) -> String {
    view.map { OrderErrorAction.message(OrderDraftTexts(), $0) } ?? ""
}
