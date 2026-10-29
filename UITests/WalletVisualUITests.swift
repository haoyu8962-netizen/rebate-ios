import SnapshotTesting
import XCTest

/// APP-09v-a 钱包页真实点击（资金页口径：按钮必须真点，用 Debug 请求记录 `debug.wallet.log` 断言去向与次数，§2.2）、读屏与问号说明半屏。
/// 真实 App + 假服务；文案按契约 / 草稿原文写在断言里（UI 测试进程不链接包）。读屏顺序是无障碍树的近似，实机 VoiceOver 仍须人工遍历。
@MainActor
final class WalletVisualUITests: XCTestCase, WalletVisualUITest {
    private let reason30302 = "账户有待抵扣金额，抵扣完成前暂不能提现"
    private let reason30306 = "提现功能暂时关闭，请稍后再试"

    override func setUp() async throws {
        continueAfterFailure = true
    }

    override func tearDown() async throws {
        XCUIDevice.shared.appearance = .light
    }

    // MARK: - 资金按钮真点

    /// 【提现】真点一次：恰好一次 route:Withdraw（空参数）；钱包页在导航之前不发 rules（G-W02），之后由提现页取 rules；无写请求。
    /// 风控冻结同样可点（BR-WDR-05 细则，G11 更正）。
    func testWithdrawRealTapOpensWithdrawOnceWithoutRulesPrefetch() throws {
        for name in ["normal", "risk"] {
            let app = try launchWallet(name, expect: "12.34")
            let before = log(app).count
            let button = app.buttons["提现"].firstMatch
            XCTAssertTrue(button.isEnabled, "\(name)：【提现】可点")
            button.tap()
            waitLog(app, beyond: before)
            let after = Array(log(app).dropFirst(before))
            XCTAssertEqual(after.filter { $0.hasPrefix("route:") }, ["route:Withdraw"], "\(name)：只进 Withdraw 一次、空参数")
            let routeAt = after.firstIndex(of: "route:Withdraw") ?? Int.max
            let rulesAt = after.firstIndex(of: "request:GET /v1/withdrawals/rules") ?? Int.max
            XCTAssertLessThan(routeAt, rulesAt, "\(name)：rules 只在进入提现页之后发（钱包不预取）")
            XCTAssertLessThanOrEqual(
                after.filter { $0 == "request:GET /v1/withdrawals/rules" }.count,
                1,
                "\(name)：rules 至多一次"
            )
            XCTAssertFalse(
                after.contains { $0.hasPrefix("request:POST") || $0.hasPrefix("request:PUT") },
                "\(name)：无写请求"
            )
            app.terminate()
        }
    }

    /// 置灰的【提现】真点：待抵扣、30306、断网旧数据——不导航、不发任何请求；读屏读出置灰原因（brief §4.2「置灰读原因」）。
    func testDisabledWithdrawRealTapIsInertAndReadsReason() throws {
        for (name, reason) in [("negative", reason30302), ("disabled", reason30306)] {
            let app = try launchWallet(name, expect: nil)
            try assertInert(app, name)
            let button = app.buttons["提现"].firstMatch
            let spoken = button.label + " " + ((button.value as? String) ?? "")
            XCTAssertTrue(spoken.contains(reason), "\(name)：置灰【提现】读出原因「\(reason)」，实际「\(spoken)」")
            app.terminate()
        }
        // 断网旧数据：先在线成功一次（写缓存），再断网冷启动（G-W05：旧数据置灰）
        try launchWallet("normal", expect: "12.34").terminate()
        let app = try launchWallet("normal", offline: true, expect: nil)
        XCTAssertTrue(node(app, "wallet.stale").waitForExistence(timeout: 10), "断网显示缓存")
        try assertInert(app, "断网旧数据")
        app.terminate()
    }

    /// 只读出口真点：「提现记录 ›」→ WithdrawRecords、风控条 → RiskNotice、订单 → OrderList、余额流水 → Ledger；各一次、空参数、无写请求。
    func testExitsRealTapRouteOnce() throws {
        let cases: [(summary: String, route: String)] = [
            ("normal", "WithdrawRecords"), ("risk", "RiskNotice"), ("normal", "OrderList"), ("normal", "Ledger"),
        ]
        for item in cases {
            let app = try launchWallet(item.summary, expect: "12.34")
            let before = log(app).count
            let target = switch item.route {
            case "WithdrawRecords": app.buttons["提现记录"].firstMatch
            case "RiskNotice": node(app, "wallet.risk")
            case "OrderList": node(app, "wallet.entries").buttons["订单"].firstMatch
            default: node(app, "wallet.entries").buttons["余额流水"].firstMatch
            }
            XCTAssertTrue(target.waitForExistence(timeout: 5), "\(item.route)：入口存在")
            target.tap()
            waitLog(app, beyond: before)
            let after = Array(log(app).dropFirst(before))
            XCTAssertEqual(after.filter { $0.hasPrefix("route:") }, ["route:\(item.route)"], "\(item.route)：一次、空参数")
            XCTAssertFalse(after.contains { $0.hasPrefix("request:POST") || $0.hasPrefix("request:PUT") }, "无写请求")
            // a v3（评审 r1 S2-1）：出口记录同步写、请求记录异步写，「出口之前」那段恒为空，v2 的窗口拦不住任何东西。改按目的页
            // 基线计数：整段点击之后的 getMe 次数扣掉目的页自己的已知读取（RiskNotice 进页读一次风险状态；订单切 Tab 时「我的」
            // Tab 根在切换瞬间可见，至多一次；提现记录、余额流水零次），多出来的就是钱包发的。点击时钱包零 getMe 另由进程内
            // WalletVisualMoneyTests.testOtherExitsKeepRoutes（不渲染目的页）精确守住。
            let getMe = after.filter { $0 == "request:GET /v1/me" }.count
            switch item.route {
            case "RiskNotice": XCTAssertEqual(getMe, 1, "RiskNotice：只有目的页自己那一次 getMe（G-W03）：\(after)")
            case "OrderList": XCTAssertLessThanOrEqual(getMe, 1, "OrderList：至多「我的」Tab 根那一次（G-W03）：\(after)")
            default: XCTAssertEqual(getMe, 0, "\(item.route)：目的页不读 getMe，钱包也不能读（G-W03）：\(after)")
            }
            app.terminate()
        }
    }

    /// 收益看板入口（Debug 打开开关）：三项入口，真点 → Earnings 一次、空参数。
    func testEarningsEntryRealTap() throws {
        let app = try launchWallet("normal", earnings: true, expect: "12.34")
        let entries = node(app, "wallet.entries")
        for title in ["订单", "余额流水", "收益看板"] {
            XCTAssertTrue(entries.buttons[title].firstMatch.exists, "入口「\(title)」")
        }
        let before = log(app).count
        entries.buttons["收益看板"].firstMatch.tap()
        waitLog(app, beyond: before)
        XCTAssertEqual(log(app).dropFirst(before).filter { $0.hasPrefix("route:") }, ["route:Earnings"])
        app.terminate()
    }

    /// Android 评审 r1 S2-1 的真点对照（AX3，iPhone 17 宽）：眼睛命中区下缘内 1pt 只切隐藏、不导航；「提现记录」命中区上缘内 1pt 只进记录。
    /// 两个命中区都 ≥ 44 且不重叠（窄屏 320 的几何另在 AppTests/WalletVisualAdaptTests）。
    func testEyeAndRecordsEdgesAtAX3HitTheirOwnTarget() throws {
        let app = try launchWallet("normal", expect: "12.34", extra: [
            "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXL",
        ])
        let eye = app.buttons["隐藏金额"].firstMatch
        let records = app.buttons["提现记录"].firstMatch
        XCTAssertTrue(eye.exists && records.exists)
        for frame in [eye.frame, records.frame] {
            XCTAssertGreaterThanOrEqual(frame.width, 43.5)
            XCTAssertGreaterThanOrEqual(frame.height, 43.5)
        }
        XCTAssertTrue(!eye.frame.intersects(records.frame), "眼睛 \(eye.frame) 与提现记录 \(records.frame) 命中区重叠")
        var before = log(app).count
        tapEdge(eye, .bottom)
        XCTAssertTrue(app.buttons["显示金额"].firstMatch.waitForExistence(timeout: 3), "眼睛下缘：切到隐藏")
        Thread.sleep(forTimeInterval: 0.8)
        XCTAssertFalse(log(app).dropFirst(before).contains { $0.hasPrefix("route:") }, "眼睛下缘不能打开提现记录")
        before = log(app).count
        tapEdge(app.buttons["提现记录"].firstMatch, .top)
        waitLog(app, beyond: before)
        XCTAssertEqual(log(app).dropFirst(before).filter { $0.hasPrefix("route:") }, ["route:WithdrawRecords"],
                       "提现记录上缘只进记录")
        app.terminate()
    }

    // MARK: - 读屏

    /// Android 评审 r1 S2-2：隐藏后逐项读「金额已隐藏」——可提现、冻结中、已提现、预估收益、其中已收货、暂缓入账各自都读得到，任何读屏名都不含原值；
    /// 眼睛不发请求。
    func testHiddenReadoutsPerItem() throws {
        let app = try launchWallet("normal", expect: "12.34")
        let before = log(app).count
        app.buttons["隐藏金额"].firstMatch.tap()
        XCTAssertTrue(app.buttons["显示金额"].firstMatch.waitForExistence(timeout: 3))
        Thread.sleep(forTimeInterval: 0.8)
        XCTAssertFalse(log(app).dropFirst(before).contains { $0.hasPrefix("request:") }, "眼睛不发请求")
        let items = try readingOrder(app)
        keep(items, "hidden-readouts")
        for name in ["可提现余额", "冻结中", "已提现", "预估收益", "其中已收货", "暂缓入账"] {
            let hits = items.filter { $0.label.contains(name) && $0.label.contains("金额已隐藏") }
            XCTAssertFalse(hits.isEmpty, "「\(name)」要读「金额已隐藏」")
        }
        for raw in ["12.34", "56.78", "34.56", "4.56"] {
            XCTAssertFalse(items.contains { $0.label.contains(raw) }, "隐藏后读屏不能读出 \(raw)")
        }
        XCTAssertTrue(items.contains { $0.label.contains("10 月结算") || $0.label.contains("10月结算") }, "月份照常读")
        app.terminate()
    }

    /// 读屏顺序（brief §4.2）：风控条 → 可提现（含金额）→【提现】→ 提现记录 → 冻结中 → 已提现 → 预估收益（问号「预估收益说明」）→ 入口。
    func testReadingOrder() throws {
        let app = try launchWallet("risk", expect: "12.34")
        let items = try readingOrder(app)
        keep(items, "reading-order")
        func first(_ what: String, _ predicate: (WalletA11yItem) -> Bool) -> Int {
            guard let index = items.firstIndex(where: predicate) else {
                XCTFail("读屏树里没有 \(what)")
                return Int.max
            }
            return index
        }
        let order = [
            first("风控条") { $0.label.contains("提现已暂停") },
            first("可提现金额") { $0.label.contains("可提现余额") && $0.label.contains("12.34") },
            first("【提现】") { $0.label == "提现" || $0.label.hasPrefix("提现，") || $0.label.hasPrefix("提现,") },
            first("提现记录") { $0.label.hasPrefix("提现记录") },
            first("冻结中") { $0.label.hasPrefix("冻结中") && !$0.label.contains("说明") },
            first("已提现") { $0.label.hasPrefix("已提现") },
            first("预估收益") { $0.label.hasPrefix("预估收益") && !$0.label.contains("说明") },
            first("预估收益说明") { $0.label == "预估收益说明" },
            first("入口订单") { $0.label == "订单" && $0.frame.minY > 200 },
        ]
        XCTAssertEqual(order, order.sorted(), "读屏顺序 \(order)")
        app.terminate()
    }

    // MARK: - 问号说明半屏（W15；WalletNote* 三张基准）

    /// 三个问号真点打开说明：正文 14（与 17 比更接近 14 的排版高度）、【知道了】描边次按钮（按钮中部不是品牌实底）；关闭不发请求；整屏基准。
    func testHelpSheetsBodyAndOutlineButton() throws {
        let boards = [("预估收益说明", "WalletNoteEstimate-light"), ("冻结中说明", "WalletNoteFrozen-light"),
                      ("暂缓入账说明", "WalletNotePaused-light")]
        for (label, name) in boards {
            let app = try launchWallet("normal", expect: "12.34")
            let before = log(app).count
            app.buttons[label].firstMatch.tap()
            let body = node(app, "wallet.help.text")
            XCTAssertTrue(body.waitForExistence(timeout: 5), "\(name)：说明打开")
            Thread.sleep(forTimeInterval: 1.2)
            let image = app.screenshot().image
            let ok = node(app, "wallet.help.ok")
            XCTAssertTrue(ok.exists, "\(name)：【知道了】")
            XCTAssertFalse(isBrandFill(image, ok.frame), "\(name)：【知道了】是描边次按钮，不是实心主按钮")
            XCTAssertTrue(closerTo14(body), "\(name)：正文 14/21（不是 17）：框 \(body.frame)")
            withSnapshotTesting(record: ProcessInfo.processInfo
                .environment["COULI_RECORD_SNAPSHOTS"] == "1" ? .missing : .never) {
                    assertSnapshot(of: image, as: .image(precision: 0.99, perceptualPrecision: 0.98), named: name)
                }
            ok.tap()
            XCTAssertTrue(body.waitForNonExistence(timeout: 3), "\(name)：【知道了】关闭")
            XCTAssertFalse(log(app).dropFirst(before).contains { $0.hasPrefix("request:") || $0.hasPrefix("route:") },
                           "\(name)：说明不发请求、不导航")
            app.terminate()
        }
    }

    // MARK: - 工具

    private func assertInert(_ app: XCUIApplication, _ name: String) throws {
        let button = app.buttons["提现"].firstMatch
        XCTAssertTrue(button.exists, "\(name)：有【提现】")
        XCTAssertFalse(button.isEnabled, "\(name)：【提现】置灰")
        let before = log(app).count
        button.tap()
        Thread.sleep(forTimeInterval: 1.5)
        XCTAssertEqual(Array(log(app).dropFirst(before)), [], "\(name)：置灰按钮真点不导航、不发请求")
    }

    /// 按钮框中部（避开文字的左右 1/6 处）像素是不是品牌实底（#C44820 附近）。
    private func isBrandFill(_ image: UIImage, _ frame: CGRect) -> Bool {
        guard let cg = image.cgImage else { return false }
        let scale = CGFloat(cg.width) / image.size.width
        var brand = 0
        for dx in [frame.width / 6, frame.width * 5 / 6] {
            let point = CGPoint(x: (frame.minX + dx) * scale, y: frame.midY * scale)
            guard let rgb = Self.rgb(cg, point) else { continue }
            if abs(rgb[0] - 196) < 30, abs(rgb[1] - 72) < 30, abs(rgb[2] - 32) < 30 {
                brand += 1
            }
        }
        return brand == 2
    }

    private static func rgb(_ image: CGImage, _ point: CGPoint) -> [Int]? {
        var pixel = [UInt8](repeating: 0, count: 4)
        guard let context = CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.draw(image, in: CGRect(x: -point.x, y: -(CGFloat(image.height) - point.y), width: CGFloat(image.width),
                                       height: CGFloat(image.height)))
        return [Int(pixel[0]), Int(pixel[1]), Int(pixel[2])]
    }

    /// 正文框高度更接近 14 号（行高 21）还是 17 号（行高 25.5）按同宽排版的高度（「离谁近」，不依赖绝对阈值）。
    private func closerTo14(_ body: XCUIElement) -> Bool {
        let width = body.frame.width
        func height(_ size: CGFloat) -> CGFloat {
            let style = NSMutableParagraphStyle()
            style.minimumLineHeight = size * 1.5
            style.maximumLineHeight = size * 1.5
            let text = NSAttributedString(string: body.label, attributes: [
                .font: UIFont.systemFont(ofSize: size), .paragraphStyle: style,
            ])
            return text.boundingRect(with: CGSize(width: width, height: .greatestFiniteMagnitude),
                                     options: [.usesLineFragmentOrigin], context: nil).height
        }
        return abs(body.frame.height - height(14)) < abs(body.frame.height - height(17))
    }
}
