@testable import OrderCore
import XCTest

/// FU-IOS-0712 第 1 轮修复（编排追加 F-X-19，模拟器实走发现）：订单列表冷启动恢复时只有第一页、目标卡在第一页末尾，直接对齐会被列表底部
/// 截住，落到前两张。目标之后不够一屏（`tailCards`）且还能翻页时先翻页，到够或到底再一次对齐；翻页在途时等。
@MainActor
final class OrderAnchorTailFixR1Tests: XCTestCase {
    private func summary(_ id: String) -> OrderSummary {
        OrderSummary(
            orderId: id, platform: "taobao", title: "t", imageUrl: nil, payAmountFen: 100, quantity: 1,
            orderNo: "37" + id, maskedOrderNo: nil, displayStatusRaw: "PAID", reason: nil, estRebateFen: 1, paidAt: nil,
            isOtherProduct: false, actualFen: nil, clawbackFen: nil
        )
    }

    func testTargetNearTheEndOfTheFirstPageLoadsMoreBeforeAligning() {
        let keeper = OrderAnchorKeeper()
        keeper.begin(target: "o5")
        var snapshot = OrderListSnapshot(query: .initial(nil))
        snapshot.phase = .content
        snapshot.items = (1...5).map { summary("o\($0)") }
        snapshot.nextCursor = "page-1"
        XCTAssertEqual(keeper.step(snapshot), .loadMore, "目标之后不够一屏、还能翻页：先翻页")
        snapshot.loadingMore = true
        XCTAssertEqual(keeper.step(snapshot), .none, "翻页在途：等")
        snapshot.loadingMore = false
        snapshot.items += (6...10).map { summary("o\($0)") }
        snapshot.nextCursor = "page-2"
        XCTAssertEqual(keeper.step(snapshot), .loadMore, "仍不够 \(OrderAnchorKeeper.tailCards) 张：再翻")
        snapshot.items += (11...12).map { summary("o\($0)") }
        snapshot.nextCursor = nil
        guard case let .align(id, _) = keeper.step(snapshot) else {
            return XCTFail("到底：一次对齐")
        }
        XCTAssertEqual(id, "o5")
        XCTAssertEqual(keeper.moves, 0, "对齐在复核后才算挪动")
    }

    func testEnoughCardsAfterTheTargetAlignsWithoutPaging() {
        let keeper = OrderAnchorKeeper()
        keeper.begin(target: "o2")
        var snapshot = OrderListSnapshot(query: .initial(nil))
        snapshot.phase = .content
        snapshot.items = (1...(3 + OrderAnchorKeeper.tailCards)).map { summary("o\($0)") }
        snapshot.nextCursor = "page-1"
        guard case .align = keeper.step(snapshot) else {
            return XCTFail("目标之后已够一屏：直接对齐，不多翻")
        }
    }
}
