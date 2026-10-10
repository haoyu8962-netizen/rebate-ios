import ClientCore
import Config
@testable import Couli
import CouliNetwork
import Foundation
import Generated
import OrderCore
import Orders
import Privacy
import Router
import Session
import Update
import UserNotifications
import XCTest

/// APP-08 iOS 第 1 轮评审（NATIVE/APP-08/ios-review-r1.md）的 App 接线复现：R1-02 通知申请的有效性、R1-04 外跳后回前台拉待跟单卡、
/// R1-05 订单页时间基准为服务端校准时钟、R1-06 会话换代同步取消旧列表页的恢复任务并拒绝持久化。
@MainActor
final class OrdersReviewR1WiringTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        suiteName = "OrdersReviewR1WiringTests.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        AppStubProtocol.reset()
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        AppStubProtocol.reset()
    }

    private func make() -> OrdersAppFixture {
        OrdersAppFixture.make(suiteName: suiteName, defaults: defaults)
    }

    /// R1-02：卡内【开启通知】的有效性在点击时捕获 App 侧的会话 / 隐私 / 环境版本；等待期间会话换代即失效，不弹系统申请。
    func testPushValidityCapturedAtClickInvalidatedBySessionChange() throws {
        let fixture = make()
        AppStubProtocol.install { _ in .hold }
        let valid = fixture.orders.pushValidity()
        XCTAssertTrue(valid())
        fixture.network.client.signOut()
        try fixture.tokens.save(access: "at-b", refresh: "rt-b", scope: "full", account: "user-b")
        XCTAssertFalse(valid(), "会话换代后（即使还没走到 checkSession）点击时的申请失效")
        fixture.orders.checkSession()
        XCTAssertTrue(fixture.orders.pushValidity()(), "新会话里重新点击照常有效")
    }

    /// R1-02：申请经 PermissionRequester 时带着并好的有效性；等待期间失效则不弹系统框。
    func testPushRequestPassesValidityToPermissionEntry() async throws {
        let fixture = make()
        let probe = PushProbe()
        fixture.orders.pushRequest = { isValid in
            guard isValid() else { return }
            await withCheckedContinuation { probe.waiting = $0 }
            if isValid() {
                probe.prompts += 1
            }
        }
        let valid = fixture.orders.pushValidity()
        let task = Task { @MainActor in await fixture.orders.requestPush(isValid: valid) }
        for _ in 0..<200 where probe.waiting == nil {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertNotNil(probe.waiting, "申请在等系统通知状态")
        fixture.network.client.signOut()
        probe.waiting?.resume()
        await task.value
        XCTAssertEqual(probe.prompts, 0, "等待期间会话失效：不弹系统申请")
    }

    /// R1-04：外跳（含未安装但口令已复制）后回到发起页前台，拉一次待跟单卡并显示服务端卡片。
    func testJumpedOutThenForegroundFetchesPendingCards() async throws {
        let fixture = make()
        AppStubProtocol.install { request in
            request.path == "/v1/orders/pending-tracks"
                ? .json(status: 200, body: "{\"code\":0,\"msg\":\"\",\"data\":{\"items\":[{\"link_id\":\"L1\","
                    + "\"attempt_id\":\"a1\",\"platform\":\"taobao\",\"jumped_at\":\"2026-10-09T10:00:00+08:00\","
                    + "\"show_claim_entry\":true,\"dismissed\":false}]},\"trace_id\":\"t\"}")
                : .hold
        }
        let destination = RouteDestination(route: "ProductDetail")
        _ = fixture.orders.pendingSlot(for: destination, purchase: nil, trade: nil)
        let service = try XCTUnwrap(fixture.orders.pendingService(destination.id))
        fixture.orders.jumped(
            destination.id, platform: "taobao", origin: fixture.orders.jumpOrigin(destination.id), visible: false
        )
        XCTAssertTrue(AppStubProtocol.requests.isEmpty, "还在外面：不拉")
        fixture.orders.pageForeground(destination.id)
        for _ in 0..<400 where service.state.cards.isEmpty {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertEqual(service.state.cards.map(\.linkId), ["L1"], "回前台后显示服务端已有的卡片")
    }

    /// R1-05：订单页的时间基准是服务端校准后的时钟（响应头 Date 相差超过 300 秒时校正）。
    func testOrderClockUsesServerCalibratedTime() async throws {
        let fixture = make()
        let dayAhead = Date().addingTimeInterval(86400)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        AppStubProtocol.install { _ in
            .jsonHeaders(
                status: 200, headers: ["Date": formatter.string(from: dayAhead)],
                body: "{\"code\":0,\"msg\":\"\",\"data\":{\"items\":[],\"next_cursor\":null,"
                    + "\"earliest_visible_date\":null},\"trace_id\":\"t\"}"
            )
        }
        let page = fixture.orders.listPage(RouteDestination(route: "OrderList"))
        page.controller.start()
        for _ in 0..<400 where page.controller.snapshot.phase != .empty {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertEqual(page.controller.snapshot.phase, .empty)
        let expected = Int64(dayAhead.timeIntervalSince1970 * 1000)
        XCTAssertLessThan(abs(page.now() - expected), 5000, "列表时间按服务端时钟（快一天）")
        XCTAssertLessThan(abs(fixture.orders.now() - expected), 5000, "缓存获取时刻同一基准")
    }

    /// R1-06：会话换代的同步出口取消旧列表页的恢复任务；之后延迟回调不滚动、旧页面不再持久化。
    func testSessionChangeInvalidatesOldListPageRestore() throws {
        let fixture = make()
        AppStubProtocol.install { _ in .hold }
        let list = fixture.orders.listPage(RouteDestination(route: "OrderList"))
        list.anchor.begin(target: "o7")
        XCTAssertTrue(list.isCurrent())
        fixture.network.client.signOut()
        try fixture.tokens.save(access: "at-b", refresh: "rt-b", scope: "full", account: "user-b")
        XCTAssertFalse(list.isCurrent(), "会话变了：旧页面不再有效（延迟回调据此放弃）")
        list.onStateChange()
        XCTAssertNil(fixture.orders.restorer.stored, "旧页面的持久化被拒绝（不把旧账号的条件写成新账号的记录）")
        fixture.orders.checkSession()
        XCTAssertFalse(list.anchor.restoring, "同步出口取消恢复任务")
        XCTAssertTrue(list.invalidated)
        XCTAssertFalse(list.recordTop("o1"), "旧页面不再记录")
    }
}

/// R1-02 测试的系统申请探针。
@MainActor
private final class PushProbe {
    var prompts = 0
    var waiting: CheckedContinuation<Void, Never>?
}
