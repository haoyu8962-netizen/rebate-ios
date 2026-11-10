import Foundation
import UIKit
import XCTest

/// APP-08v 的 UI 测试入口：真实 App（Debug）+ 本机假服务（`-CouliFakeLoginServer`）+ 新 Debug 输入（§2.2，实现方在 App target 的
/// `#if DEBUG` 里接，Release 不存在；调试开关只走启动参数 / 环境变量，不写 App 标准偏好）：
///
/// 环境变量 `COULI_FAKE_ORDER_VISUAL` = UTF-8 JSON 对象的 Base64：
/// `{"list": {"self": <OrderListData>, "share": <OrderListData>, "q:<词>": <OrderListData>, "cursor:<游标>":
/// <OrderListData>},
///   "details": {"<order_id>": <OrderDetail>}}`（报文原样来自 specs/order-vectors.json 的 visualOrders）。生效时假服务：
/// - `GET /v1/orders`：有 cursor 回 `cursor:<游标>`、有 q 回 `q:<词>`、否则按 scope 回 `self` / `share`；缺省回空页；
/// - `GET /v1/orders/<order_id>`：回 `details` 里同 id 的报文；没有回 30701；`GET /v1/orders/pending-tracks` 回空；
/// - 只读记录 `debug.order.log`（根视图左上 1 × 1 只读元素，accessibilityValue = 全部记录按发生顺序以「 | 」连接）：
///   `request:<方法> <路径>[?<查询串按键名排序 k=v&…>]`（假服务收到的每个订单请求，不含待跟单卡）；
///   `route:<路由名>[?<参数按键名排序 k=v&…，嵌套对象按点号展开，如 context.order_id=C>]`（订单列表 / 详情经 App 出口打开的每个路由）；
///   `cs:OrderDetail`（【联系客服】交给统一客服出口一次）；`copy:<原文>`（订单号经剪贴板统一写入口写入一次）。
@MainActor
protocol OrderVisualUITest: XCTestCase {}

enum OrderVisualUIError: Error, CustomStringConvertible {
    case notInjected(String)

    var description: String {
        switch self {
        case let .notInjected(what):
            "假服务没有按 COULI_FAKE_ORDER_VISUAL 回答注入的数据（\(what)；§2.2 Debug 输入未接）"
        }
    }
}

extension OrderVisualUITest {
    static func repo() -> URL {
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while !FileManager.default.fileExists(atPath: directory.appendingPathComponent("contract.lock").path) {
            directory = directory.deletingLastPathComponent()
        }
        return directory
    }

    func visual() throws -> [String: Any] {
        let data = try Data(contentsOf: Self.repo().appendingPathComponent("specs/order-vectors.json"))
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try XCTUnwrap(root["visualOrders"] as? [String: Any])
    }

    func listPage(_ name: String) throws -> [String: Any] {
        if let page = try (visual()["pages"] as? [String: Any])?[name] as? [String: Any] {
            return page
        }
        // v3：iOS 独立组 specs/order-visual-extra-pages.json
        let data = try Data(contentsOf: Self.repo().appendingPathComponent("specs/order-visual-extra-pages.json"))
        let extra = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try XCTUnwrap((extra["pages"] as? [String: Any])?[name] as? [String: Any], "缺 pages.\(name)")
    }

    func detail(_ name: String) throws -> [String: Any] {
        let root = try visual()
        if let found = (root["details"] as? [String: Any])?[name] as? [String: Any] {
            return found
        }
        return try XCTUnwrap((root["reasonDetails"] as? [String: Any])?[name] as? [String: Any], "缺 \(name)")
    }

    /// 启动并直接进订单 Tab；`expect` 是注入数据里应出现的第一张卡（不是 DebugFakeOrders 通用样例），没出现即抛错结束。
    func launchOrders(list: [String: Any], details: [String: Any] = [:], expect: String,
                      extra: [String] = []) throws -> XCUIApplication {
        let app = XCUIApplication()
        let payload: [String: Any] = ["list": list, "details": details]
        app.launchEnvironment["COULI_FAKE_ORDER_VISUAL"] = try JSONSerialization.data(withJSONObject: payload)
            .base64EncodedString()
        app.launchArguments += [
            "-CouliPrivacyPreset", "consented", "-CouliFakeLoginServer", "-CouliUpdateReset", "1",
            "-CouliHideDebugInfo", "1", "-CouliFakeTradeLoggedIn", "-CouliFakeTradeNoExternal",
            "-CouliStartTab", "orders",
        ] + extra
        app.launch()
        XCTAssertTrue(ShellTabBar.bar(app).waitForExistence(timeout: 30), "没有进入 Tab 外壳")
        guard node(app, "order.card.\(expect)").waitForExistence(timeout: 15) else {
            throw OrderVisualUIError.notInjected("订单卡 \(expect)")
        }
        return app
    }

    /// 进某张卡的详情（真点卡上的文字）。
    func openDetail(_ app: XCUIApplication, _ id: String) {
        node(app, "order.card.\(id)").staticTexts.firstMatch.tap()
        XCTAssertTrue(node(app, "orderDetail.product").waitForExistence(timeout: 10), "没有进 \(id) 详情")
    }

    func node(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any)[id].firstMatch
    }

    /// `debug.order.log` 的全部记录（没有该元素时为空数组，由调用方断言报红）。
    func log(_ app: XCUIApplication) -> [String] {
        let element = node(app, "debug.order.log")
        guard element.exists, let value = element.value as? String, !value.isEmpty else { return [] }
        return value.components(separatedBy: " | ")
    }

    func requireLog(_ app: XCUIApplication, file _: StaticString = #filePath, line _: UInt = #line) throws {
        guard node(app, "debug.order.log").waitForExistence(timeout: 5) else {
            throw OrderVisualUIError.notInjected("只读记录 debug.order.log")
        }
    }

    func routes(_ app: XCUIApplication) -> [String] {
        log(app).filter { $0.hasPrefix("route:") || $0.hasPrefix("cs:") }
    }

    func requests(_ app: XCUIApplication) -> [String] {
        log(app).filter { $0.hasPrefix("request:") }
    }

    /// 等记录条数变化（真点之后）。
    func waitLog(_ app: XCUIApplication, beyond count: Int, timeout: TimeInterval = 5) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline, log(app).count <= count {
            Thread.sleep(forTimeInterval: 0.2)
        }
        Thread.sleep(forTimeInterval: 0.3)
    }

    /// 在元素命中区（读屏框即按钮框）内某个相对位置真点（dx / dy 为 0…1）；默认中点。
    func tap(_ element: XCUIElement, dx: CGFloat = 0.5, dy: CGFloat = 0.5) {
        element.coordinate(withNormalizedOffset: CGVector(dx: dx, dy: dy)).tap()
    }

    /// 命中区边缘内 1pt 处真点（上 / 下 / 左 / 右）。
    func tapEdge(_ element: XCUIElement, _ edge: UIRectEdge) {
        let frame = element.frame
        let dx: CGFloat = switch edge {
        case .left: 1 / frame.width
        case .right: 1 - 1 / frame.width
        default: 0.5
        }
        let dy: CGFloat = switch edge {
        case .top: 1 / frame.height
        case .bottom: 1 - 1 / frame.height
        default: 0.5
        }
        tap(element, dx: dx, dy: dy)
    }

    /// 无障碍树深度优先顺序（有名称的元素）。顺序是读屏遍历的近似，实机 VoiceOver 仍须人工核对。
    func readingOrder(_ app: XCUIApplication) throws -> [ProductVisualA11yItem] {
        var items: [ProductVisualA11yItem] = []
        func walk(_ element: XCUIElementSnapshot) {
            if !element.label.isEmpty {
                items.append(ProductVisualA11yItem(type: element.elementType, id: element.identifier,
                                                   label: element.label, frame: element.frame))
            }
            element.children.forEach(walk)
        }
        try walk(app.snapshot())
        return items
    }

    func keep(_ items: [ProductVisualA11yItem], _ name: String) {
        let text = items.enumerated()
            .map { "\($0.offset)\t\($0.element.type.rawValue)\t\($0.element.id)\t\($0.element.label)" }
        let attachment = XCTAttachment(string: text.joined(separator: "\n"))
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// 读屏顺序里第一个满足条件的位置。
    func index(_ items: [ProductVisualA11yItem], _ what: String, file: StaticString = #filePath, line: UInt = #line,
               where predicate: (ProductVisualA11yItem) -> Bool) -> Int {
        guard let found = items.firstIndex(where: predicate) else {
            XCTFail("读屏树里没有 \(what)", file: file, line: line)
            return Int.max
        }
        return found
    }

    func occurrences(_ text: String, in label: String) -> Int {
        label.components(separatedBy: text).count - 1
    }
}
