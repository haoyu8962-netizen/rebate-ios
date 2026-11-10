import XCTest

/// APP-08 订单页的界面冒烟与设计稿比对截图（Debug 包 + 本机假服务 DebugFakeOrders）。截图用例只在设置 TEST_RUNNER_COULI_SHOT_DIR 时跑，
/// 写到 NATIVE/APP-08/shots/ios/。全部假数据（样例订单号，没有个人信息）。
@MainActor
final class OrdersShotTests: XCTestCase, TradeUITest {
    override func setUp() async throws {
        continueAfterFailure = false
    }

    override func tearDown() async throws {
        resetFakeSession()
    }

    private func openOrders(_ extra: [String] = []) -> XCUIApplication {
        // 冷启动直接切到订单 Tab（窄屏截图时首页布局会挡住 Tab 栏）
        let app = launch(["-CouliStartTab", "orders"] + extra)
        XCTAssertTrue(element(app, "order.card.ord-3741234567890123456").waitForExistence(timeout: 15)
            || element(app, "orders.empty.self").waitForExistence(timeout: 2)
            || element(app, "orders.stale").waitForExistence(timeout: 2)
            || element(app, "orders.error").waitForExistence(timeout: 2), "没有进订单页")
        return app
    }

    private func pause(_ seconds: TimeInterval = 0.8) {
        Thread.sleep(forTimeInterval: seconds)
    }

    private func openDetail(_ app: XCUIApplication, number: String) {
        let field = app.textFields["orders.search"]
        field.tap()
        field.typeText(number + "\n")
        let card = element(app, "order.card.ord-\(number)")
        XCTAssertTrue(card.waitForExistence(timeout: 10), "没有搜到 \(number)")
        card.staticTexts.firstMatch.tap()
        XCTAssertTrue(element(app, "orderDetail.product").waitForExistence(timeout: 10), "没有进详情")
        pause()
    }

    // MARK: - 冒烟（verify 每次都跑）

    /// 订单 Tab：列表出现；分享单只有脱敏号、没有【复制】；进详情再返回，筛选与搜索词保留。
    func testOrdersSmoke() {
        let app = openOrders()
        XCTAssertTrue(element(app, "order.copy").exists, "自购单有【复制】")
        element(app, "orders.tab.share").tap()
        XCTAssertTrue(element(app, "order.card.ord-s1").waitForExistence(timeout: 10))
        XCTAssertFalse(element(app, "order.copy").exists, "分享单没有【复制】")
        XCTAssertTrue(element(app, "order.maskedNumber").exists)
        element(app, "order.card.ord-s1").staticTexts.firstMatch.tap()
        XCTAssertTrue(element(app, "orderDetail.product").waitForExistence(timeout: 10))
        XCTAssertFalse(element(app, "order.copy").exists, "分享单详情没有【复制】")
        app.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(element(app, "order.card.ord-s1").waitForExistence(timeout: 10), "返回后仍在分享子 Tab")
    }

    /// R2-02（共性第 37 条）：订单列表滚到下面 → 切到首页 Tab → 切回订单 Tab，视口顶部那张订单不变（Tab 外壳会重建视图）。
    func testTabSwitchKeepsTopOrder() {
        let app = openOrders()
        app.swipeUp()
        app.swipeUp()
        pause(1.2)
        let before = topCard(app)
        XCTAssertNotNil(before)
        XCTAssertNotEqual(before, "order.card.ord-3741234567890123456", "前提：已滚离顶部")
        ShellTabBar.tap(app, "首页")
        pause()
        XCTAssertFalse(element(app, "orders.list").exists, "已切到首页")
        ShellTabBar.tap(app, "订单")
        XCTAssertTrue(element(app, "orders.list").waitForExistence(timeout: 10))
        pause(1.5)
        XCTAssertEqual(topCard(app), before, "切回后顶部订单不变")
    }

    /// 视口里最上面那张订单卡（底边在列表顶边以下的第一张）。
    private func topCard(_ app: XCUIApplication) -> String? {
        let listTop = element(app, "orders.list").frame.minY
        let cards = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'order.card.ord-'")).allElementsBoundByIndex
        return cards.filter { $0.frame.maxY > listTop + 1 && !$0.frame.isEmpty }
            .min { $0.frame.minY < $1.frame.minY }?.identifier
    }

    // MARK: - 截图（设计稿比对）

    func testShotsList() throws {
        try requireShots()
        var app = openOrders()
        pause()
        save(app, "Orders")
        app.swipeUp()
        pause()
        save(app, "Orders-scrolled")
        element(app, "orders.tab.share").tap()
        XCTAssertTrue(element(app, "order.card.ord-s1").waitForExistence(timeout: 10))
        pause()
        save(app, "OrdersShare")
        element(app, "orders.filter.platform").tap()
        pause()
        save(app, "OrdersFilterPlatform")
        element(app, "orders.option.taobao").tap()
        pause()
        element(app, "orders.filter.month").tap()
        pause()
        save(app, "OrdersFilterMonth")
        element(app, "orders.option.all").tap()
        pause()
        let field = app.textFields["orders.search"]
        field.tap()
        field.typeText("xyz\n")
        XCTAssertTrue(element(app, "orders.searchEmpty").waitForExistence(timeout: 10))
        pause()
        save(app, "OrdersSearchEmpty")
        app.terminate()

        app = openOrders()
        let search = app.textFields["orders.search"]
        search.tap()
        search.typeText("3741234567890123456\n")
        XCTAssertTrue(element(app, "orders.searchFound").waitForExistence(timeout: 10))
        pause()
        save(app, "OrdersSearch")
    }

    func testShotsListStates() throws {
        try requireShots()
        var app = openOrders(["-CouliFakeOrders", "empty"])
        pause()
        save(app, "OrdersEmpty")
        element(app, "orders.tab.share").tap()
        pause(1.2)
        save(app, "OrdersShareEmpty")
        app.terminate()

        app = openOrders(["-CouliFakeOrders", "pending"])
        pause(1.5)
        save(app, "Orders-withPendingTrack")
        app.terminate()

        // 先在线加载一次（写缓存），再断网冷启动：显示缓存与提示条
        app = openOrders()
        pause()
        app.terminate()
        app = openOrders(["-CouliFakeOrders", "offline"])
        XCTAssertTrue(element(app, "orders.stale").waitForExistence(timeout: 10), "断网冷启动应显示缓存")
        pause()
        save(app, "OrdersStale")
        element(app, "orders.group.credited").tap()
        XCTAssertTrue(element(app, "orders.error").waitForExistence(timeout: 10), "带筛选断网不用缓存")
        pause()
        save(app, "OrdersStale-filteredNetworkError")
    }

    func testShotsDetails() throws {
        try requireShots()
        let cases: [DetailShot] = [
            DetailShot("3741234567890123456", "OrderDetailEstimated", []),
            DetailShot("3798765432109876543", "OrderDetailPresale", []),
            DetailShot("305678901234", "OrderDetailWaiting", []),
            DetailShot("3744444444444444444", "OrderDetailSettled", []),
            DetailShot("3733333333333333333", "OrderDetailPartClawed", []),
            DetailShot("3711111111111111111", "OrderDetailSettledPriceCompare", []),
            DetailShot("306666666666", "OrderDetailClawedBack", []),
            DetailShot("3722222222222222222", "OrderDetailNoRebate", []),
            DetailShot("260920-111122223333444", "OrderDetailPriceCompareNoRebate", []),
            DetailShot("3767777777777777777", "OrderDetailReviewing", []),
            DetailShot("3755555555555555555", "OrderDetailRightsPending", []),
            DetailShot("3768888888888888888", "OrderDetailBlacklist", []),
            DetailShot("3768888888888888888", "OrderDetailAppealPending", ["-CouliFakeOrders", "appeal"]),
            DetailShot("309999999999", "OrderDetailUnknownStatus", []),
        ]
        for shot in cases {
            let app = openOrders(shot.extra)
            openDetail(app, number: shot.number)
            save(app, shot.name)
            if shot.name == "OrderDetailEstimated" {
                element(app, "order.copy").tap()
                pause(0.4)
                save(app, "OrderDetailCopyToast")
                element(app, "order.mask").tap()
                pause(0.4)
                save(app, "OrderDetailMasked")
            }
            app.terminate()
        }
        let app = openOrders()
        element(app, "orders.tab.share").tap()
        XCTAssertTrue(element(app, "order.card.ord-s2").waitForExistence(timeout: 10))
        element(app, "order.card.ord-s2").staticTexts.firstMatch.tap()
        XCTAssertTrue(element(app, "orderDetail.product").waitForExistence(timeout: 10))
        pause()
        save(app, "OrderDetailShare")
    }

    func testShotsAdapt() throws {
        try requireShots()
        var app = openOrders(["-CouliDebugLayoutWidth", "320"])
        pause()
        save(app, "AdaptNarrowOrders")
        app.terminate()
        app = openOrders(["-CouliDebugLayoutWidth", "320", "-UIPreferredContentSizeCategoryName",
                          "UICTContentSizeCategoryAccessibilityXXL"])
        pause()
        save(app, "AdaptNarrowLargeText200-Orders")
        element(app, "orders.filter.platform").tap()
        pause()
        element(app, "orders.option.pdd").tap()
        pause()
        element(app, "orders.filter.month").tap()
        pause()
        app.descendants(matching: .any).matching(identifier: "orders.option.2026-10").firstMatch.tap()
        pause()
        save(app, "AdaptNarrowLargeText200-OrdersFiltered")
        app.terminate()
        app = openOrders(["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXL"])
        pause()
        save(app, "AdaptLargeText200-Orders")
        openDetail(app, number: "3741234567890123456")
        save(app, "AdaptLargeText200-OrderDetail")
        app.terminate()
        app = openOrders(["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryExtraExtraExtraLarge"])
        openDetail(app, number: "3741234567890123456")
        save(app, "AdaptLargeTextOrderDetail")
    }

    func testShotsPendingTrack() throws {
        try requireShots()
        let app = launch(["-CouliFakeTipsRead", "-CouliFakeOrders", "pending"])
        product(app, "tb:t-ok")
        element(app, "product.buy").tap()
        XCTAssertTrue(element(app, "pendingTrack.card.taobao").waitForExistence(timeout: 15), "外跳后没有待跟单卡")
        pause()
        save(app, "ProductPendingTrack")
        if element(app, "pendingTrack.notify").exists {
            element(app, "pendingTrack.notify").tap()
            pause(1.5)
            save(app, "ProductPendingTrack-systemPrompt")
            let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
            for label in ["Don’t Allow", "Don't Allow", "不允许"] where springboard.buttons[label].exists {
                springboard.buttons[label].tap()
                break
            }
            pause(1)
            save(app, "ProductPendingTrackDecided")
        }
        element(app, "pendingTrack.close").tap()
        pause(1.2)
        save(app, "ProductPendingTrack-dismissed")
    }
}

/// 一张详情截图：按完整单号搜到并打开。
private struct DetailShot {
    let number: String
    let name: String
    let extra: [String]

    init(_ number: String, _ name: String, _ extra: [String]) {
        self.number = number
        self.name = name
        self.extra = extra
    }
}
