import XCTest

extension XCUIElement {
    /// 点卡片正文进详情（搜索结果卡、订单卡）。FU-IOS-A11Y-04 / 10 起卡内文字合成整卡一项读屏按钮，卡里不再有 staticText 可点，
    /// 改为点卡片上部（标题 / 头行，避开【复制】与购买按钮）；点卡片本身的手势不变，仍是用户真实点到的位置。
    func tapCardBody(file: StaticString = #filePath, line: UInt = #line) {
        // 坐标点击不会先把元素滚进可点区：不可点时先报清楚原因（test-change-review B5）
        XCTAssertTrue(waitForExistence(timeout: 5), "要点的卡不存在：\(identifier)", file: file, line: line)
        XCTAssertTrue(isHittable, "要点的卡不在可点区（先滚动到可见）：\(identifier)", file: file, line: line)
        coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.1)).tap()
    }
}
