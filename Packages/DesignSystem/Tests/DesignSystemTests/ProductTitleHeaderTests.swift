@testable import DesignSystem
import SwiftUI
import XCTest

/// APP-06a R2-04（共性 30）：详情页合并后的「平台 + 商品名」有读屏标题角色（A11yFocusProduct 第 10 项「平台、商品名，
/// 标题」，03 §10.5），仍合为一项、来源在前；列表卡里的同一组件不是标题。实际渲染出的读屏角色由 UI 测试
/// `SearchRound3Tests.testProductTitleIsHeaderForVoiceOver` 读取（单测进程里 SwiftUI 不生成读屏元素树）。
@MainActor
final class ProductTitleHeaderTests: XCTestCase {
    func testTraitsAndMergedLabel() {
        XCTAssertTrue(BadgedTitle.accessibilityTraits(isHeader: true).contains(.isHeader))
        XCTAssertFalse(BadgedTitle.accessibilityTraits(isHeader: false).contains(.isHeader))
        XCTAssertEqual(BadgedTitle.accessibilityText(platform: "淘宝", title: "样例"), "淘宝" + PriceTerms.spokenPause + "样例")
    }
}
