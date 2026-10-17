import XCTest

/// FU-IOS-0712 第 1 轮修复（编排追加 F-X-19）：冷启动 → 打开订单 Tab 恢复到锚点。订单列表滚下去 → 进后台（等保存完成信号）→ 进程被结束 →
/// 以同一次假登录冷启动直接进订单 Tab：冷启动期间的启动态变化不被当作会话变化，恢复记录不被误删，视口顶部回到原来那张订单。
@MainActor
final class OrdersProcessRestoreTests: XCTestCase, TradeUITest {
    override func setUp() async throws {
        continueAfterFailure = false
    }

    override func tearDown() async throws {
        resetFakeSession()
    }

    private let arguments = ["-CouliStartTab", "orders", "-CouliFakeOrdersKeepState"]

    /// 视口里最上面那张订单卡（底边在列表顶边以下的第一张）。
    private func topCard(_ app: XCUIApplication) -> String? {
        let listTop = element(app, "orders.list").frame.minY
        let cards = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'order.card.ord-'")).allElementsBoundByIndex
        return cards.filter { $0.frame.maxY > listTop + 1 && !$0.frame.isEmpty }
            .min { $0.frame.minY < $1.frame.minY }?.identifier
    }

    func testColdStartOpensOrdersTabRestoredToAnchor() {
        let first = "order.card.ord-3741234567890123456"
        let app = launch(arguments)
        XCTAssertTrue(element(app, first).waitForExistence(timeout: 30), "订单列表出现")
        app.swipeUp()
        app.swipeUp()
        UIWait.until("列表滚下去") { !element(app, first).isHittable }
        var before: String?
        UIWait.until("滚动停下") {
            let now = topCard(app)
            defer { before = now }
            return now != nil && now == before
        }
        let anchor = try? XCTUnwrap(before)
        XCTAssertNotEqual(anchor, first, "前提：已滚离顶部")
        UIWait.pressHomeAndWaitForBackgroundSave(app)
        app.terminate()

        let restored = launch(arguments)
        XCTAssertTrue(element(restored, "orders.list").waitForExistence(timeout: 30), "冷启动直接进订单 Tab")
        UIWait.until("回到原来那张顶部订单（\(anchor ?? "-")）") { topCard(restored) == anchor }
        XCTAssertEqual(topCard(restored), anchor, "冷启动后恢复到锚点，不是列表顶部")
        restored.terminate()
    }
}
