import XCTest

/// APP-08v-b 订单详情真点（真实 App + 假服务 + `debug.order.log`）：所有资金 / 写动作按钮与查看类入口从真实控件点击出发，
/// 断言精确路由、参数与次数（brief §4.4；G-O06 挪位置后落点与次数不变）；G-O08 未知状态；读屏顺序（规格 §6「状态 → 金额 → 原因 →
/// 按钮」）；Android b r1 S2-2（申诉进度与按钮边缘错投）、S2-3（无底栏页底部安全区）。
@MainActor
final class OrderDetailVisualUITests: XCTestCase, OrderVisualUITest {
    override func setUp() async throws {
        continueAfterFailure = false
    }

    /// 列表只放这一单（报文取详情本身的列表字段），真点进详情。
    private func launchDetail(_ detail: [String: Any], extra: [String] = []) throws -> XCUIApplication {
        let id = try XCTUnwrap(detail["order_id"] as? String)
        let page: [String: Any] = ["items": [detail], "next_cursor": NSNull(), "earliest_visible_date": NSNull()]
        let app = try launchOrders(list: ["self": page], details: [id: detail], expect: id, extra: extra)
        try requireLog(app)
        openDetail(app, id)
        return app
    }

    private func launchDetail(_ name: String, change: [String: Any] = [:]) throws -> XCUIApplication {
        try launchDetail(detail(name).merging(change) { $1 })
    }

    /// 真点一个元素，返回这次点击新增的记录。
    private func press(_ app: XCUIApplication, _ element: XCUIElement, edge: UIRectEdge? = nil) -> [String] {
        let before = log(app).count
        if let edge {
            tapEdge(element, edge)
        } else {
            element.tap()
        }
        waitLog(app, beyond: before)
        return Array(log(app).dropFirst(before))
    }

    /// 【刷新】的固定观察窗口（秒）。点击后不看「记录一变就截取」，而是固定等满这么久再数 `request:` 条数，把迟到的重发也收进来。
    /// 上限推算：假服务回答延迟 0.3 秒（DebugOrderVisual）；产品侧刷新没有防抖，网络层读接口只在超时 / 断连时自动重试 1 次、退避 0.5 秒
    /// （RetryPolicy.readBackoffMillis），一次刷新最晚约 0.3 + 0.5 + 0.3 = 1.1 秒内发完全部请求。取 3 秒（≥ 2.5 秒且明显大于该上限）。
    private static let refreshWindow: TimeInterval = 3.0

    /// 真点之后固定等满 `window` 秒，返回这段时间新增的全部记录（不因记录先变化而提前截取）。
    /// `taps` > 1：一次手势里连点多下（相邻两下约 0.1 秒，第二下起落在首个请求在途期间）。
    private func pressAndHold(_ app: XCUIApplication, _ element: XCUIElement, window: TimeInterval,
                              taps: Int = 1) -> [String] {
        let before = log(app).count
        let start = Date()
        if taps > 1 {
            element.tap(withNumberOfTaps: taps, numberOfTouches: 1)
        } else {
            element.tap()
        }
        let rest = window - Date().timeIntervalSince(start)
        if rest > 0 {
            Thread.sleep(forTimeInterval: rest)
        }
        return Array(log(app).dropFirst(before))
    }

    private func button(_ app: XCUIApplication, _ action: String) -> XCUIElement {
        node(app, "orderDetail.action.\(action)")
    }

    // MARK: - 资金 / 写动作按钮（逐个真点）

    func testWithdrawInBottomBarOpensWithdrawOnce() throws {
        let app = try launchDetail("detail_settled")
        let added = press(app, button(app, "withdraw"))
        XCTAssertEqual(added.filter { $0.hasPrefix("route:") }, ["route:Withdraw"], "【去提现】→ Withdraw {}，一次")
    }

    func testAppealInCardOpensAppealOnce() throws {
        let app = try launchDetail("detail_blacklist")
        let added = press(app, button(app, "appeal"))
        XCTAssertEqual(added.filter { $0.hasPrefix("route:") }, ["route:Appeal"], "【去申诉】→ Appeal {}")
    }

    /// 扣回 PUNISH：【联系客服】走统一客服出口一次；【查看流水】→ Ledger；两者都在卡内、各一次。
    func testContactServiceAndLedgerInCard() throws {
        let app = try launchDetail("detail_clawed_two")
        var added = press(app, button(app, "contact_cs"))
        XCTAssertEqual(added.filter { $0.hasPrefix("cs:") || $0.hasPrefix("route:") }, ["cs:OrderDetail"],
                       "【联系客服】→ 统一客服出口一次")
        app.terminate()
        let again = try launchDetail("detail_clawed_two")
        added = press(again, button(again, "ledger"))
        XCTAssertEqual(added.filter { $0.hasPrefix("route:") }, ["route:Ledger"], "【查看流水】→ Ledger {}")
    }

    /// reason.action 的 CLAIM / REAUTH（测试内派生：失效单下发两个动作）：【去找回】→ FindOrder、【去授权】→ AuthManage。
    func testClaimAndReauthRoutes() throws {
        for (action, route) in [("claim", "route:FindOrder"), ("reauth", "route:AuthManage")] {
            let app = try launchDetail("detail_no_rebate", change: ["reason_action": ["CLAIM", "REAUTH"]])
            let added = press(app, button(app, action))
            XCTAssertEqual(added.filter { $0.hasPrefix("route:") }, [route], "【\(action)】")
            app.terminate()
        }
    }

    // MARK: - 未知状态（G-O08）

    /// 下发了 CLAIM / REAUTH / APPEAL / CONTACT_CS 的未知状态：一个写动作都没有；【刷新】复用 getOrder 同一路径、一次点击一次请求；
    /// 在途置灰期间再点不产生新请求；「查看流水」→ Ledger。
    /// 测试 b v2（实现交回 T1）：点击后固定观察 `refreshWindow` 秒再数请求（原先记录一变再等 0.3 秒就截取，1 秒后的重发落在窗口外）。
    func testUnknownStatusOnlyRefreshAndLedgerLink() throws {
        let app = try launchDetail("detail_unknown")
        for action in ["claim", "reauth", "appeal", "contact_cs", "withdraw", "ledger"] {
            XCTAssertFalse(button(app, action).exists, "未知状态不显示 \(action)")
        }
        let refresh = node(app, "orderDetail.refresh")
        XCTAssertTrue(refresh.exists, "【刷新】存在")
        // 进详情时的首次加载可能还没落记录：先等它静下来，免得算进刷新这一次
        Thread.sleep(forTimeInterval: Self.refreshWindow)
        let added = pressAndHold(app, refresh, window: Self.refreshWindow)
        XCTAssertEqual(added.filter { $0.hasPrefix("request:") }, ["request:GET /v1/orders/M"],
                       "刷新一次 = getOrder 恰好一次（点击后固定观察 \(Self.refreshWindow) 秒）：\(added)")
        XCTAssertTrue(added.filter { $0.hasPrefix("route:") }.isEmpty, "刷新不跳转")
        // 在途置灰：一次连点三下（后两下落在首个请求在途、按钮置灰期间），整个窗口内仍只有一次 getOrder
        XCTAssertTrue(refresh.isEnabled, "上一次刷新结束后【刷新】恢复可点")
        let twice = pressAndHold(app, refresh, window: Self.refreshWindow, taps: 3)
        XCTAssertEqual(twice.filter { $0.hasPrefix("request:") }, ["request:GET /v1/orders/M"],
                       "在途置灰期间再点不产生新请求（连点三下 = getOrder 恰好一次）：\(twice)")
        XCTAssertTrue(twice.filter { $0.hasPrefix("route:") }.isEmpty, "刷新不跳转")
        let link = press(app, node(app, "orderDetail.ledgerLink"))
        XCTAssertEqual(link.filter { $0.hasPrefix("route:") }, ["route:Ledger"], "「查看流水」→ Ledger {}")
        XCTAssertTrue(link.filter { $0.hasPrefix("request:") }.isEmpty, "「查看流水」不发 getOrder")
    }

    // MARK: - 查看类入口

    func testViewHelpOpensConfiguredArticle() throws {
        let app = try launchDetail("detail_settled")
        let added = press(app, node(app, "orderDetail.viewHelp"))
        XCTAssertEqual(added.filter { $0.hasPrefix("route:") }, ["route:Help?article_id=example-article-one"])
    }

    func testViewProductOpensProductDetailWithPlatformAndKeyOnly() throws {
        let app = try launchDetail("detail_estimated")
        let added = press(app, node(app, "orderDetail.viewProduct"))
        XCTAssertEqual(
            added.filter { $0.hasPrefix("route:") },
            ["route:ProductDetail?platform=jd&product_key=fixture:C"]
        )
    }

    func testAskAIOpensAgentChatWithOrderContext() throws {
        let app = try launchDetail("detail_estimated")
        let ask = node(app, "orderDetail.askAI")
        app.swipeUp()
        XCTAssertTrue(ask.waitForExistence(timeout: 5), "【问问 AI】整行在时间线之后")
        let added = press(app, ask)
        XCTAssertEqual(added.filter { $0.hasPrefix("route:") }, ["route:AgentChat?context.order_id=C"],
                       "AgentChat 带订单 context，不自动发送")
        // 评审 r1 S2-4：上面的记录在 Router 判定之前写下；这里看判定之后的落地——Tab 切到「AI 助手」、详情出栈。
        // 参数里的 order_id 界面上看不到（AgentChat 消费 context 属 APP-10），由进程内 OrderDetailVisualReviewR1Tests 读 Router.tabRoot 断言。
        let agentTab = node(app, "shell.tabBar").buttons["AI 助手"]
        let landed = NSPredicate(format: "isSelected == true")
        XCTAssertEqual(XCTWaiter.wait(for: [expectation(for: landed, evaluatedWith: agentTab)], timeout: 5), .completed,
                       "Router 放行：Tab 切到「AI 助手」")
        XCTAssertFalse(node(app, "orderDetail.product").exists, "详情已出栈")
    }

    func testCopyWritesOrderNumberOnceWithoutNavigation() throws {
        let app = try launchDetail("detail_estimated")
        let added = press(app, node(app, "orderDetail.product").descendants(matching: .any)["order.copy"].firstMatch)
        XCTAssertEqual(added.filter { $0.hasPrefix("copy:") }, ["copy:305678901234"])
        XCTAssertTrue(added.filter { $0.hasPrefix("route:") }.isEmpty)
    }

    /// Android b r1 S2-2：申诉中 + 服务端下发 CONTACT_CS——进度链接下缘、按钮上缘各自真点只落到自己的出口。
    func testAppealProgressAndButtonEdgesHitTheirOwnExit() throws {
        let app = try launchDetail("detail_appeal_pending", change: ["reason_action": ["CONTACT_CS"]])
        let progress = node(app, "orderDetail.appealProgress")
        let contact = button(app, "contact_cs")
        XCTAssertGreaterThanOrEqual(progress.frame.height, 43.5)
        XCTAssertGreaterThanOrEqual(contact.frame.height, 43.5)
        XCTAssertLessThanOrEqual(progress.frame.maxY, contact.frame.minY + 0.5, "两个命中区不重叠")
        let first = press(app, progress, edge: .bottom)
        XCTAssertEqual(first.filter { $0.hasPrefix("route:") || $0.hasPrefix("cs:") }, ["route:Appeal"],
                       "进度链接下缘 → Appeal")
        app.terminate()
        let again = try launchDetail("detail_appeal_pending", change: ["reason_action": ["CONTACT_CS"]])
        let second = press(again, button(again, "contact_cs"), edge: .top)
        XCTAssertEqual(second.filter { $0.hasPrefix("route:") || $0.hasPrefix("cs:") }, ["cs:OrderDetail"],
                       "按钮上缘 → 客服")
    }

    // MARK: - 读屏 / 安全区

    /// 读屏顺序：返回 → 标题 → 状态标题 → 眼睛 → 返利金额 → 实付 → 原因区 heading → 卡内按钮 → 商品卡 → 时间线 → 问问 AI。
    func testReadingOrderStatusAmountReasonButton() throws {
        let app = try launchDetail("detail_blacklist")
        let items = try readingOrder(app)
        keep(items, "detail-reading-order")
        let title = index(items, "页面标题") { $0.label == "订单详情" }
        let status = index(items, "状态标题") { $0.id == "orderDetail.status" }
        let eye = index(items, "眼睛") { $0.id == "order.mask" }
        let rebate = index(items, "返利金额") { $0.label.contains("返利") && $0.label.contains("¥0") }
        let paid = index(items, "实付") { $0.label.contains("¥129") }
        let heading = index(items, "为什么没返利？") { $0.label == "为什么没返利？" }
        let appeal = index(items, "【去申诉】") { $0.id == "orderDetail.action.appeal" }
        let product = index(items, "商品") { $0.label.contains("剃须刀") }
        let ask = index(items, "问问 AI") { $0.id == "orderDetail.askAI" }
        let order = [title, status, eye, rebate, paid, heading, appeal, product, ask]
        XCTAssertEqual(order, order.sorted(), "读屏顺序：状态 → 金额 → 原因 → 按钮 → 商品 → 问问 AI")
        XCTAssertTrue(items[heading].type == .staticText || items[heading].type == .other)
    }

    /// Android b r1 S2-3：没有底栏的页面滚到底，最后一张卡（问问 AI）完整在主屏指示条之上。
    func testLastCardStaysAboveHomeIndicatorWithoutBottomBar() throws {
        let app = try launchDetail("detail_reviewing")
        XCTAssertFalse(node(app, "orderDetail.action.withdraw").exists, "前提：没有底栏")
        for _ in 0..<4 {
            app.swipeUp()
        }
        Thread.sleep(forTimeInterval: 0.8)
        let ask = node(app, "orderDetail.askAI")
        XCTAssertTrue(ask.exists)
        let window = app.windows.firstMatch.frame
        let insetBottom = window.maxY - 34
        XCTAssertLessThanOrEqual(ask.frame.maxY, insetBottom + 0.5, "末卡底边在安全区之上（\(ask.frame) / \(window)）")
    }
}
