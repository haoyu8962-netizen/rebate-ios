import Foundation
import UIKit
import XCTest

/// APP-09v-b 的 UI 测试入口：真实 App（Debug）+ 本机假服务（`-CouliFakeLoginServer`）+ a 组 Debug 输入 `COULI_FAKE_WALLET_VISUAL`
/// 的**扩展**（交回 §2.2；实现方在 App target 的 `#if DEBUG` 里接，Release 不存在；只走环境变量，不写 App 标准偏好）：
///
/// 载荷在 a 组 `{"summary": …}` 之外多一个可选键 `records`：
/// `{"pages": {"<游标>": <列表报文>, …}（"" = 第一页）, "details": {"<withdrawal_id>": <详情报文>, …}, "nowMillis": <Int>}`。生效时：
/// - `GET /v1/withdrawals`：无 cursor 回 `pages[""]`，有 cursor 回 `pages[<解码后的游标>]`，缺页回 50001；
/// - `GET /v1/withdrawals/{id}`：回 `details[id]`，没有回 30701；
/// - 这两类回答带 `Date` 响应头 = `nowMillis`（生产 ApiClient 据此校准显示时钟，「今天 10:00」）；
/// - 只读记录 `debug.wallet.log` 另记两类出口（交给系统 / Router 之前、同步追加）：`copy:<文本>`（AppWallet.copy，每调用一次一条）、
///   `contact:<来源路由名>`（AppWallet.contactService，每调用一次一条）。a 组的 `request:` / `route:` 两类不变。
@MainActor
protocol RecordsVisualUITest: WalletVisualUITest {}

extension RecordsVisualUITest {
    func visualRecords() throws -> [String: Any] {
        let data = try Data(contentsOf: Self.repo().appendingPathComponent("specs/wallet-vectors.json"))
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try XCTUnwrap(root["visualWithdrawRecords"] as? [String: Any], "缺 visualWithdrawRecords")
    }

    /// 冷启动 → 「我的」→【钱包】→「提现记录」，列表回 `page` 那份报文；注入没生效（列表里没有 `expect` 这张单）即抛错结束。
    func launchRecords(_ page: String, expect: String, extra: [String] = []) throws -> XCUIApplication {
        let visual = try visualRecords()
        let pages = try XCTUnwrap((visual["pages"] as? [String: Any])?[page], "缺 pages.\(page)")
        return try launchRecords(pages: ["": pages], expect: expect, extra: extra)
    }

    /// 同上，列表按游标给多页（v3：`["": 第 1 页, "p2": 第 2 页]`）。
    func launchRecords(pages: [String: Any], expect: String, extra: [String] = []) throws -> XCUIApplication {
        let visual = try visualRecords()
        var details: [String: Any] = [:]
        for case let object as [String: Any] in (visual["details"] as? [String: Any] ?? [:]).values {
            if let id = object["withdrawal_id"] as? String {
                details[id] = object
            }
        }
        let now = try XCTUnwrap((visual["clock"] as? [String: Any])?["nowMillis"] as? NSNumber)
        let payload: [String: Any] = try [
            "summary": summary("normal"),
            "records": ["pages": pages, "details": details, "nowMillis": now],
            // #24 T21（升锁 00deded0ef6f）：包内 withdraw.sla_text 已等于 BR-TEXT-07 回落句；经 Debug 假服务 GET /v1/config 下发旧包内值
            "configTexts": ["withdraw.sla_text": Self.configuredSla],
        ]
        let app = XCUIApplication()
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
        let records = app.buttons["提现记录"].firstMatch
        XCTAssertTrue(records.waitForExistence(timeout: 15), "钱包页没有「提现记录」")
        records.tap()
        XCTAssertTrue(node(app, "records.page").waitForExistence(timeout: 15), "没有进提现记录页")
        try requireLog(app)
        guard node(app, "record.\(expect)").waitForExistence(timeout: 8) else {
            throw WalletVisualUIError.notInjected("记录页没有注入的单 \(expect)（records 载荷未接）")
        }
        Thread.sleep(forTimeInterval: 0.8)
        return app
    }

    /// v3：同月派生的一页（照拷 `pages.pending` 的单，只换 ID 与申请时间，同进程内 `RecordsVisualData.sameMonth`）：ID 为 R + 两位序号。
    func sameMonthPage(_ range: ClosedRange<Int>, next: String?) throws -> [String: Any] {
        let visual = try visualRecords()
        let pending = try XCTUnwrap((visual["pages"] as? [String: Any])?["pending"] as? [String: Any])
        let base = try XCTUnwrap((pending["items"] as? [[String: Any]])?.first)
        let items = range.map { index -> [String: Any] in
            var item = base
            item["withdrawal_id"] = String(format: "R%02d", index)
            item["created_at"] = String(format: "2026-10-%02dT%02d:00:00+08:00", 11 - index / 24, 23 - (index % 24))
            return item
        }
        return ["items": items, "next_cursor": next.map { $0 as Any } ?? NSNull()]
    }

    func entries(_ app: XCUIApplication, after count: Int) -> [String] {
        Array(log(app).dropFirst(count))
    }

    /// 宿主下发的时效句：升锁前包内 DefaultConfig（锁 a7c9f1f 的 openapi 示例）的值，与 BR-TEXT-07 回落句不同。
    /// 与 AppTests 的 `RecordsVisualServer.configuredSla`（#24 T14）同一个值。
    static var configuredSla: String {
        "工作日 24 小时内处理"
    }

    /// v2 / T1：App 生效配置里的时效句。UI 进程不链接包；`-CouliFakeLoginServer` 的 `GET /v1/config` 在包内 `DefaultConfig` 上
    /// 并入注入的 `configTexts`（`DebugWalletVisual.configReply`）。#24 T21：升锁 00deded0ef6f 后包内值已等于 BR-TEXT-07 回落句，
    /// 改为注入旧包内值，期望值就是注入值；判据（配置值 ≠ 回落句、页面按配置取值）不变。
    func configSla() throws -> String {
        Self.configuredSla
    }

    /// v2 / T3：读屏可达的顺序。iOS 26 的 XCUI 快照会把一个无障碍元素（按钮、`children: .combine / .ignore` 的整行）内部的子文字
    /// 也列出来，而 VoiceOver 停在该元素上、不进入其子树。这里按读屏规则过滤：有 label 的元素（应用根除外）收进来后**不再展开它的子树**；
    /// 无 label 的容器（`children: .contain` 等）照常展开。只用于判断读屏先后，不改变「卡头 label 不含副文案 / 副文案只读一次」的断言。
    /// v2.1：展开卡头的画面内容（「申请金额」小字、大数、胶囊、箭头）是按钮的**兄弟**而不是子元素（画在按钮之上、读屏隐藏，K5），
    /// 快照照样列出；读屏只停在合成整句的按钮上。所以再丢掉 frame 整个落在之前已收的按钮里的元素（容差 1pt）。
    func spokenOrder(_ app: XCUIApplication) throws -> [WalletA11yItem] {
        var items: [WalletA11yItem] = []
        var buttons: [CGRect] = []
        func walk(_ element: XCUIElementSnapshot, root: Bool) {
            if !root, !element.label.isEmpty {
                let frame = element.frame
                if buttons.contains(where: { $0.insetBy(dx: -1, dy: -1).contains(frame) }) {
                    return
                }
                items.append(WalletA11yItem(id: element.identifier, label: element.label, frame: frame))
                if element.elementType == .button {
                    buttons.append(frame)
                }
                return
            }
            element.children.forEach { walk($0, root: false) }
        }
        try walk(app.snapshot(), root: true)
        return items
    }

    /// 读屏树里 label 含 `text` 的元素个数。
    func spokenCount(_ items: [WalletA11yItem], _ text: String) -> Int {
        items.filter { $0.label.contains(text) }.count
    }
}
