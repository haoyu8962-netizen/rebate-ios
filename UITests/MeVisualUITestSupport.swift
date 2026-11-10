import Foundation
import UIKit
import XCTest

/// APP-12v 的 UI 测试入口：真实 App（Debug）+ 本机假服务（`-CouliFakeLoginServer`）+ 新 Debug 输入（交回 §2，实现方在 App target 的 `#if DEBUG` 里接，
/// Release 不存在；只走环境变量，不写 App 标准偏好）：
///
/// 环境变量 `COULI_FAKE_ME_VISUAL` = UTF-8 JSON 对象的 Base64：`{"me": <Me 报文，原样来自 specs/me-vectors.json 的
/// visualMe.profiles.<名>>}`。生效时：
/// - 假服务 `GET /v1/me` 回注入的 `me`（先于 `-CouliFakeMe me=…`；`guide=1` 仍然生效）；游客可不带 `me`（`{}`）；
/// - 只读记录 `debug.me.log`（根视图左上 1 × 1 只读元素，不挡点击，与 `debug.wallet.log` 同做法），accessibilityValue = 记录按发生顺序以「 | 」连接：
///   `request:GET /v1/me`（假服务收到的 getMe）、`route:<路由名>`（Router 打开的每个路由，含切 Tab）、`copy`（统一写入口写入成功，不记内容）、
///   `toast:<文字>`（`MeAnnounceProbe.toast`）、`announce:polite:<文字>` /
/// `announce:assertive:<文字>`（`MeAnnounceProbe.observe`）。
/// 瞬时轻提示一律读记录，不用 waitForExistence 抓（F-IOS-62）。
@MainActor
protocol MeVisualUITest: WalletVisualUITest {}

enum MeVisualUIError: Error, CustomStringConvertible {
    case notInjected

    var description: String {
        "没有只读记录 debug.me.log：COULI_FAKE_ME_VISUAL 未接（交回 §2）"
    }
}

extension MeVisualUITest {
    func profile(_ name: String) throws -> [String: Any] {
        let data = try Data(contentsOf: Self.repo().appendingPathComponent("specs/me-vectors.json"))
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let visual = try XCTUnwrap(root["visualMe"] as? [String: Any])
        return try XCTUnwrap((visual["profiles"] as? [String: Any])?[name] as? [String: Any], "缺 \(name)")
    }

    /// 冷启动到「我的」。`profile` 为 nil = 游客。`fake` 是 `-CouliFakeMe` 开关（guide=1 强制显示引导条）。
    func launchMe(_ name: String? = "me_member", fake: String = "") throws -> XCUIApplication {
        // 读屏类用例不读记录：底版也能跑到判据本身；要记录的用例开头调 requireMeLog
        let app = XCUIApplication()
        let payload: [String: Any] = try name.map { try ["me": profile($0)] } ?? [:]
        app.launchEnvironment["COULI_FAKE_ME_VISUAL"] = try JSONSerialization.data(withJSONObject: payload)
            .base64EncodedString()
        app.launchArguments += [
            "-CouliPrivacyPreset", "consented", "-CouliFakeLoginServer", "-CouliUpdateReset", "1",
            "-CouliHideDebugInfo", "1", "-CouliFakeTradeNoExternal", "-CouliStartTab", "me",
            "-CouliFakeWalletResetPending",
        ]
        if name != nil {
            app.launchArguments.append("-CouliFakeTradeLoggedIn")
        }
        if !fake.isEmpty {
            app.launchArguments += ["-CouliFakeMe", fake]
        }
        app.launch()
        XCTAssertTrue(ShellTabBar.bar(app).waitForExistence(timeout: 30), "没有进入 Tab 外壳")
        let page = name == nil ? "me.guest" : "me.nickname"
        XCTAssertTrue(node(app, page).waitForExistence(timeout: 15), "「我的」页没有到位")
        return app
    }

    func requireMeLog(_ app: XCUIApplication) throws {
        guard node(app, "debug.me.log").waitForExistence(timeout: 5) else {
            throw MeVisualUIError.notInjected
        }
    }

    func meLog(_ app: XCUIApplication) -> [String] {
        let element = node(app, "debug.me.log")
        guard element.exists, let value = element.value as? String, !value.isEmpty else { return [] }
        return value.components(separatedBy: " | ")
    }

    /// 等记录出现某条（上限内），再多等一会儿让重复的记录也落进来，返回全部。
    func waitMeLog(_ app: XCUIApplication, _ entry: String, count: Int = 1, timeout: TimeInterval = 8) -> [String] {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline, meLog(app).filter({ $0 == entry }).count < count {
            Thread.sleep(forTimeInterval: 0.2)
        }
        Thread.sleep(forTimeInterval: 0.8)
        return meLog(app)
    }

    /// 屏幕外的格子滑到可点（宫格在折叠线下）。
    func reveal(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        let target = node(app, id)
        XCTAssertTrue(target.waitForExistence(timeout: 10), "没有 \(id)")
        for _ in 0..<4 where !target.isHittable {
            app.swipeUp()
        }
        return target
    }

    /// 读屏遍历：XCUI 快照把合并元素的子节点、读屏隐藏的图标也列出来（实测 person、时钟、****），不是真实朗读项。规则：有名称的元素算一个
    /// 朗读单元、不再往里走（按钮、整块读的预估块、带读屏名的金额）；图片一律不算（本页图标全是装饰）；去掉调试元素与外壳 Tab 栏。实机 VoiceOver 仍须人工核对。
    func spoken(_ app: XCUIApplication) throws -> [WalletA11yItem] {
        var items: [WalletA11yItem] = []
        func walk(_ element: XCUIElementSnapshot) {
            if element.identifier.hasPrefix("debug.") || ShellTabBar.isShellTabBar(element) {
                return
            }
            if element.elementType == .image {
                return
            }
            if !element.label.isEmpty, element.elementType != .application, element.elementType != .window {
                items.append(WalletA11yItem(id: element.identifier, label: element.label, frame: element.frame))
                return
            }
            element.children.forEach(walk)
        }
        try walk(app.snapshot())
        return items
    }

    /// `patterns` 按顺序逐条匹配（正则，整段）：之间可以夹别的元素，但这些元素各自恰好出现一次。
    func assertOrder(
        _ items: [WalletA11yItem],
        _ patterns: [String],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        var cursor = 0
        for pattern in patterns {
            let regex = "^(" + pattern + ")$"
            let hits = items.indices.filter { items[$0].label.range(of: regex, options: .regularExpression) != nil }
            XCTAssertEqual(hits.count, 1, "「\(pattern)」应恰好出现一次，实际 \(hits.count)", file: file, line: line)
            guard let index = hits.first else { continue }
            XCTAssertGreaterThanOrEqual(index, cursor, "「\(pattern)」顺序不对：\(items.map(\.label))", file: file, line: line)
            cursor = index
        }
    }
}
