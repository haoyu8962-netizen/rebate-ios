import Clipboard
import CouliNetwork
import OrderCore
import Router
import XCTest

/// 订单详情与待跟单卡执行器（真实 ApiClient + 本地假服务）：AC-S1-73 30701、AC-S1-25 / 84、复制只经统一写入口、会话换代清空（共性第 1 条）、
/// 缓存态刷新（第 26 条）、关闭按尝试与跨位置共享（第 3、9、14、15、25、27 条）。
@MainActor
final class OrderDetailAndPendingTests: XCTestCase {
    private var env = FakeOrderEnv()

    override func setUp() async throws {
        env = FakeOrderEnv()
    }

    private func detail(_ id: String, cache: OrderCacheStore? = nil, gate: OrderRateGate = OrderRateGate())
        -> OrderDetailController {
        OrderDetailController(api: makeOrdersClient(), orderId: id, gate: gate, env: env, cache: cache)
    }

    // MARK: - 详情

    func testDetail30701ShowsEmptyAndNoRetry() async {
        OrdersStub.install { _ in OrderFixtures.fail(30701) }
        let page = detail("o404")
        page.start()
        await eventually { page.snapshot.phase == .empty }
        XCTAssertEqual(page.snapshot.error?.textKey, "error.30701")
        XCTAssertFalse(page.retry(), "30701 不重试")
        XCTAssertEqual(OrdersStub.requests.count, 1)
    }

    func testLeaveIgnoresLateResponse() async {
        OrdersStub.install { _ in .hold("d") }
        let page = detail("o1")
        page.start()
        await eventually { OrdersStub.isHeld("d") }
        page.leave()
        OrdersStub.release("d", with: OrderFixtures.ok(OrderFixtures.detail("o1")))
        await settle()
        XCTAssertNil(page.snapshot.detail, "出栈后响应回来不改任何状态")
        XCTAssertEqual(page.snapshot.phase, .loading)
    }

    func testSessionChangeClearsShownSnapshot() async {
        OrdersStub.install { _ in OrderFixtures.ok(OrderFixtures.detail("o1", number: "3712345678901234567")) }
        let page = detail("o1")
        page.start()
        await eventually { page.snapshot.phase == .content }
        page.sessionChanged()
        XCTAssertNil(page.snapshot.detail, "会话换代后不再显示旧账号的订单号与金额")
        XCTAssertEqual(page.snapshot.phase, .cleared)
        XCTAssertFalse(page.refresh())
    }

    func testCopyGoesThroughUnifiedWriterAndRefusesWhenLedgerFails() async {
        OrdersStub.install { _ in OrderFixtures.ok(OrderFixtures.detail("o1", number: "3712345678901234567")) }
        let store = MemoryClipboardHashStore()
        let system = CountingClipboard()
        let writer = ClipboardWriter(system: system, ledger: ClipboardWriteLedger(store: store))
        let page = detail("o1")
        page.copy = { writer.write($0) }
        page.start()
        await eventually { page.snapshot.phase == .content }
        page.copyOrderNo(page.copyTicket(), rendered: "3712345678901234567")
        XCTAssertEqual(system.writes, ["3712345678901234567"], "剪贴板内容等于 order_no")
        XCTAssertTrue(ClipboardWriteLedger(store: store).contains("3712345678901234567"), "台账有记录")
        XCTAssertEqual(page.snapshot.copyToast?.key, "order_detail.copy.done")
        store.failWrites = true
        page.copyOrderNo(page.copyTicket(), rendered: "3712345678901234567")
        XCTAssertEqual(system.writes.count, 1, "记 hash 失败不写")
        XCTAssertEqual(page.snapshot.copyToast?.key, "order_detail.copy.failed")
    }

    func testShareOrderHasNoCopyPath() async throws {
        OrdersStub.install { _ in OrderFixtures.ok(OrderFixtures.detail("s1", masked: "3712****67")) }
        let system = CountingClipboard()
        let writer = ClipboardWriter(system: system, ledger: ClipboardWriteLedger())
        let page = detail("s1")
        page.copy = { writer.write($0) }
        page.start()
        await eventually { page.snapshot.phase == .content }
        page.copyOrderNo(page.copyTicket(), rendered: "3712****67")
        XCTAssertTrue(system.writes.isEmpty, "分享单剪贴板写入次数为 0")
        XCTAssertFalse(OrderNumberDisplay.view(try XCTUnwrap(page.snapshot.detail?.summary)).copyable)
        XCTAssertEqual(OrderNumberDisplay.spoken("3712****67", star: "星号"), "3712星号星号星号星号67")
    }

    func testStaleDetailHasRefreshEntryHonoringRateLimit() async {
        let cache = OrderCacheStore(root: temporaryDirectory())
        OrdersStub.install { _ in OrderFixtures.ok(OrderFixtures.detail("o1")) }
        let online = detail("o1", cache: cache)
        online.start()
        await eventually { online.snapshot.phase == .content }
        OrdersStub.install { _ in .offline }
        let clock = OrdersClock()
        let gate = OrderRateGate(clock: { clock.now })
        let page = detail("o1", cache: cache, gate: gate)
        page.start()
        await eventually { page.snapshot.phase == .stale }
        gate.start(3000)
        XCTAssertFalse(page.refresh(), "共享禁用期内不可刷新")
        clock.advance(3001)
        OrdersStub.install { _ in OrderFixtures.ok(OrderFixtures.detail("o1", status: "WAITING")) }
        XCTAssertTrue(page.refresh())
        await eventually { page.snapshot.phase == .content }
        XCTAssertNil(page.snapshot.staleAt, "成功后提示条移除")
        XCTAssertEqual(cache.readDetail(account: "user-a", orderId: "o1")?.detail.summary.displayStatusRaw, "WAITING")
    }

    func testViewProductOnlyPlatformAndKeyAndActionsUnaffected() throws {
        let object = try XCTUnwrap(JSONSerialization.jsonObject(
            with: Data(OrderFixtures.detail("o7", status: "CREDITED", productKey: "tb:9007").utf8)
        ) as? [String: Any])
        let detail = try XCTUnwrap(OrderJSON.detail(object))
        XCTAssertEqual(ViewProductEntry.view(detail), RouteTarget(
            route: "ProductDetail", params: ["platform": "taobao", "product_key": "tb:9007"]
        ))
        var noKey = detail
        noKey.productKey = nil
        XCTAssertNil(ViewProductEntry.view(noKey))
        XCTAssertEqual(OrderDetailActions.view(detail).buttons.count, OrderDetailActions.view(noKey).buttons.count,
                       "详情底部按钮数不因「查看商品」变化")
    }

    // MARK: - 待跟单卡

    private func service(_ hub: OrderSessionHub, platform: String? = nil) -> PendingTrackService {
        PendingTrackService(api: makeOrdersClient(), hub: hub, env: env, platform: platform)
    }

    func testDismissedHiddenAndDismissRequestCarriesRenderedAttempt() async throws {
        let hub = OrderSessionHub(defaults: try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString)),
                                  notification: PendingTrackRaw.notDetermined)
        OrdersStub.install { request in
            request.method == "POST" ? OrderFixtures.ok("{}") : OrderFixtures.ok(OrderFixtures.tracks([
                .init("L1", "a1", "taobao", false), .init("L2", "a2", "jd", true),
            ]))
        }
        let cards = service(hub)
        cards.refresh()
        await eventually { cards.state.cards.count == 1 }
        let card = try XCTUnwrap(cards.state.cards.first)
        XCTAssertTrue(card.notificationRow, "未决定且没申请过：有通知行")
        XCTAssertEqual(env.pushRequests, 0, "不点不弹系统框")
        XCTAssertTrue(cards.dismiss(card))
        XCTAssertFalse(cards.dismiss(card), "在途时不重复发")
        await eventually { cards.state.cards.isEmpty }
        let post = try XCTUnwrap(OrdersStub.requests.last { $0.method == "POST" })
        XCTAssertEqual(post.path, "/v1/orders/pending-tracks/L1/dismiss")
        XCTAssertEqual(post.body, "{\"attempt_id\":\"a1\"}")
    }

    func testClosedAttemptSharedAcrossPositionsAndLateSnapshotDoesNotRevive() async throws {
        let hub = OrderSessionHub(defaults: try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString)))
        OrdersStub.install { _ in OrderFixtures.ok(OrderFixtures.tracks([.init("L1", "a1", "taobao", false)])) }
        let list = service(hub)
        let product = service(hub, platform: "taobao")
        list.refresh()
        product.refresh()
        await eventually { list.state.cards.count == 1 && product.state.cards.count == 1 }
        // 商品页再拉一次（hold 住），列表位置关闭成功，之后旧快照才到
        OrdersStub.install { request in
            request.method == "POST" ? .hold("close")
                : .hold("late")
        }
        product.refresh()
        await eventually { OrdersStub.isHeld("late") }
        let card = try XCTUnwrap(list.state.cards.first)
        XCTAssertTrue(list.dismiss(card))
        await eventually { OrdersStub.isHeld("close") }
        await eventually { product.state.busy.contains(card.key) }
        XCTAssertFalse(product.dismiss(card), "别处在途时同一尝试忙碌、不能重复发")
        OrdersStub.release("close", with: OrderFixtures.ok("{}"))
        await eventually { list.state.cards.isEmpty && product.state.cards.isEmpty }
        OrdersStub.release("late", with: OrderFixtures.ok(OrderFixtures.tracks([
            .init("L1", "a1", "taobao", false), .init("L1", "a9", "jd", false),
        ])))
        await settle()
        XCTAssertTrue(product.state.cards.isEmpty, "旧快照不得复活已关闭的尝试；商品页只显示同平台")
        XCTAssertTrue(product.state.busy.isEmpty)
    }

    func testDismissErrorsSplitByKind() async throws {
        let hub = OrderSessionHub(defaults: try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString)))
        OrdersStub.install { _ in OrderFixtures.ok(OrderFixtures.tracks([.init("L1", "a1", "taobao", false)])) }
        let cards = service(hub)
        cards.refresh()
        await eventually { cards.state.cards.count == 1 }
        let card = try XCTUnwrap(cards.state.cards.first)

        OrdersStub.install { request in request.method == "POST" ? OrderFixtures.fail(50301) : .offline }
        cards.dismiss(card)
        await eventually { cards.state.toast != nil }
        let message = try XCTUnwrap(cards.state.toast).message(OrderDraftTexts())
        XCTAssertTrue(message.hasSuffix("（123456）"), "5xxxx 用对应文案 + trace6，不是网络错误：\(message)")
        XCTAssertFalse(message.contains(OrderDraftTexts().text("order_list.network_error")))
        XCTAssertEqual(cards.state.cards.count, 1)
        XCTAssertTrue(cards.state.busy.isEmpty, "失败后清掉忙碌，用户能再点")
        cards.consumeToast()

        OrdersStub.install { request in request.method == "POST" ? .offline : .offline }
        cards.dismiss(card)
        await eventually { cards.state.toast != nil }
        XCTAssertEqual(
            cards.state.toast?.message(OrderDraftTexts()),
            OrderDraftTexts().text("order_list.network_error")
        )
        cards.consumeToast()

        var fetches = 0
        OrdersStub.install { request in
            if request.method == "POST" {
                return OrderFixtures.fail(20001)
            }
            fetches += 1
            return OrderFixtures.ok(OrderFixtures.tracks([.init("L1", "a2", "taobao", false)]))
        }
        cards.dismiss(card)
        await eventually { cards.state.cards.first?.attemptId == "a2" }
        XCTAssertEqual(fetches, 1, "20001 后重拉一次，按服务端结果显示")

        OrdersStub.install { request in
            request.method == "POST" ? OrderFixtures.fail(42901, headers: ["Retry-After": "9"]) : .offline
        }
        cards.dismiss(try XCTUnwrap(cards.state.cards.first))
        await eventually { hub.gate.active }
        XCTAssertTrue(cards.state.blocked, "42901 禁用关闭按钮")
        XCTAssertFalse(cards.dismiss(try XCTUnwrap(cards.state.cards.first)))
    }

    func testPendingFetch42901StartsSharedGate() async throws {
        let hub = OrderSessionHub(defaults: try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString)))
        OrdersStub.install { _ in OrderFixtures.fail(42901, headers: ["Retry-After": "6"]) }
        let cards = service(hub)
        cards.refresh()
        await eventually { hub.gate.active }
        let sent = OrdersStub.requests.count
        cards.refresh()
        await settle()
        XCTAssertEqual(OrdersStub.requests.count, sent, "待跟单查询自身的 42901 同样生效")
    }

    func testNotificationRowUsedSyncsAllPositions() async throws {
        let hub = OrderSessionHub(defaults: try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString)),
                                  notification: PendingTrackRaw.notDetermined)
        OrdersStub.install { _ in OrderFixtures.ok(OrderFixtures.tracks([.init("L1", "a1", "taobao", false)])) }
        let list = service(hub)
        let product = service(hub)
        list.refresh()
        product.refresh()
        await eventually {
            list.state.cards.first?.notificationRow == true && product.state.cards.first?.notificationRow == true
        }
        list.requestNotification(try XCTUnwrap(list.state.cards.first))
        await eventually { product.state.cards.first?.notificationRow == false }
        XCTAssertEqual(list.state.cards.first?.notificationRow, false)
        await eventually { self.env.pushRequests == 1 }
        product.requestNotification(try XCTUnwrap(product.state.cards.first))
        await settle()
        XCTAssertEqual(env.pushRequests, 1, "别处点过：只重算、不再申请")
    }

    func testSessionChangeClearsCards() async throws {
        let hub = OrderSessionHub(defaults: try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString)))
        OrdersStub.install { _ in OrderFixtures.ok(OrderFixtures.tracks([.init("L1", "a1", "taobao", false)])) }
        let cards = service(hub)
        cards.refresh()
        await eventually { cards.state.cards.count == 1 }
        hub.gate.start(5000)
        hub.markClosed("x")
        hub.sessionChanged()
        await eventually { cards.state.cards.isEmpty }
        XCTAssertFalse(hub.gate.active, "新会话一份新的禁用期")
        XCTAssertTrue(hub.closed.isEmpty)
    }
}
