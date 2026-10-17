@testable import Couli
import CouliNetwork
import Foundation
@testable import OrderCore
@testable import Orders
import Router
import XCTest

/// FU-IOS-0713 终版补测：待跟单执行器的完成信号承重（`whenIdle()` 之后直接正向断言，不再轮询）。
/// - M43b：OrderInFlight 包装（拉取请求）；
/// - M44h：执行器自身的重算任务（关闭记录变化后的 republishSoon）。
extension FollowupIos0713PendingTrackTests {
    func test_fuios0713_final_pendingWhenIdleCoversFetchAndRepublish() async throws {
        for route in Self.routes {
            let tag = "\(route) 完成信号"
            let wired = wire(tag)
            let page = try open(wired, route)
            jumpOut(wired, page)
            AppScenePhases.apply(.active, wired.targets)
            let current = try service(wired, page)
            await current.whenIdle()
            let shown = current.state.cards
            XCTAssertEqual(shown.map(\.linkId), ["L-A"], "\(tag)：whenIdle 返回时拉取结果已显示")
            let card = try XCTUnwrap(shown.first)
            wired.orders.hub.markClosed(card.key)
            await current.whenIdle()
            XCTAssertTrue(current.state.cards.isEmpty, "\(tag)：whenIdle 返回时关闭记录变化已重算显示")
        }
    }
}
