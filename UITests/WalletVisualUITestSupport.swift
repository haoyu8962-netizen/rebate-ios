import Foundation
import UIKit
import XCTest

/// APP-09v-a 的 UI 测试入口：真实 App（Debug）+ 本机假服务（`-CouliFakeLoginServer`）+ 新 Debug 输入（§2.2，实现方在 App target 的
/// `#if DEBUG` 里接，Release 不存在；调试开关只走启动参数 / 环境变量，不写 App 标准偏好）：
///
/// 环境变量 `COULI_FAKE_WALLET_VISUAL` = UTF-8 JSON 对象的 Base64：
/// `{"summary": <WalletSummary 报文，原样来自 specs/wallet-vectors.json 的 visualWallet.summaries.<名>>, "offline": <bool，缺省
/// false>,
///   "earnings": <bool，缺省 false>}`。生效时：
/// - 假服务 `GET /v1/wallet/summary` 回注入的 `summary`（优先于 `-CouliFakeWallet wallet=…` 的通用样例）；`offline: true` 时这条按传输层失败
///   结束（生产读断网缓存，WalletStale）；其余钱包类接口照旧由 DebugFakeWallet 回答；
/// - `earnings: true`：只在 Debug 把收益看板开关当作打开、Earnings 路由 since 当作 "1.0.0"（WalletEarningsEntry 画板；生产 since=null 不变）；
/// - 只读记录 `debug.wallet.log`（根视图左上 1 × 1 只读元素，不挡点击，与 `debug.purchase.log` 同做法），accessibilityValue = 记录按发生顺序以
///   「 | 」连接：`request:<方法> <路径>`（假服务收到的每个钱包类请求：/v1/wallet/*、/v1/withdrawals*、/v1/me、/v1/me/payout-account、
///   /v1/auth/step-up、/v1/idempotency-keys/abandon）；`route:<路由名>[?<参数按键名排序 k=v&…>]`（AppWallet 经 Router 打开 / 替换的每个路由）。
@MainActor
protocol WalletVisualUITest: XCTestCase {}

/// 读屏树里的一个有名称元素。
struct WalletA11yItem {
    let id: String
    let label: String
    let frame: CGRect
}

enum WalletVisualUIError: Error, CustomStringConvertible {
    case notInjected(String)

    var description: String {
        switch self {
        case let .notInjected(what):
            "假服务没有按 COULI_FAKE_WALLET_VISUAL 回答注入的数据（\(what)；§2.2 Debug 输入未接）"
        }
    }
}

extension WalletVisualUITest {
    static func repo() -> URL {
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while !FileManager.default.fileExists(atPath: directory.appendingPathComponent("contract.lock").path) {
            directory = directory.deletingLastPathComponent()
        }
        return directory
    }

    func summary(_ name: String) throws -> [String: Any] {
        let data = try Data(contentsOf: Self.repo().appendingPathComponent("specs/wallet-vectors.json"))
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let visual = try XCTUnwrap(root["visualWallet"] as? [String: Any])
        return try XCTUnwrap((visual["summaries"] as? [String: Any])?[name] as? [String: Any], "缺 \(name)")
    }

    /// 冷启动到「我的」，点【钱包】进钱包页；注入的摘要没生效（主卡大数不是注入值）即抛错结束。
    /// `expect` 是注入摘要下主卡读屏名里应出现的文字（如可提现「12.34」；隐藏时传 nil 不核对）。
    func launchWallet(_ name: String, offline: Bool = false, earnings: Bool = false, expect: String?,
                      extra: [String] = []) throws -> XCUIApplication {
        let app = XCUIApplication()
        let payload: [String: Any] = try ["summary": summary(name), "offline": offline, "earnings": earnings]
        app.launchEnvironment["COULI_FAKE_WALLET_VISUAL"] = try JSONSerialization.data(withJSONObject: payload)
            .base64EncodedString()
        app.launchArguments += [
            "-CouliPrivacyPreset", "consented", "-CouliFakeLoginServer", "-CouliUpdateReset", "1",
            "-CouliHideDebugInfo", "1", "-CouliFakeTradeLoggedIn", "-CouliFakeTradeNoExternal",
            "-CouliStartTab", "me", "-CouliFakeWalletResetPending",
        ] + extra
        app.launch()
        XCTAssertTrue(ShellTabBar.bar(app).waitForExistence(timeout: 30), "没有进入 Tab 外壳")
        let entry = node(app, "me.wallet")
        XCTAssertTrue(entry.waitForExistence(timeout: 15), "「我的」页没有【钱包】入口")
        entry.tap()
        let opened = node(app, "wallet.hero").waitForExistence(timeout: 15)
            || node(app, "wallet.content").waitForExistence(timeout: 2)
        XCTAssertTrue(opened, "没有进钱包页")
        // 只读记录在 = Debug 输入已接（通用样例与注入值同为 ¥12.34 时，单看金额分不出来）
        guard node(app, "debug.wallet.log").waitForExistence(timeout: 5) else {
            throw WalletVisualUIError.notInjected("只读记录 debug.wallet.log")
        }
        if let expect {
            let hit = app.descendants(matching: .any).containing(NSPredicate(format: "label CONTAINS %@", expect))
            guard hit.firstMatch.waitForExistence(timeout: 5) else {
                throw WalletVisualUIError.notInjected("主卡读不到「\(expect)」")
            }
        }
        Thread.sleep(forTimeInterval: 0.8)
        return app
    }

    func node(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any)[id].firstMatch
    }

    /// `debug.wallet.log` 的全部记录（没有该元素时为空数组）。
    func log(_ app: XCUIApplication) -> [String] {
        let element = node(app, "debug.wallet.log")
        guard element.exists, let value = element.value as? String, !value.isEmpty else { return [] }
        return value.components(separatedBy: " | ")
    }

    func requireLog(_ app: XCUIApplication) throws {
        guard node(app, "debug.wallet.log").waitForExistence(timeout: 5) else {
            throw WalletVisualUIError.notInjected("只读记录 debug.wallet.log")
        }
    }

    /// 等记录条数变化（真点之后），再多等一会儿让迟到的请求也落进来。
    func waitLog(_ app: XCUIApplication, beyond count: Int, timeout: TimeInterval = 5) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline, log(app).count <= count {
            Thread.sleep(forTimeInterval: 0.2)
        }
        Thread.sleep(forTimeInterval: 1.0)
    }

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

    /// 无障碍树深度优先顺序（有名称的元素）：读屏遍历的近似，实机 VoiceOver 仍须人工核对。
    func readingOrder(_ app: XCUIApplication) throws -> [WalletA11yItem] {
        var items: [WalletA11yItem] = []
        func walk(_ element: XCUIElementSnapshot) {
            if !element.label.isEmpty {
                items.append(WalletA11yItem(id: element.identifier, label: element.label, frame: element.frame))
            }
            element.children.forEach(walk)
        }
        try walk(app.snapshot())
        return items
    }

    func keep(_ items: [WalletA11yItem], _ name: String) {
        let text = items.enumerated().map { "\($0.offset)\t\($0.element.id)\t\($0.element.label)" }
        let attachment = XCTAttachment(string: text.joined(separator: "\n"))
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
