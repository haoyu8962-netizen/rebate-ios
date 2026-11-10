import XCTest

/// FU-IOS-NATIVE-TABBAR 测试 v6（评审 r1 S1-1；编排 11-10 08:44，notices 第 12097 行）：订单列表恢复对齐之后的「补对齐」
/// （`OrdersScreen.settleRestore`：对齐后 2 秒内列表回到顶部就按同一目标再对齐一次）不能和用户抢滚动——
/// 用户在这 2 秒内自己回到顶部（真拖 / 点状态栏回顶），2 秒后列表仍在顶部，不被拉回目标；Tab 切回订单（非冷启动）同样不抢。
/// 「恢复后被系统重置回顶 → 补对齐到目标」由 OrdersProcessRestoreTests.testColdStartOpensOrdersTabRestoredToAnchor 守（保留不动）。
/// v7：取消逻辑本身（m13 / m14）由进程内用例 AppTests/OrdersRestoreSettleSequenceTests 直接驱动位置序列钉住；本文件是真机手势的端到端补充。
///
/// 时间前提：补对齐窗口是对齐后 2 秒，用户动作必须在窗口里到顶，否则测不出抢滚动。用例在看到恢复到锚点后立即动手（一次快速甩动或
/// 一次点状态栏），并记下「看到锚点 → 到顶」用时；超过 1.8 秒判前提不成立（明确失败、提示重跑），不当作通过。
@MainActor
final class OrdersRestoreYieldsToUserTests: XCTestCase, TradeUITest {
    private let first = "order.card.ord-3741234567890123456"
    private let arguments = ["-CouliStartTab", "orders", "-CouliFakeOrdersKeepState"]

    override func setUp() async throws {
        continueAfterFailure = false
    }

    override func tearDown() async throws {
        resetFakeSession()
    }

    /// 1. 冷启动恢复到锚点后立即真拖回顶部（v7：一次快甩到不了顶，实现 r5 实测）：第一次甩动后 2.5 秒内锚点没有被拉回视口顶部；
    /// 再甩到顶为止（总共最多 3 次），到顶后仍在顶部。
    func testColdRestoreThenDragToTopIsNotPulledBack() {
        let (app, anchor) = coldRestored()
        flingUntilTopAndHold(app, since: Date(), anchor: anchor, how: "真拖")
    }

    /// 2. 冷启动恢复到锚点后立即点状态栏回顶：2 秒后仍在顶部。
    /// XCUI 点不到系统状态栏这个元素（它属于 SpringBoard）；按坐标点窗口顶边状态栏区域，与用户点状态栏同一条系统回顶路径
    /// （UIScrollView scrollsToTop）。若这一下根本没回顶，判「回顶方式在本机不生效」并失败，不当作通过。
    func testColdRestoreThenStatusBarTapToTopIsNotPulledBack() {
        let (app, anchor) = coldRestored()
        let seen = Date()
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0)).withOffset(CGVector(dx: 0, dy: 12)).tap()
        assertStaysAtTop(app, since: seen, anchor: anchor, how: "点状态栏回顶")
    }

    /// 3. Tab 切回订单（非冷启动，列表重建后做一次性顶对齐）后立即真拖回顶部：2 秒后仍在顶部。
    func testTabSwitchBackThenDragToTopIsNotPulledBack() {
        let app = launch(["-CouliStartTab", "orders"])
        XCTAssertTrue(element(app, first).waitForExistence(timeout: 30), "订单列表出现")
        let anchor = scrollAway(app)
        ShellTabBar.tap(app, "首页")
        XCTAssertTrue(element(app, "orders.list").waitForNonExistence(timeout: 10), "已切到首页")
        ShellTabBar.tap(app, "订单")
        XCTAssertTrue(element(app, "orders.list").waitForExistence(timeout: 10), "切回订单 Tab")
        // v7：切回后列表保持原位、不做顶对齐（实现 r5 实测），「已回原位」与 OrdersShotTests.testTabSwitchKeepsTopOrder 同口径：顶部那张卡 == 锚点
        UIWait.until("切回后顶部订单仍是原来那张（\(anchor)）", ceiling: 10) { topCard(app) == anchor }
        XCTAssertEqual(topCard(app), anchor, "前提不成立：切回后顶部订单不是原来那张")
        flingUntilTopAndHold(app, since: Date(), anchor: anchor, how: "切回 Tab 后真拖")
    }

    // MARK: - 工具

    /// 滚下去、记下顶部订单 → 进后台（等保存完成信号）→ 结束进程 → 冷启动直接进订单 Tab，等它恢复到锚点。
    private func coldRestored() -> (XCUIApplication, String) {
        let app = launch(arguments)
        XCTAssertTrue(element(app, first).waitForExistence(timeout: 30), "订单列表出现")
        let anchor = scrollAway(app)
        UIWait.pressHomeAndWaitForBackgroundSave(app)
        app.terminate()
        let restored = launch(arguments)
        XCTAssertTrue(element(restored, "orders.list").waitForExistence(timeout: 30), "冷启动直接进订单 Tab")
        waitAligned(restored, to: anchor, "冷启动后恢复到锚点")
        return (restored, anchor)
    }

    /// 上滑两次离开顶部，等滚动停下，返回视口顶部那张订单。
    private func scrollAway(_ app: XCUIApplication) -> String {
        app.swipeUp()
        app.swipeUp()
        UIWait.until("列表滚下去") { !element(app, first).isHittable }
        var before: String?
        UIWait.until("滚动停下") {
            let now = topCard(app)
            defer { before = now }
            return now != nil && now == before
        }
        let anchor = before ?? ""
        XCTAssertFalse(anchor.isEmpty)
        XCTAssertNotEqual(anchor, first, "前提：已滚离顶部")
        return anchor
    }

    /// 等锚点那张卡的顶边到列表顶边附近（只查一张卡，查询快，看到即动手）。
    private func waitAligned(_ app: XCUIApplication, to anchor: String, _ what: String) {
        let card = element(app, anchor)
        let list = element(app, "orders.list")
        UIWait.until("\(what)（\(anchor)）", ceiling: 30) {
            card.exists && abs(card.frame.minY - list.frame.minY) < 40
        }
    }

    /// 一次快速向下甩动（真拖，带惯性往顶部走）。
    private func flingToTop(_ app: XCUIApplication) {
        element(app, "orders.list").swipeDown(velocity: .fast)
    }

    /// 首张订单在视口顶部。
    private func atTop(_ app: XCUIApplication) -> Bool {
        let card = element(app, first)
        return card.exists && card.isHittable && card.frame.minY >= element(app, "orders.list").frame.minY - 1
    }

    /// v7：第一次甩动须在补对齐窗口内开始（看到锚点 → 开始甩 ≤ 1 秒，否则判前提不成立）；之后 2.5 秒每 0.25 秒取样，锚点卡不回到视口
    /// 顶部（不被拉回）。再甩到顶为止（总共最多 3 次；3 次仍不到顶判前提不成立），到顶后 1.5 秒内一直在顶部。
    private func flingUntilTopAndHold(_ app: XCUIApplication, since seen: Date, anchor: String, how: String) {
        // XCUI 的一次甩动连同前后等空闲约 2.8 秒（v7 实测），甩完必然在窗口外；前提只核「看到锚点 → 开始甩」在窗口里（≤ 1 秒）
        let elapsed = Date().timeIntervalSince(seen)
        XCTAssertLessThanOrEqual(elapsed, 1.0,
                                 "前提不成立：看到锚点到开始甩动用了 \(elapsed) 秒，补对齐窗口 2 秒，测不出抢滚动（请重跑）")
        flingToTop(app)
        let card = element(app, anchor)
        let list = element(app, "orders.list")
        var samples: [String] = []
        let deadline = Date().addingTimeInterval(2.5)
        while Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
            let back = card.exists && abs(card.frame.minY - list.frame.minY) < 40
            samples.append(back ? "锚点在顶" : "离开")
            XCTAssertFalse(back, "\(how)第一次甩动后被拉回锚点（\(anchor)）：补对齐与用户抢滚动；取样 \(samples)")
        }
        var flings = 1
        while !atTop(app), flings < 3 {
            flingToTop(app)
            flings += 1
            // 等惯性停下（只是间隔，不作判据；到没到顶由下面判）
            RunLoop.current.run(until: Date().addingTimeInterval(1.2))
        }
        XCTAssertTrue(atTop(app), "前提不成立：\(how)甩了 \(flings) 次仍没到顶")
        let hold = Date().addingTimeInterval(1.5)
        samples = []
        while Date() < hold {
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
            let top = atTop(app)
            samples.append(top ? "顶" : "离顶")
            XCTAssertTrue(top, "\(how)到顶后被拉回：取样 \(samples)")
        }
    }

    /// 到顶（首张订单在视口顶部）的用时须在补对齐窗口里；之后观察 2.5 秒，首张订单一直在顶部、锚点卡没被拉回顶部。
    private func assertStaysAtTop(_ app: XCUIApplication, since seen: Date, anchor: String, how: String) {
        let card = element(app, first)
        let list = element(app, "orders.list")
        let atTop = { card.exists && card.isHittable && card.frame.minY >= list.frame.minY - 1 }
        XCTAssertTrue(UIWait.until("\(how)后列表到顶（首张订单在视口顶部）", ceiling: 5, atTop),
                      "\(how)没有回到顶部：回顶方式在本机不生效或没拖到顶")
        let elapsed = Date().timeIntervalSince(seen)
        XCTAssertLessThanOrEqual(elapsed, 1.8,
                                 "前提不成立：看到锚点到回顶用了 \(elapsed) 秒，已超出 2 秒补对齐窗口，测不出抢滚动（请重跑）")
        let deadline = Date().addingTimeInterval(2.5)
        var samples: [String] = []
        while Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
            let top = atTop()
            samples.append(top ? "顶" : "离顶")
            XCTAssertTrue(top, "\(how)回到顶部后被拉回原目标（\(anchor)）：补对齐与用户抢滚动；取样 \(samples)")
        }
    }

    /// 视口里最上面那张订单卡（底边在列表顶边以下的第一张）。
    private func topCard(_ app: XCUIApplication) -> String? {
        let listTop = element(app, "orders.list").frame.minY
        let cards = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'order.card.ord-'")).allElementsBoundByIndex
        return cards.filter { $0.frame.maxY > listTop + 1 && !$0.frame.isEmpty }
            .min { $0.frame.minY < $1.frame.minY }?.identifier
    }
}
