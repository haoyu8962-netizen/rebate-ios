import XCTest

/// APP-06v-b 测试 b v2：独立评审 r1 的用例缺口（S1-1、S1-2、S2-1、S2-2、S2-4、S2-5、S2-8）。真实 App + DebugFakeTrade 场景，
/// 请求 / 路由 / 播报读 `debug.purchase.log`（见 PurchaseVisualLog）。先真点，再看记录；判据只加不放。
@MainActor
final class PurchaseVisualReviewR1UITests: XCTestCase, ProductVisualUITest {
    override func setUp() async throws {
        continueAfterFailure = false
    }

    private func launch(_ link: String, _ id: String = "tb_coupon_range", extra: [String] = []) throws
        -> XCUIApplication {
        try launchProduct(
            visualCard(id, overrides: ["link_id": link]),
            extra: extra
        )
    }

    private func buy(_ app: XCUIApplication) {
        node(app, "product.buy").tap()
    }

    private func waitLog(_ app: XCUIApplication, seconds: TimeInterval = 5,
                         until done: (PurchaseVisualLog) -> Bool) throws -> PurchaseVisualLog {
        let end = Date().addingTimeInterval(seconds)
        var log = try PurchaseVisualLog.read(app)
        while !done(log), Date() < end {
            Thread.sleep(forTimeInterval: 0.2)
            log = try PurchaseVisualLog.read(app)
        }
        return log
    }

    // MARK: - S1-2 资金按钮：【仍去购买（无返利）】必须发 no_rebate=true 的新 open

    func testNoRebateButtonsSendNoRebateOpen() throws {
        for scenario in ["t-blocked", "t-norebate", "t-rebind", "t-503"] {
            let app = try launch(scenario)
            buy(app)
            let notice = node(app, "purchase.notice")
            XCTAssertTrue(notice.waitForExistence(timeout: 10), "\(scenario) 没有弹窗")
            var log = try PurchaseVisualLog.read(app)
            XCTAssertEqual(log.opens.count, 1, "\(scenario)：首次 open 一次")
            XCTAssertEqual(log.opens.first?.noRebate, false, "\(scenario)：首次 open 不带 no_rebate")
            notice.buttons["仍去购买（无返利）"].tap()
            log = try waitLog(app) { $0.opens.count >= 2 }
            XCTAssertEqual(log.opens.count, 2, "\(scenario)：无返利按钮恰好再发一次 open")
            XCTAssertEqual(log.opens.last?.noRebate, true, "\(scenario)：第二次 open 必须带 no_rebate=true（不是有返利重试）")
            XCTAssertFalse(log.routes.contains("Help"), "\(scenario)：无返利按钮不进客服")
            app.terminate()
        }
    }

    /// 比价确认的次按钮接 `confirm`：沿用本次尝试的方案外跳（不再发 open，所以没有第二个请求可带 no_rebate），不去搜索页。
    func testCompareSecondaryConfirmsExistingAttemptOnly() throws {
        let app = try launch("t-compare", "pdd_coupon", extra: ["-CouliFakePlatformStatus", "pdd=on"])
        buy(app)
        let dialog = node(app, "purchase.compare")
        XCTAssertTrue(dialog.waitForExistence(timeout: 10), "没有比价确认")
        dialog.buttons["仍去购买（无返利）"].tap()
        let log = try waitLog(app) { !$0.jumps.isEmpty }
        XCTAssertEqual(log.opens.count, 1, "次按钮不再发 open（比价结果本身就是无返利方案）")
        XCTAssertEqual(log.jumps.count, 1, "按本次方案外跳恰好一次")
        XCTAssertFalse(log.routes.contains("Search"), "次按钮不去搜索（不是【看看相似商品】）")
        XCTAssertFalse(dialog.exists, "弹窗已关")
    }

    /// 「查看说明」：只打开配置的说明文章，不外跳、不发 open、不去搜索；弹窗本身不当作确认。
    func testCompareExplainOpensArticleOnly() throws {
        let app = try launch("t-compare", "pdd_coupon", extra: ["-CouliFakePlatformStatus", "pdd=on"])
        buy(app)
        let dialog = node(app, "purchase.compare")
        XCTAssertTrue(dialog.waitForExistence(timeout: 10), "没有比价确认")
        let link = dialog.links["查看说明"].firstMatch
        XCTAssertTrue(link.waitForExistence(timeout: 3), "假服务配置了比价说明文章时要有行内「查看说明」链接")
        link.tap()
        let log = try waitLog(app) { !$0.routes.isEmpty }
        XCTAssertEqual(log.routes.first, "Help", "「查看说明」打开帮助文章路由")
        XCTAssertEqual(log.opens.count, 1, "不发新 open")
        XCTAssertTrue(log.jumps.isEmpty, "不外跳")
        XCTAssertFalse(log.routes.contains("Search"), "不去搜索")
    }

    /// 【联系客服】：进客服（Help），不发 open、不外跳。
    func testContactServiceOpensHelpOnly() throws {
        for scenario in ["t-blocked", "t-norebate", "t-rebind"] {
            let app = try launch(scenario)
            buy(app)
            let notice = node(app, "purchase.notice")
            XCTAssertTrue(notice.waitForExistence(timeout: 10), "\(scenario) 没有弹窗")
            notice.buttons["联系客服"].tap()
            let log = try waitLog(app) { !$0.routes.isEmpty }
            XCTAssertEqual(log.routes, ["Help"], "\(scenario)：【联系客服】只进客服")
            XCTAssertEqual(log.opens.count, 1, "\(scenario)：不发新 open")
            XCTAssertTrue(log.jumps.isEmpty, "\(scenario)：不外跳")
            XCTAssertFalse(notice.exists, "\(scenario)：弹窗已关")
            app.terminate()
        }
    }

    // MARK: - S1-1 搜索页没有常驻说明行：未安装淘宝时仍要给合并句

    func testSearchListTaobaoNotInstalledKeepsMergedHint() throws {
        let app = try launch("visual-link", extra: ["-CouliFakeInstalled", "taobao=false"])
        app.buttons["返回"].firstMatch.tap()
        let card = node(app, "search.card.0")
        XCTAssertTrue(card.waitForExistence(timeout: 10), "回到搜索结果")
        let buttons = card.buttons.matching(NSPredicate(format: "NOT (label CONTAINS %@)", "说明"))
        buttons.element(boundBy: max(0, buttons.count - 1)).tap()
        let merged = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "安装淘宝后下单才有返利，口令已复制"))
        XCTAssertTrue(merged.firstMatch.waitForExistence(timeout: 10),
                      "搜索页没有常驻说明行：提示仍是合并句「安装淘宝后下单才有返利，口令已复制」")
    }

    // MARK: - S2-4 G-I01 两个方向

    func testCancelButtonG_I01BothDirections() throws {
        for (scenario, hasCancel) in [("t-503", false), ("t-blocked", true), ("t-norebate", true), ("t-rebind", true)] {
            let app = try launch(scenario)
            buy(app)
            let notice = node(app, "purchase.notice")
            XCTAssertTrue(notice.waitForExistence(timeout: 10), "\(scenario) 没有弹窗")
            XCTAssertEqual(notice.buttons["取消"].exists, hasCancel,
                           "\(scenario)：G-I01 \(hasCancel ? "保留【取消】" : "50303 去掉【取消】（「稍后再试」已是关闭）")")
            app.terminate()
        }
    }

    // MARK: - S2-1 轻提示在导航栏之下

    func testToastSitsBelowNavigationBar() throws {
        let app = try launch("t-price")
        buy(app)
        XCTAssertTrue(node(app, "purchase.priceChanged").waitForExistence(timeout: 10), "没有改价确认")
        node(app, "purchase.dialog.cancel").tap()
        let toast = app.staticTexts["已取消购买，价格已更新为最新"].firstMatch
        XCTAssertTrue(toast.waitForExistence(timeout: 5), "取消后轻提示")
        let back = app.buttons["返回"].firstMatch
        let title = app.staticTexts["商品详情"].firstMatch
        let navBottom = max(back.frame.maxY, title.frame.maxY)
        XCTAssertGreaterThanOrEqual(toast.frame.minY, navBottom, "轻提示的框不得与导航栏重叠（画板：导航栏下约 8）")
    }

    // MARK: - S2-2 下单须知没有右上关闭

    func testJumpTipHasNoCloseButton() throws {
        let app = try launch("visual-link", extra: [Self.tipsUnread])
        buy(app)
        let tip = node(app, "purchase.jumpTip")
        XCTAssertTrue(tip.waitForExistence(timeout: 10), "没有下单须知")
        XCTAssertFalse(tip.buttons["关闭"].exists, "下单须知不再有右上关闭（画板 / Android 同；关闭方式为遮罩、下滑、读屏擦除）")
        XCTAssertTrue(tip.buttons["知道了，去淘宝"].exists, "通栏【知道了，去淘宝】")
    }

    // MARK: - S2-5 / S2-8 下架：搜索卡状态读在购买按钮之前；礼貌播报只一次

    func testSearchOffShelfStatusIsReadBeforeBuyAndAnnouncedOnce() throws {
        let app = try launch("t-offshelf")
        app.buttons["返回"].firstMatch.tap()
        let card = node(app, "search.card.0")
        XCTAssertTrue(card.waitForExistence(timeout: 10), "回到搜索结果")
        let buttons = card.buttons.matching(NSPredicate(format: "NOT (label CONTAINS %@)", "说明"))
        buttons.element(boundBy: max(0, buttons.count - 1)).tap()
        let status = app.descendants(matching: .any).containing(NSPredicate(format: "label CONTAINS %@", "商品已下架"))
        XCTAssertTrue(status.firstMatch.waitForExistence(timeout: 10), "列表卡下架后可读「商品已下架」")
        let items = try readingOrder(app)
        keep(items, "search-off-shelf-order")
        let statusIndex = try XCTUnwrap(items.firstIndex { $0.label.contains("商品已下架") })
        let buyIndex = try XCTUnwrap(items.firstIndex { $0.type == .button && $0.label.hasPrefix("领券购买") },
                                     "找不到列表卡购买按钮")
        XCTAssertLessThan(statusIndex, buyIndex, "「商品已下架」读在购买按钮之前")
        Thread.sleep(forTimeInterval: 2)
        let log = try PurchaseVisualLog.read(app)
        XCTAssertEqual(log.announcements.filter { $0.contains("商品已下架") }.count, 1, "下架礼貌播报只播一次")
    }

    func testDetailOffShelfAnnouncedOnce() throws {
        let app = try launch("t-offshelf")
        buy(app)
        let capsule = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "商品已下架"))
        XCTAssertTrue(capsule.firstMatch.waitForExistence(timeout: 10), "详情卡原位置灰")
        Thread.sleep(forTimeInterval: 2)
        var log = try PurchaseVisualLog.read(app)
        XCTAssertEqual(log.announcements.filter { $0.contains("商品已下架") }.count, 1, "变成下架时礼貌播报恰好一次")
        node(app, "product.buy").tap()
        Thread.sleep(forTimeInterval: 1.5)
        log = try PurchaseVisualLog.read(app)
        XCTAssertEqual(log.announcements.filter { $0.contains("商品已下架") }.count, 1, "已是下架时不再播")
        XCTAssertEqual(log.opens.count, 1, "下架卡再点不发 open")
    }
}
