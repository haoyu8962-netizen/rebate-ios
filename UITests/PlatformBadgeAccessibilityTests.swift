import XCTest

/// V2：读真实 App 的无障碍树。复用现有 Gallery 启动入口，不给产品新增测试后门。
@MainActor
final class PlatformBadgeAccessibilityTests: XCTestCase {
    override func setUp() async throws {
        continueAfterFailure = false
    }

    func testCatalogBadgesSpeakOnlyTheChineseNameOnceAndHaveNoFocusableImage() {
        let app = XCUIApplication()
        app.launchArguments += [
            "-CouliPrivacyPreset", "consented", "-CouliFakeLoginServer", "-CouliUpdateReset", "1",
            "-CouliHideDebugInfo", "1", "-CouliCatalogPage", "Gallery", "-CouliCatalogSection", "4",
        ]
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.descendants(matching: .any)["COULI_DS_COMPONENT_CATALOG_7Q4XK2"]
            .firstMatch.waitForExistence(timeout: 30))
        for name in ["淘宝", "京东", "拼多多"] {
            let matches = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", name))
            XCTAssertTrue(matches.firstMatch.waitForExistence(timeout: 10), name)
            XCTAssertEqual(matches.count, 1, "徽标与子图标不可各读一遍：\(name)")
            let badge = matches.firstMatch
            XCTAssertTrue(badge.isHittable, "Gallery 应滚到徽标段")
            XCTAssertEqual(badge.label, name)
            XCTAssertEqual(badge.descendants(matching: .any).count, 0, "徽标必须是一项，不能另暴露文字或装饰子节点")
            XCTAssertEqual(badge.descendants(matching: .image).count, 0)
            let imagesInBadge = app.images.allElementsBoundByIndex.filter {
                !$0.frame.isEmpty && badge.frame.contains($0.frame)
            }
            XCTAssertTrue(imagesInBadge.isEmpty, "装饰图即使 label 为空也不应成为单独的图片元素")
            XCTAssertTrue(badge.value == nil || (badge.value as? String) == "")
        }
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "F-X-05a-platform-badges-accessibility"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testSearchAndProductTitleDoNotRepeatPlatformOrAnnounceAnImage() {
        let app = XCUIApplication()
        app.launchArguments += [
            "-CouliPrivacyPreset", "consented", "-CouliFakeLoginServer", "-CouliUpdateReset", "1",
            "-CouliHideDebugInfo", "1",
        ]
        app.launch()
        defer { app.terminate() }
        let search = app.descendants(matching: .any)["home.search"].firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 30))
        search.tap()
        let field = app.textFields["search.field"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        field.typeText("milk")
        app.buttons["search.submit"].tap()
        let card = app.descendants(matching: .any)["search.card.0"].firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 15))
        let title = card.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "淘宝，")).firstMatch
        XCTAssertTrue(title.exists)
        assertMergedTitle(title)
        title.tap()
        let detailTitle = app.descendants(matching: .any)["product.title"].firstMatch
        XCTAssertTrue(detailTitle.waitForExistence(timeout: 10))
        assertMergedTitle(detailTitle)
    }

    private func assertMergedTitle(_ element: XCUIElement) {
        XCTAssertTrue(element.label.hasPrefix("淘宝，"))
        XCTAssertEqual(element.label.components(separatedBy: "淘宝").count - 1, 1)
        for unwanted in ["图标", "图片", "taobao", "png"] {
            XCTAssertFalse(element.label.contains(unwanted), element.label)
        }
        XCTAssertEqual(element.descendants(matching: .image).count, 0)
    }
}
