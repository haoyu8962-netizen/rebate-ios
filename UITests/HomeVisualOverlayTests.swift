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

    // FU-X-CLIP-DEFAULT-ON（test-change）：删除 testConsentIsSheetAndDismissDoesNotEnable、
    // testConsentSheetIsModalAndFocusesTitle——
    // 剪贴板首次用途说明弹层 2026-10-30 停用、已实现的移除（BR-ID-16 2026-10-30；变更记录 §2 第 1、5 行；brief C2）。
    // 「不出现弹层」由 ClipDefaultOnUITests 与 AppTests/ClipDefaultOnSourceGuardTests 守。

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
