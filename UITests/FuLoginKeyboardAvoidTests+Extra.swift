import XCTest

/// FU-LOGIN-KEYBOARD-AVOID-ios 评审 r2（review-r2 S2-1 / S2-2）补的两条用例；主文件 FuLoginKeyboardAvoidTests.swift 已到
/// swiftlint 行数上限，拆到这里。导航、停稳、断言辅助都复用主文件。不截图；失败信息带全几何（`geometry`）。
extension FuLoginKeyboardAvoidTests {
    private static let maxType = ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]

    /// review-r2 S2-1：375 宽 + 最大字号的绑手机手机号步按普通档断言（getCode 离栏上沿、离键盘顶 ≥ 12，输入框整块可见，不享受
    /// 极端档放宽），钉住「375 不得误判成极端档」（只有 320 + AXXXL 才是 D10-2495 / 2496 的极端档）。
    func testBindPhone375AXXXLUsesNormalFloors() {
        let page = "绑手机手机号步"
        let tier = "w375-AXXXL"
        let ctx = "\(page)/\(tier)"
        let app = launch(["-CouliDebugLayoutWidth", "375"] + Self.maxType)
        defer {
            app.terminate()
            geometry = nil
        }
        guard openBindPhone(app, page, tier) else { return }
        let field = app.textFields["bindPhone.phone"]
        guard need(field, 5, "\(ctx)：缺手机号框 bindPhone.phone") else { return }
        let button = app.buttons["bindPhone.getCode"]
        let submit = app.buttons["bindPhone.submit"]
        geometry = { [unowned self] in
            geometryLine(app, field: field, primary: button, bar: [submit], top: bindPhoneTopBarBottom(app))
        }
        type(field, "13800005678")
        guard check(app, page, tier, button), need(submit, 5, "\(ctx)：缺钉底提交栏 bindPhone.submit") else { return }
        if let geometry {
            print("KBDGEOM|bind|\(tier)|\(geometry())")
        }
        XCTAssertFalse(Self.narrowBind(page, tier), "\(ctx)：本档不得按极端档放宽")
        checkAboveBar(ctx, button, barTop: barTop([submit]), floor: Self.margin(page, tier))
        checkFieldVisible(app, page, tier, field, within: (bindPhoneTopBarBottom(app), barTop([submit])))
    }

    /// review-r2 S2-2：登录手机号步点「填写邀请码」展开邀请码框、聚焦 login.invite 输入（AXXXL、320 + AXXXL）：邀请码框整块在
    /// 顶栏下沿之下、键盘顶（有底栏时再取栏上沿）之上；login.getCode 不在钉底栏里（结构判定：是页面主 ScrollView 的后代，同收起后
    /// 复位那条）。
    func testLoginInviteFieldVisibleAndPrimaryNotPinned() {
        let tiers = [("AXXXL", Self.maxType), ("w320-AXXXL", ["-CouliDebugLayoutWidth", "320"] + Self.maxType)]
        for (tier, extra) in tiers {
            let app = launch(extra)
            defer { app.terminate() }
            let page = "登录手机号步·邀请码"
            let ctx = "\(page)/\(tier)"
            guard openLogin(app, page, tier), reveal(app, "login.inviteEntry", ctx) else { continue }
            element(app, "login.inviteEntry").tap()
            guard reveal(app, "login.invite", ctx) else { continue }
            let invite = app.textFields["login.invite"]
            let button = app.buttons["login.getCode"]
            geometry = { [unowned self] in
                geometryLine(app, field: invite, primary: button, bar: [button], top: loginTopBarBottom(app))
            }
            defer { geometry = nil }
            type(invite, "AB12CD")
            let keyboard = app.keyboards.firstMatch
            guard need(keyboard, 5, "\(ctx)：键盘没有弹起"), need(button, 5, "\(ctx)：缺 login.getCode"),
                  settle("\(ctx)：键盘、邀请码框与主按钮停稳", [keyboard, invite, button]) else { continue }
            guard let main = mainScroll(app, "login.page") else {
                XCTFail("\(ctx)：登录页里找不到滚动区，无法判定 login.getCode 是否在底栏\(geometryNote)")
                continue
            }
            let inContent = main.descendants(matching: .button)["login.getCode"].exists
            XCTAssertTrue(inContent, "\(ctx)：聚焦邀请码框时 login.getCode 钉进了底栏（不在滚动内容里）\(geometryNote)")
            let bottom = inContent ? CGFloat.greatestFiniteMagnitude : barTop([button])
            checkFieldVisible(app, page, tier, invite, within: (loginTopBarBottom(app), bottom))
        }
    }
}

extension FuLoginKeyboardAvoidTests {
    /// 页面里最高的 scrollView（主 ScrollView；底栏是 safeAreaInset，不在其内）。
    func mainScroll(_ app: XCUIApplication, _ page: String) -> XCUIElement? {
        element(app, page).scrollViews.allElementsBoundByIndex.max { $0.frame.height < $1.frame.height }
    }

    /// 一行几何：输入框、主按钮、顶栏下沿、栏上沿、键盘（元素不在时写 none，不触发读取失败）。
    func geometryLine(
        _ app: XCUIApplication, field: XCUIElement, primary: XCUIElement, bar: [XCUIElement], top: CGFloat
    ) -> String {
        let keyboard = app.keyboards.firstMatch
        let frames = [field, primary, keyboard].map { $0.exists ? text($0.frame) : "none" }
        return "field=\(frames[0])|primary=\(frames[1])|topBar=\(top)|barTop=\(barTop(bar))|kbd=\(frames[2])"
    }
}
