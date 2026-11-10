import XCTest

/// APP-12w-a 真实点击与读屏（brief §4.2–§4.5）。verify 已很长：只留进程内做不了的核心路径（真点换了控件的入口、读屏树、键盘下的保存栏），
/// 其余在 AppTests/SettingsVisualBehaviorTests。沿用 `COULI_FAKE_ME_VISUAL` 与 `debug.me.log`（APP-12v 已接），本任务不新增 Debug 输入。
/// 瞬时轻提示读记录，不用 waitForExistence 抓（F-IOS-62）。XCUI 读屏顺序是近似，实机 VoiceOver 随真机批次核。
@MainActor
final class SettingsVisualUITests: XCTestCase, MeVisualUITest {
    override func setUp() async throws {
        continueAfterFailure = false
    }

    private func enterSettings(_ app: XCUIApplication) {
        let cell = reveal(app, "me.settings")
        // 引导条把宫格往下推时格子可能压在 Tab 栏下面（isHittable 仍为真，点到的是 Tab）
        let tabBar = ShellTabBar.bar(app)
        for _ in 0..<4 where cell.frame.maxY > tabBar.frame.minY - 8 {
            app.swipeUp()
        }
        cell.tap()
        XCTAssertTrue(node(app, "settings.page").waitForExistence(timeout: 10), "没有进设置")
    }

    /// 错误节点的显示文字（读屏名称），不在测试里抄一遍文案。
    private func text(_ app: XCUIApplication, _ id: String) throws -> String {
        let label = node(app, id).label
        XCTAssertFalse(label.isEmpty, "\(id) 没有文字")
        return label
    }

    private func count(_ log: [String], _ entry: String) -> Int {
        log.filter { $0 == entry }.count
    }

    /// 已登录读屏顺序：标题 → 分组名 → 行 → 剪贴板 → 清缓存 → 退出；计数元素各一次。
    func testMemberReadingOrder() throws {
        let app = try launchMe()
        enterSettings(app)
        let items = try spoken(app)
        keep(items, "settings-member-order")
        assertOrder(items, [
            "设置", "账号与安全", "昵称.*", "手机号.*", "授权管理", "隐私", "隐私中心", "用户协议与隐私政策", "通用", "通知设置",
            "重新显示下单须知", "打开 App 自动识别剪贴板", "清除缓存.*", "帮助中心", "关于凑狸", "退出登录",
        ])
        let row = node(app, "settings.row.clipboard_auto")
        XCTAssertEqual(row.label, "打开 App 自动识别剪贴板", "名称不被说明覆盖（G-S12）")
        XCTAssertTrue((row.value as? String ?? "").contains("开关，已"), "值读「开关，已打开 / 已关闭」")
    }

    /// 真点换过控件 / 样式的入口，每个恰好一次，取消零动作（一次冷启动走完）。协议放最后：落点是 H5。
    func testRealTapsOnce() throws {
        let app = try launchMe()
        try requireMeLog(app)
        enterSettings(app)
        let done = "toast:已重新显示下单须知"
        reveal(app, "settings.row.reset_tip").tap()
        XCTAssertEqual(count(waitMeLog(app, done), done), 1, "resetTip 一次，不跳页")
        XCTAssertTrue(node(app, "settings.page").exists)

        reveal(app, "settings.row.clear_cache").tap()
        XCTAssertTrue(app.buttons["取消"].firstMatch.waitForExistence(timeout: 5), "没有确认框")
        app.buttons["取消"].firstMatch.tap()
        XCTAssertFalse(meLog(app).contains("toast:已清除"), "取消零动作")
        reveal(app, "settings.row.clear_cache").tap()
        XCTAssertTrue(app.buttons["清除"].firstMatch.waitForExistence(timeout: 5))
        app.buttons["清除"].firstMatch.tap()
        XCTAssertEqual(count(waitMeLog(app, "toast:已清除"), "toast:已清除"), 1, "清除一次")

        reveal(app, "settings.logout").tap()
        XCTAssertTrue(app.buttons["取消"].firstMatch.waitForExistence(timeout: 5))
        app.buttons["取消"].firstMatch.tap()
        XCTAssertTrue(UIWait.until("确认框没有关", ceiling: 5) { !app.buttons["取消"].firstMatch.exists })

        reveal(app, "settings.row.agreement").tap()
        let close = node(app, "settings.sheet.close")
        XCTAssertTrue(close.waitForExistence(timeout: 5), "半屏关闭要有标识（closeID）")
        XCTAssertGreaterThanOrEqual(close.frame.width, 43.5, "关闭命中宽")
        XCTAssertGreaterThanOrEqual(close.frame.height, 43.5, "关闭命中高")
        close.tap()
        XCTAssertTrue(UIWait.until("半屏没有关", ceiling: 5) { !self.node(app, "settings.agreementSheet").exists })
        XCTAssertFalse(meLog(app).contains("route:Agreement"), "关闭零动作")
        reveal(app, "settings.row.agreement").tap()
        let row = node(app, "settings.agreement.privacy")
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        XCTAssertGreaterThanOrEqual(row.frame.height, 43.5, "半屏行命中高")
        XCTAssertGreaterThan(row.frame.width, 300, "半屏行整行可点")
        tapEdge(row, .left)
        let log = waitMeLog(app, "route:Agreement")
        XCTAssertEqual(count(log, "route:Agreement"), 1, "半屏行左缘真点，恰好一次：\(log)")
    }

    /// 昵称：标签作输入框名称、计数不进读屏（画板 aria-hidden）；敏感词错误 assertive 一次；键盘在时【保存】仍可点；改好回设置页提示一次。
    func testNicknameFlow() throws {
        let app = try launchMe()
        try requireMeLog(app)
        enterSettings(app)
        reveal(app, "settings.row.nickname").tap()
        let input = node(app, "nickname.input")
        XCTAssertTrue(input.waitForExistence(timeout: 10), "没有进昵称页")
        let items = try spoken(app)
        keep(items, "settings-nickname-order")
        assertOrder(items, ["修改昵称", "昵称", "清除昵称", "1–16 个字.*", "保存"])
        XCTAssertFalse(items.contains { $0.label.contains("/16") }, "计数不被读屏读出")
        let clear = node(app, "nickname.clear")
        XCTAssertGreaterThanOrEqual(clear.frame.height, 43.5, "清除命中高")
        clear.tap()
        input.tap()
        input.typeText("mingan")
        let save = node(app, "nickname.save")
        XCTAssertTrue(save.isHittable, "键盘在时【保存】仍可点（底部固定栏）")
        save.tap()
        XCTAssertTrue(node(app, "nickname.error").waitForExistence(timeout: 10), "没有错误")
        Thread.sleep(forTimeInterval: 0.8)
        // v2：清除出的 nickname.empty 是另一个错误事件（R2-04），自己也 assertive 一次；这里只数敏感词这一条
        let sensitive = "announce:assertive:" + (try text(app, "nickname.error"))
        XCTAssertEqual(count(meLog(app), sensitive), 1, "敏感词 assertive 一次：\(meLog(app))")
        XCTAssertTrue(node(app, "nickname.clear").isHittable)
        node(app, "nickname.clear").tap()
        input.typeText("xiaoli")
        save.tap()
        let done = "toast:昵称已修改"
        XCTAssertEqual(count(waitMeLog(app, done), done), 1, "保存成功提示一次")
        XCTAssertTrue(node(app, "settings.logout").waitForExistence(timeout: 10), "回到设置页")
    }

    /// 游客：说明 → 去登录；链接真点恰好一次到 Login，命中 ≥ 44。
    func testGuestLink() throws {
        let app = try launchMe(nil)
        try requireMeLog(app)
        enterSettings(app)
        let items = try spoken(app)
        keep(items, "settings-guest-order")
        assertOrder(items, ["设置", "隐私中心", "用户协议与隐私政策", "关于凑狸", "清除缓存.*", "帮助中心",
                            "登录后可以管理账号、授权和通知", "去登录"])
        let link = reveal(app, "settings.login")
        XCTAssertGreaterThanOrEqual(link.frame.height, 43.5, "去登录命中高")
        XCTAssertLessThan(link.frame.width, 200, "是文字链接，不是通栏按钮（现状通栏）")
        link.tap()
        XCTAssertEqual(count(waitMeLog(app, "route:Login"), "route:Login"), 1, "恰好一次")
    }

    /// 通知（guide=1 = 已拒绝）：提示句 → 去设置 → 服务类推送；去设置是按钮、命中 ≥ 44；真点这里跳出 App，点击在进程内测。开关真点翻转一次。
    func testNotifyDeniedOrder() throws {
        let app = try launchMe(fake: "guide=1")
        enterSettings(app)
        reveal(app, "settings.row.notify").tap()
        XCTAssertTrue(node(app, "notify.page").waitForExistence(timeout: 10), "没有进通知页")
        let go = node(app, "notify.goSettings")
        XCTAssertTrue(go.waitForExistence(timeout: 5), "已拒绝要有去设置")
        XCTAssertEqual(go.elementType, .button, "读屏是按钮")
        XCTAssertGreaterThanOrEqual(go.frame.height, 43.5, "去设置命中高")
        let items = try spoken(app)
        keep(items, "settings-notify-order")
        assertOrder(items, ["通知设置", "通知权限已关闭.*", "去设置", "服务类推送"])
        let row = node(app, "notify.switch")
        let before = row.value as? String ?? ""
        row.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
        XCTAssertTrue(UIWait.until("开关没有翻转", ceiling: 5) { (row.value as? String ?? "") != before })
    }
}
