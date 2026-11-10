import XCTest

/// APP-06a 第 3 轮（Debug 包 + 本机假服务）：搜索滚动 → 详情 → 后台回收 → 重启返回搜索仍在原位置（R2-02）；
/// 重启时版本检查返回 below_min 不恢复业务页面（R2-03）；详情「平台 + 商品名」是读屏标题（R2-04）；
/// 平台购买状态维护中 / 未开放时的按钮（R2-01）。设置 TEST_RUNNER_COULI_SHOT_DIR 时截图。
@MainActor
final class SearchRound3Tests: XCTestCase {
    override func setUp() async throws {
        continueAfterFailure = false
    }

    private let baseArguments = [
        "-CouliPrivacyPreset", "consented", "-CouliFakeLoginServer", "-CouliUpdateReset", "1",
        "-CouliHideDebugInfo", "1",
    ]

    private func launch(_ extra: [String] = [], waitForShell: Bool = true) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += baseArguments + extra
        app.launch()
        if waitForShell {
            XCTAssertTrue(ShellTabBar.bar(app).waitForExistence(timeout: 30), "没有进入 Tab 外壳")
        }
        return app
    }

    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any)[id].firstMatch
    }

    private func search(_ app: XCUIApplication, _ keyword: String) {
        element(app, "home.search").tap()
        let field = app.textFields["search.field"]
        XCTAssertTrue(field.waitForExistence(timeout: 10), "没有进搜索页")
        field.tap()
        field.typeText(keyword)
        app.buttons["search.submit"].tap()
        XCTAssertTrue(element(app, "search.card.0").waitForExistence(timeout: 15), "没有结果")
    }

    private func pause(_ seconds: Double = 0.6) {
        Thread.sleep(forTimeInterval: seconds)
    }

    private var shotDir: String? {
        let dir = ProcessInfo.processInfo.environment["COULI_SHOT_DIR"]
        return dir?.isEmpty == false ? dir : nil
    }

    private func save(_ app: XCUIApplication, _ name: String) {
        let shot = app.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        if let dir = shotDir {
            try? shot.pngRepresentation.write(to: URL(fileURLWithPath: dir).appendingPathComponent(name + ".png"))
        }
    }

    /// 视口顶部的结果卡（R3-01）：按序号第一张底边还在列表视口顶边以下的卡，及其顶边相对视口顶边的偏移（pt）。
    private func topCard(_ app: XCUIApplication) -> (index: Int, offset: CGFloat)? {
        let list = app.scrollViews["search.results"].firstMatch
        guard list.exists else { return nil }
        let top = list.frame.minY
        let cards = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "search.card.")).allElementsBoundByIndex
        return cards.compactMap { card -> (Int, CGRect)? in
            guard let index = Int(card.identifier.dropFirst("search.card.".count)) else { return nil }
            return (index, card.frame)
        }
        .sorted { $0.0 < $1.0 }
        .first { $0.1.maxY > top + 0.5 }
        .map { ($0.0, $0.1.minY - top) }
    }

    /// 搜索并滚到第二页的第 4 张卡，记下视口顶部的卡，点第 4 张卡进详情。
    @discardableResult
    private func scrollThenOpenDetail(_ app: XCUIApplication) -> (index: Int, offset: CGFloat)? {
        search(app, "milk")
        let card = element(app, "search.card.3")
        for _ in 0..<4 where !(card.exists && card.isHittable) {
            app.swipeUp()
        }
        XCTAssertTrue(card.waitForExistence(timeout: 10), "翻到第二页")
        pause()
        XCTAssertFalse(element(app, "search.card.0").isHittable, "已经滚下去")
        let top = topCard(app)
        save(app, "R3-Restore-1-search-scrolled")
        card.staticTexts.firstMatch.tap()
        XCTAssertTrue(element(app, "product.header").waitForExistence(timeout: 10), "没有进详情")
        pause()
        save(app, "R3-Restore-2-detail-before-kill")
        return top
    }

    // MARK: - R2-02：搜索滚动 → 详情 → 后台回收 → 重启返回搜索

    func testSearchScrolledThenDetailThenProcessDeathRestoresScrollPosition() {
        let app = launch()
        let before = scrollThenOpenDetail(app)
        XCTAssertNotNil(before, "记下滚动后视口顶部的卡")
        XCUIDevice.shared.press(.home)
        pause(2)
        app.terminate()

        let restored = launch(waitForShell: false)
        XCTAssertTrue(element(restored, "product.header").waitForExistence(timeout: 30), "详情页恢复")
        pause()
        save(restored, "R3-Restore-3-detail-after-relaunch")
        restored.buttons["返回"].firstMatch.tap()
        XCTAssertTrue(restored.textFields["search.field"].waitForExistence(timeout: 10), "返回搜索页")
        XCTAssertEqual(restored.textFields["search.field"].value as? String, "milk")
        XCTAssertTrue(element(restored, "search.card.3").waitForExistence(timeout: 15), "按条件重新加载到锚点")
        pause(1)
        XCTAssertFalse(element(restored, "search.card.0").isHittable, "回到原来的滚动位置，不是列表顶部")
        save(restored, "R3-Restore-4-search-after-back")
        // R3-01：恢复前后视口顶部是同一张卡（不是更前面的卡）；恢复只把它顶对齐，卡内偏移不恢复（共性 43）。
        let after = topCard(restored)
        XCTAssertEqual(
            after?.index, before?.index,
            "恢复后视口顶部的卡：前 \(String(describing: before))，后 \(String(describing: after))"
        )
        if let before, let after {
            XCTAssertEqual(after.offset, 0, accuracy: 8, "顶部卡顶对齐（恢复前偏移 \(before.offset)）")
        }
        restored.terminate()
    }

    // MARK: - R2-03：重启时版本检查 below_min，不恢复业务页面

    func testRelaunchWithBelowMinDoesNotRestoreBusinessPages() {
        let app = launch()
        scrollThenOpenDetail(app)
        XCUIDevice.shared.press(.home)
        pause(2)
        app.terminate()

        let forced = launch(["-CouliUpdateScenario", "force"], waitForShell: false)
        XCTAssertTrue(element(forced, "update.force").waitForExistence(timeout: 30), "进强更页")
        pause(1)
        XCTAssertFalse(element(forced, "product.header").exists, "详情没有被恢复")
        XCTAssertFalse(forced.textFields["search.field"].exists, "搜索页没有被恢复")
        save(forced, "R3-Restore-below-min-force-update")
        forced.terminate()
        // 清掉调试强更记录，免得影响之后的用例（baseArguments 带 -CouliUpdateReset）。
        let clean = launch()
        clean.terminate()
    }

    // MARK: - R2-04：详情标题的读屏角色

    func testProductTitleIsHeaderForVoiceOver() throws {
        let app = launch()
        search(app, "milk")
        element(app, "search.card.0").staticTexts.firstMatch.tap()
        let title = element(app, "product.title")
        XCTAssertTrue(title.waitForExistence(timeout: 10), "详情标题")
        XCTAssertTrue(title.label.hasPrefix("淘宝，"), "平台与商品名合为一项、来源在前：\(title.label)")
        XCTAssertTrue(title.label.count > "淘宝，".count)
        let snapshot = try title.snapshot()
        let traits = (snapshot as? NSObject)?.value(forKey: "traits") as? UInt64
        let header = UInt64(1) << 16 // UIAccessibilityTraitHeader
        XCTAssertNotNil(traits, "读不到读屏角色")
        XCTAssertEqual((traits ?? 0) & header, header, "详情的平台 + 商品名是标题角色")
        // 列表卡里的标题不是页面标题。
        app.buttons["返回"].firstMatch.tap()
        let card = element(app, "search.card.0")
        XCTAssertTrue(card.waitForExistence(timeout: 10))
        let cardTitle = card.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "淘宝，")).firstMatch
        XCTAssertTrue(cardTitle.exists)
        let cardTraits = ((try cardTitle.snapshot()) as? NSObject)?.value(forKey: "traits") as? UInt64 ?? 0
        XCTAssertEqual(cardTraits & header, 0, "列表卡标题不是标题角色")
        app.terminate()
    }

    // MARK: - R2-01：平台购买状态

    func testPurchaseStatusMaintenanceAndNotLaunchedDisableBuy() {
        // R3-02：on → 显示返利金额；maintenance 只置灰按钮（返利照常）；not_launched 隐藏返利金额与预估返后、保留价格。
        let cases = [
            PurchaseCase(status: "on", text: nil, name: "On", rebateShown: true),
            PurchaseCase(status: "maintenance", text: "稍后再试", name: "Maintenance", rebateShown: true),
            PurchaseCase(status: "not_launched", text: "淘宝返利即将开放", name: "NotLaunched", rebateShown: false),
        ]
        let rebate = NSPredicate(format: "label CONTAINS %@", "预估返")
        let price = NSPredicate(format: "label CONTAINS %@ OR label CONTAINS %@", "券后", "售价")
        for item in cases {
            let (status, text, name, rebateShown) = (item.status, item.text, item.name, item.rebateShown)
            let app = launch(["-CouliFakePlatformStatus", "taobao=" + status])
            search(app, "milk")
            let card = element(app, "search.card.0")
            if let text {
                let listButton = card.buttons[text]
                XCTAssertTrue(listButton.waitForExistence(timeout: 10), "列表卡按钮：\(text)")
                XCTAssertFalse(listButton.isEnabled, "列表卡按钮置灰")
            }
            XCTAssertEqual(
                card.descendants(matching: .any).matching(rebate).firstMatch.exists, rebateShown,
                "\(status)：列表卡返利金额 / 预估返后（含读屏）"
            )
            XCTAssertTrue(card.descendants(matching: .any).matching(price).firstMatch.exists, "列表卡商品价格保留")
            pause()
            save(app, "R3-Search-purchase-" + name)
            card.staticTexts.firstMatch.tap()
            let buy = element(app, "product.buy")
            XCTAssertTrue(buy.waitForExistence(timeout: 10), "没有进详情")
            if let text {
                XCTAssertEqual(buy.label, text, "详情按钮：\(text)")
                XCTAssertFalse(buy.isEnabled, "详情按钮置灰")
            }
            let header = element(app, "product.header")
            XCTAssertEqual(
                header.descendants(matching: .any).matching(rebate).firstMatch.exists, rebateShown,
                "\(status)：详情返利金额 / 预估返后（含读屏）"
            )
            XCTAssertTrue(header.descendants(matching: .any).matching(price).firstMatch.exists, "详情商品价格保留")
            pause()
            save(app, "R3-Product-purchase-" + name)
            app.terminate()
        }
    }
}

private struct PurchaseCase {
    let status: String
    let text: String?
    let name: String
    let rebateShown: Bool
}
