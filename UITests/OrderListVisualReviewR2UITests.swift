import Vision
import XCTest

/// APP-08v-a 测试 v5（D10-362 ②）：真实 App + 本机假服务 DebugFakeOrders（通用样例：自购 15 单、每页 5 单）。
/// 1. 参数化（查询范围 / 断网缓存 / 翻页失败三种列表尾）：系统字号 AX3、月份 14 个（history=2025-09-01，半屏放不下、走滚动分支），
///    列表先滚到底让列表尾出现、再停到中部，然后真点【月份】——事件循环必须及时空闲（点击本身 < 15 秒；卡死时 XCTest 要等 60 秒空闲超时），
///    半屏可操作：在半屏里拖到最后一个月、真点选中、半屏关闭、筛选显示所选月份。另核 D10-362 ① 的结构要求：列表停在中部时，
///    列表尾不在可视区却已在读屏树里——常驻在惰性列表之外（放回惰性列表时，远在视口下方的页脚不会被建出来）。
/// 2. 新用户首单前空态（无订单 + 一张待跟单卡）：默认字号下页面一打开、不滚动，【去首页逛逛】整块在 Tab 栏之上、可点，真点回首页。
///    390 宽默认字号 / 320 宽 AX3 两种尺寸的首屏几何在 AppTests `OrderListVisualReviewR2Tests`（模拟器宽度固定，这里是 402 宽真点）。
/// 3. D10-366（已知差异，编排裁定接受；修订 D10-364）：系统字号 AX3 + 一张待跟单卡——连续滚动（每次固定距离的慢拖，最多 6 次，
///    按钮出现即停）后【去首页逛逛】整块可见、高 ≥ 44、真点回首页；待跟单卡内容不截断：读屏文本（卡内各文字元素的标签与文案字典
///    逐字相同、不带省略号）+ 像素（每屏截图文字识别合起来完整读到、没有省略号）。默认字号那一条（用例 2）仍判不滚动首屏可见。
///    D10-366 要求「能做 320 宽就用 320」：做不到——本机唯一的 iOS 运行时是 26.5，320 宽的机型（iPhone SE 第 1 代、iPod touch 7）
///    最高只到 iOS 15，App 最低 iOS 16 装不上；本线 UI 用例固定跑在本线模拟器 APP08v-ios（iPhone 17，402 宽）。320 宽的几何与像素判据在
///    AppTests `OrderListVisualReviewR2Tests.testFirstOrderEmptyHomeButtonOnFirstScreen320AX3`（进程内 320 × 568 画布）。
@MainActor
final class OrderListVisualReviewR2UITests: XCTestCase, TradeUITest {
    enum Tail: String, CaseIterable {
        case history
        case stale
        case pageError
    }

    private let ax3 = ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityExtraLarge"]
    private let firstCard = "order.card.ord-3741234567890123456"

    override func setUp() async throws {
        continueAfterFailure = false
    }

    override func tearDown() async throws {
        resetFakeSession()
    }

    func testMonthSheetDoesNotHangWithHistoryTail() throws {
        try runMonthSheet(.history)
    }

    func testMonthSheetDoesNotHangWithStaleTail() throws {
        try runMonthSheet(.stale)
    }

    func testMonthSheetDoesNotHangWithPageErrorTail() throws {
        try runMonthSheet(.pageError)
    }

    // MARK: - 1

    /// 按种类启动并准备好列表尾的数据（断网缓存先在线取一次再断网冷启动）；返回 App 与列表尾的标识。
    private func prepare(_ tail: Tail) -> (XCUIApplication, String) {
        let start = ["-CouliStartTab", "orders"] + ax3
        var app: XCUIApplication
        let tailID: String
        switch tail {
        case .history:
            app = launch(start + ["-CouliFakeOrders", "history=2025-09-01"])
            XCTAssertTrue(element(app, firstCard).waitForExistence(timeout: 20), "列表出现")
            tailID = "orders.historyHint"
        case .stale:
            // 先在线取一次（写断网缓存，带查询范围 → 月份 14 个），再断网冷启动显示缓存
            app = launch(start + ["-CouliFakeOrders", "history=2025-09-01"])
            XCTAssertTrue(element(app, firstCard).waitForExistence(timeout: 20), "在线列表出现")
            Thread.sleep(forTimeInterval: 1)
            app.terminate()
            app = launch(start + ["-CouliFakeOrders", "offline,history=2025-09-01"])
            XCTAssertTrue(element(app, "orders.stale").waitForExistence(timeout: 20), "前提：断网冷启动显示缓存")
            tailID = "orders.pageError"
        case .pageError:
            app = launch(start + ["-CouliFakeOrders", "history=2025-09-01"])
            XCTAssertTrue(element(app, firstCard).waitForExistence(timeout: 20), "列表出现")
            let field = app.textFields["orders.search"]
            field.tap()
            field.typeText("pageerr\n")
            Thread.sleep(forTimeInterval: 1.5)
            tailID = "orders.pageError"
        }
        return (app, tailID)
    }

    private func runMonthSheet(_ tail: Tail) throws {
        let (app, tailID) = prepare(tail)
        // 滚到底：列表尾（查询范围提示 / 断网错误 +【重试】/ 翻页失败 + trace6 +【重试】）出现
        let tailElement = element(app, tailID)
        for _ in 0..<15 where !(tailElement.exists && tailElement.isHittable) {
            app.swipeUp()
        }
        XCTAssertTrue(tailElement.exists && tailElement.isHittable, "前提：\(tail) 列表尾 \(tailID) 已出现")
        // 停在中部：从底部小步往回拖，直到【月份】可点为止（控件区在惰性列表里，滚出视口就不存在），并且搜索框已滚出视口（不在顶）、
        // 列表尾不可见（不在底）。小步拖动、慢速，不甩动。
        let month = element(app, "orders.filter.month")
        let search = app.textFields["orders.search"]
        for _ in 0..<40 where !(month.exists && month.isHittable) {
            drag(app, from: 0.45, to: 0.55)
        }
        for _ in 0..<10 where search.exists && search.isHittable {
            drag(app, from: 0.55, to: 0.5)
        }
        XCTAssertTrue(month.exists && month.isHittable, "前提：【月份】在视口内可点")
        XCTAssertFalse(search.exists && search.isHittable, "前提：列表停在中部（搜索框已滚出，不在顶）")
        XCTAssertFalse(tailElement.exists && tailElement.isHittable, "前提：列表停在中部（列表尾不可见，不在底）")
        // D10-362 ①：列表尾在惰性列表之外常驻——停在中部、不可见时也已建出（在读屏树里）。放到最后断言，先看是否卡死
        let tailBuilt = tailElement.exists

        let began = Date()
        month.tap()
        let elapsed = Date().timeIntervalSince(began)
        XCTAssertLessThan(elapsed, 15, "\(tail)：点【月份】后事件循环没有及时空闲（\(Int(elapsed)) 秒；卡死时 XCTest 要等 60 秒）")
        let all = element(app, "orders.option.all")
        XCTAssertTrue(all.waitForExistence(timeout: 5), "\(tail)：月份半屏打开")

        let last = element(app, "orders.option.2025-09")
        let screen = app.windows.firstMatch.frame
        func onScreen() -> Bool {
            last.exists && last.frame.minY >= screen.minY && last.frame.maxY <= screen.maxY
        }
        for _ in 0..<10 where !onScreen() {
            app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8))
                .press(forDuration: 0.05, thenDragTo: app.windows.firstMatch
                    .coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35)))
            Thread.sleep(forTimeInterval: 0.4)
        }
        XCTAssertTrue(onScreen(), "\(tail)：半屏可操作，能拖到最后一个月")
        last.tap()
        XCTAssertTrue(all.waitForNonExistence(timeout: 5), "\(tail)：选中后半屏关闭")
        XCTAssertTrue(month.label.contains("2025") || (month.value as? String)?.contains("2025") == true,
                      "\(tail)：筛选显示所选月份（\(month.label)）")
        XCTAssertTrue(tailBuilt, "\(tail)：列表停在中部时列表尾 \(tailID) 不在读屏树里——它仍在惰性列表里按需建（D10-362 ①）")
        app.terminate()
    }

    // MARK: - 2

    /// 新用户首单前（无订单 + 一张待跟单卡）：假服务 pending 场景下发淘宝、京东两张，先经生产入口关掉京东那张，剩一张淘宝；
    /// 不滚动，【去首页逛逛】整块在 Tab 栏之上、可点；真点回首页。
    func testFirstOrderEmptyHomeButtonTappableOnFirstScreen() {
        let app = launch(["-CouliStartTab", "orders", "-CouliFakeOrders", "empty,pending"])
        let jd = element(app, "pendingTrack.card.jd")
        XCTAssertTrue(jd.waitForExistence(timeout: 20), "前提：待跟单卡出现")
        jd.descendants(matching: .any)["pendingTrack.close"].firstMatch.tap()
        XCTAssertTrue(jd.waitForNonExistence(timeout: 10), "前提：京东那张已关闭")
        XCTAssertTrue(element(app, "pendingTrack.card.taobao").exists, "前提：剩一张待跟单卡（淘宝）")
        let button = app.buttons["去首页逛逛"].firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 10), "【去首页逛逛】在首屏（没有滚动；不在首屏时惰性列表不建它）")
        Thread.sleep(forTimeInterval: 1)
        let tabTop = ShellTabBar.bar(app).frame.minY
        XCTAssertTrue(button.isHittable, "【去首页逛逛】可点")
        XCTAssertGreaterThanOrEqual(button.frame.minY, 0, "【去首页逛逛】上缘在屏内：\(button.frame)")
        XCTAssertLessThanOrEqual(
            button.frame.maxY,
            tabTop + 0.5,
            "【去首页逛逛】整块在 Tab 栏之上：\(button.frame) / Tab 栏顶 \(tabTop)"
        )
        button.tap()
        XCTAssertTrue(element(app, "home.search").waitForExistence(timeout: 10), "点了回首页")
        app.terminate()
    }

    // MARK: - 3

    /// D10-366：AX3 + 一张待跟单卡（同用例 2 的准备）。先核读屏文本，再从首屏开始连续滚动：每次窗口内 0.75 → 0.35 一次慢拖（固定距离、
    /// 不甩动），最多 6 次，【去首页逛逛】存在、可点、高 ≥ 44、整块在列表顶 ～ Tab 栏顶之间即停；每屏截图读一遍文字。最后真点回首页。
    func testFirstOrderEmptyHomeButtonAX3ScrollsThenTap() throws {
        let app = launch(["-CouliStartTab", "orders", "-CouliFakeOrders", "empty,pending"] + ax3)
        let jd = element(app, "pendingTrack.card.jd")
        XCTAssertTrue(jd.waitForExistence(timeout: 20), "前提：待跟单卡出现")
        jd.descendants(matching: .any)["pendingTrack.close"].firstMatch.tap()
        XCTAssertTrue(jd.waitForNonExistence(timeout: 10), "前提：京东那张已关闭")
        let card = element(app, "pendingTrack.card.taobao")
        XCTAssertTrue(card.exists, "前提：剩一张待跟单卡（淘宝）")
        Thread.sleep(forTimeInterval: 1)
        let expected = try cardTexts(notificationRow: element(app, "pendingTrack.notifyRow").exists)
        assertSpoken(card, expected)

        let button = app.buttons["去首页逛逛"].firstMatch
        let listTop = element(app, "orders.list").frame.minY
        let tabTop = ShellTabBar.bar(app).frame.minY
        func visible() -> Bool {
            button.exists && button.isHittable && button.frame.height >= 43.5
                && button.frame.minY >= listTop - 0.5 && button.frame.maxY <= tabTop + 0.5
        }
        var lines: [String] = []
        var drags = 0
        while true {
            lines += ScreenTextReader.lines(XCUIScreen.main.screenshot().image, region: CGRect(
                x: 0, y: listTop, width: app.windows.firstMatch.frame.width, height: tabTop - listTop
            ), pointWidth: app.windows.firstMatch.frame.width)
            if visible() || drags >= 6 {
                break
            }
            drag(app, from: 0.75, to: 0.35)
            drags += 1
            Thread.sleep(forTimeInterval: 0.7)
        }
        XCTAssertTrue(button.exists, "滚 \(drags) 次后【去首页逛逛】已出现（不在时惰性列表不建它）")
        XCTAssertTrue(button.isHittable, "滚 \(drags) 次后【去首页逛逛】可点")
        XCTAssertGreaterThanOrEqual(button.frame.height, 43.5, "【去首页逛逛】高 ≥ 44：\(button.frame)")
        XCTAssertGreaterThanOrEqual(button.frame.minY, listTop - 0.5,
                                    "滚 \(drags) 次后【去首页逛逛】上缘在列表可视区内：\(button.frame) / 列表顶 \(listTop)")
        XCTAssertLessThanOrEqual(button.frame.maxY, tabTop + 0.5,
                                 "滚 \(drags) 次后【去首页逛逛】整块在 Tab 栏之上：\(button.frame) / Tab 栏顶 \(tabTop)")
        // D10-366 ②（像素判据）
        let read = lines.joined(separator: " | ")
        for text in expected {
            let missing = ScreenTextReader.missing(text, in: lines)
            XCTAssertTrue(missing.isEmpty, "待跟单卡文字「\(text)」没有完整读到，缺「\(missing)」（识别结果：\(read)）")
        }
        let cut = lines.filter(ScreenTextReader.hasEllipsis)
        XCTAssertTrue(cut.isEmpty, "滚动过程中出现省略号（文字被截断）：\(cut)")
        button.tap()
        XCTAssertTrue(element(app, "home.search").waitForExistence(timeout: 10), "点了回首页")
        app.terminate()
    }

    /// D10-366 ②（读屏文本判据）：卡内每段文字都作为读屏元素出现、标签与文案字典逐字相同；卡内没有带省略号的标签。
    private func assertSpoken(_ card: XCUIElement, _ expected: [String]) {
        let nodes = card.descendants(matching: .any)
        for text in expected {
            XCTAssertTrue(nodes.matching(NSPredicate(format: "label == %@", text)).firstMatch.exists,
                          "读屏：待跟单卡里没有完整的「\(text)」")
        }
        let cut = nodes.matching(NSPredicate(format: "label CONTAINS %@ OR label CONTAINS %@", "…", "..."))
            .allElementsBoundByIndex
        XCTAssertTrue(cut.isEmpty, "读屏：待跟单卡里有带省略号的标签：\(cut.map(\.label))")
    }

    /// 卡内应出现的全部文字（文案字典 contracts/snapshot/contracts/texts.default.json；平台名「淘宝」= enums/platform.json 的 taobao）。
    private func cardTexts(notificationRow: Bool) throws -> [String] {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("contracts/snapshot/contracts/texts.default.json")
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let texts = try XCTUnwrap(root["texts"] as? [String: String], "文案字典没有 texts")
        func text(_ key: String) throws -> String {
            try XCTUnwrap(texts[key], "文案字典缺 \(key)")
        }
        var result = try [
            text("pending_track_card.title"),
            text("pending_track_card.desc").replacingOccurrences(of: "{platform_name}", with: "淘宝"),
        ]
        if notificationRow {
            result += try [text("perm.push.card_hint"), text("perm.push.cta")]
        }
        return result
    }

    /// 窗口内纵向慢拖（归一化坐标），不甩动。
    private func drag(_ app: XCUIApplication, from: CGFloat, to: CGFloat) {
        let window = app.windows.firstMatch
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: from)).press(
            forDuration: 0.05, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: to)),
            withVelocity: XCUIGestureVelocity(200), thenHoldForDuration: 0.2
        )
        Thread.sleep(forTimeInterval: 0.3)
    }
}

/// 按截图读文字（Vision 文字识别，简体中文，不做语言纠正）：D10-366 ② 的像素判据。与 AppTests `CardTextReader` 同口径
/// （两个测试目标不共享源码，各留一份）。
private enum ScreenTextReader {
    /// 截图上 region（点坐标；pointWidth = 窗口宽，用来换算像素）内识别出的各行文字。
    static func lines(_ image: UIImage, region: CGRect, pointWidth: CGFloat) -> [String] {
        guard let cgImage = image.cgImage, pointWidth > 0 else { return [] }
        let scale = CGFloat(cgImage.width) / pointWidth
        let bounds = CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height)
        let crop = CGRect(x: region.minX * scale, y: region.minY * scale, width: region.width * scale,
                          height: region.height * scale).integral.intersection(bounds)
        guard !crop.isEmpty, let part = cgImage.cropping(to: crop) else { return [] }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["zh-Hans"]
        request.usesLanguageCorrection = false
        try? VNImageRequestHandler(cgImage: part).perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
    }

    static func normalized(_ text: String) -> [Character] {
        text.filter { $0.isLetter || $0.isNumber }.map(\.self)
    }

    /// text 里没被识别行覆盖到的字（空 = 全部读到）；覆盖规则同 AppTests `CardTextReader.missing`。
    static func missing(_ text: String, in lines: [String]) -> String {
        let target = normalized(text)
        var covered = Array(repeating: false, count: target.count)
        func mark(_ piece: ArraySlice<Character>) -> Bool {
            guard !piece.isEmpty, piece.count <= target.count else { return false }
            var hit = false
            for start in 0...(target.count - piece.count)
                where target[start..<(start + piece.count)].elementsEqual(piece) {
                (start..<(start + piece.count)).forEach { covered[$0] = true }
                hit = true
            }
            return hit
        }
        for line in lines {
            let chars = normalized(line)
            if mark(chars[...]) {
                continue
            }
            var index = 0
            while index < chars.count {
                var length = chars.count - index
                while length >= 3, !mark(chars[index..<(index + length)]) {
                    length -= 1
                }
                index += length >= 3 ? length : 1
            }
        }
        return String(zip(target, covered).filter { !$0.1 }.map(\.0))
    }

    static func hasEllipsis(_ line: String) -> Bool {
        line.contains("…") || line.contains("...") || line.contains("⋯")
    }
}
