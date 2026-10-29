@testable import Couli
import Foundation
import OrderCore
import UIKit
import XCTest

/// b 组宿主自证（当前产品上应全绿）：详情页确实经 Router 推入、生产执行器只发一次 getOrder 拿到 visualOrders 的报文；
/// 断网缓存造法可用（09:30 缓存、10:30 显示）；挂住 / 错误回答可让页面停在加载 / 错误态。红灯因此不是宿主问题。
@MainActor
final class OrderDetailVisualOracleTests: OrderVisualTestCase {
    private func controller(_ page: OrderVisualHost) -> OrderDetailController? {
        page.orders.details.values.compactMap(\.controller).first
    }

    func testHostRendersRealDetailFromVisualFixture() async throws {
        let detail = try OrderVisualData.detail("detail_estimated")
        let page = try fresh(OrderVisualStub.Script(details: ["C": .data(detail)]))
        try await page.showDetail("C")
        _ = await page.stable { host, _ in
            host.orders.details.values.contains { $0.controller?.snapshot.phase == .content }
        }
        XCTAssertEqual(page.fixture.routing.router.path.last?.route, "OrderDetail", "经 Router 推入")
        XCTAssertEqual(OrderVisualStub.orderRequests.map(\.line), ["GET /v1/orders/C"], "只发一次 getOrder")
        let snapshot = try XCTUnwrap(controller(page)?.snapshot)
        XCTAssertEqual(snapshot.detail?.summary.orderId, "C")
        XCTAssertEqual(snapshot.detail?.summary.displayStatus, .waiting)
        XCTAssertEqual(snapshot.detail?.expectedCreditPeriod, "2026-10")
    }

    func testPrepareStaleReachesDetailStaleCache() async throws {
        let detail = try OrderVisualData.detail("detail_estimated")
        let page = try fresh(OrderVisualStub.Script(details: ["C": .data(detail)]))
        try await page.showDetail("C")
        try await page.prepareStale()
        _ = await page.stable { host, _ in
            host.orders.details.values.contains { $0.controller?.snapshot.phase == .stale }
        }
        let snapshot = try XCTUnwrap(page.orders.details.values.compactMap(\.controller)
            .first { $0.snapshot.phase == .stale }?.snapshot, "详情进断网缓存态")
        XCTAssertEqual(snapshot.staleAt, try OrderVisualData.staleAtMillis(), "缓存时刻 09:30")
        XCTAssertEqual(snapshot.detail?.summary.orderId, "C")
    }

    func testHoldAndErrorRepliesReachLoadingAndErrorPhases() async throws {
        for (reply, phase) in [(OrderVisualStub.Reply.hold, OrderDetailPhase.loading), (.error(50001), .error),
                               (.error(30701), .empty)] {
            let page = try fresh(OrderVisualStub.Script(details: ["C": reply]))
            try await page.showDetail("C")
            _ = await page.stable { host, _ in
                host.orders.details.values.contains { $0.controller?.snapshot.phase == phase }
            }
            XCTAssertEqual(controller(page)?.snapshot.phase, phase)
        }
    }
}
