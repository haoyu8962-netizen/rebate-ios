import CouliNetwork
import Foundation
import OrderCore
import XCTest

/// APP-08v-a G-O04「未跟单？去找回」置顶（锁定契约 `OrderListData.claim_entry_pinned`，只 scope=self）：执行层规则
/// （真实 ApiClient + 本地假服务）。字段与快照属性经 Mirror 按名读取（§2 新接口：`OrderListData.claimEntryPinned`、
/// `OrderListSnapshot.claimPinned`），实现前以明确的断言失败报红，不造成编译失败。
/// 还含 Android a 评审 r1 S2-1「刷新解析失败（成功响应解析不出）要清置顶标志，列表与旧游标保留」。
@MainActor
final class OrderListVisualClaimTests: XCTestCase {
    private var env = FakeOrderEnv()

    override func setUp() async throws {
        env = FakeOrderEnv()
    }

    private func make(cache: OrderCacheStore? = nil, scope: String? = nil) -> OrderListController {
        OrderListController(api: makeOrdersClient(), gate: OrderRateGate(), env: env, cache: cache, scope: scope)
    }

    /// 假服务在网络线程调用：不带主线程隔离。
    private nonisolated static func page(_ ids: [String], next: String? = "c-1", pinned: String?) -> String {
        let base = OrderFixtures.page(ids.map { OrderFixtures.row($0) }, next: next)
        guard let pinned else { return base }
        return String(base.dropLast()) + ",\"claim_entry_pinned\":\(pinned)}"
    }

    private func bool(_ value: Any, _ name: String, file: StaticString = #filePath, line: UInt = #line) throws -> Bool {
        let child = Mirror(reflecting: value).children.first { $0.label == name }
        let found = try XCTUnwrap(child, "缺 \(type(of: value)).\(name)（§2 新接口）", file: file, line: line)
        return try XCTUnwrap(found.value as? Bool, "\(name) 应为 Bool", file: file, line: line)
    }

    private func pinned(_ list: OrderListController, file: StaticString = #filePath,
                        line: UInt = #line) throws -> Bool {
        try bool(list.snapshot, "claimPinned", file: file, line: line)
    }

    // MARK: - 解析

    /// 只认 JSON 布尔 true；缺失 / null / false / 字符串 "true" / 数字 1 一律不置顶（不臆造、不宽松解析）。
    func testListDataReadsClaimEntryPinnedOnlyFromJSONTrue() throws {
        let cases: [(String?, Bool)] = [("true", true), ("false", false), (nil, false), ("null", false),
                                        ("\"true\"", false), ("1", false)]
        for (raw, expected) in cases {
            let text = Self.page(["o1"], pinned: raw)
            let data = try JSONSerialization.jsonObject(with: Data(text.utf8))
            let parsed = try XCTUnwrap(OrderJSON.listData(data), "合法页仍能解析（\(raw ?? "缺失")）")
            XCTAssertEqual(parsed.items.map(\.orderId), ["o1"], "置顶字段不影响行解析")
            XCTAssertEqual(try bool(parsed, "claimEntryPinned"), expected, "claim_entry_pinned=\(raw ?? "缺失")")
        }
    }

    // MARK: - 执行器快照：pinned × scope × stale

    func testPinnedOnlyForFreshSelfScope() async throws {
        OrdersStub.install { _ in
            OrderFixtures.ok(Self.page(["o1"], pinned: "true"))
        }
        let own = make()
        own.start()
        await eventually { own.snapshot.phase == .content }
        XCTAssertTrue(try pinned(own), "自购 + true → 置顶")

        let share = make(scope: "share")
        share.start()
        await eventually { share.snapshot.phase == .content }
        XCTAssertFalse(try pinned(share), "分享 + true → 不置顶（只 scope=self）")

        OrdersStub.install { _ in OrderFixtures.ok(Self.page(["o1"], pinned: "false")) }
        let off = make()
        off.start()
        await eventually { off.snapshot.phase == .content }
        XCTAssertFalse(try pinned(off), "自购 + false → 不置顶")
    }

    /// 断网显示上次数据：按不置顶；缓存不写这个字段（新 Store 重读同样为假）。
    func testStaleCacheIsNeverPinnedAndCacheDoesNotStoreIt() async throws {
        let root = temporaryDirectory()
        let cache = OrderCacheStore(root: root)
        OrdersStub.install { _ in OrderFixtures.ok(Self.page(["o1"], pinned: "true")) }
        let online = make(cache: cache)
        online.start()
        await eventually { online.snapshot.phase == .content }
        XCTAssertTrue(try pinned(online), "前提：在线置顶")

        let reread = OrderCacheStore(root: root)
        let cached = try XCTUnwrap(reread.readList(account: "user-a", scope: "self"), "前提：已写断网缓存")
        XCTAssertFalse(try bool(cached.data, "claimEntryPinned"), "缓存不存置顶值（与当时时间有关）")

        OrdersStub.install { _ in .offline }
        let offline = make(cache: cache)
        offline.start()
        await eventually { offline.snapshot.phase == .stale }
        XCTAssertEqual(offline.snapshot.items.map(\.orderId), ["o1"], "缓存数据照常显示")
        XCTAssertFalse(try pinned(offline), "stale → 不置顶")
    }

    /// Android a 评审 r1 S2-1：先置顶，再刷新收到「成功但解析不出」的响应（data={}）——旧列表与旧游标保留（原行为），
    /// 置顶标志必须清除；随后翻页仍用旧游标。
    func testMalformedSuccessfulRefreshClearsPinnedButKeepsItemsAndCursor() async throws {
        OrdersStub.install { _ in OrderFixtures.ok(Self.page(["o1", "o2"], next: "c-1", pinned: "true")) }
        let list = make()
        list.start()
        await eventually { list.snapshot.phase == .content }
        XCTAssertTrue(try pinned(list), "前提：已置顶")

        OrdersStub.install { _ in OrderFixtures.ok("{}") }
        XCTAssertTrue(list.refresh())
        await eventually { !list.snapshot.refreshing }
        await settle()
        XCTAssertEqual(list.snapshot.items.map(\.orderId), ["o1", "o2"], "坏响应：保留原列表")
        XCTAssertEqual(list.snapshot.nextCursor, "c-1", "坏响应：保留原游标")
        XCTAssertFalse(try pinned(list), "坏响应：置顶退回非置顶（右上入口回来）")

        OrdersStub.install { _ in OrderFixtures.ok(Self.page(["o3"], next: nil, pinned: nil)) }
        XCTAssertTrue(list.loadMore())
        await eventually { list.snapshot.items.count == 3 }
        XCTAssertEqual(OrdersStub.requests("/v1/orders").last?.query["cursor"], "c-1", "翻页仍用旧游标")
    }

    /// 对照：可解析的刷新照常替换列表、游标与置顶值（true 保持、false 退回），不能为修坏响应把正常响应一律置假。
    func testParseableRefreshReplacesPinnedValue() async throws {
        OrdersStub.install { _ in OrderFixtures.ok(Self.page(["o1"], pinned: "true")) }
        let list = make()
        list.start()
        await eventually { list.snapshot.phase == .content }

        OrdersStub.install { _ in OrderFixtures.ok(Self.page(["o2"], next: "c-2", pinned: "true")) }
        XCTAssertTrue(list.refresh())
        await eventually { list.snapshot.items.map(\.orderId) == ["o2"] }
        XCTAssertEqual(list.snapshot.nextCursor, "c-2")
        XCTAssertTrue(try pinned(list), "可解析 true → 仍置顶")

        OrdersStub.install { _ in OrderFixtures.ok(Self.page(["o3"], pinned: "false")) }
        XCTAssertTrue(list.refresh())
        await eventually { list.snapshot.items.map(\.orderId) == ["o3"] }
        XCTAssertFalse(try pinned(list), "可解析 false → 退回右上入口")
    }

    // MARK: - 文案（G-O13、G-O04 键名三端一致）

    func testDraftTextsForMonthNoteAndFindEntry() {
        let texts = OrderDraftTexts()
        XCTAssertEqual(texts.text("order_list.filter.month_note"), "按付款时间", "G-O13：月份半屏副标题按画板措辞")
        XCTAssertEqual(texts.text("order_list.find_entry"), "未跟单？去找回", "置顶行与右上入口同一键")
    }

    // MARK: - v3（评审 r1 S2-1）：身份暂时未知时的整页错误态不置顶

    /// 先正：pinned=true 的空页（phase=.empty）置顶；再反：身份暂时未知时下拉刷新 → 整页错误态（「加载失败」+【重试】），置顶为假，
    /// 不发新请求。
    func testIdentityUnknownRefreshOnEmptyPinnedPageFallsBackToUnpinnedError() async throws {
        let env = ClaimIdentityEnv()
        OrdersStub.install { _ in OrderFixtures.ok(Self.page([], next: nil, pinned: "true")) }
        let list = OrderListController(api: makeOrdersClient(), gate: OrderRateGate(), env: env, cache: nil)
        list.start()
        await eventually { list.snapshot.phase == .empty }
        XCTAssertTrue(try pinned(list), "前提：空页也按服务端置顶")
        let before = OrdersStub.requests("/v1/orders").count

        env.unknown = true
        _ = list.refresh()
        await settle()
        XCTAssertEqual(list.snapshot.phase, .error, "前提：身份未知的刷新结算为整页错误态")
        XCTAssertTrue(list.snapshot.identityPending)
        XCTAssertFalse(try pinned(list), "整页错误态不置顶（右上入口回来）")
        XCTAssertEqual(OrdersStub.requests("/v1/orders").count, before, "身份未知时不发请求")
    }

    /// 身份暂时未知时切到「分享」：旧结果清掉、整页错误态，scope=share 且不置顶（不能留着自购的置顶）。
    func testIdentityUnknownSwitchToShareClearsPinned() async throws {
        let env = ClaimIdentityEnv()
        OrdersStub.install { _ in OrderFixtures.ok(Self.page(["o1"], pinned: "true")) }
        let list = OrderListController(api: makeOrdersClient(), gate: OrderRateGate(), env: env, cache: nil)
        list.start()
        await eventually { list.snapshot.phase == .content }
        XCTAssertTrue(try pinned(list), "前提：自购置顶")

        env.unknown = true
        _ = list.setScope("share")
        await settle()
        XCTAssertEqual(list.snapshot.query.scope, "share")
        XCTAssertTrue(list.snapshot.items.isEmpty, "旧结果不冒充新条件")
        XCTAssertEqual(list.snapshot.phase, .error, "前提：身份未知时进整页错误态")
        XCTAssertFalse(try pinned(list), "scope=share + 整页错误态不置顶")
    }
}

/// 可切到「身份暂时未知」的列表环境（`check` 返回 `.unknown`；其余同 FakeOrderEnv 的最小实现）。
@MainActor
final class ClaimIdentityEnv: OrderListEnv {
    var unknown = false
    private let owner = OrderOwner(account: "user-a", key: "user-a#0", member: true)

    func now() -> Int64 {
        1_791_000_000_000
    }

    func currentOwner() -> OrderOwner {
        owner
    }

    func isCurrent(_ candidate: OrderOwner) -> Bool {
        !unknown && candidate == owner
    }

    func check(_ candidate: OrderOwner) -> IdentityCheck {
        if unknown {
            return .unknown
        }
        return candidate == owner ? .current : .stale
    }
}
