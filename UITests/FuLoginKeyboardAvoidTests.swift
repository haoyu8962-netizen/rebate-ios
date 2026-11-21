import XCTest

/// FU-LOGIN-KEYBOARD-AVOID-ios（D10-2378 缺陷、D10-2458 范围三处；规划视觉验收 §2.4：最大字号与最小宽度下键盘弹起时主按钮
/// 整块可见、可点）。登录手机号步、登录验证码步、绑手机手机号步 × 三档（默认 / AXXXL / 320 宽 + AXXXL），每档单独冷启动、跑完
/// terminate。聚焦输入框、输入合法值、等键盘弹起且键盘与主按钮位置停稳后，**不滚动**，断言主按钮存在、可点、整块在窗口内、
/// 与键盘顶余量 ≥ 12pt（余量 = 键盘 minY − 按钮 maxY）。某档导航前提不满足时记失败并继续下一档。不截图（带键盘截图不入库）。
/// r2 补断言（首轮评审 review-r1 S1-1 / S2-1 / S2-3 / S2-4）：正在输入的框整块在顶栏之下、键盘顶与钉底栏上沿之上（用户看得到
/// 自己输入的内容）；绑手机【获取验证码】与钉底提交栏上沿留 ≥ 12pt；绑手机默认档聚焦前后输入框不动（≤ 1pt）；键盘收起后主按钮
/// 回到聚焦前的位置（≤ 1pt），验证码步另核【登录】只有一个、回到协议行与【登录遇到问题】之间。
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
    /// 钉底栏按钮上方留白（绑手机 bottomBar 与登录验证码步 pinnedSubmitBar 都是 `.padding(.top, CouliSpacing.s3)`）：
    /// 栏上沿 = 栏内按钮 minY − 12。
    private static let barTopPadding: CGFloat = 12
    /// 「位置不变」的容差（S2-1 / S2-4）。
    private static let sameTolerance: CGFloat = 1
    private static let phone = "13800005678"

    override func setUp() async throws {
        continueAfterFailure = true
    }

    /// 登录手机号步：聚焦 login.phone 输入手机号后，主按钮【获取验证码】login.getCode 不滚动即在键盘以上、可点、余量 ≥ 12；
    /// 手机号框整块可见；键盘收起后【获取验证码】回到聚焦前的位置。
    func testLoginPhoneStepGetCodeAboveKeyboard() {
        for (tier, extra) in Self.tiers {
            let app = launch(extra)
            defer { app.terminate() }
            let page = "登录手机号步"
            guard openLogin(app, page, tier) else { continue }
            let field = app.textFields["login.phone"]
            let button = app.buttons["login.getCode"]
            let before = baseline(page, tier, button)
            type(field, Self.phone)
            if check(app, page, tier, button) {
                checkFieldVisible(app, page, tier, field,
                                  within: (loginTopBarBottom(app), button.frame.minY - Self.barTopPadding))
            }
            checkRestored(app, page, tier, button, before)
        }
    }

    /// 登录验证码步：发码进验证码步，先收起自动弹出的键盘记【登录】原位，再聚焦 login.code 输入验证码，主按钮【登录】
    /// login.submit 不滚动即在键盘以上、可点、余量 ≥ 12；验证码框整块可见；键盘收起后【登录】只有一个、回到原位。
    func testLoginCodeStepSubmitAboveKeyboard() {
        for (tier, extra) in Self.tiers {
            let app = launch(extra)
            defer { app.terminate() }
            let page = "登录验证码步"
            guard openLogin(app, page, tier), openCodeStep(app, page, tier) else { continue }
            let code = app.textFields["login.code"]
            guard need(code, 5, "\(page)/\(tier)：缺验证码框 login.code") else { continue }
            let button = app.buttons["login.submit"]
            // 进验证码步时验证码框自动聚焦、键盘已弹起：先收起，记键盘收起时【登录】的原位
            let before = dismissKeyboard(app, page, tier, "记原位前") ? baseline(page, tier, button) : nil
            type(code, "482913")
            if check(app, page, tier, button) {
                checkFieldVisible(app, page, tier, code,
                                  within: (loginTopBarBottom(app), button.frame.minY - Self.barTopPadding))
            }
            if checkRestored(app, page, tier, button, before) {
                checkSubmitBackInPlace(app, page, tier)
            }
        }
    }

    /// 绑手机手机号步：微信登录 →【去绑定】进绑手机页，聚焦 bindPhone.phone 输入手机号后，主按钮【获取验证码】bindPhone.getCode
    /// 不滚动即在键盘以上、可点、余量 ≥ 12，且与钉底提交栏上沿留 ≥ 12；手机号框整块可见；默认档手机号框不动；键盘收起后
    /// 【获取验证码】回到聚焦前的位置。
    func testBindPhonePhoneStepGetCodeAboveKeyboard() {
        for (tier, extra) in Self.tiers {
            let app = launch(extra)
            defer { app.terminate() }
            let page = "绑手机手机号步"
            guard openBindPhone(app, page, tier) else { continue }
            let field = app.textFields["bindPhone.phone"]
            guard need(field, 5, "\(page)/\(tier)：缺手机号框 bindPhone.phone") else { continue }
            let button = app.buttons["bindPhone.getCode"]
            let submit = app.buttons["bindPhone.submit"]
            let before = baseline(page, tier, button)
            let fieldBefore = field.frame
            type(field, Self.phone)
            if check(app, page, tier, button), need(submit, 5, "\(page)/\(tier)：缺钉底提交栏 bindPhone.submit") {
                let barTop = submit.frame.minY - Self.barTopPadding
                checkAboveBar(page, tier, button, barTop: barTop)
                checkFieldVisible(app, page, tier, field, within: (bindPhoneTopBarBottom(app), barTop))
                if tier == "normal" {
                    checkFieldUnmoved(page, tier, field, fieldBefore)
                }
            }
            checkRestored(app, page, tier, button, before)
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

    /// 手机号步输入号码 → 未勾选点【获取验证码】→【同意并继续】→ 进验证码步。
    func openCodeStep(_ app: XCUIApplication, _ page: String, _ tier: String) -> Bool {
        type(app.textFields["login.phone"], Self.phone)
        let getCode = app.buttons["login.getCode"]
        makeHittable(app, getCode)
        getCode.tap()
        let agree = app.buttons["同意并继续"]
        guard need(agree, 5, "\(page)/\(tier)：未勾选点【获取验证码】没有弹确认框") else { return false }
        agree.tap()
        return need(element(app, "login.codeTitle"), 10, "\(page)/\(tier)：没有进验证码步")
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

    /// 收起键盘：两页都没有收键盘的按钮（号码 / 验证码键盘无回车），ScrollView 拖动即收（scrollDismissesKeyboard 缺省）。
    /// 从顶栏下 40pt 往下短拖 100pt（不点到输入框、不碰键盘与钉底栏；内容在顶时回弹、不改滚动位置），最多 3 次，再等键盘消失。
    func dismissKeyboard(_ app: XCUIApplication, _ page: String, _ tier: String, _ when: String) -> Bool {
        let keyboard = app.keyboards.firstMatch
        let win = app.windows.firstMatch.frame
        let top = max(loginTopBarBottom(app), bindPhoneTopBarBottom(app), win.minY)
        for _ in 0..<3 where keyboard.exists {
            let origin = app.coordinate(withNormalizedOffset: .zero)
            origin.withOffset(CGVector(dx: win.midX, dy: top + 40))
                .press(forDuration: 0.05, thenDragTo: origin.withOffset(CGVector(dx: win.midX, dy: top + 140)))
            _ = UIWait.untilQuietly(seconds: 2) { !keyboard.exists }
        }
        return UIWait.until("\(page)/\(tier)：\(when)收起键盘", ceiling: 3) { !keyboard.exists }
    }

    /// 登录页顶栏下沿：顶栏只有关闭 / 返回与【设置】两个 44pt 命中区，无上下留白，取二者 maxY 的较大者。
    func loginTopBarBottom(_ app: XCUIApplication) -> CGFloat {
        bottomEdge([element(app, "login.close"), element(app, "login.settings")])
    }

    /// 绑手机顶栏下沿：标题（最多两行）与返回键（minHeight 44）叠放，取二者 maxY 的较大者。
    func bindPhoneTopBarBottom(_ app: XCUIApplication) -> CGFloat {
        bottomEdge([element(app, "bindPhone.title"), element(app, "bindPhone.back")])
    }

    func bottomEdge(_ elements: [XCUIElement]) -> CGFloat {
        elements.filter(\.exists).map(\.frame.maxY).max() ?? 0
    }
}

// MARK: - 断言

private extension FuLoginKeyboardAvoidTests {
    /// 等这些元素的 frame 连续两次不变（每 0.2 秒取一次，即 3 次读数相同；上限 3 秒，超时由 UIWait 记失败）。
    func settle(_ what: String, _ elements: [XCUIElement]) -> Bool {
        var last: [CGRect] = []
        var still = 0
        return UIWait.until(what, ceiling: 3) {
            guard elements.allSatisfy(\.exists) else { return false }
            let now = elements.map(\.frame)
            still = now == last ? still + 1 : 0
            last = now
            return still >= 2
        }
    }

    /// 聚焦前主按钮停稳后的 frame（S2-4 的对照）；取不到时记失败并返回 nil（后面只跳过「收起后复位」一条）。
    func baseline(_ page: String, _ tier: String, _ button: XCUIElement) -> CGRect? {
        guard need(button, 5, "\(page)/\(tier)：聚焦前主按钮不存在"),
              settle("\(page)/\(tier)：聚焦前主按钮位置停稳", [button]) else { return nil }
        return button.frame
    }

    /// 等键盘弹起、键盘与主按钮位置停稳（frame 连续两次不变，上限 3 秒），不滚动，断言主按钮整块在窗口内、在键盘以上
    /// 留 ≥ 12pt、可点。返回是否走到了断言（键盘与按钮都在且停稳）。
    @discardableResult
    func check(_ app: XCUIApplication, _ page: String, _ tier: String, _ button: XCUIElement) -> Bool {
        let keyboard = app.keyboards.firstMatch
        guard need(keyboard, 5, "\(page)/\(tier)：键盘没有弹起"),
              need(button, 5, "\(page)/\(tier)：主按钮不存在") else { return false }
        let settled = settle("\(page)/\(tier)：键盘与主按钮位置停稳", [keyboard, button])
        guard settled, keyboard.exists, button.exists else { return false }
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
        return true
    }

    /// S1-1：键盘弹起、不滚动时，正在输入的框整块在「窗口顶 / 顶栏下沿」之下、「键盘顶 / 钉底栏上沿」之上。
    /// `bounds.bottom` 由调用方给：登录页取主按钮 minY − 12（输入框在主按钮之上；钉底时即栏上沿），绑手机取提交栏上沿；再与键盘顶取小。
    func checkFieldVisible(
        _ app: XCUIApplication, _ page: String, _ tier: String, _ field: XCUIElement,
        within bounds: (top: CGFloat, bottom: CGFloat)
    ) {
        let keyboard = app.keyboards.firstMatch
        guard field.exists, keyboard.exists else {
            XCTFail("\(page)/\(tier)：核输入框可见时输入框或键盘不在")
            return
        }
        let win = app.windows.firstMatch.frame
        let frame = field.frame
        let upper = max(bounds.top, win.minY)
        let lower = min(bounds.bottom, keyboard.frame.minY)
        let facts = "输入框 frame=\(text(frame)) 上界=\(String(format: "%.1f", upper)) "
            + "下界=\(String(format: "%.1f", lower)) 键盘 frame=\(text(keyboard.frame))"
        XCTAssertGreaterThanOrEqual(frame.minY, upper, "\(page)/\(tier)：输入框上沿被顶栏或窗口顶挡住；\(facts)")
        XCTAssertLessThanOrEqual(frame.maxY, lower, "\(page)/\(tier)：输入框下沿被键盘或钉底栏挡住；\(facts)")
    }

    /// S2-3：绑手机【获取验证码】下沿 + 12 ≤ 钉底提交栏上沿（= bindPhone.submit.minY − 栏上留白 12）。
    func checkAboveBar(_ page: String, _ tier: String, _ button: XCUIElement, barTop: CGFloat) {
        let frame = button.frame
        let gap = barTop - frame.maxY
        XCTAssertGreaterThanOrEqual(
            gap, Self.minMargin,
            "\(page)/\(tier)：主按钮与钉底栏上沿余量不足 \(Int(Self.minMargin))pt；按钮 frame=\(text(frame)) "
                + "栏上沿=\(String(format: "%.1f", barTop)) 余量=\(String(format: "%.1f", gap))"
        )
    }

    /// S2-1：默认档聚焦、输入后输入框 minY 与聚焦前相差 ≤ 1pt（本来就看得见，不该滚）。
    func checkFieldUnmoved(_ page: String, _ tier: String, _ field: XCUIElement, _ before: CGRect) {
        let after = field.frame
        XCTAssertLessThanOrEqual(
            abs(after.minY - before.minY), Self.sameTolerance,
            "\(page)/\(tier)：聚焦后输入框移动了；聚焦前 frame=\(text(before)) 聚焦后 frame=\(text(after))"
        )
    }

    /// S2-4：收起键盘、主按钮停稳后，frame 四边与聚焦前相差都 ≤ 1pt。`before` 为 nil（没取到原位）时只记失败。
    /// 返回是否走到了比较（键盘已收起且按钮停稳）。
    @discardableResult
    func checkRestored(
        _ app: XCUIApplication, _ page: String, _ tier: String, _ button: XCUIElement, _ before: CGRect?
    ) -> Bool {
        guard let before else {
            XCTFail("\(page)/\(tier)：没有取到聚焦前主按钮原位，跳过收起后复位比较")
            return false
        }
        guard dismissKeyboard(app, page, tier, "断言完"),
              need(button, 5, "\(page)/\(tier)：收起键盘后主按钮不存在"),
              settle("\(page)/\(tier)：收起键盘后主按钮位置停稳", [button]) else { return false }
        let after = button.frame
        let drift = [after.minX - before.minX, after.minY - before.minY, after.maxX - before.maxX,
                     after.maxY - before.maxY].map(abs).max() ?? 0
        XCTAssertLessThanOrEqual(
            drift, Self.sameTolerance,
            "\(page)/\(tier)：键盘收起后主按钮没回原位；聚焦前 frame=\(text(before)) 收起后 frame=\(text(after)) "
                + "最大偏差=\(String(format: "%.1f", drift))"
        )
        return true
    }

    /// S2-4（验证码步）：键盘收起后【登录】只有一个，且回到协议行之下、【登录遇到问题】之上（不再钉底）。
    func checkSubmitBackInPlace(_ app: XCUIApplication, _ page: String, _ tier: String) {
        let submits = app.buttons.matching(identifier: "login.submit")
        XCTAssertEqual(submits.count, 1, "\(page)/\(tier)：键盘收起后【登录】应只有一个")
        let submit = submits.firstMatch
        let agree = element(app, "login.agreeCheckbox")
        let help = element(app, "login.help")
        guard submit.exists, need(agree, 2, "\(page)/\(tier)：缺协议勾选 login.agreeCheckbox"),
              need(help, 2, "\(page)/\(tier)：缺【登录遇到问题】login.help") else { return }
        let facts = "登录 frame=\(text(submit.frame)) 协议 frame=\(text(agree.frame)) 帮助 frame=\(text(help.frame))"
        XCTAssertLessThanOrEqual(agree.frame.maxY, submit.frame.minY, "\(page)/\(tier)：【登录】不在协议行之下；\(facts)")
        XCTAssertLessThanOrEqual(submit.frame.maxY, help.frame.minY, "\(page)/\(tier)：【登录】仍在钉底位置；\(facts)")
    }

    func text(_ rect: CGRect) -> String {
        String(format: "(%.1f,%.1f,%.1f,%.1f)", rect.minX, rect.minY, rect.width, rect.height)
    }
}
