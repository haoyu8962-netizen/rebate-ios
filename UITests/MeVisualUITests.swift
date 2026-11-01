import XCTest

/// APP-12v 真实点击与读屏（brief §4.2–§4.5）。verify 已约 3.7 小时：这里只留进程内做不了的核心路径（真点、命中区边缘、读屏树、下拉），
/// 全部宫格路由表在 AppTests/MeVisualBehaviorTests。
@MainActor
final class MeVisualUITests: XCTestCase, MeVisualUITest {
    override func setUp() async throws {
        continueAfterFailure = false
    }

    /// 已登录读屏顺序（§4.2，含隐藏读法）：引导条整句一次（不因样式切分读两遍）→ 关闭 → 昵称 → 码 → 复制 → 邀请人 → 余额 → 眼睛 →【提现】→ 预估 → 各组。
    func testMemberReadingOrder() throws {
        let app = try launchMe(fake: "guide=1")
        XCTAssertTrue(node(app, "me.guideBar").waitForExistence(timeout: 10), "没有引导条")
        app.buttons["隐藏金额"].firstMatch.tap()
        XCTAssertTrue(app.buttons["显示金额"].firstMatch.waitForExistence(timeout: 5), "眼睛名称没有换")
        let items = try spoken(app)
        keep(items, "member-reading-order")
        assertOrder(items, [
            "我的", "消息中心", "通知没有开启，跟单和提现到账的消息可能收不到。去开启", "关闭提示", "凑狸用户",
            "我的邀请码\\s*K7M3QX", "复制(我的)?邀请码", "邀请人：已绑定", "可提现余额，金额已隐藏", "显示金额", "提现",
            "预估收益，金额已隐藏", "订单与钱包", "我的订单", "钱包", "余额流水", "找回订单", "推广与邀请", "邀请好友", "更多服务",
            "帮助中心", "联系客服", "授权管理", "设置",
        ])
        XCTAssertFalse(items.contains { $0.label == "去开启" }, "「去开启」不单独成读屏项")
        XCTAssertFalse(items.contains { $0.label == "可提现余额" }, "不再单读标题（否则读两遍「可提现余额」，眼睛夹在中间）")
    }

    /// 游客读屏顺序：标题 → 还没有登录 + 说明 →【登录 / 注册】→ 宫格；没有铃铛与金额。
    func testGuestReadingOrder() throws {
        let app = try launchMe(nil)
        let items = try spoken(app)
        keep(items, "guest-reading-order")
        assertOrder(items, ["我的", "还没有登录", "登录后可以查看返利、提现和邀请好友", "登录 / 注册", "更多服务", "帮助中心", "设置"])
        XCTAssertFalse(items.contains { $0.label.contains("消息中心") || $0.label.contains("可提现余额") })
    }

    /// 真实控件点一次 → 恰好一次导航（核心入口；每个入口冷启动一次，不依赖各落点页的返回方式）。
    func testRealTapsNavigateOnce() throws {
        let cases: [(String, String)] = [
            ("me.bell", "route:Messages"), ("me.wallet", "route:Wallet"), ("me.grid.help", "route:Help"),
        ]
        for (id, entry) in cases {
            let app = try launchMe()
            try requireMeLog(app)
            let before = meLog(app).filter { $0 == entry }.count
            reveal(app, id).tap()
            let log = waitMeLog(app, entry, count: before + 1)
            XCTAssertEqual(log.filter { $0 == entry }.count, before + 1, "\(id) 恰好一次：\(log)")
            app.terminate()
        }
        let app = try launchMe()
        app.buttons["提现"].firstMatch.tap()
        let log = waitMeLog(app, "route:Wallet")
        XCTAssertEqual(log.filter { $0 == "route:Wallet" }.count, 1, "【提现】恰好一次 → Wallet：\(log)")
        XCTAssertFalse(log.contains("route:Withdraw"), "不直接开 Withdraw（G-M05）")
        app.terminate()
        let guest = try launchMe(nil)
        node(guest, "me.login").tap()
        XCTAssertEqual(waitMeLog(guest, "route:Login").filter { $0 == "route:Login" }.count, 1, "【登录 / 注册】")
    }

    /// 联系客服仍走统一客服出口（出半屏，G-M15 不在本任务）：真点一次，半屏一个。
    func testCustomerServiceCellOpensSheet() throws {
        let app = try launchMe()
        reveal(app, "me.grid.cs").tap()
        XCTAssertTrue(node(app, "cs.title").waitForExistence(timeout: 8), "没有出客服半屏")
    }

    /// 命中区：复制、眼睛四条边内 1pt 真点各生效一次，且 ≥ 44、邻近目标不被触发（brief §4.3「含实际点击落点」）。
    func testHitEdgesCopyAndEye() throws {
        let app = try launchMe()
        try requireMeLog(app)
        let copy = node(app, "me.copyInvite")
        XCTAssertTrue(copy.waitForExistence(timeout: 10))
        XCTAssertGreaterThanOrEqual(copy.frame.width, 43.5, "复制命中宽")
        XCTAssertGreaterThanOrEqual(copy.frame.height, 43.5, "复制命中高")
        var copies = 0
        for edge in [UIRectEdge.top, .bottom, .left, .right] {
            tapEdge(copy, edge)
            copies += 1
            let log = waitMeLog(app, "copy", count: copies)
            XCTAssertEqual(log.filter { $0 == "copy" }.count, copies, "复制边缘 \(edge) 恰好一次：\(log)")
        }
        XCTAssertFalse(meLog(app).contains { $0.hasPrefix("route:") && $0 != "route:Me" }, "没有误触导航")
        let eye = app.buttons["隐藏金额"].firstMatch
        XCTAssertGreaterThanOrEqual(eye.frame.width, 43.5, "眼睛命中宽")
        XCTAssertGreaterThanOrEqual(eye.frame.height, 43.5, "眼睛命中高")
        tapEdge(eye, .top)
        XCTAssertTrue(app.buttons["显示金额"].firstMatch.waitForExistence(timeout: 5), "眼睛上边缘生效")
        tapEdge(app.buttons["显示金额"].firstMatch, .bottom)
        XCTAssertTrue(app.buttons["隐藏金额"].firstMatch.waitForExistence(timeout: 5), "眼睛下边缘生效")
        let log = waitMeLog(app, "announce:polite:金额已显示")
        XCTAssertEqual(log.filter { $0 == "announce:polite:金额已隐藏" }.count, 1, "隐藏播报一次：\(log)")
        XCTAssertEqual(log.filter { $0 == "announce:polite:金额已显示" }.count, 1, "显示播报一次：\(log)")
    }

    /// 引导条关闭真点一次收起；读取次数不变。
    func testGuideBarCloseTap() throws {
        let app = try launchMe(fake: "guide=1")
        XCTAssertTrue(node(app, "me.guideBar").waitForExistence(timeout: 10))
        try requireMeLog(app)
        let reads = meLog(app).filter { $0 == "request:GET /v1/me" }.count
        node(app, "me.guideBar.close").tap()
        XCTAssertTrue(UIWait.until("引导条没有收起", ceiling: 5) { !self.node(app, "me.guideBar").exists })
        XCTAssertEqual(meLog(app).filter { $0 == "request:GET /v1/me" }.count, reads, "关闭不发 getMe")
    }

    /// 真实下拉、子页返回各恰一次 getMe（回前台、进入在进程内 MeVisualBehaviorTests）。
    func testPullAndReturnReadOnce() throws {
        let app = try launchMe()
        try requireMeLog(app)
        let entry = "request:GET /v1/me"
        XCTAssertEqual(waitMeLog(app, entry).filter { $0 == entry }.count, 1, "进入一次")
        let scroll = node(app, "me.scroll")
        let start = scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2))
        start.press(forDuration: 0.1, thenDragTo: scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8)))
        XCTAssertEqual(waitMeLog(app, entry, count: 2).filter { $0 == entry }.count, 2, "下拉一次")
        let settings = reveal(app, "me.settings")
        let position = settings.frame.minY
        settings.tap()
        XCTAssertTrue(node(app, "settings.logout").waitForExistence(timeout: 10), "没有进设置")
        // 设置页 appeared 自己读一次（AppMe+Pages makeEntry），不是「我的」的
        XCTAssertEqual(waitMeLog(app, entry, count: 3).filter { $0 == entry }.count, 3, "进设置一次")
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(node(app, "me.nickname").waitForExistence(timeout: 10), "没有回到「我的」")
        XCTAssertEqual(waitMeLog(app, entry, count: 4).filter { $0 == entry }.count, 4, "子页返回一次")
        XCTAssertEqual(node(app, "me.settings").frame.minY, position, accuracy: 2, "返回保持滚动位置")
    }
}

/// 余额卡读屏（类名含 Money，D10-512 不吃 verify 重试）：可提现、预估逐项读；隐藏时读屏树里没有原金额。
@MainActor
final class MeVisualMoneyUITests: XCTestCase, MeVisualUITest {
    override func setUp() async throws {
        continueAfterFailure = false
    }

    func testVisibleAmountsSpokenItemByItem() throws {
        let app = try launchMe("me_no_sum")
        let items = try spoken(app)
        keep(items, "money-visible")
        assertOrder(items, ["可提现余额，.*12.*34.*", "隐藏金额", "提现", "预估收益，.*56.*78.*"])
        XCTAssertFalse(items.contains { $0.label.contains("99") }, "读屏里没有 available（9900）")
        try requireMeLog(app)
    }

    func testHiddenAmountsAbsentFromTree() throws {
        let app = try launchMe()
        app.buttons["隐藏金额"].firstMatch.tap()
        XCTAssertTrue(app.buttons["显示金额"].firstMatch.waitForExistence(timeout: 5))
        let items = try spoken(app)
        keep(items, "money-hidden")
        assertOrder(items, ["可提现余额，金额已隐藏", "显示金额", "预估收益，金额已隐藏"])
        for raw in ["12.34", "56.78", "¥", "****"] {
            XCTAssertFalse(items.contains { $0.label.contains(raw) }, "隐藏时读屏出现 \(raw)")
        }
    }
}
