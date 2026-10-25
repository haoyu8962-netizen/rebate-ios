import XCTest

/// APP-06v-b 测试 b v2：购买流程的 Debug 记录（评审 r1 S1-2 / S2-4 / S2-8：请求带不带 no_rebate、去了哪个路由、外跳几次、播报几次）。
///
/// 接口沿用实现方已接的 `DebugPurchaseLog`（App target `#if DEBUG`，注入卡 `COULI_FAKE_PRODUCT_CARDS` 生效时记录）：根视图里
/// 1×1 只读元素 `debug.purchase.log`，`value` = 全部记录按发生顺序以「 | 」连接。已有两种记录，b v2 再要两种：
/// - `open:<link_id>:no_rebate=<0|1>`：假服务每收到一次 open（已有）；
/// - `announce:<文字>`：每次礼貌播报（已有）；
/// - `route:<路由名>`：执行器经 `env.open` 打开的每个路由（Help / Search / Login …，**新增**）；
/// - `jump:<步骤类型>`：DebugJumpPorts 实际执行的每次外跳（不真的离开 App，**新增**）。
/// 全部取实际调用，不能照场景回填。
struct PurchaseVisualLog {
    struct Open {
        let linkID: String
        let noRebate: Bool
    }

    let opens: [Open]
    let routes: [String]
    let jumps: [String]
    let announcements: [String]

    init(_ raw: String) {
        let entries = raw.components(separatedBy: " | ").filter { !$0.isEmpty }
        func values(_ prefix: String) -> [String] {
            entries.filter { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)) }
        }
        opens = values("open:").map { body in
            let parts = body.components(separatedBy: ":no_rebate=")
            return Open(linkID: parts.first ?? "", noRebate: parts.count > 1 && parts[1] == "1")
        }
        routes = values("route:")
        jumps = values("jump:")
        announcements = values("announce:")
    }

    @MainActor
    static func read(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) throws
        -> PurchaseVisualLog {
        let element = app.descendants(matching: .any)["debug.purchase.log"].firstMatch
        XCTAssertTrue(element.waitForExistence(timeout: 5), "缺 Debug 记录 debug.purchase.log", file: file, line: line)
        let raw = element.value as? String ?? ""
        return PurchaseVisualLog(raw)
    }
}
