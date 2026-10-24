import XCTest

@MainActor
final class HomeVisualOverlayTests: HomeVisualUITestCase {
    func testPopupNameCloseFocusAndReturnFocus() throws {
        try launch(.standard(scene: "popup"))
        XCTAssertEqual(element("home.popup").label, "首页弹窗")
        let close = element("home.popup.close")
        assertHit(close)
        // Debug 回报真实 AccessibilityFocusState 变化，不读取请求里的预期值。
        XCTAssertEqual(element("home.visual.focus").value as? String, "home.popup.close")
        close.tap()
        XCTAssertFalse(element("home.popup").exists)
        XCTAssertEqual(element("home.visual.focus").value as? String, "home.search")
        keepTree("popup-closed")
    }

    func testConsentIsSheetAndDismissDoesNotEnable() throws {
        for dismissal in ["button", "swipe", "scrim"] {
            try launch(.standard(scene: "consent"))
            let sheet = element("clipboard.consent.sheet")
            XCTAssertTrue(sheet.exists)
            let no = element("clipboard.consent.notNow")
            let yes = element("clipboard.consent.enable")
            assertHit(no); assertHit(yes)
            XCTAssertEqual(no.frame.minY, yes.frame.minY, accuracy: 1)
            XCTAssertEqual(no.frame.width, yes.frame.width, accuracy: 1)
            let before = try diagnostics()
            if dismissal == "button" {
                no.tap()
            } else if dismissal == "swipe" {
                sheet.swipeDown()
            } else {
                element("clipboard.consent.scrim").tap()
            }
            XCTAssertFalse(sheet.exists)
            XCTAssertEqual(try diagnostics().consentRequests, before.consentRequests)
        }
    }

    /// 用途说明半屏是模态（adaptation-a11y-spec §4、§8）：半屏以模态容器暴露给读屏（isModal：VoiceOver 只在半屏内移动、底层首页
    /// 不可达），半屏内控件可达；打开时焦点进半屏标题。
    /// 口径说明：
    /// - 底层隐藏：XCUI 的元素树不反映 isModal 对 VoiceOver 的屏蔽，组件库对底层的 accessibilityHidden 在 XCUI 树里也看不到
    ///   （有半屏时 `home.search` 仍在树里，实测见测试交回 v2 §2）；所以这里断言的是读屏可观察的模态标记——带 isModal 的容器
    ///   在 XCUI 里是 `.alert` 类型，去掉 isModal 即变回普通容器。真实「底层不可达」仍须 VoiceOver 实机核对。
    /// - 焦点：按实现交回 §3 取舍 5，模拟器没开 VoiceOver 时系统忽略 AccessibilityFocusState 写入，`home.visual.focus`
    ///   报的是生产半屏「把焦点移到标题」的那一次请求（`couliFocusProbe`，读数 `clipboard.consent.title`），断言的是
    ///   「产品请求了焦点」。
    func testConsentSheetIsModalAndFocusesTitle() throws {
        try launch(.standard(scene: "consent"))
        let sheet = element("clipboard.consent.sheet")
        XCTAssertTrue(sheet.exists)
        keepTree("consent-open")
        XCTAssertEqual(sheet.elementType, .alert, "用途说明半屏没有以模态容器暴露给读屏（缺 isModal）")
        XCTAssertTrue(sheet.staticTexts["开启回到 App 自动查返利？"].exists, "标题应在半屏模态容器内")
        for id in ["clipboard.consent.notNow", "clipboard.consent.enable"] {
            XCTAssertTrue(sheet.descendants(matching: .any)[id].exists, "\(id) 应在半屏模态容器内")
            assertHit(element(id))
        }
        let focus = element("home.visual.focus")
        UIWait.until("半屏打开后焦点请求落在标题（读数：\(focus.value as? String ?? "nil")）", ceiling: 5) {
            focus.value as? String == "clipboard.consent.title"
        }
        element("clipboard.consent.notNow").tap()
        XCTAssertFalse(sheet.exists)
        XCTAssertTrue(element("home.search").waitForExistence(timeout: 5), "半屏关闭后首页仍在")
    }

    /// 邀请条在 320 宽 × 200%（AX3，与 HomeVisualLayoutTests 同口径）下换行而不截断，【绑定】与关闭仍完整可点
    /// （实现交回 §9-2、Android r1 S2-2 同类）。截断看两点：文字整块在条内、条在窗口内；文字高度随字号放大，
    /// 不是被压成一行（与同宽常规字号比，高度至少翻倍）。
    func testInvitePromptWrapsWithoutTruncationAt320LargeText() throws {
        let fullText = "检测到好友邀请码 K7M3QX，绑定为邀请人？"
        try launch(.standard(scene: "invite", width: 320))
        let normalHeight = try inviteText(fullText).frame.height
        keepTree("invite-320-large")
        try launch(.standard(scene: "invite", width: 320, category: "accessibilityExtraLarge"))
        let window = app.windows.firstMatch.frame
        let bar = element("clipboard.invitePrompt")
        XCTAssertTrue(bar.exists)
        let text = try inviteText(fullText)
        let bind = element("clipboard.invite.confirm")
        let close = element("clipboard.invite.close")
        XCTAssertLessThanOrEqual(window.width, 320.5, "调试窗口没有按 320 宽布局")
        XCTAssertGreaterThanOrEqual(bar.frame.minX, window.minX - 0.5, "邀请条左侧出窗口")
        XCTAssertLessThanOrEqual(bar.frame.maxX, window.maxX + 0.5, "邀请条右侧出窗口")
        for (name, part) in [("文字", text), ("绑定", bind), ("关闭", close)] {
            XCTAssertTrue(
                bar.frame.insetBy(dx: -0.5, dy: -0.5).contains(part.frame),
                "\(name) 超出邀请条：\(part.frame) / \(bar.frame)"
            )
        }
        XCTAssertGreaterThanOrEqual(text.frame.height, normalHeight * 2, "200% 下文字高度没有随字号放大，疑似被截成一行")
        XCTAssertFalse(text.frame.insetBy(dx: 0.5, dy: 0.5).intersects(bind.frame), "文字与【绑定】重叠")
        XCTAssertFalse(text.frame.insetBy(dx: 0.5, dy: 0.5).intersects(close.frame), "文字与关闭重叠")
        XCTAssertFalse(bind.frame.intersects(close.frame), "【绑定】与关闭重叠")
        keepTree("invite-320-ax3")
        assertHit(bind)
        assertHit(close)
        XCTAssertEqual(bind.label, "绑定邀请人")
        bind.tap()
        XCTAssertTrue(bar.waitForNonExistence(timeout: 5), "200% 下点【绑定】没有生效")
    }

    private func inviteText(_ fullText: String) throws -> XCUIElement {
        let text = element("clipboard.invitePrompt").staticTexts[fullText].firstMatch
        XCTAssertTrue(text.waitForExistence(timeout: 5), "邀请条缺整句文字元素（读屏应读完整原文）")
        XCTAssertGreaterThan(text.frame.height, 0)
        return text
    }

    func testClipboardSheetHasNoVisibleTitle() throws {
        try launch(.standard(scene: "clipboard_card"))
        XCTAssertTrue(element("clipboard.cardList").exists)
        XCTAssertFalse(app.staticTexts["识别到的商品"].exists)
        assertHit(element("clipboard.cards.close"))
        keepTree("clipboard-single-product")
    }
}
