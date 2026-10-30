import XCTest

/// APP-09v-b 提现记录真实点击与读屏（资金页口径：写操作入口必须真点，用 `debug.wallet.log` 断言去向与次数，交回 §2.2）。
/// 文案按契约 / 草稿原文写在断言里（UI 测试进程不链接包）。读屏顺序是无障碍树的近似，实机 VoiceOver 仍须人工遍历。
/// Android b 评审抓过的：整行一个目标读全文与展开状态、展开卡头不重复朗读副文案（r1 S2-3）、复制 / 修改账号命中区真点（r1 S2-4）。
@MainActor
final class RecordsVisualUITests: XCTestCase, RecordsVisualUITest {
    /// BR-TEXT-07 原文（配置没下发时的回落句）。v2 / T1：时效句期望改取 App 生效配置（`configSla()`），并要求两者不同。
    private let fallbackSla = "人工审核，工作日 24 小时内处理，节假日顺延"
    private let frozen = "¥10 已冻结"

    override func setUp() async throws {
        continueAfterFailure = true
    }

    /// W22：收起行整行一个读屏目标——读金额、状态、时间账号与**完整**副文案（含画面上不画的第二句「¥10 已冻结」），并读出展开状态
    /// （accessibilityValue，展开前后不同）；展开后卡头不再重复副文案，「¥10 已冻结」在整棵读屏树里只出现一次（Android r1 S2-3）。
    func testRowOneTargetFullTextStateAndNoRepeatWhenExpanded() throws {
        let sla = try configSla()
        XCTAssertNotEqual(sla, fallbackSla, "前提：配置时效句与 BR-TEXT-07 回落句不同，才能区分按配置取值")
        let app = try launchRecords("list", expect: "PENDING")
        let row = node(app, "record.PENDING")
        let label = row.label
        for part in ["¥10", "审核中", "支付宝", sla, frozen] {
            XCTAssertTrue(label.contains(part), "收起行读屏含「\(part)」，实际「\(label)」")
        }
        // 配置句是回落句的子串，单看 contains 分不出来：再要求没有回落成 BR-TEXT-07（v2 / T1）
        XCTAssertFalse(label.contains(fallbackSla), "时效句按配置取值，不回落 BR-TEXT-07：\(label)")
        let collapsed = (row.value as? String) ?? ""
        XCTAssertFalse(collapsed.isEmpty, "收起行读出展开状态（accessibilityValue）")
        row.tap()
        Thread.sleep(forTimeInterval: 1.5)
        let header = node(app, "record.PENDING")
        XCTAssertTrue(header.waitForExistence(timeout: 5), "展开后卡头仍是同一个可点目标（收起）")
        let expanded = (header.value as? String) ?? ""
        XCTAssertFalse(expanded.isEmpty, "卡头读出展开状态")
        XCTAssertNotEqual(expanded, collapsed, "展开前后状态不同")
        XCTAssertFalse(header.label.contains(frozen), "卡头不重复副文案：\(header.label)")
        XCTAssertFalse(header.label.contains(sla), "卡头不重复时效句：\(header.label)")
        let items = try readingOrder(app)
        keep(items, "records-expanded-PENDING")
        XCTAssertEqual(spokenCount(items, frozen), 1, "「\(frozen)」只读一次（状态块）")
        XCTAssertEqual(spokenCount(items, sla), 1, "时效句只读一次（状态块）")
    }

    /// W28 / G-W08：【修改收款账号】挪进状态块——读屏顺序在退回句之后、明细「申请金额」之前；命中 ≥ 44、通栏；真点一次恰好
    /// `route:PayoutAccount`（空参数）、无写请求。
    func testChangeAccountOrderAndRealTapOnce() throws {
        let app = try launchRecords("list", expect: "FAILED")
        node(app, "record.FAILED").tap()
        let button = node(app, "record.changeAccount")
        XCTAssertTrue(button.waitForExistence(timeout: 8), "展开后有【修改收款账号】")
        XCTAssertGreaterThanOrEqual(button.frame.height, 43.5, "命中高 ≥ 44")
        XCTAssertGreaterThan(button.frame.width, app.frame.width * 0.6, "通栏")
        keep(try readingOrder(app), "records-expanded-FAILED-xcui")
        // v2 / T3：按读屏可达过滤（卡头按钮内部已隐藏的「申请金额」小字不算明细）；明细行 = 读屏可达的「申请金额，¥8」
        let items = try spokenOrder(app)
        keep(items, "records-expanded-FAILED")
        let returned = items.firstIndex { $0.label.contains("已退回可提现余额") } ?? Int.max
        let change = items.firstIndex { $0.id == "record.changeAccount" } ?? Int.max
        let fields = items.firstIndex { $0.label.hasPrefix("申请金额") && $0.id != "record.FAILED" } ?? Int.max
        XCTAssertLessThan(returned, change, "修改收款账号在退回句之后")
        XCTAssertLessThan(change, fields, "修改收款账号在明细之前")
        let before = log(app).count
        button.tap()
        waitLog(app, beyond: before)
        let after = entries(app, after: before)
        XCTAssertEqual(after.filter { $0.hasPrefix("route:") }, ["route:PayoutAccount"], "只进 PayoutAccount 一次、空参数")
        XCTAssertFalse(after.contains { $0.hasPrefix("request:POST") || $0.hasPrefix("request:PUT") }, "无写请求")
    }

    /// W27：复制命中 ≥ 44；命中区上 / 下 / 左 / 右边缘内 1pt 各真点一次，每次恰好一条 `copy:<流水号>`，不导航、不发请求。
    func testCopyHitEdgesEachCopyOnce() throws {
        let app = try launchRecords("list", expect: "PAID")
        node(app, "record.PAID").tap()
        let copy = node(app, "record.copy")
        XCTAssertTrue(copy.waitForExistence(timeout: 8), "展开后有【复制】")
        XCTAssertGreaterThanOrEqual(copy.frame.height, 43.5, "复制命中高 ≥ 44")
        XCTAssertGreaterThanOrEqual(copy.frame.width, 43.5, "复制命中宽 ≥ 44")
        for edge in [UIRectEdge.top, .bottom, .left, .right] {
            let before = log(app).count
            tapEdge(copy, edge)
            waitLog(app, beyond: before, timeout: 3)
            let after = entries(app, after: before)
            XCTAssertEqual(
                after.filter { $0.hasPrefix("copy:") },
                ["copy:20260928200040011100"],
                "边缘 \(edge.rawValue)：恰好一次复制"
            )
            XCTAssertFalse(after.contains { $0.hasPrefix("route:") || $0.hasPrefix("request:") }, "复制不导航、不发请求")
            Thread.sleep(forTimeInterval: 2.5)
        }
    }

    /// W29：【联系客服】命中 ≥ 44；真点一次恰好一条 `contact:WithdrawRecords`。
    func testContactRealTapOnce() throws {
        let app = try launchRecords("list", expect: "PENDING")
        node(app, "record.PENDING").tap()
        let link = node(app, "record.cs")
        XCTAssertTrue(link.waitForExistence(timeout: 8), "审核中展开后有【联系客服】")
        XCTAssertGreaterThanOrEqual(link.frame.height, 43.5, "命中高 ≥ 44")
        let before = log(app).count
        link.tap()
        waitLog(app, beyond: before)
        XCTAssertEqual(entries(app, after: before).filter { $0.hasPrefix("contact:") }, ["contact:WithdrawRecords"])
    }

    /// r1 ①（测试 v3）：真实快速上滑（XCUI press-drag，高速度松手）甩过第 1 页底部，页脚露出触发翻页，假服务约 0.3s 后回第 2 页——
    /// 结果在甩动 / 回弹期间到达。断言：翻页恰好一次；第 2 页追加；停下后列表没有被拉回到第 1 页上方（R20 底边在可视区底边之上、
    /// R01 不在屏上）。甩动中每次能取到的 R20 顶边与日志条数存为附件 `records-fling-samples`，供对照分析。
    /// 注：Debug 假服务的回答延迟固定 0.3s，而翻页只在页脚真正露出时发（r1 之前 S1 的要求），结果到达时列表多半已在底部回弹，
    /// 「惯性中途被拉回」不一定能在真机手势里稳定复现；确定性的判据在进程内 `RecordsVisualR1Tests.testMomentumPageArrivalNotPulledBack`。
    func testRealFlingIntoNextPageNotPulledBack() throws {
        let app = try launchRecords(
            pages: ["": sameMonthPage(1...20, next: "p2"), "p2": sameMonthPage(21...40, next: nil)], expect: "R01"
        )
        let list = app.scrollViews.containing(.any, identifier: "record.R01").firstMatch
        XCTAssertTrue(list.exists, "找不到记录列表的滚动视图")
        let listRequests = { (app: XCUIApplication) in
            self.log(app).filter { $0 == "request:GET /v1/withdrawals" }.count
        }
        let first = listRequests(app)
        let start = list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.9))
        let end = list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.1))
        start.press(forDuration: 0.02, thenDragTo: end, withVelocity: XCUIGestureVelocity(5000), thenHoldForDuration: 0)
        let r20 = node(app, "record.R20")
        var samples: [String] = []
        let began = Date()
        while Date().timeIntervalSince(began) < 3 {
            samples.append(String(format: "%.2f\t%.1f\t%d", Date().timeIntervalSince(began), r20.frame.minY,
                                  listRequests(app)))
        }
        let attachment = XCTAttachment(string: samples.joined(separator: "\n"))
        attachment.name = "records-fling-samples"
        attachment.lifetime = .keepAlways
        add(attachment)
        XCTAssertTrue(node(app, "record.R21").waitForExistence(timeout: 5), "甩到底后第 2 页没有追加")
        Thread.sleep(forTimeInterval: 1.5)
        XCTAssertEqual(listRequests(app) - first, 1, "甩动翻页恰好一次")
        XCTAssertLessThanOrEqual(r20.frame.maxY, list.frame.maxY + 0.5, "停下后没被拉回到第 1 页底部之上（R20 底边应已露出或在上方）")
        XCTAssertFalse(node(app, "record.R01").isHittable, "停下后不回到列表开头")
    }

    /// 未知状态：标题「处理中」，展开后没有复制、修改收款账号、客服任何入口（只读）。
    func testUnknownStatusHasNoWriteEntries() throws {
        let app = try launchRecords("unknown", expect: "UNKNOWN")
        let row = node(app, "record.UNKNOWN")
        XCTAssertTrue(row.label.contains("处理中"), "未知状态读「处理中」：\(row.label)")
        let before = log(app).count
        row.tap()
        waitLog(app, beyond: before)
        for id in ["record.copy", "record.changeAccount", "record.cs"] {
            XCTAssertFalse(node(app, id).exists, "未知状态不出 \(id)")
        }
        XCTAssertFalse(entries(app, after: before).contains { $0.hasPrefix("copy:") || $0.hasPrefix("route:") })
    }
}
