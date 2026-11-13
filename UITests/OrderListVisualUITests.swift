import XCTest

/// APP-08v-a 订单列表真机行为（真实 App + 假服务 + `debug.order.log`）：读屏顺序与读名（brief §4.2）、
/// 所有入口从真实控件点击出发断言精确路由与参数（§4.4，APP-08 共性第 12、18 条）、命中区上下缘真点（§4.3）、金额隐藏读法（G21）。
@MainActor
final class OrderListVisualUITests: XCTestCase, OrderVisualUITest {
    override func setUp() async throws {
        continueAfterFailure = false
    }

    private func list(_ selfPage: String = "list_self") throws -> [String: Any] {
        try ["self": listPage(selfPage), "share": listPage("list_share"),
             "cursor:visual-next-2": listPage("list_self_empty")]
    }

    /// 读屏：标题 → 找回入口 → 子 Tab（选中）→ 搜索框 → 分组（选中）→ 平台 / 月份（展开状态）→ 眼睛 → 卡片整卡一项
    /// （平台、商品名、件数、单号、金额、状态；平台只读一次）→【复制】第二项。
    func testReadingOrderAndCardIsOneItemWithCopySecond() throws {
        let app = try launchOrders(list: list(), expect: "A")
        let items = try readingOrder(app)
        keep(items, "orders-reading-order")
        let title = index(items, "标题「订单」") { $0.label == "订单" }
        let find = index(items, "找回入口") { $0.id == "orders.findEntry" }
        let tab = index(items, "子 Tab 自购") { $0.id == "orders.tab.self" }
        let search = index(items, "搜索框") { $0.id == "orders.search" }
        let group = index(items, "分组「全部」") { $0.id == "orders.group.all" }
        let platform = index(items, "平台筛选") { $0.id == "orders.filter.platform" }
        let month = index(items, "月份筛选") { $0.id == "orders.filter.month" }
        let eye = index(items, "眼睛") { $0.id == "order.mask" }
        let card = index(items, "卡片 A") { $0.label.contains("纯牛奶") }
        let copy = index(items, "卡片 A 的复制") { $0.id == "order.copy" }
        XCTAssertEqual([title, find, tab, search, group, platform, month, eye, card, copy].sorted(),
                       [title, find, tab, search, group, platform, month, eye, card, copy], "读屏顺序")
        let cardLabel = items[card].label
        for part in ["淘宝", "纯牛奶", "件数 2", "3741234567890123456", "¥45.6", "¥1.23", "已付款"] {
            XCTAssertTrue(cardLabel.contains(part), "整卡一项读出「\(part)」：\(cardLabel)")
        }
        XCTAssertEqual(occurrences("淘宝", in: cardLabel), 1, "平台图标不重复播报：\(cardLabel)")
        XCTAssertEqual(items[copy].label, "复制订单号 3741234567890123456", "【复制】独立第二项，读出本行完整单号（D10-1248 ⑨）")
        XCTAssertEqual(node(app, "orders.filter.platform").value as? String, "已收起", "筛选读出展开状态")
    }

    /// 置顶找回行（G-O04）：读屏里在标题之后、子 Tab 之前；右上入口不存在；整行左右两端真点都到 `FindOrder {}`，各一次、不多发订单请求。
    func testPinnedRowBothEdgesOpenFindOrderOnly() throws {
        for edge in [UIRectEdge.left, .right] {
            let app = try launchOrders(list: list("list_self_pinned"), expect: "A")
            try requireLog(app)
            XCTAssertFalse(node(app, "orders.findEntry").exists, "置顶时右上入口不在")
            let row = node(app, "orders.findPinned")
            XCTAssertTrue(row.waitForExistence(timeout: 5), "置顶行存在")
            let items = try readingOrder(app)
            let pinned = index(items, "置顶行") { $0.id == "orders.findPinned" }
            let tab = index(items, "子 Tab") { $0.id == "orders.tab.self" }
            XCTAssertLessThan(pinned, tab, "读屏：置顶行在子 Tab 前")
            let before = log(app)
            tapEdge(row, edge)
            waitLog(app, beyond: before.count)
            let added = Array(log(app).dropFirst(before.count))
            XCTAssertEqual(added.filter { $0.hasPrefix("route:") }, ["route:FindOrder"], "置顶行 \(edge) 端 → FindOrder {}")
            XCTAssertTrue(added.filter { $0.hasPrefix("request:") }.isEmpty, "点找回不多发订单请求")
            app.terminate()
        }
    }

    /// 不置顶：右上「未跟单？去找回」→ `FindOrder {}`（同一去向、无参数）。
    func testTopRightFindEntryOpensFindOrder() throws {
        let app = try launchOrders(list: list(), expect: "A")
        try requireLog(app)
        XCTAssertFalse(node(app, "orders.findPinned").exists, "不置顶时没有置顶行")
        let before = log(app).count
        node(app, "orders.findEntry").tap()
        waitLog(app, beyond: before)
        XCTAssertEqual(routes(app), ["route:FindOrder"])
    }

    /// 整卡 → `OrderDetail {order_id}`；【复制】真点（含命中区上缘）只写一次剪贴板、不穿透到整卡。
    func testCardOpensDetailAndCopyDoesNotPassThrough() throws {
        let app = try launchOrders(list: list(), expect: "A")
        try requireLog(app)
        let copy = node(app, "order.card.A").descendants(matching: .any)["order.copy"].firstMatch
        XCTAssertTrue(copy.exists, "A 有【复制】")
        XCTAssertGreaterThanOrEqual(copy.frame.height, 43.5, "复制命中区 ≥ 44")
        var before = log(app).count
        tapEdge(copy, .top)
        waitLog(app, beyond: before)
        XCTAssertEqual(log(app).filter { $0.hasPrefix("copy:") }, ["copy:3741234567890123456"], "复制原文一次")
        XCTAssertTrue(routes(app).isEmpty, "复制不穿透到整卡（不打开详情）")

        before = log(app).count
        node(app, "order.card.A").tapCardBody()
        waitLog(app, beyond: before)
        XCTAssertEqual(routes(app), ["route:OrderDetail?order_id=A"], "整卡 → OrderDetail {order_id}")
    }

    /// 分组胶囊与平台筛选：命中区下 / 上缘真点各自生效，互不错投（§9 风险 1）。
    func testChipAndFilterEdgesHitTheirOwnTarget() throws {
        let app = try launchOrders(list: list(), expect: "A")
        try requireLog(app)
        restoreDefaultsAtTeardown(app)
        let chip = node(app, "orders.group.estimating")
        XCTAssertGreaterThanOrEqual(chip.frame.height, 43.5, "分组命中区 ≥ 44")
        let before = log(app).count
        tapEdge(chip, .bottom)
        waitLog(app, beyond: before)
        XCTAssertTrue(requests(app).last?.contains("status_group=estimating") == true, "分组下缘 → 预估中：\(requests(app))")
        XCTAssertFalse(node(app, "orders.option.taobao").exists, "没有错投到平台筛选")
        let filter = node(app, "orders.filter.platform")
        XCTAssertGreaterThanOrEqual(filter.frame.height, 43.5, "平台筛选命中区 ≥ 44")
        tapEdge(filter, .top)
        XCTAssertTrue(node(app, "orders.option.taobao").waitForExistence(timeout: 5), "平台筛选上缘 → 打开平台半屏")
    }

    /// 金额隐藏：读屏读「金额已隐藏」，不读返利原数；实付照读（G21）。先正后反。
    func testHiddenAmountsAreReadAsHidden() throws {
        let app = try launchOrders(list: list(), expect: "A")
        let card = node(app, "order.card.A")
        XCTAssertTrue(try readingOrder(app).contains { $0.label.contains("¥1.23") }, "前提：未隐藏时读出返利")
        restoreDefaultsAtTeardown(app, maskLabel: node(app, "order.mask").label)
        node(app, "order.mask").tap()
        Thread.sleep(forTimeInterval: 0.8)
        let items = try readingOrder(app)
        keep(items, "orders-hidden")
        XCTAssertFalse(items.contains { $0.label.contains("¥1.23") }, "隐藏后不读返利原数")
        XCTAssertTrue(items.contains { $0.label.contains("金额已隐藏") }, "读「金额已隐藏」")
        XCTAssertTrue(items.contains { $0.label.contains("¥45.6") }, "实付不隐藏")
        XCTAssertTrue(card.exists)
    }

    /// v3（评审 r1 S2-3）：系统字号 AX3（UICTContentSizeCategoryAccessibilityExtraLarge）、14 个月（独立 fixture month_options_long）——
    /// 月份半屏放不下：最后一项起初不在屏内，在半屏里真拖动到完整在屏内、命中 ≥ 44，真点选中 → 第一页请求只发一次且按 paid_month=2025-09、半屏关。
    func testMonthSheetAtAX3ScrollsToLastMonthAndSelects() throws {
        let app = try launchOrders(
            list: ["self": listPage("month_options_long"), "share": listPage("list_share"),
                   "cursor:visual-next-2": listPage("list_self_empty")], expect: "A",
            extra: ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityExtraLarge"]
        )
        try selectLastOption(app, filter: "month", last: "2025-09", query: "paid_month=2025-09", mustScroll: true)
    }

    /// v3（评审 r1 S2-3）：AX3 下平台半屏最后一项（拼多多）——平台选项固定 4 项，竖屏手机放得下（放不下的滚动由进程内
    /// `testPlatformSheetOnShortWindowScrollsToLast` 用矮窗口证明）；需要时拖到屏内，真点选中 → 第一页请求只发一次且按 platform=pdd、半屏关。
    func testPlatformSheetAtAX3LastOptionSelects() throws {
        let app = try launchOrders(
            list: list(), expect: "A",
            extra: ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityExtraLarge"]
        )
        try selectLastOption(app, filter: "platform", last: "pdd", query: "platform=pdd", mustScroll: false)
    }

    /// 打开半屏，必要时在半屏区域里真拖动（坐标拖动，不依赖会滚出屏的元素）直到最后一项完整在屏内，再真点。
    /// 请求断言只看第一页（不带 cursor）：选中后生产执行器自动翻页属正常行为；上一用例留下的恢复条件（如分组）不影响判断。
    private func selectLastOption(_ app: XCUIApplication, filter: String, last id: String, query: String,
                                  mustScroll: Bool) throws {
        try requireLog(app)
        restoreDefaultsAtTeardown(app)
        node(app, "orders.filter.\(filter)").tap()
        XCTAssertTrue(node(app, "orders.option.all").waitForExistence(timeout: 5), "半屏打开")
        let last = node(app, "orders.option.\(id)")
        let screen = app.windows.firstMatch.frame
        func onScreen() -> Bool {
            last.exists && last.frame.minY >= screen.minY && last.frame.maxY <= screen.maxY
        }
        if mustScroll {
            XCTAssertFalse(onScreen(), "前提：AX3 下放不下，最后一项起初不完整在屏内")
        }
        for _ in 0..<10 where !onScreen() {
            let start = app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8))
            start.press(forDuration: 0.05, thenDragTo: app.windows.firstMatch
                .coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35)))
            Thread.sleep(forTimeInterval: 0.4)
        }
        XCTAssertTrue(onScreen(), "最后一项完整在屏内：\(last.frame)")
        XCTAssertGreaterThanOrEqual(last.frame.height, 43.5, "命中 ≥ 44")
        let before = log(app).count
        last.tap()
        waitLog(app, beyond: before)
        let firstPages = Array(log(app).dropFirst(before))
            .filter { $0.hasPrefix("request:") && !$0.contains("cursor=") }
        XCTAssertEqual(firstPages.count, 1, "选中只发一次第一页请求：\(firstPages)")
        XCTAssertTrue(firstPages.first?.contains(query) == true, "按所选值请求：\(firstPages)")
        XCTAssertFalse(node(app, "orders.option.all").waitForExistence(timeout: 2), "选中后半屏关闭")
    }

    // MARK: - v4：不把筛选留进恢复记录

    /// v4（完整 verify 互扰）：订单页条件（分组 / 平台 / 月份）与金额隐藏会写进恢复记录与设备偏好，跨进程保留；之后带
    /// `-CouliFakeOrdersKeepState` 冷启动的 OrdersProcessRestoreTests 会被筛空。改了条件的用例在结束时（无论成败）把条件还原为
    /// 「全部」、眼睛还原为原状态，并等后台保存完成再结束进程——还原走的是生产的同一入口，恢复用例本身不改、不弱化。
    private func restoreDefaultsAtTeardown(_ app: XCUIApplication, maskLabel: String? = nil) {
        addTeardownBlock { @MainActor in
            guard app.state == .runningForeground else { return }
            // 半屏若还开着（用例中途失败），先选「全部」关掉它
            let open = app.descendants(matching: .any)["orders.option.all"].firstMatch
            if open.exists {
                open.tap()
                Thread.sleep(forTimeInterval: 0.6)
            }
            let all = app.descendants(matching: .any)["orders.group.all"].firstMatch
            if all.waitForExistence(timeout: 3) {
                all.tap()
                Thread.sleep(forTimeInterval: 0.6)
            }
            for filter in ["platform", "month"] {
                let button = app.descendants(matching: .any)["orders.filter.\(filter)"].firstMatch
                guard button.waitForExistence(timeout: 3) else { continue }
                button.tap()
                let option = app.descendants(matching: .any)["orders.option.all"].firstMatch
                if option.waitForExistence(timeout: 3) {
                    option.tap()
                    Thread.sleep(forTimeInterval: 0.6)
                }
            }
            if let maskLabel {
                let eye = app.descendants(matching: .any)["order.mask"].firstMatch
                if eye.exists, eye.label != maskLabel {
                    eye.tap()
                    Thread.sleep(forTimeInterval: 0.4)
                }
            }
            _ = UIWait.pressHomeAndWaitForBackgroundSave(app)
            app.terminate()
        }
    }
}
