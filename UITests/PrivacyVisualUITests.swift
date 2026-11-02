import XCTest

/// APP-12w-b 真实点击与读屏（brief §4.2–§4.5）。verify 已很长：只留进程内做不了的——真 `.sheet`、遮罩真点、读屏树。沿用 `COULI_FAKE_ME_VISUAL` 与
/// `debug.me.log`，
/// `-CouliFakeMe wechat=no|cs_open=fail` 是 APP-12 已有开关，本任务不新增 Debug 输入。瞬时轻提示读记录（F-IOS-62）。XCUI 顺序是近似，实机 VoiceOver
/// 随真机批次核。
@MainActor
final class PrivacyVisualUITests: XCTestCase, MeVisualUITest {
    override func setUp() async throws {
        continueAfterFailure = false
    }

    private func count(_ log: [String], _ entry: String) -> Int {
        log.filter { $0 == entry }.count
    }

    private func enterSettings(_ app: XCUIApplication) {
        let cell = reveal(app, "me.settings")
        let tabBar = node(app, "shell.tabBar")
        for _ in 0..<4 where cell.frame.maxY > tabBar.frame.minY - 8 {
            app.swipeUp()
        }
        cell.tap()
        XCTAssertTrue(node(app, "settings.page").waitForExistence(timeout: 10), "没有进设置")
    }

    private func keepScreen(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// 已登录：读屏顺序；清单行真点一次；开关名称不被说明覆盖。
    func testPrivacyMemberOrder() throws {
        let app = try launchMe()
        try requireMeLog(app)
        enterSettings(app)
        reveal(app, "settings.row.privacy_center").tap()
        XCTAssertTrue(node(app, "privacy.page").waitForExistence(timeout: 10), "没有进隐私中心")
        let items = try spoken(app)
        keep(items, "privacy-member-order")
        assertOrder(items, ["隐私中心", "个人信息收集清单", "第三方共享清单", "隐私政策", "用户协议", "个性化推荐", "系统权限"])
        let row = node(app, "privacy.personalization")
        XCTAssertEqual(row.label, "个性化推荐", "名称不被说明覆盖（K2）")
        XCTAssertTrue((row.value as? String ?? "").contains("开关，已"), "值读「开关，已打开 / 已关闭」")
        let first = node(app, "privacy.list.collect")
        XCTAssertGreaterThanOrEqual(first.frame.height, 43.5, "行命中高")
        XCTAssertGreaterThan(first.frame.width, 300, "整行可点")
        tapEdge(first, .left)
        let log = waitMeLog(app, "route:Agreement")
        XCTAssertEqual(count(log, "route:Agreement"), 1, "行左缘真点，恰好一次：\(log)")
    }

    /// 红线 ①：确认框打开后点遮罩既不关闭也不执行；系统返回不可用；【取消】关闭零动作。
    func testWithdrawDialogScrimAndCancel() throws {
        let app = try launchMe()
        try requireMeLog(app)
        enterSettings(app)
        reveal(app, "settings.row.privacy_center").tap()
        reveal(app, "privacy.withdraw").tap()
        let cancel = app.buttons["取消"].firstMatch
        XCTAssertTrue(cancel.waitForExistence(timeout: 5), "没有确认框")
        keepScreen("PrivacyCenterWithdraw")
        let back = app.navigationBars.buttons.firstMatch
        XCTAssertFalse(back.exists && back.isHittable, "确认框显示期间没有系统返回")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.03, dy: 0.5)).tap()
        Thread.sleep(forTimeInterval: 0.5)
        XCTAssertTrue(cancel.exists, "点遮罩不关闭")
        XCTAssertTrue(node(app, "privacy.page").exists, "点遮罩不执行")
        cancel.tap()
        XCTAssertTrue(UIWait.until("确认框没有关", ceiling: 5) { !app.buttons["取消"].firstMatch.exists })
        XCTAssertTrue(node(app, "privacy.withdraw").exists, "取消后还在隐私中心")
    }

    /// 关于：读屏顺序；复制真点一次、提示一次。
    func testAboutOrderAndCopy() throws {
        let app = try launchMe()
        try requireMeLog(app)
        enterSettings(app)
        reveal(app, "settings.row.about").tap()
        XCTAssertTrue(node(app, "about.page").waitForExistence(timeout: 10), "没有进关于")
        let items = try spoken(app)
        keep(items, "about-order")
        assertOrder(items, ["关于凑狸", "凑狸", "版本 .*", "生成式 AI 服务公示", "复制诊断信息"])
        node(app, "about.copy").tap()
        let done = "toast:已复制，可以粘贴给客服"
        let log = waitMeLog(app, done)
        XCTAssertEqual(count(log, done), 1, "提示一次：\(log)")
        XCTAssertEqual(count(log, "copy"), 1, "写入口一次：\(log)")
    }

    /// 真 `.sheet`：打不开半屏读屏顺序、默认 detent 下三个动作都点得到；重试一次；链接真点开帮助一次。
    func testCsOpenFailedInRealSheet() throws {
        let app = try launchMe(fake: "cs_open=fail")
        try requireMeLog(app)
        reveal(app, "me.grid.cs").tap()
        let open = node(app, "cs.openWechat")
        XCTAssertTrue(open.waitForExistence(timeout: 8), "没有出 HANDOFF 半屏")
        open.tap()
        let retry = node(app, "cs.retry")
        XCTAssertTrue(retry.waitForExistence(timeout: 8), "没有换成打不开")
        Thread.sleep(forTimeInterval: 0.6)
        keepScreen("CsOpenFailed-real-sheet")
        let items = try spoken(app)
        keep(items, "cs-open-failed-order")
        assertOrder(items, ["暂时打不开客服", "关闭", "微信没有成功打开.*", "客服不会向你索要验证码或密码", "重试", "复制客服链接", "去帮助中心"])
        for id in ["cs.title", "cs.retry", "cs.copyLink", "cs.goHelp"] {
            XCTAssertTrue(node(app, id).isHittable, "\(id) 在默认 detent 下可点")
        }
        try assertHitOnScreen(app, "cs.goHelp", sheet: "cs.sheet.open_failed")
        try assertHitOnScreen(app, "cs.close", sheet: "cs.sheet.open_failed")
        node(app, "cs.goHelp").tap()
        let log = waitMeLog(app, "route:Help")
        XCTAssertEqual(count(log, "route:Help"), 1, "恰好一次：\(log)")
        XCTAssertFalse(node(app, "cs.retry").exists, "先关半屏")
    }

    /// 屏上命中 ≥ 44（v2 第 8 条）。`frame` 是无障碍框，含框外焦点环每边 4，要按系统缩放减掉。不能靠真点量：副本实测 SwiftUI 触点有容差，
    /// 中线外 27～30pt（已超出框）还点得中，邻键也是，真点判不红。系统缩放取半屏宽 / 窗口宽（实测 386 / 402 = 0.96），比例变了这里先红，进程内的 46 要跟着改。
    private func assertHitOnScreen(_ app: XCUIApplication, _ id: String, sheet: String) throws {
        let frame = node(app, id).frame
        let scale = node(app, sheet).frame.width / app.frame.width
        let ring = 2 * Self.focusRingOutset * scale
        XCTAssertGreaterThanOrEqual(frame.height - ring, 43.75, "\(id) 屏上命中高（无障碍框 \(frame)，缩放 \(scale)）")
        XCTAssertGreaterThanOrEqual(frame.width - ring, 43.75, "\(id) 屏上命中宽（无障碍框 \(frame)，缩放 \(scale)）")
    }

    /// `CouliFocusRing` 框外写法每边外扩。
    private static let focusRingOutset: CGFloat = 4

    /// 真 `.sheet`：未装微信复制后留在半屏、复制一次、提示只播一次；关闭零动作。
    func testCsWechatMissingCopyStays() throws {
        let app = try launchMe(fake: "wechat=no")
        try requireMeLog(app)
        reveal(app, "me.grid.cs").tap()
        let copy = node(app, "cs.copyLink")
        XCTAssertTrue(copy.waitForExistence(timeout: 8), "没有出未装微信半屏")
        Thread.sleep(forTimeInterval: 0.6)
        keepScreen("CsWechatMissing-real-sheet")
        copy.tap()
        let done = "announce:polite:已复制客服链接"
        let log = waitMeLog(app, done)
        XCTAssertEqual(count(log, done), 1, "只播一次：\(log)")
        XCTAssertEqual(count(log, "copy"), 1, "写入口一次：\(log)")
        XCTAssertFalse(log.contains { $0.hasPrefix("toast:") }, "不走页面轻提示（不双播）：\(log)")
        XCTAssertTrue(node(app, "cs.toast").waitForExistence(timeout: 3), "留在半屏")
        try assertHitOnScreen(app, "cs.close", sheet: "cs.sheet.wechat_missing")
        let close = node(app, "cs.close")
        close.tap()
        XCTAssertTrue(UIWait.until("半屏没有关", ceiling: 5) { !self.node(app, "cs.copyLink").exists })
        XCTAssertFalse(meLog(app).contains("route:Help"), "关闭零动作")
    }
}
