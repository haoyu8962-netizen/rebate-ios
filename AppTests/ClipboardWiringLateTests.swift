import Clipboard
@testable import Couli
import Foundation
import Router
import XCTest

/// APP-07 接线测试（续）：迟到与作废、42901、30132 / 5xxxx。
extension ClipboardWiringTests {
    // MARK: - 迟到与作废

    func testLateResponsesDroppedAfterBackgroundTabPrivacyAndSession() async {
        let exits: [(String, (Fixture) -> Void)] = [
            ("background", { $0.clipboard.sceneBackground() }),
            ("tab", { _ = $0.routing.selectTab(.me) }),
            ("cover", { $0.routing.router.path = [RouteDestination(route: "Help")] }),
            ("session", { $0.state.session += 1
                $0.clipboard.sessionChanged()
            }),
            ("privacy", { $0.state.privacy = .basicMode
                $0.clipboard.privacyChanged(.basicMode)
            }),
            ("overlay", { $0.clipboard.sensitiveOverlayShown() }),
        ]
        for (name, exit) in exits {
            let fixture = make()
            fixture.clipboard.sceneActive()
            fixture.api.hold = true
            fixture.api.reply = .success(card: true)
            fixture.clipboard.pasted(entry: ManualPasteAction.entryHome, text: link)
            await settle()
            XCTAssertEqual(fixture.api.bodies.count, 1, name)
            let before = fixture.routing.router.path
            exit(fixture)
            fixture.api.release()
            await settle()
            XCTAssertFalse(fixture.routing.router.path.contains { $0.route == "ProductDetail" }, name)
            XCTAssertNil(fixture.clipboard.result, name)
            _ = before
        }
    }

    func testCoverThenReturnSameSearchPageDoesNotRevive() async {
        let fixture = make()
        let search = RouteDestination(route: "Search")
        fixture.routing.router.path = [search]
        fixture.clipboard.sceneActive()
        fixture.api.hold = true
        fixture.api.reply = .failure(code: 30132)
        fixture.clipboard.pasted(entry: ManualPasteAction.entrySearchTyping, text: link)
        await settle()
        fixture.routing.router.path = [search, RouteDestination(route: "Help")]
        fixture.routing.router.path = [search]
        fixture.api.release()
        await settle()
        XCTAssertNil(fixture.clipboard.result, "回到同一页面实例也不恢复离开前发起的请求（共性第 2 条）")
    }

    // MARK: - 42901

    func testRateLimitBlocksAllPasteEntries() async {
        let fixture = make()
        fixture.clipboard.sceneActive()
        fixture.api.reply = .rateLimited(millis: 60000)
        fixture.clipboard.pasted(entry: ManualPasteAction.entryHome, text: link)
        await settle()
        XCTAssertTrue(fixture.clipboard.blocked)
        XCTAssertFalse(fixture.clipboard.pasteEnabled)
        guard case .notice = fixture.clipboard.result?.kind else { return XCTFail("42901 轻提示") }
        fixture.clipboard.pasted(entry: ManualPasteAction.entrySearchTyping, text: link)
        await settle()
        XCTAssertEqual(fixture.api.bodies.count, 1, "执行层也拦")
        let paste = fixture.clipboard.makeLoginInvitePaste()
        XCTAssertFalse(paste.enabled, "登录页邀请码【粘贴】同样置灰（共性第 6 条）")
        fixture.routing.router.path = [RouteDestination(route: "Login")]
        XCTAssertEqual(paste.handle("邀请码 K7M2QX"), .message("操作太频繁，请稍后再试"), "不误报「未识别到邀请码」")
    }

    // MARK: - 30132 / 5xxxx

    func testLocalUnrecognizedAndTrace6() async {
        let fixture = make()
        fixture.clipboard.sceneActive()
        fixture.clipboard.pasted(entry: ManualPasteAction.entryHome, text: "「全脂纯牛奶 250ml」 好喝")
        XCTAssertEqual(fixture.api.bodies.count, 0, "没抽到链接不上传（G10）")
        guard case let .unrecognized(text, prefill) = fixture.clipboard.result?.kind else {
            return XCTFail("30132 本地提示")
        }
        // #24 test-change（FU-X-CTA-KEY-DRIFT-ios 升锁 a89c1ec3a）：契约 error.30132 新值，判据不变
        XCTAssertEqual(text, "这个链接或口令暂时识别不了")
        XCTAssertEqual(prefill, "全脂纯牛奶 250ml")
        fixture.api.reply = .failure(code: 59999)
        fixture.clipboard.pasted(entry: ManualPasteAction.entryHome, text: link)
        await settle()
        guard case let .notice(error) = fixture.clipboard.result?.kind else { return XCTFail("5xxxx 轻提示") }
        XCTAssertTrue(error.hasPrefix("出了点问题"), "未收录的 5xxxx 回落通用正文（共性第 9 条）：\(error)")
        XCTAssertTrue(error.contains("1a2b3c"), "带 trace_id 末 6 位：\(error)")
    }

    func testEmptyClipboardOpensSearch() {
        let fixture = make()
        fixture.clipboard.sceneActive()
        fixture.clipboard.pasted(entry: ManualPasteAction.entryHome, text: nil)
        XCTAssertEqual(fixture.routing.router.path.last?.route, "Search")
    }
}
