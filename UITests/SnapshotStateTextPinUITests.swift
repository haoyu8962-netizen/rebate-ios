import Foundation
import XCTest

/// FU-IOS-SNAPSHOT-STALE-TEXT 文字级回归钉（编排 D10-2877，独立写测方）：`PurchaseVisualScreenSnapshotTests` 的
/// ProductJumpBrowser-v2-light 底部主按钮。放 UITests 而不放 AppTests：这张图是真实 App 点购买后经 DebugFakeTrade `t-browser`
/// 场景弹出的「即将打开浏览器」浮层；AppTests 的 `ProductVisualHost` 只能渲染同卡详情页，进程内点不到购买、假服务也不回 h5 跳转方案，
/// 到不了同一状态。浮层打开时页面整体 `accessibilityHidden`，按钮读名只能在点购买前读（同一次启动、同一张卡、同一页面）。
/// 期望值 = 契约字典 `texts.default.json` 里卡片 `cta.text_key` 的文字（运行时契约优先；契约缺键时会回落草稿旧字，这里判红）。
@MainActor
final class SnapshotStateTextPinUITests: XCTestCase, ProductVisualUITest {
    override func setUp() async throws {
        continueAfterFailure = true
    }

    override func tearDown() async throws {
        XCUIDevice.shared.appearance = .light
    }

    /// 契约字典 texts 段里的一条（运行时契约优先）。
    private func contractText(_ key: String) throws -> String {
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while !FileManager.default.fileExists(atPath: directory.appendingPathComponent("contract.lock").path) {
            directory = directory.deletingLastPathComponent()
        }
        let url = directory.appendingPathComponent("contracts/snapshot/contracts/texts.default.json")
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let texts = try XCTUnwrap(root["texts"] as? [String: String], "文案字典没有 texts")
        return try XCTUnwrap(texts[key], "契约缺 \(key)：运行时会回落 SearchDraftTexts 草稿")
    }

    /// 与截图用例同一张卡与链接场景（PurchaseVisualScreenSnapshotTests.swift:106–107）：主按钮读名以 cta.text_key 的契约文字开头。
    func testJumpBrowserPrimaryButtonText() throws {
        XCUIDevice.shared.appearance = .light
        let card = try visualCard("jd_no_coupon_single", overrides: ["link_id": "t-browser"])
        let key = try XCTUnwrap((card["cta"] as? [String: Any])?["text_key"] as? String, "卡片缺 cta.text_key")
        let verb = try contractText(key)
        XCTAssertFalse(verb.isEmpty, "前提：\(key) 非空")
        let app = try launchProduct(card)
        let buy = node(app, "product.buy")
        XCTAssertTrue(buy.waitForExistence(timeout: 10), "没有主按钮")
        let label = buy.label
        XCTAssertTrue(label.hasPrefix(verb), "主按钮读名以「\(key)」的契约文字开头：\(label)")
        buy.tap()
        XCTAssertTrue(node(app, "purchase.browser").waitForExistence(timeout: 12), "没进到截图同一状态（purchase.browser）")
        app.terminate()
    }
}
