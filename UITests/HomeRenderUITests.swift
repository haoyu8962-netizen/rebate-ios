import UIKit
import XCTest

/// 首页真实 App 的渲染验收（第 4 版 P1 / P2，第 5 版 T-01～T-03）：Debug 包 + 本机假服务（`-CouliFakeLoginServer`；首页页面由
/// DebugFakeHome 按 `-CouliFakeHome <名字>` 回答，golden 页名以外的名字（main）是 Main 组合页），经无障碍树与整屏截图读出
/// 屏幕上实际画出来的内容。
/// - 隔离（T-02）：每次启动都带 `-CouliHomeTestReset 1`，App 在首页读本机数据之前清掉首页 LKG 与公告关闭等偏好，清完发 Darwin
///   信号；假服务回答页面时发「回答了哪一页」的信号。用例先等这两个信号，再看屏幕——没有缓存，首屏就是这次回答的页面，不靠
///   可被持久关闭的公告认页，也不需要重启换页。
/// - P1：每张区段卡都画出来。
/// - P2 / T-03：页底口径说明按受控样例（假服务 first(taobao) 三件商品：有券 + 无券混排、普通返利与比价区间）合并后应正好是
///   price_basis.general、rebate_compare、rebate_estimate 三句文案各一次（与搜索页 SearchDisclaimers.footerKeys 同一规则），
///   不出券后价句、不出键名；页底说明不论画成一个还是多个元素，都收齐后一起数。
/// - 置灰（T-01 / T-05 / T-07）在 HomeGrayscaleUITests（第 6 版挪出）。
@MainActor
final class HomeRenderUITests: XCTestCase {
    /// BR-PRICE-03 / 17 默认文案（三端同一句）。
    private static let generalPrice = "价格按单件计算，不含运费及会员价等优惠，以下单页为准"
    private static let couponPrice = "券后价按单件计算，不含运费及会员价等优惠，以下单页为准"
    private static let rebateEstimate = "预估返利以平台结算为准，未结算或订单失效时不返"
    private static let rebateCompare = "以结算为准"
    private static let rawKeys = ["price_basis", "rebate_estimate", "rebate_compare", "disclaimer"]

    override func setUp() async throws {
        continueAfterFailure = true
    }

    // MARK: - 启动（隔离 + 认页）

    /// 带重置启动，等「首页本机数据已清」与「假服务回答了 `page`」两个信号（HomeUILaunch）。
    private func launchHome(page: String, extra: [String] = []) -> XCUIApplication {
        HomeUILaunch.home(page: page, extra: extra)
    }

    private func labeled(_ app: XCUIApplication, _ text: String) -> XCUIElementQuery {
        HomeUILaunch.labeled(app, text)
    }

    // MARK: - P1

    /// 包内默认页同结构（金刚区 + 双入口，golden default_home）：两张卡都在屏幕上画出来。
    func testDefaultHomeDrawsBothSectionCards() {
        let app = launchHome(page: "default_home")
        XCTAssertTrue(labeled(app, "新人指南").firstMatch.waitForExistence(timeout: 20), "前提：第一张卡（金刚区）画出来了")
        var found = labeled(app, "订单没显示怎么办").firstMatch.waitForExistence(timeout: 5)
        for _ in 0..<3 where !found {
            app.swipeUp()
            found = labeled(app, "订单没显示怎么办").firstMatch.exists
        }
        XCTAssertTrue(found, "第二张卡（双入口：新人怎么拿返利 / 订单没显示怎么办）没有画出来")
    }

    // MARK: - P1 + P2

    /// Main 组合页：从上滚到底，每张区段卡的标识都出现；页底口径说明是合并后的全部文案、每句正好一次；全程没有键名。
    func testMainHomeDrawsEverySectionAndDisclaimerText() {
        let app = launchHome(page: "main")
        XCTAssertTrue(labeled(app, "确认收货后").firstMatch.waitForExistence(timeout: 20), "前提：首页公告画出来了")
        let markers: [(String, () -> Bool)] = [
            ("公告", { self.labeled(app, "确认收货后").firstMatch.exists }),
            ("轮播", { self.labeled(app, "测试活动").firstMatch.exists }),
            ("金刚区", { self.labeled(app, "新人指南").firstMatch.exists }),
            ("双入口", { self.labeled(app, "订单没显示怎么办").firstMatch.exists }),
            ("今日精选", { app.staticTexts["今日精选"].exists }),
            ("超市百货", { app.staticTexts["超市百货"].exists }),
        ]
        var seen: Set<String> = []
        var leaks: Set<String> = []
        var reachedFooter = false
        for _ in 0..<30 {
            for (name, present) in markers where present() {
                seen.insert(name)
            }
            for key in Self.rawKeys {
                for element in labeled(app, key).allElementsBoundByIndex {
                    leaks.insert(element.label)
                }
            }
            if labeled(app, "不含运费及会员价等优惠").firstMatch.exists {
                reachedFooter = true
                break
            }
            app.swipeUp()
        }
        let missing = markers.map(\.0).filter { !seen.contains($0) }
        XCTAssertTrue(missing.isEmpty, "这些区段卡没有画出来：\(missing)")
        XCTAssertTrue(leaks.isEmpty, "屏幕上出现了文案键名：\(leaks.sorted())")
        guard reachedFooter else {
            return XCTFail("页底口径说明没有显示文案（只有键名或整块没有）")
        }
        // 再滚一屏，整块页底说明都在屏幕上，再收齐
        app.swipeUp()
        let footer = footerText(app)
        reportMissingFooter(app, footer)
        XCTAssertEqual(occurrences(footer, Self.generalPrice), 1, "混排时价格句应为 price_basis.general 一句、只出现一次：\(footer)")
        XCTAssertEqual(occurrences(footer, "券后价按单件计算"), 0, "混排时不得列出券后价那一句（BR-PRICE-03 细则）：\(footer)")
        XCTAssertEqual(occurrences(footer, "不含运费及会员价等优惠"), 1, "价格句（不论哪一句）只能出现一次：\(footer)")
        XCTAssertEqual(occurrences(footer, Self.rebateCompare), 1, "样例商品下发的 rebate_compare（以结算为准）要正好一次：\(footer)")
        XCTAssertEqual(
            occurrences(footer, Self.rebateEstimate), 1, "有普通返利金额的商品时要带 rebate_estimate（结算说明）且只一次：\(footer)"
        )
        for key in Self.rawKeys {
            XCTAssertEqual(occurrences(footer, key), 0, "页底说明里出现键名 \(key)：\(footer)")
        }
    }

    /// 页底说明的全部文字：屏幕上最后一件商品以下、含任一说明句或键名的元素，去掉被另一个含它文字的元素包住的子元素
    /// （合并读屏的说明块与它的文字子元素会在无障碍树里重复出现；位置按 4pt 容差比较），按位置从上到下拼起来。说明画成一个还是多个元素都收得齐。
    private func footerText(_ app: XCUIApplication) -> String {
        let tokens = [Self.generalPrice, "券后价按单件计算", Self.rebateEstimate, Self.rebateCompare] + Self.rawKeys
        // 商品卡上的「预估返」标签（整句相等；页底的「预估返利以平台结算为准…」不算卡片）
        let cards = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "预估返"))
            .allElementsBoundByIndex.map(\.frame)
        let floor = cards.map(\.maxY).max() ?? 0
        var found: [(frame: CGRect, label: String)] = []
        for token in tokens {
            for element in labeled(app, token).allElementsBoundByIndex where element.frame.minY >= floor - 1 {
                let item = (frame: element.frame, label: element.label)
                if !found.contains(where: { $0.frame == item.frame && $0.label == item.label }) {
                    found.append(item)
                }
            }
        }
        let outer = found.filter { item in
            !found.contains { other in
                other.frame.insetBy(dx: -4, dy: -4).contains(item.frame) && other.label.contains(item.label) &&
                    (other.label.count > item.label.count ||
                        other.frame.width * other.frame.height > item.frame.width * item.frame.height)
            }
        }
        return outer.sorted { $0.frame.minY < $1.frame.minY }.map(\.label).joined(separator: "｜")
    }

    /// 页底说明一句也没收到时，把屏上元素位置与文字报出来（便于看是收集口径还是产品问题）。
    private func reportMissingFooter(_ app: XCUIApplication, _ footer: String) {
        guard footer.isEmpty else { return }
        let all = app.descendants(matching: .any).allElementsBoundByIndex.filter { !$0.label.isEmpty }
            .map { "\($0.frame.minY.rounded())~\($0.frame.maxY.rounded()) \($0.label.prefix(40))" }
        XCTFail("页底说明没收到；屏上元素：\(all.suffix(40))")
    }

    private func occurrences(_ text: String, _ part: String) -> Int {
        text.components(separatedBy: part).count - 1
    }
}
