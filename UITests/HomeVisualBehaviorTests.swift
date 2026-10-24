import UIKit
import XCTest

@MainActor
final class HomeVisualBehaviorTests: HomeVisualUITestCase {
    func testSearchPinnedAndNativeHeaderSharesSduiScroll() throws {
        try launch()
        let search = element("home.search")
        let paste = element("clipboard.homeCard.paste")
        let icons = element("home.section.icons")
        assertHit(search)
        XCTAssertEqual(search.elementType, .button)
        XCTAssertEqual(search.label, "搜商品名，或粘贴商品链接")
        XCTAssertFalse(app.textFields["home.search"].exists)
        XCTAssertTrue(element("home.list").descendants(matching: .any)["home.guest.value"].exists)
        XCTAssertTrue(element("home.list").descendants(matching: .any)["clipboard.homeCard.paste"].exists)
        let before = (search.frame, paste.frame, icons.frame)
        // 从原生区内开始真实手势；旧的两个独立滚动容器会使 icons 不动或 delta 不一致。
        paste.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.85)).press(
            forDuration: 0.05, thenDragTo: search.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 1.1))
        )
        XCTAssertEqual(search.frame.minY, before.0.minY, accuracy: 1)
        XCTAssertLessThan(paste.frame.minY, before.1.minY - 20)
        XCTAssertEqual(paste.frame.minY - before.1.minY, icons.frame.minY - before.2.minY, accuracy: 3)
        XCTAssertTrue(try reveal("home.footer").exists, "同一列表能到口径页脚")
        XCTAssertEqual(search.frame.minY, before.0.minY, accuracy: 1)
    }

    func testPullFromNativeHeaderOnlyRefreshesSdui() throws {
        try launch(.standard(scene: "invite"))
        let before = try diagnostics()
        XCTAssertNotNil(before.promptIdentity, "刷新前必须有真实提示条，不能以 nil == nil 代过")
        let text = element("clipboard.invitePrompt").label
        let list = element("home.list")
        list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.08)).press(
            forDuration: 0.1, thenDragTo: list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8))
        )
        UIWait.until("整列表下拉发出且完成一次 SDUI 刷新", ceiling: 10) {
            guard let state = try? self.diagnostics() else { return false }
            return state.pageRequests == before.pageRequests + 1 && state.settled
        }
        let after = try diagnostics()
        XCTAssertEqual(after.pageRequests, before.pageRequests + 1)
        XCTAssertGreaterThan(after.sectionRequests, before.sectionRequests)
        XCTAssertEqual(after.parseRequests, before.parseRequests)
        XCTAssertEqual(after.clipboardReads, before.clipboardReads)
        XCTAssertEqual(after.consentRequests, before.consentRequests)
        XCTAssertEqual(after.promptIdentity, before.promptIdentity)
        XCTAssertEqual(after.nativeRevision, before.nativeRevision)
        XCTAssertEqual(element("clipboard.invitePrompt").label, text)
    }

    func testGuestValueFollowsRealSessionImmediatelyWhileNewPageIsHeld() throws {
        try launch()
        assertHit(element("home.guest.login"))
        XCTAssertTrue(element("home.guest.value").exists)
        // Debug 命令必须经真实 session 出口，且挂住会员 getPage；不能直接改视图布尔值。
        HomeUITestSignalNames.post("com.couli.app.debug.uitest.home-visual.login-hold")
        UIWait.until("身份切到会员", ceiling: 10) { (try? self.diagnostics().level) == "member" }
        XCTAssertFalse(element("home.guest.value").exists, "不能等会员 SDUI 返回才隐藏")
        HomeUITestSignalNames.post("com.couli.app.debug.uitest.home-visual.logout")
        XCTAssertTrue(element("home.guest.login").waitForExistence(timeout: 10))
        element("home.guest.login").tap()
        XCTAssertTrue(element("login.page").waitForExistence(timeout: 10), "游客价值卡真实经 Router 到 Login")
    }

    func testPasteIsOneSystemControlAndAccessibleDecorationsAreHidden() throws {
        try launch()
        XCTAssertEqual(try diagnostics().pasteControlClass, "UIPasteControl")
        XCTAssertEqual(app.descendants(matching: .any).matching(identifier: "clipboard.homeCard.paste").count, 1)
        assertHit(element("clipboard.homeCard.paste"))
        XCTAssertFalse(element("home.paste.illustration").isHittable)
        XCTAssertFalse(app.staticTexts["支持淘宝、京东、拼多多"].exists)
        for name in ["淘宝", "京东", "拼多多"] {
            let cells = app.buttons.matching(NSPredicate(format: "label == %@", name))
            XCTAssertEqual(cells.count, 1, "金刚区整格读一次平台名")
            assertHit(cells.firstMatch)
        }
        let scroll = try reveal("home.product.scroll.0")
        XCTAssertEqual(scroll.elementType, .button)
        var rest = scroll.label[...]
        // BR-TEXT-10：moneySpoken 去尾零，保留口径、单位和四部分的顺序。
        for part in ["淘宝", "林间果 每日坚果 30袋", "券后 19.9 元", "预估返 1.1 元"] {
            let range = try XCTUnwrap(rest.range(of: part), "横滑读屏名缺少或顺序不对：\(part)")
            rest = rest[range.upperBound...]
        }
        XCTAssertFalse(scroll.staticTexts["林间果 每日坚果 30袋"].exists, "只从可见层去掉标题")
        XCTAssertFalse(scroll.staticTexts["淘宝"].exists)
        keepTree("main-native-and-scroll")
    }

    func testNoRebateInfoActuallyOpensOnAllThreeCardKinds() throws {
        for kind in ["scroll", "grid", "feed"] {
            try launch(.standard(scene: "no_rebate_" + kind))
            let info = try reveal("home.info.\(kind).0")
            assertHit(info)
            info.tap()
            let content = element("home.info.content.\(kind).0")
            XCTAssertTrue(content.waitForExistence(timeout: 5))
            XCTAssertTrue(content.label.contains("价格按单件计算"))
            XCTAssertFalse(element("product.header").exists, "i 的触摸不得被父卡抢走")
        }
    }

    func testMoreAndPromptCloseHitTargets() throws {
        try launch(.standard(scene: "invite"))
        assertHit(element("clipboard.invite.close"))
        let bind = element("clipboard.invite.confirm")
        assertHit(bind)
        XCTAssertFalse(bind.frame.intersects(element("clipboard.invite.close").frame))
        element("clipboard.invite.close").tap()
        XCTAssertFalse(element("clipboard.invitePrompt").exists)
        let more = try reveal("home.more.scroll")
        assertHit(more)
        more.tap()
        XCTAssertTrue(element("search.field").waitForExistence(timeout: 10))
    }

    func testWidthChangePreservesTheVisibleProductAnchor() throws {
        try launch()
        let anchor = try reveal("home.product.feed.0")
        let offset = anchor.frame.minY - element("home.list").frame.minY
        HomeUITestSignalNames.post("com.couli.app.debug.uitest.home-visual.width-840")
        UIWait.until("同一实例完成宽度变化", ceiling: 5) {
            self.element("home.visual.width").value as? String == "840"
        }
        XCTAssertTrue(anchor.exists)
        XCTAssertEqual(anchor.frame.minY - element("home.list").frame.minY, offset, accuracy: 3)
        HomeUITestSignalNames.post("com.couli.app.debug.uitest.home-visual.width-390")
        UIWait.until("回到窄屏", ceiling: 5) { self.element("home.visual.width").value as? String == "390" }
        XCTAssertEqual(anchor.frame.minY - element("home.list").frame.minY, offset, accuracy: 3)
    }
}
