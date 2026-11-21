import XCTest

/// FU-LOGIN-KEYBOARD-AVOID-ios（D10-2378 缺陷、D10-2458 范围三处；规划视觉验收 §2.4：最大字号与最小宽度下键盘弹起时主按钮
/// 整块可见、可点）。登录手机号步、登录验证码步、绑手机手机号步 × 三档（默认 / AXXXL / 320 宽 + AXXXL），每档单独冷启动、跑完
/// terminate。聚焦输入框、输入合法值、等键盘弹起且键盘与主按钮位置停稳后，**不滚动**，断言主按钮存在、可点、整块在窗口内、
/// 与键盘顶余量 ≥ 12pt（余量 = 键盘 minY − 按钮 maxY）。某档导航前提不满足时记失败并继续下一档。不截图（带键盘截图不入库）。
/// r2（review-r1）：输入框整块在顶栏之下、键盘顶与钉底栏上沿之上；绑手机默认档聚焦前后输入框不动（≤ 1pt）。
/// r4（D10-2472）：栏上沿按实际留白 12 算；绑手机【获取验证码】离栏上沿 ≥ 12；收起后复位改结构判定（②）；输入框可见仅
/// 「绑手机 · 320 + AXXXL」一档放宽外框上沿 ≤ 16（①，见 checkFieldVisible）。
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
    /// 栏上沿 = 底栏里最上面那颗按钮的 minY − 12（D10-2472：两页底栏顶部留白实际都是 CouliSpacing.s3 = 12）。
    /// 底栏按钮：登录页 login.getCode / login.submit（钉底时），绑手机 bindPhone.submit。登录页主按钮不钉底时在内容里、排在
    /// 输入框之下，这个值仍是输入框的下界。
    private static let barTopAllowance: CGFloat = 12
    private static let sameTolerance: CGFloat = 1 // 「位置不变」的容差（S2-1）
    private static let outerFrameAllowance: CGFloat = 16 // 仅绑手机 · 320 + AXXXL：外框上沿可进顶栏（D10-2472 ①）
    private static let textMidClearance: CGFloat = 8 // 同档：外框中线须在顶栏下沿以下至少 8pt
    private static let phone = "13800005678"

    override func setUp() async throws {
        continueAfterFailure = true
    }

    /// 登录手机号步：聚焦 login.phone 输入手机号后，主按钮【获取验证码】login.getCode 不滚动即在键盘以上、可点、余量 ≥ 12；
    /// 手机号框整块可见；键盘收起后【获取验证码】只有一个、不在底栏、在手机号框之下。
    func testLoginPhoneStepGetCodeAboveKeyboard() {
        for (tier, extra) in Self.tiers {
            let app = launch(extra)
            defer { app.terminate() }
            let page = "登录手机号步"
            guard openLogin(app, page, tier) else { continue }
            let field = app.textFields["login.phone"]
            let button = app.buttons["login.getCode"]
            type(field, Self.phone)
            if check(app, page, tier, button) {
                checkFieldVisible(app, page, tier, field, within: (loginTopBarBottom(app), barTop([button])))
            }
            let ctx = "\(page)/\(tier)"
            let scene = KeyboardScene(page: "login.page", field: field, bar: [button])
            if checkRestored(app, ctx, "login.getCode", scene) {
                checkOrderBelow(ctx, upper: field, lower: button, sameRowRight: false)
            }
        }
    }

    /// 登录验证码步：发码进验证码步（验证码框自动聚焦），在 login.code 输入验证码，主按钮【登录】login.submit 不滚动即在键盘
    /// 以上、可点、余量 ≥ 12；验证码框整块可见；键盘收起后【登录】只有一个、不在底栏、在协议行与【登录遇到问题】之间。
    func testLoginCodeStepSubmitAboveKeyboard() {
        for (tier, extra) in Self.tiers {
            let app = launch(extra)
            defer { app.terminate() }
            let page = "登录验证码步"
            guard openLogin(app, page, tier), openCodeStep(app, page, tier) else { continue }
            let code = app.textFields["login.code"]
            guard need(code, 5, "\(page)/\(tier)：缺验证码框 login.code") else { continue }
            let button = app.buttons["login.submit"]
            type(code, "482913")
            if check(app, page, tier, button) {
                checkFieldVisible(app, page, tier, code, within: (loginTopBarBottom(app), barTop([button])))
            }
            let scene = KeyboardScene(page: "login.page", field: code, bar: [button])
            if checkRestored(app, "\(page)/\(tier)", "login.submit", scene) {
                checkSubmitBackInPlace(app, page, tier)
            }
        }
    }

    /// 绑手机手机号步：微信登录 →【去绑定】进绑手机页，聚焦 bindPhone.phone 输入手机号后，主按钮【获取验证码】bindPhone.getCode
    /// 不滚动即在键盘以上、可点、余量 ≥ 12，且离钉底提交栏上沿 ≥ 12（按钮始终在滚动内容里）；手机号框整块在顶栏之下、栏上沿
    /// 之上；默认档手机号框不动；键盘收起后【获取验证码】只有一个、不在底栏、在手机号框之下或同一行右侧。
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
            let ctx = "\(page)/\(tier)"
            _ = settle("\(ctx)：聚焦前手机号框位置停稳", [field])
            let fieldBefore = field.frame
            type(field, Self.phone)
            if check(app, page, tier, button), need(submit, 5, "\(ctx)：缺钉底提交栏 bindPhone.submit") {
                checkAboveBar(ctx, button, barTop: barTop([submit]))
                checkFieldVisible(app, page, tier, field, within: (bindPhoneTopBarBottom(app), barTop([submit])))
                if tier == "normal" {
                    checkFieldUnmoved(page, tier, field, fieldBefore)
                }
            }
            let scene = KeyboardScene(page: "bindPhone.page", field: field, bar: [submit])
            if checkRestored(app, ctx, "bindPhone.getCode", scene) {
                checkOrderBelow(ctx, upper: field, lower: button, sameRowRight: true)
            }
        }
    }
}

/// 收起键盘与结构判定用到的页面信息：页面标识（找主 ScrollView）、正在输入的框（拖动起点要避开）、底栏按钮（算栏上沿）。
private struct KeyboardScene {
    let page: String
    let field: XCUIElement
    let bar: [XCUIElement]
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

    /// 收起键盘（r3）：两页 ScrollView 是 `.scrollDismissesKeyboard(.interactively)`，要从内容区一路拖进键盘、越过键盘顶才收。
    /// 起点：栏上沿（`bar` 里最上面那颗按钮 minY − 12）与键盘顶取小，再往上 60pt，水平居中；落在输入框上时挪到输入框上方 20pt
    /// （不低于顶栏下沿 + 10）。慢速拖到键盘顶下方 150pt（按 0.1 秒、`.slow`），最多 3 次，再等键盘消失（上限 3 秒）。
    func dismissKeyboard(_ app: XCUIApplication, _ what: String, avoid field: XCUIElement, bar: [XCUIElement]) -> Bool {
        let keyboard = app.keyboards.firstMatch
        for _ in 0..<3 where keyboard.exists {
            let win = app.windows.firstMatch.frame
            let kbdTop = keyboard.frame.minY
            let floor = max(loginTopBarBottom(app), bindPhoneTopBarBottom(app), win.minY) + 10
            var startY = min(barTop(bar), kbdTop) - 60
            if field.exists, field.frame.insetBy(dx: 0, dy: -8).minY <= startY,
               startY <= field.frame.insetBy(dx: 0, dy: -8).maxY {
                startY = max(field.frame.minY - 20, floor)
            }
            let origin = app.coordinate(withNormalizedOffset: .zero)
            origin.withOffset(CGVector(dx: win.midX, dy: startY)).press(
                forDuration: 0.1, thenDragTo: origin.withOffset(CGVector(dx: win.midX, dy: kbdTop + 150)),
                withVelocity: .slow, thenHoldForDuration: 0
            )
            _ = UIWait.untilQuietly(seconds: 2) { !keyboard.exists }
        }
        return UIWait.until("\(what)收起键盘", ceiling: 3) { !keyboard.exists }
    }

    /// 栏上沿口径：`bar` 里现存按钮的最小 minY − 12（没有可用按钮时不设限，调用方再与键盘顶取小）。
    func barTop(_ bar: [XCUIElement]) -> CGFloat {
        let tops = bar.filter(\.exists).map(\.frame.minY)
        guard let top = tops.min() else { return .greatestFiniteMagnitude }
        return top - Self.barTopAllowance
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
    /// `bounds.bottom` 由调用方给：栏上沿口径 `barTop`（登录页取主按钮，绑手机取【绑定】）；再与键盘顶取小。
    /// 仅此一档，D10-2472 ①：「绑手机 · 320 + AXXXL」。TextField 撑满外框（PhoneNumberField.swift:77 maxHeight .infinity、:113
    /// 整行 minHeight），`bindPhone.phone` 的 frame 当外框：外框 minY ≥ 顶栏下沿 − 16、maxY ≤ 下界（下沿不放宽），另近似核文字行：
    /// 外框 midY ≥ 顶栏下沿 + 8。文字行完整可见由视觉验收该档的遮罩截图人工核。其他档与登录两步照旧整块可见。
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
        let facts = "输入框 frame=\(text(frame)) 上界=\(String(format: "%.1f", upper)) 下界=\(String(format: "%.1f", lower))"
        let relaxed = page == "绑手机手机号步" && tier == "w320-AXXXL"
        let slack = relaxed ? Self.outerFrameAllowance : 0
        XCTAssertGreaterThanOrEqual(frame.minY, upper - slack, "\(page)/\(tier)：输入框上沿被顶栏挡住（放宽 \(slack)）；\(facts)")
        if relaxed {
            XCTAssertGreaterThanOrEqual(frame.midY, upper + Self.textMidClearance,
                                        "\(page)/\(tier)：框中线离顶栏下沿 < 8；\(facts)")
        }
        XCTAssertLessThanOrEqual(frame.maxY, lower, "\(page)/\(tier)：输入框下沿被键盘或钉底栏挡住；\(facts)")
    }

    /// S2-3（D10-2472 恢复 r3 前定义）：绑手机【获取验证码】下沿 + 12 ≤ 钉底提交栏上沿（= bindPhone.submit.minY − 12）。
    func checkAboveBar(_ ctx: String, _ button: XCUIElement, barTop: CGFloat) {
        let frame = button.frame
        let gap = barTop - frame.maxY
        XCTAssertGreaterThanOrEqual(
            gap, Self.minMargin,
            "\(ctx)：主按钮与钉底栏上沿余量不足 \(Int(Self.minMargin))pt；按钮 frame=\(text(frame)) "
                + "栏上沿=\(String(format: "%.1f", barTop)) 余量=\(String(format: "%.1f", gap))"
        )
    }

    /// S2-1：默认档聚焦、输入后输入框 minY 与聚焦前相差 ≤ 1pt（本来就看得见，不该滚）。
    func checkFieldUnmoved(_ page: String, _ tier: String, _ field: XCUIElement, _ before: CGRect) {
        let after = field.frame
        XCTAssertLessThanOrEqual(abs(after.minY - before.minY), Self.sameTolerance,
                                 "\(page)/\(tier)：聚焦后输入框移动了；聚焦前 frame=\(text(before)) 聚焦后 frame=\(text(after))")
    }

    /// S2-4（D10-2472 ②，结构判定）：收起键盘、停稳后 (c) identifier 只有一个；(a) 不在底栏＝是页面主 ScrollView（页内最高的
    /// scrollView；底栏是 safeAreaInset、不在其内）的后代；(b) 先后顺序由调用方另核。返回是否走到了判定。
    @discardableResult
    func checkRestored(_ app: XCUIApplication, _ ctx: String, _ id: String, _ layout: KeyboardScene) -> Bool {
        let button = app.buttons[id]
        guard dismissKeyboard(app, "\(ctx)：断言完", avoid: layout.field, bar: layout.bar),
              need(button, 5, "\(ctx)：收起键盘后主按钮不存在"),
              settle("\(ctx)：收起键盘后主按钮位置停稳", [button]) else { return false }
        XCTAssertEqual(app.buttons.matching(identifier: id).count, 1, "\(ctx)：键盘收起后 \(id) 应只有一个")
        let scrolls = element(app, layout.page).scrollViews.allElementsBoundByIndex
        guard let main = scrolls.max(by: { $0.frame.height < $1.frame.height }) else {
            XCTFail("\(ctx)：页面 \(layout.page) 里找不到滚动区，无法判定主按钮是否在底栏")
            return true
        }
        XCTAssertTrue(
            main.descendants(matching: .button)[id].exists,
            "\(ctx)：键盘收起后 \(id) 仍在底栏（不在滚动内容里）；按钮 frame=\(text(button.frame)) 滚动区=\(text(main.frame))"
        )
        return true
    }

    /// S2-4 (b)：键盘收起后主按钮在输入框之下（`lower.minY ≥ upper.maxY`）；`sameRowRight` 时同一行右侧也算（绑手机）。
    func checkOrderBelow(_ ctx: String, upper: XCUIElement, lower: XCUIElement, sameRowRight: Bool) {
        guard upper.exists, lower.exists else {
            XCTFail("\(ctx)：核先后顺序时输入框或主按钮不在")
            return
        }
        let top = upper.frame
        let bottom = lower.frame
        let below = bottom.minY >= top.maxY
        let rightSameRow = sameRowRight && bottom.minX >= top.maxX && bottom.minY < top.maxY && bottom.maxY > top.minY
        XCTAssertTrue(below || rightSameRow,
                      "\(ctx)：键盘收起后主按钮不在输入框之下（或同行右侧）；输入框=\(text(top)) 主按钮=\(text(bottom))")
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
