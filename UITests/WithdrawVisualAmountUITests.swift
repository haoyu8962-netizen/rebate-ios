import UIKit
import XCTest

/// APP-09v-c 金额框的显示一致性（测试 v3；评审 r1 后输入框换成可折行，`WithdrawAmountBox` 新增换行归一与框内文字对回）：
/// 框里显示的字 = 页面实际用的金额。「实际金额」看估算行：假服务回 `est_net_fen = amount_fen`，估算句里的数字是执行器发出去的金额换算回来的，
/// 不是框里的字。框里多一个字、金额少一个字这种脱节，资金写页不能留。
@MainActor
final class WithdrawVisualAmountUITests: XCTestCase, WithdrawVisualUITest {
    override func setUp() async throws {
        continueAfterFailure = true
    }

    private func shown(_ field: XCUIElement) -> String {
        field.value as? String ?? ""
    }

    /// 等框内文字到 `expected`（`Binding` 回写与 `.task` 对回都异步），再多看一会儿，防止先对后错。
    private func assertBox(_ field: XCUIElement, _ expected: String, _ message: String, file: StaticString = #filePath,
                           line: UInt = #line) {
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline, shown(field) != expected {
            Thread.sleep(forTimeInterval: 0.1)
        }
        Thread.sleep(forTimeInterval: 0.5)
        XCTAssertEqual(shown(field), expected, message, file: file, line: line)
    }

    /// 实际金额：估算句出现 `¥<金额>，`（防抖 0.5 秒后取 rules）。
    private func assertAmount(_ app: XCUIApplication, _ expected: String, _ message: String,
                              file: StaticString = #filePath, line: UInt = #line) {
        let wanted = "¥\(expected)，"
        let estimate = node(app, "withdraw.estimate")
        let deadline = Date().addingTimeInterval(6)
        while Date() < deadline, !(estimate.exists && estimate.label.contains(wanted)) {
            Thread.sleep(forTimeInterval: 0.2)
        }
        XCTAssertTrue(estimate.exists && estimate.label.contains(wanted),
                      "\(message)：估算句应含 \(wanted)，实际「\(estimate.exists ? estimate.label : "无估算")」",
                      file: file, line: line)
    }

    private func clear(_ field: XCUIElement) {
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: shown(field).count + 1))
        Thread.sleep(forTimeInterval: 0.4)
    }

    /// 真实长按菜单粘贴（输入过程里一次进一整串，逐字键入测不到归一）。菜单没出来算失败，不跳过。
    private func paste(_ app: XCUIApplication, _ field: XCUIElement, _ text: String, file: StaticString = #filePath,
                       line: UInt = #line) throws {
        UIPasteboard.general.string = text
        field.press(forDuration: 1.2)
        Thread.sleep(forTimeInterval: 0.8)
        let item = app.menuItems.allElementsBoundByIndex.first { $0.label.contains("Paste") || $0.label.contains("粘贴") }
        try XCTUnwrap(item, "长按没有出现粘贴菜单", file: file, line: line).tap()
        Thread.sleep(forTimeInterval: 0.8)
    }

    /// 被过滤拒绝的字不留在框里：`12.345` 框里、金额都是 12.34；再输字母不变；删除后两边一起变。先正（合法输入照常）后反。
    func testRejectedCharsDoNotStayInBox() throws {
        let app = try launchWithdraw()
        let field = node(app, "withdraw.input")
        field.tap()
        field.typeText("12.34")
        assertBox(field, "12.34", "合法输入")
        assertAmount(app, "12.34", "合法输入")
        field.typeText("5")
        assertBox(field, "12.34", "第三位小数不留在框里")
        assertAmount(app, "12.34", "金额没变")
        field.typeText("a")
        assertBox(field, "12.34", "字母不留在框里")
        assertAmount(app, "12.34", "金额没变")
        field.typeText(XCUIKeyboardKey.delete.rawValue)
        assertBox(field, "12.3", "删除后对得上")
        assertAmount(app, "12.3", "删除后金额")
        app.terminate()
    }

    /// 粘贴含换行：框里没有换行、金额 = 去掉换行的值；带拒绝内容的整串不进框也不进金额。
    func testPastedNewlineNeverReachesAmount() throws {
        let app = try launchWithdraw()
        let field = node(app, "withdraw.input")
        field.tap()
        try paste(app, field, "7.5\n")
        assertBox(field, "7.5", "末尾换行不进框")
        assertAmount(app, "7.5", "换行归一后金额可用")
        field.tap()
        clear(field)
        assertBox(field, "", "清空")
        try paste(app, field, "7.5\n8")
        assertBox(field, "", "中间有换行的整串被拒，不留在框里")
        XCTAssertFalse(node(app, "withdraw.estimate").exists, "被拒后没有金额，就没有估算")
        XCTAssertFalse(node(app, "withdraw.submit").isEnabled, "被拒后【提交】置灰")
        app.terminate()
    }

    /// 回车键入：不写入换行，已有金额不变。
    func testTypedReturnKeepsAmount() throws {
        let app = try launchWithdraw()
        let field = node(app, "withdraw.input")
        field.tap()
        field.typeText("10")
        field.typeText("\n")
        assertBox(field, "10", "回车不进框")
        assertAmount(app, "10", "金额不变")
        app.terminate()
    }
}
