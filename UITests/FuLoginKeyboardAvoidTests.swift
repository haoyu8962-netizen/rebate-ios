import XCTest

/// FU-LOGIN-KEYBOARD-AVOID-ios（D10-2378 缺陷、D10-2458 范围三处；规划视觉验收 §2.4：最大字号与最小宽度下键盘弹起时主按钮
/// 整块可见、可点）。登录手机号步、登录验证码步、绑手机手机号步 × 三档（默认 / AXXXL / 320 宽 + AXXXL），每档单独冷启动、跑完
/// terminate。聚焦输入框、输入合法值、等键盘弹起且键盘与主按钮位置停稳后，**不滚动**，断言主按钮存在、可点、整块在窗口内、
/// 与键盘顶余量 ≥ 12pt（余量 = 键盘 minY − 按钮 maxY）。某档导航前提不满足时记失败并继续下一档。不截图（带键盘截图不入库）。
@MainActor
final class FuLoginKeyboardAvoidTests: XCTestCase {
    private static let axxxl = ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
    private static let tiers: [(String, [String])] = [
        ("normal", []),
        ("AXXXL", axxxl),
        ("w320-AXXXL", ["-CouliDebugLayoutWidth", "320"] + axxxl),
    ]
    private static let base = [
        "-CouliPrivacyPreset", "consented", "-CouliFakeLoginServer", "-CouliUpdateReset", "1",
        "-CouliHideDebugInfo", "1",
    ]
    private static let minMargin: CGFloat = 12
    private static let phone = "13800005678"

    override func setUp() async throws {
        continueAfterFailure = true
    }

    /// 登录手机号步：聚焦 login.phone 输入手机号后，主按钮【获取验证码】login.getCode 不滚动即在键盘以上、可点、余量 ≥ 12。
    func testLoginPhoneStepGetCodeAboveKeyboard() {
        for (tier, extra) in Self.tiers {
            let app = launch(extra)
            defer { app.terminate() }
            let page = "登录手机号步"
            guard openLogin(app, page, tier) else { continue }
            type(app.textFields["login.phone"], Self.phone)
            check(app, page, tier, app.buttons["login.getCode"])
        }
    }

    /// 登录验证码步：发码进验证码步，聚焦 login.code 输入验证码后，主按钮【登录】login.submit 不滚动即在键盘以上、可点、余量 ≥ 12。
    func testLoginCodeStepSubmitAboveKeyboard() {
        for (tier, extra) in Self.tiers {
            let app = launch(extra)
            defer { app.terminate() }
            let page = "登录验证码步"
            guard openLogin(app, page, tier) else { continue }
            type(app.textFields["login.phone"], Self.phone)
            let getCode = app.buttons["login.getCode"]
            makeHittable(app, getCode)
            getCode.tap()
            let agree = app.buttons["同意并继续"]
            guard need(agree, 5, "\(page)/\(tier)：未勾选点【获取验证码】没有弹确认框") else { continue }
            agree.tap()
            guard need(element(app, "login.codeTitle"), 10, "\(page)/\(tier)：没有进验证码步") else { continue }
            let code = app.textFields["login.code"]
            guard need(code, 5, "\(page)/\(tier)：缺验证码框 login.code") else { continue }
            type(code, "482913")
            check(app, page, tier, app.buttons["login.submit"])
        }
    }

    /// 绑手机手机号步：微信登录 →【去绑定】进绑手机页，聚焦 bindPhone.phone 输入手机号后，主按钮【获取验证码】bindPhone.getCode
    /// 不滚动即在键盘以上、可点、余量 ≥ 12。
    func testBindPhonePhoneStepGetCodeAboveKeyboard() {
        for (tier, extra) in Self.tiers {
            let app = launch(extra)
            defer { app.terminate() }
            let page = "绑手机手机号步"
            guard openBindPhone(app, page, tier) else { continue }
            let field = app.textFields["bindPhone.phone"]
            guard need(field, 5, "\(page)/\(tier)：缺手机号框 bindPhone.phone") else { continue }
            type(field, Self.phone)
            check(app, page, tier, app.buttons["bindPhone.getCode"])
        }
    }
}

// MARK: - 导航（只在断言前用；断言阶段不滚动）

private extension FuLoginKeyboardAvoidTests {
    func launch(_ extra: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += Self.base + extra
        app.launch()
        return app
    }

    func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any)[id].firstMatch
    }

    func openLogin(_ app: XCUIApplication, _ page: String, _ tier: String) -> Bool {
        guard need(ShellTabBar.bar(app), 30, "\(page)/\(tier)：没有进入 Tab 外壳") else { return false }
        ShellTabBar.tap(app, "订单")
        return need(element(app, "login.page"), 10, "\(page)/\(tier)：游客点订单没有进登录页")
    }

    func openBindPhone(_ app: XCUIApplication, _ page: String, _ tier: String) -> Bool {
        guard openLogin(app, page, tier), reveal(app, "login.wechat", "\(page)/\(tier)") else { return false }
        element(app, "login.wechat").tap()
        let agree = app.buttons["同意并继续"]
        guard need(agree, 5, "\(page)/\(tier)：没有协议确认框") else { return false }
        agree.tap()
        let bind = app.buttons["去绑定"]
        guard need(bind, 10, "\(page)/\(tier)：没有【去绑定】") else { return false }
        if !bind.isHittable {
            app.swipeUp()
        }
        bind.tap()
        return need(element(app, "bindPhone.page"), 10, "\(page)/\(tier)：没有进绑手机页")
    }

    /// 等元素出现，没出现记 XCTFail 并返回 false（不中止用例，继续下一档）。
    func need(_ target: XCUIElement, _ timeout: TimeInterval, _ why: String) -> Bool {
        if target.waitForExistence(timeout: timeout) {
            return true
        }
        XCTFail(why)
        return false
    }

    /// 滚到元素出现且可点（BindPhoneLayoutShotTests.reveal 同写法）。
    func reveal(_ app: XCUIApplication, _ id: String, _ context: String) -> Bool {
        let target = element(app, id)
        var found = target.waitForExistence(timeout: 5)
        let screen = app.windows.firstMatch.frame
        for _ in 0..<6 where !found || !target.isHittable || !screen.contains(target.frame) {
            app.swipeUp()
            found = target.waitForExistence(timeout: 2)
        }
        if !found {
            XCTFail("\(context)：没有 \(id)")
        }
        return found
    }

    /// 导航途中按钮被键盘盖住时，从键盘上沿以上的内容区往上拖到可点（最多 3 次；只用于进验证码步前点【获取验证码】）。
    func makeHittable(_ app: XCUIApplication, _ target: XCUIElement) {
        for _ in 0..<3 where !target.exists || !target.isHittable {
            let win = app.windows.firstMatch.frame
            let keyboard = app.keyboards.firstMatch
            let bottom = keyboard.exists ? keyboard.frame.minY : win.maxY
            let startY = min(bottom - 40, 420)
            let endY = max(win.minY + 100, startY - 300)
            if startY - endY > 40 {
                let origin = app.coordinate(withNormalizedOffset: .zero)
                origin.withOffset(CGVector(dx: win.midX, dy: startY))
                    .press(forDuration: 0.05, thenDragTo: origin.withOffset(CGVector(dx: win.midX, dy: endY)))
            } else {
                app.swipeUp()
            }
            _ = UIWait.untilQuietly(seconds: 2) { target.exists && target.isHittable }
        }
    }

    func type(_ field: XCUIElement, _ text: String) {
        field.tap()
        field.typeText(text)
    }
}

// MARK: - 断言

private extension FuLoginKeyboardAvoidTests {
    /// 等键盘弹起、键盘与主按钮位置停稳（frame 连续两次不变，上限 3 秒），不滚动，断言主按钮整块在窗口内、在键盘以上
    /// 留 ≥ 12pt、可点。
    func check(_ app: XCUIApplication, _ page: String, _ tier: String, _ button: XCUIElement) {
        let keyboard = app.keyboards.firstMatch
        guard need(keyboard, 5, "\(page)/\(tier)：键盘没有弹起"),
              need(button, 5, "\(page)/\(tier)：主按钮不存在") else { return }
        var last: [CGRect] = []
        var still = 0
        let settled = UIWait.until("\(page)/\(tier)：键盘与主按钮位置停稳", ceiling: 3) {
            guard keyboard.exists, button.exists else { return false }
            let now = [keyboard.frame, button.frame]
            still = now == last ? still + 1 : 0
            last = now
            return still >= 2
        }
        guard settled, keyboard.exists, button.exists else { return }
        let win = app.windows.firstMatch.frame
        let frame = button.frame
        let kbd = keyboard.frame
        let margin = kbd.minY - frame.maxY
        let facts = "按钮 frame=\(text(frame)) 键盘 frame=\(text(kbd)) 窗口=\(text(win)) "
            + "余量=\(String(format: "%.1f", margin))"
        XCTAssertTrue(button.isHittable, "\(page)/\(tier)：主按钮不可点；\(facts)")
        XCTAssertTrue(win.contains(frame), "\(page)/\(tier)：主按钮不完全在窗口内；\(facts)")
        XCTAssertGreaterThanOrEqual(
            margin, Self.minMargin, "\(page)/\(tier)：主按钮与键盘顶余量不足 \(Int(Self.minMargin))pt；\(facts)"
        )
    }

    func text(_ rect: CGRect) -> String {
        String(format: "(%.1f,%.1f,%.1f,%.1f)", rect.minX, rect.minY, rect.width, rect.height)
    }
}
