import CouliNetwork
import DesignSystem
import Foundation
import OrderCore
import Orders
import Session
import XCTest

/// APP-08 iOS 第 1 轮评审（NATIVE/APP-08/ios-review-r1.md）的复现测试：R1-01 刷新等待、R1-02 通知申请有效性。
/// 共性第 30、31 条。
@MainActor
final class OrderReviewR1Tests: XCTestCase {
    private var env = FakeOrderEnv()

    override func setUp() async throws {
        env = FakeOrderEnv()
    }

    /// 「是否已结束」的探针。
    private final class Done {
        var value = false
    }

    // MARK: - R1-01：下拉刷新等待

    private func loadedDetail() async -> OrderDetailController {
        OrdersStub.install { _ in OrderFixtures.ok(OrderFixtures.detail("o1")) }
        let page = OrderDetailController(
            api: makeOrdersClient(), orderId: "o1", gate: OrderRateGate(), env: env, cache: nil
        )
        page.start()
        await eventually { page.snapshot.phase == .content }
        return page
    }

    /// 详情下拉刷新在途 → 返回上一页（leave）：等待立即结束，refreshing 同步清掉。
    func testDetailRefreshWaitEndsWhenPageLeaves() async {
        let page = await loadedDetail()
        OrdersStub.install { _ in .hold("r") }
        let done = Done()
        let task = Task { @MainActor in
            await page.refreshAndWait()
            done.value = true
        }
        await eventually { OrdersStub.isHeld("r") }
        XCTAssertTrue(page.snapshot.refreshing)
        page.leave()
        XCTAssertFalse(page.snapshot.refreshing, "leave() 同步结束刷新状态")
        await eventually { done.value }
        task.cancel()
    }

    /// SwiftUI 取消刷新任务（请求仍在途）：Task.sleep 的取消不被吞掉，等待立即结束。
    func testDetailRefreshWaitEndsWhenTaskCancelled() async {
        let page = await loadedDetail()
        OrdersStub.install { _ in .hold("r2") }
        let done = Done()
        let task = Task { @MainActor in
            await page.refreshAndWait()
            done.value = true
        }
        await eventually { OrdersStub.isHeld("r2") }
        task.cancel()
        await eventually { done.value }
        page.leave()
    }

    private func loadedList() async -> OrderListController {
        OrdersStub.install { _ in OrderFixtures.ok(OrderFixtures.page([OrderFixtures.row("o1")])) }
        let list = OrderListController(api: makeOrdersClient(), gate: OrderRateGate(), env: env, cache: nil)
        list.start()
        await eventually { list.snapshot.phase == .content }
        return list
    }

    func testListRefreshWaitEndsWhenLeft() async {
        let list = await loadedList()
        OrdersStub.install { _ in .hold("l") }
        let done = Done()
        let task = Task { @MainActor in
            await list.refreshAndWait()
            done.value = true
        }
        await eventually { OrdersStub.isHeld("l") }
        list.leave()
        XCTAssertFalse(list.snapshot.refreshing)
        await eventually { done.value }
        task.cancel()
    }

    func testListRefreshWaitEndsWhenCancelledOrSuperseded() async {
        let list = await loadedList()
        OrdersStub.install { _ in .hold("l2") }
        let done = Done()
        let task = Task { @MainActor in
            await list.refreshAndWait()
            done.value = true
        }
        await eventually { OrdersStub.isHeld("l2") }
        task.cancel()
        await eventually { done.value }

        // 被新一轮取代：旧等待按自己的轮次结束，不等新一轮
        OrdersStub.install { _ in .hold("l3") }
        let first = Done()
        let waiting = Task { @MainActor in
            await list.refreshAndWait()
            first.value = true
        }
        await eventually { OrdersStub.isHeld("l3") }
        XCTAssertTrue(list.setGroup("credited"))
        await eventually { first.value }
        waiting.cancel()
        list.leave()
    }

    // MARK: - R1-02：卡内【开启通知】的有效性

    private func notifiableCards(_ hub: OrderSessionHub) async throws -> PendingTrackService {
        OrdersStub.install { _ in OrderFixtures.ok(OrderFixtures.tracks([.init("L1", "a1", "taobao", false)])) }
        let cards = PendingTrackService(api: makeOrdersClient(), hub: hub, env: env, platform: "taobao")
        cards.refresh()
        await eventually { cards.state.cards.first?.notificationRow == true }
        return cards
    }

    private func hub() throws -> OrderSessionHub {
        try OrderSessionHub(
            defaults: XCTUnwrap(UserDefaults(suiteName: UUID().uuidString)), notification: PendingTrackRaw.notDetermined
        )
    }

    /// 仍有效：等完系统通知状态后照常弹系统框（对照组）。
    func testPushRequestProceedsWhenStillValid() async throws {
        let cards = try await notifiableCards(hub())
        env.holdStatus = true
        cards.requestNotification(try XCTUnwrap(cards.state.cards.first))
        await eventually { self.env.waitingStatus }
        env.finishStatusWait()
        await eventually { self.env.systemPrompts == 1 }
    }

    /// 等系统通知状态期间页面出栈：待执行申请被取消，不弹系统框。
    func testPushRequestDroppedWhenPageLeavesDuringStatusWait() async throws {
        let cards = try await notifiableCards(hub())
        env.holdStatus = true
        cards.requestNotification(try XCTUnwrap(cards.state.cards.first))
        await eventually { self.env.waitingStatus }
        cards.leave()
        env.finishStatusWait()
        await settle()
        XCTAssertEqual(env.pushRequests, 1)
        XCTAssertEqual(env.systemPrompts, 0, "页面已出栈：不弹系统申请")
    }

    /// 等待期间会话换代：不弹系统框。
    func testPushRequestDroppedWhenSessionChangesDuringStatusWait() async throws {
        let hub = try hub()
        let cards = try await notifiableCards(hub)
        env.holdStatus = true
        cards.requestNotification(try XCTUnwrap(cards.state.cards.first))
        await eventually { self.env.waitingStatus }
        hub.sessionChanged()
        env.finishStatusWait()
        await settle()
        XCTAssertEqual(env.systemPrompts, 0, "会话换代：不弹系统申请")
    }

    /// 等待期间 App 侧的会话 / 隐私 / 环境版本变了（撤回同意、切换环境）：不弹系统框。
    func testPushRequestDroppedWhenAppTicketChangesDuringStatusWait() async throws {
        let cards = try await notifiableCards(hub())
        env.holdStatus = true
        cards.requestNotification(try XCTUnwrap(cards.state.cards.first))
        await eventually { self.env.waitingStatus }
        env.appTicket += 1
        env.finishStatusWait()
        await settle()
        XCTAssertEqual(env.systemPrompts, 0, "撤回同意 / 切换环境：不弹系统申请")
    }
}
