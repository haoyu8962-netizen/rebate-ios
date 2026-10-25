import XCTest

/// APP-06v-b 购买浮层（资金 / 归属页）：真实 App + DebugFakeTrade 既有场景（注入 visualCards 卡、把 link_id 换成场景名）。
/// 每条先真点、看回调效果（是否发新 open = 加载层是否出现、是否外跳 / 去搜索），再看主次外观；外观像素取按钮内左缘一点。
/// Android 评审抓过的：50303「稍后再试」只关弹窗、再点购买才发 open；去掉下架 toast 后搜索入口也要有可读的「商品已下架」；
/// 30153 类主【联系客服】次【仍去购买（无返利）】；比价改居中弹窗、主【看看相似商品】。
@MainActor
final class PurchaseVisualUITests: XCTestCase, ProductVisualUITest {
    private func card(_ link: String, _ id: String = "tb_coupon_range") throws -> [String: Any] {
        try visualCard(id, overrides: ["link_id": link])
    }

    private func buy(_ app: XCUIApplication) {
        node(app, "product.buy").tap()
    }

    /// b v2（T1）：等弹窗完全不透明（按钮可点 + 连续两帧颜色一致）再取色，判据见 PurchaseVisualButtonPixels。
    private func isBrand(_ app: XCUIApplication, _ element: XCUIElement, file: StaticString = #filePath,
                         line: UInt = #line) -> Bool {
        PurchaseVisualButtonPixels.isBrand(PurchaseVisualButtonPixels.stableFill(app, element, file: file, line: line))
    }

    /// 等待期内某元素始终不出现。
    private func stays(absent element: XCUIElement, for seconds: TimeInterval) -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if element.exists {
                return false
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return true
    }

    // MARK: - G-D09（50303）

    func test50303RetryLaterOnlyClosesAndNextBuySendsNewOpen() throws {
        let app = try launchProduct(card("t-503"))
        buy(app)
        let notice = node(app, "purchase.notice")
        XCTAssertTrue(notice.waitForExistence(timeout: 10), "50303 没有弹窗")
        let later = notice.buttons["稍后再试"]
        XCTAssertTrue(later.exists, "主按钮文字「稍后再试」（card.retry_later）")
        XCTAssertFalse(notice.buttons["重试"].exists, "不再是「重试」")
        let noRebate = notice.buttons["仍去购买（无返利）"]
        XCTAssertTrue(noRebate.exists, "次按钮【仍去购买（无返利）】")
        XCTAssertLessThan(later.frame.minY, noRebate.frame.minY, "纵排：主在上")
        XCTAssertTrue(isBrand(app, later), "「稍后再试」是主按钮（品牌色底）")
        XCTAssertFalse(isBrand(app, noRebate), "【仍去购买（无返利）】是次按钮")
        later.tap()
        XCTAssertTrue(stays(absent: node(app, "purchase.opening"), for: 2.5), "「稍后再试」不能立即重发 open（不出加载层）")
        XCTAssertFalse(notice.exists, "弹窗已关、留在详情页")
        buy(app)
        XCTAssertTrue(node(app, "purchase.opening").waitForExistence(timeout: 5), "再点购买才发新一次 open")
        XCTAssertTrue(notice.waitForExistence(timeout: 10), "新一次 open 仍回 50303")
        notice.buttons["仍去购买（无返利）"].tap()
        XCTAssertTrue(node(app, "purchase.opening").waitForExistence(timeout: 5), "无返利购买发 open")
    }

    // MARK: - G-D08（30153 / 30103 / 30151；b v2 T3 补 30151 = 假服务 t-rebind）

    func testBlockedNoticePrimaryContactSecondaryNoRebate() throws {
        for scenario in ["t-blocked", "t-norebate", "t-rebind"] {
            let app = try launchProduct(card(scenario))
            buy(app)
            let notice = node(app, "purchase.notice")
            XCTAssertTrue(notice.waitForExistence(timeout: 10), "\(scenario) 没有弹窗")
            let contact = notice.buttons["联系客服"]
            let noRebate = notice.buttons["仍去购买（无返利）"]
            XCTAssertTrue(contact.exists && noRebate.exists, "\(scenario)：两个按钮都在")
            XCTAssertLessThan(contact.frame.minY, noRebate.frame.minY, "\(scenario)：纵排，【联系客服】在上")
            XCTAssertTrue(isBrand(app, contact), "\(scenario)：【联系客服】是主按钮")
            XCTAssertFalse(isBrand(app, noRebate), "\(scenario)：【仍去购买（无返利）】是次按钮")
            XCTAssertFalse(notice.buttons["关闭"].exists, "无右上关闭")
            noRebate.tap()
            XCTAssertTrue(node(app, "purchase.opening").waitForExistence(timeout: 5), "\(scenario)：次按钮回调不变（无返利 open）")
            app.terminate()
        }
    }

    // MARK: - G-D10（比价无返利确认）

    func testCompareConfirmIsCenteredDialogWithSimilarPrimary() throws {
        let extra = ["-CouliFakePlatformStatus", "pdd=on"]
        var app = try launchProduct(card("t-compare", "pdd_coupon"), extra: extra)
        buy(app)
        let dialog = node(app, "purchase.compare")
        XCTAssertTrue(dialog.waitForExistence(timeout: 10), "没有比价确认")
        XCTAssertLessThan(abs(dialog.frame.midY - app.frame.midY), 80, "居中弹窗，不是贴底半屏")
        let similar = dialog.buttons["看看相似商品"]
        let buyAnyway = dialog.buttons["仍去购买（无返利）"]
        XCTAssertLessThan(similar.frame.minY, buyAnyway.frame.minY, "主【看看相似商品】在上")
        XCTAssertTrue(isBrand(app, similar), "【看看相似商品】是主按钮")
        let close = dialog.buttons["关闭"]
        XCTAssertTrue(close.exists, "右上关闭")
        XCTAssertGreaterThan(close.frame.midX, dialog.frame.midX, "关闭在右侧")
        similar.tap()
        let field = app.textFields["search.field"]
        XCTAssertTrue(field.waitForExistence(timeout: 10), "主按钮 → 同平台原样标题去搜索（similar 回调不变）")
        XCTAssertEqual(field.value as? String, "云朵柔 抽纸 3 层 × 120 抽 24 包 家用整箱")
        app.terminate()

        app = try launchProduct(card("t-compare", "pdd_coupon"), extra: extra)
        buy(app)
        XCTAssertTrue(node(app, "purchase.compare").waitForExistence(timeout: 10))
        node(app, "purchase.compare").buttons["关闭"].tap()
        XCTAssertTrue(node(app, "product.compareReason").waitForExistence(timeout: 5), "关闭 → 留在详情、卡内出原因行")
        XCTAssertFalse(node(app, "purchase.opening").exists, "关闭不外跳")
    }

    // MARK: - G-D07（下架：详情与搜索列表都不出 toast，卡上可读「商品已下架」）

    func testOffShelfAfterOpenHasNoToastOnDetailAndSearchList() throws {
        var app = try launchProduct(card("t-offshelf"))
        buy(app)
        let capsule = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "商品已下架"))
        XCTAssertTrue(capsule.firstMatch.waitForExistence(timeout: 10), "详情卡原位置灰，可读「商品已下架」")
        Thread.sleep(forTimeInterval: 1.0)
        XCTAssertEqual(capsule.count, 1, "只有卡上的状态，没有另一条「商品已下架」轻提示")
        XCTAssertFalse(node(app, "product.buy").isEnabled, "按钮置灰")
        app.terminate()

        app = try launchProduct(card("t-offshelf"))
        app.buttons["返回"].firstMatch.tap()
        let listCard = node(app, "search.card.0")
        XCTAssertTrue(listCard.waitForExistence(timeout: 10))
        let listBuy = listCard.buttons.matching(NSPredicate(format: "NOT (label CONTAINS %@)", "说明"))
        listBuy.element(boundBy: max(0, listBuy.count - 1)).tap()
        let state = app.descendants(matching: .any).containing(NSPredicate(format: "label CONTAINS %@", "商品已下架"))
        XCTAssertTrue(state.firstMatch.waitForExistence(timeout: 10), "搜索列表卡下架后也要可读「商品已下架」（Android 评审 b r1 S2-1）")
        XCTAssertFalse(node(app, "purchase.opening").exists)
    }

    // MARK: - G-D11（未安装淘宝）

    func testTaobaoNotInstalledShowsBannerCopyButtonAndCopiedToast() throws {
        var app = try launchProduct(card("visual-link"), extra: ["-CouliFakeInstalled", "taobao=false"])
        buy(app)
        let banner = node(app, "purchase.notInstalled")
        XCTAssertTrue(banner.waitForExistence(timeout: 10), "底栏上方常驻说明行")
        XCTAssertTrue(banner.label.contains("安装淘宝后下单才有返利"), "说明行文字：\(banner.label)")
        XCTAssertTrue(app.staticTexts["已复制淘口令"].waitForExistence(timeout: 5), "复制成功轻提示「已复制淘口令」")
        let buyButton = node(app, "product.buy")
        XCTAssertTrue(buyButton.label.hasPrefix("复制淘口令"), "主按钮【复制淘口令】：\(buyButton.label)")
        XCTAssertLessThan(banner.frame.maxY, buyButton.frame.minY + 1, "说明行在主按钮上方")
        Thread.sleep(forTimeInterval: 2.5)
        XCTAssertTrue(banner.exists, "轻提示消失后说明行仍在（常驻）")
        app.terminate()

        app = try launchProduct(card("t-noinst"), extra: ["-CouliFakeInstalled", "taobao=false"])
        buy(app)
        Thread.sleep(forTimeInterval: 2.0)
        XCTAssertFalse(node(app, "product.buy").label.hasPrefix("复制淘口令"), "没有口令步骤：不能出【复制淘口令】")
        XCTAssertFalse(app.staticTexts["已复制淘口令"].exists, "没复制不能说已复制")
    }
}
