import XCTest

/// FU-IOS-BINDPHONE-LAYOUT（D10-1223）UI 判据：负责人截图的场景（320 宽 + 200%）与 AXXXL，真实 App（Debug + 假服务）走到绑手机页。
/// ① 手机号输入框是单行框、高度不到验证码框（同为 title 字号的单行框）的 1.5 倍（kick 第 6 条「钉住手机号输入框只有一行高」）；
/// ④「获取验证码」「N 秒后重新获取」放不下、换到输入框下方时，要有按钮外观（左或右缘有连续的描边 / 底色），点击区 ≥ 44×44pt。
/// 进程内的四档、顶栏、组件一致判据在 AppTests/BindPhoneLayoutTests.swift。
@MainActor
final class BindPhoneLayoutUITests: XCTestCase {
    override func setUp() async throws {
        continueAfterFailure = false
    }

    func testNarrowLargeTextPhoneOneLineAndCodeButtonLooksLikeButton() throws {
        let app = launchToBindPhone(["-CouliDebugLayoutWidth", "320",
                                     "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityL"])
        try checkPage(app, tier: "320 宽 + 200%")
    }

    func testAccessibilityXXXLPhoneOneLineAndCodeButtonLooksLikeButton() throws {
        let app = launchToBindPhone(["-UIPreferredContentSizeCategoryName",
                                     "UICTContentSizeCategoryAccessibilityXXXL"])
        try checkPage(app, tier: "AXXXL")
    }

    // MARK: - 判据

    private func checkPage(_ app: XCUIApplication, tier: String) throws {
        let button = app.buttons["bindPhone.getCode"]
        XCTAssertTrue(button.waitForExistence(timeout: 5), "[\(tier)] 没有获取验证码按钮")
        checkCodeButton(app, button, tier: tier, state: "获取验证码")

        XCTAssertTrue(app.textFields["bindPhone.phone"].exists,
                      "[\(tier)] ① 手机号要是单行输入框（textField），不是多行 textView")
        let phone = input(app, "bindPhone.phone")
        phone.tap()
        phone.typeText("13800005678")
        let code = app.textFields["bindPhone.code"]
        code.tap()
        XCTAssertEqual(phone.value as? String, "13800005678", "[\(tier)] 号码完整")
        XCTAssertGreaterThan(code.frame.height, 0)
        XCTAssertLessThan(phone.frame.height, code.frame.height * 1.5,
                          "[\(tier)] ① 手机号框只有一行高：手机号 \(phone.frame) / 验证码 \(code.frame)")

        if !button.isHittable {
            app.swipeUp()
        }
        button.tap()
        let countdown = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "秒后重新获取")).firstMatch
        XCTAssertTrue(countdown.waitForExistence(timeout: 10), "[\(tier)] 发码后没有倒计时")
        checkCodeButton(app, button, tier: tier, state: "N 秒后重新获取")
    }

    /// ④ 命中区 ≥ 44×44；换到输入框下方（按钮上沿不高于验证码框下沿）时，按钮框左缘或右缘 0.5～4.5pt 内有一列在竖直中段
    /// （上下各去 25%）≥ 90% 的点与按钮外侧 3pt 处（卡片底）颜色差 > 24：描边或底色都算，光秃秃的文字（两侧是 12pt 留白）不算。
    private func checkCodeButton(_ app: XCUIApplication, _ button: XCUIElement, tier: String, state: String) {
        guard bringClearOfBars(app, button, tier: tier, state: state) else { return }
        let frame = button.frame
        XCTAssertGreaterThanOrEqual(frame.height, 44, "[\(tier) \(state)] ④ 点击区高 ≥ 44：\(frame)")
        XCTAssertGreaterThanOrEqual(frame.width, 44, "[\(tier) \(state)] ④ 点击区宽 ≥ 44：\(frame)")
        let code = app.textFields["bindPhone.code"]
        guard code.exists, frame.minY >= code.frame.maxY - 1 else { return }
        let shot = app.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = "BindPhoneLayout-\(tier)-\(state)"
        attachment.lifetime = .keepAlways
        add(attachment)
        guard let pixels = ScreenPixels(shot.image) else {
            XCTFail("[\(tier) \(state)] 截图读不出像素")
            return
        }
        let outsideX = frame.minX - 3 > 1 ? frame.minX - 3 : frame.maxX + 3
        let reference = pixels.rgb(outsideX, frame.midY)
        let rows = Array(stride(from: frame.minY + frame.height * 0.25, through: frame.maxY - frame.height * 0.25,
                                by: 1))
        var edged = false
        for inset in stride(from: 0.5, through: 4.5, by: 1.0) {
            for column in [frame.minX + inset, frame.maxX - inset] {
                let differing = rows.filter { ScreenPixels.distance(pixels.rgb(column, $0), reference) > 24 }.count
                if !rows.isEmpty, Double(differing) >= 0.9 * Double(rows.count) {
                    edged = true
                }
            }
        }
        XCTAssertTrue(edged, "[\(tier) \(state)] ④ 换到输入框下方后要有按钮外观（描边或底色），不能是一行光秃秃的字：框 \(frame)，"
            + "外侧底色 \(reference)")
    }

    /// 取样前把按钮整块挪到顶栏下沿与底部【绑定】栏上沿之间（v2）：XCUI 的 isHittable 只看中心点，按钮下半截压在底栏的
    /// 12pt 上留白里时也算可点，取样点会落在底栏底色上（impl-ios-handback §4-2）。用慢速拖动小步滚（swipeUp 会甩过头把按钮
    /// 推到顶栏下）；挪不出来直接判失败，不跳过判据。底栏上沿 = 【绑定】按钮上沿 − CouliSpacing.s3（12pt 上内边距）。
    private func bringClearOfBars(_ app: XCUIApplication, _ button: XCUIElement, tier: String, state: String) -> Bool {
        let submit = app.buttons["bindPhone.submit"]
        let title = element(app, "bindPhone.title")
        let back = app.buttons["bindPhone.back"]
        guard submit.exists, title.exists, back.exists else {
            XCTFail("[\(tier) \(state)] 找不到底栏【绑定】或顶栏，无法定位取样区")
            return false
        }
        let origin = app.coordinate(withNormalizedOffset: .zero)
        func limits() -> (top: CGFloat, bottom: CGFloat) {
            (max(title.frame.maxY, back.frame.maxY) + 2, submit.frame.minY - 12 - 2)
        }
        for _ in 0..<8 {
            let (top, bottom) = limits()
            let frame = button.frame
            let shift: CGFloat
            if frame.maxY > bottom {
                shift = -(frame.maxY - bottom + 16)
            } else if frame.minY < top {
                shift = top - frame.minY + 16
            } else {
                return true
            }
            // 起点在按钮左侧 6pt（卡片内边距，不压输入框和按钮），终点限制在可见内容区内
            let startY = min(max(frame.midY, top + 8), bottom - 8)
            let endY = min(max(startY + shift, top + 4), bottom - 4)
            let start = origin.withOffset(CGVector(dx: frame.minX - 6, dy: startY))
            let end = origin.withOffset(CGVector(dx: frame.minX - 6, dy: endY))
            start.press(forDuration: 0.1, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.3)
        }
        let (top, bottom) = limits()
        let frame = button.frame
        XCTAssertTrue(frame.minY >= top && frame.maxY <= bottom,
                      "[\(tier) \(state)] ④ 按钮 \(frame) 挪不到顶栏（下沿 \(top)）与底栏（上沿 \(bottom)）之间：可见内容区放不下整个按钮")
        return frame.minY >= top && frame.maxY <= bottom
    }

    // MARK: - 走到绑手机页（同 OAuthBindPhoneSmokeTests 的链路）

    private func launchToBindPhone(_ extra: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-CouliPrivacyPreset", "consented", "-CouliFakeLoginServer", "-CouliUpdateReset", "1",
                                "-CouliHideDebugInfo", "1"]
        app.launchArguments += extra
        app.launch()
        XCTAssertTrue(ShellTabBar.bar(app).waitForExistence(timeout: 30), "没有进入 Tab 外壳")
        ShellTabBar.tap(app, "订单")
        XCTAssertTrue(element(app, "login.page").waitForExistence(timeout: 10), "游客点订单没有进登录页")
        reveal(app, "login.wechat").tap()
        XCTAssertTrue(app.buttons["同意并继续"].waitForExistence(timeout: 5), "未勾选时没有弹确认框")
        app.buttons["同意并继续"].tap()
        let bind = app.buttons["去绑定"]
        XCTAssertTrue(bind.waitForExistence(timeout: 10), "第三方新号没有弹绑手机引导")
        if !bind.isHittable {
            app.swipeUp()
        }
        bind.tap()
        XCTAssertTrue(element(app, "bindPhone.page").waitForExistence(timeout: 10), "没有进绑手机页")
        return app
    }

    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any)[id].firstMatch
    }

    private func input(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.textFields[id].exists ? app.textFields[id] : app.textViews[id]
    }

    private func reveal(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        let target = element(app, id)
        var found = target.waitForExistence(timeout: 5)
        let screen = app.windows.firstMatch.frame
        for _ in 0..<6 where !found || !target.isHittable || !screen.contains(target.frame) {
            app.swipeUp()
            found = target.waitForExistence(timeout: 2)
        }
        XCTAssertTrue(found, "没有 \(id)")
        return target
    }
}

/// 整屏截图的 RGBA 像素（按屏幕点坐标取色）。
private struct ScreenPixels {
    let width: Int
    let height: Int
    let scale: CGFloat
    private let bytes: [UInt8]

    init?(_ image: UIImage) {
        guard let cg = image.cgImage else { return nil }
        width = cg.width
        height = cg.height
        scale = CGFloat(cg.width) / max(image.size.width, 1)
        var buffer = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = buffer.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(
                data: raw.baseAddress,
                width: cg.width,
                height: cg.height,
                bitsPerComponent: 8,
                bytesPerRow: cg.width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
            return true
        }
        guard drawn else { return nil }
        bytes = buffer
    }

    func rgb(_ px: CGFloat, _ py: CGFloat) -> [Int] {
        let column = min(max(Int(px * scale), 0), width - 1)
        let row = min(max(Int(py * scale), 0), height - 1)
        let index = (row * width + column) * 4
        return [Int(bytes[index]), Int(bytes[index + 1]), Int(bytes[index + 2])]
    }

    static func distance(_ lhs: [Int], _ rhs: [Int]) -> Int {
        zip(lhs, rhs).map { abs($0 - $1) }.max() ?? 0
    }
}
