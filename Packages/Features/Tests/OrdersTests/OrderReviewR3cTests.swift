import CouliNetwork
import Foundation
@testable import OrderCore
import Session
import XCTest

/// APP-08 iOS 第 3 轮后第二次定向复核（NATIVE/APP-08/ios-recheck-r3fix-b.md）RC-01：执行器固定的账号、会话世代与环境票据随请求交给网络层，
/// 在首次归属绑定与实际发送前只比较。场景：入口已通过身份检查、请求排进 Task，执行前底层会话换成 B（或切了环境），App 的换代通知还没处理
/// （执行器看来仍是当前）→ 旧请求零发送，不带 B 的凭据发出 A 的搜索词、详情或关闭参数。
@MainActor
final class OrderReviewR3cTests: XCTestCase {
    private var env = FakeOrderEnv()
    private var tokens = MemorySessionTokens(access: "at-1", refresh: "rt-1", scope: "full", account: "user-a")
    private var client = makeOrdersClient()

    override func setUp() async throws {
        freshSession()
    }

    /// 新的一份会话与客户端（同一测试里重新开始一轮也用它）；App 一次读出的网络归属（AppOrders.currentOwner 同口径）交给 env。
    private func freshSession() {
        env = FakeOrderEnv()
        tokens = MemorySessionTokens(access: "at-1", refresh: "rt-1", scope: "full", account: "user-a")
        client = makeOrdersClient(tokens: tokens)
        env.request = client.currentOwnership(credentialsReadable: true)
    }

    /// 底层会话换成 B（退出 + 保存 B 的令牌）；App 的换代通知不处理（env 仍是 A）。
    private func switchToB() throws {
        client.signOut()
        try tokens.save(access: "at-b", refresh: "rt-b", scope: "full", account: "user-b")
    }

    /// 让排队的 Task 执行完（零发送时没有回包可等）。
    private func drain() async throws {
        try await Task.sleep(nanoseconds: 100_000_000)
    }

    private static let fullNo = "3712345678901234567"

    /// 对照：会话没变时带固定归属照常发送、照常出结果（不误拦）。
    func testFixedOwnershipUnchangedSendsNormally() async {
        OrdersStub.install { _ in OrderFixtures.ok(OrderFixtures.page([OrderFixtures.row("o1")])) }
        let list = OrderListController(api: client, gate: OrderRateGate(), env: env, cache: nil)
        list.start()
        await eventually { list.snapshot.phase == .content }
        XCTAssertEqual(OrdersStub.requests.count, 1)
    }

    /// 列表首发与搜索：排队后、首发前换账号 → 零发送。
    func testListAndSearchQueuedThenSessionSwapSendNothing() async throws {
        OrdersStub.install { _ in OrderFixtures.ok(OrderFixtures.page([OrderFixtures.row("o1")], next: "c2")) }
        let first = OrderListController(api: client, gate: OrderRateGate(), env: env, cache: nil)
        first.start()
        try switchToB()
        try await drain()
        XCTAssertTrue(OrdersStub.requests.isEmpty, "首发前换代：列表请求零发送")

        // 搜索：A 的列表已显示 → 输入完整订单号并提交（入口检查通过）→ 执行前换成 B
        freshSession()
        let list = OrderListController(api: client, gate: OrderRateGate(), env: env, cache: nil)
        list.start()
        await eventually { list.snapshot.phase == .content }
        let before = OrdersStub.requests.count
        list.updateSearchText(Self.fullNo)
        XCTAssertTrue(list.submitSearch(), "前提：入口检查通过")
        try switchToB()
        try await drain()
        XCTAssertEqual(OrdersStub.requests.count, before, "A 的搜索词不随 B 的凭据发出")
    }

    /// 翻页：排队后、首发前换账号 → 零发送。
    func testLoadMoreQueuedThenSessionSwapSendsNothing() async throws {
        OrdersStub.install { _ in OrderFixtures.ok(OrderFixtures.page([OrderFixtures.row("o1")], next: "c2")) }
        let list = OrderListController(api: client, gate: OrderRateGate(), env: env, cache: nil)
        list.start()
        await eventually { list.snapshot.phase == .content }
        let before = OrdersStub.requests.count
        XCTAssertTrue(list.loadMore(), "前提：入口检查通过")
        try switchToB()
        try await drain()
        XCTAssertEqual(OrdersStub.requests.count, before, "翻页零发送")
    }

    /// 详情：排队后、首发前换账号 / 切环境 → 零发送。
    func testDetailQueuedThenSessionOrEnvironmentChangeSendsNothing() async throws {
        for path in ["account", "environment"] {
            freshSession()
            OrdersStub.install { _ in OrderFixtures.ok(OrderFixtures.detail("o1", number: Self.fullNo)) }
            let page = OrderDetailController(api: client, orderId: "o1", gate: OrderRateGate(), env: env, cache: nil)
            page.start()
            if path == "account" {
                try switchToB()
            } else {
                client.invalidateSessions()
            }
            try await drain()
            XCTAssertTrue(OrdersStub.requests.isEmpty, "\(path)：详情零发送")
        }
    }

    /// 待跟单拉取与关闭：排队后、首发前换账号 → 零发送（关闭参数不随 B 的凭据发出）。
    func testPendingFetchAndDismissQueuedThenSessionSwapSendNothing() async throws {
        let hub = OrderSessionHub(
            defaults: try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString)), notification: PendingTrackRaw.granted
        )
        OrdersStub.install { request in
            request.method == "POST" ? OrderFixtures.ok("{}") : OrderFixtures.ok(OrderFixtures.tracks([
                .init("L1", "a1", "taobao", false),
            ]))
        }
        let fetchOnly = PendingTrackService(api: client, hub: hub, env: env, platform: "taobao")
        fetchOnly.refresh()
        try switchToB()
        try await drain()
        XCTAssertTrue(OrdersStub.requests.isEmpty, "拉取零发送")
        fetchOnly.leave()

        freshSession()
        let cards = PendingTrackService(api: client, hub: hub, env: env, platform: "taobao")
        cards.refresh()
        await eventually { cards.state.cards.count == 1 }
        let card = try XCTUnwrap(cards.state.cards.first)
        XCTAssertTrue(cards.dismiss(card), "前提：入口检查通过")
        try switchToB()
        try await drain()
        XCTAssertTrue(OrdersStub.requests.filter { $0.method == "POST" }.isEmpty, "关闭零发送")
    }
}
