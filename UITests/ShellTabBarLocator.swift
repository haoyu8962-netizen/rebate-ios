import XCTest

/// 外壳标签栏的统一定位（FU-IOS-NATIVE-TABBAR，D10-826 ⑤ / D10-831 ②，#24）：底栏改成系统 TabView 标签栏后，SwiftUI 挂不上
/// `shell.tabBar` 标识，UI 测试一律用系统标签栏元素定位（`app.tabBars`）。只换定位，各用例的判据不变。
/// iOS 26 起标签栏随滚动收起（`.tabBarMinimizeBehavior(.onScrollDown)`）：收起后只剩左下角一颗选中项的小胶囊，其余 Tab 不可点。
/// 点 Tab、取可见区下沿之前先展开（D10-831 ⑤：在测试 helper 里处理，产品不加测试开关）。
/// v2：XCUI 里 `bar.frame` 是整条容器（收起与否都一样），胶囊不在容器中心——展开改为点选中项的按钮（就是那颗胶囊），
/// 点不开时再点容器左侧；只有允许滚动时才用反向拖动兜底。
@MainActor
enum ShellTabBar {
    /// 外壳的 Tab 数（首页 / AI 助手 / 订单 / 我的）。
    static let tabCount = 4

    /// 外壳的系统标签栏（App 里只有外壳一个 TabView）。
    static func bar(_ app: XCUIApplication) -> XCUIElement {
        app.tabBars.firstMatch
    }

    /// 标签栏里某个 Tab 的按钮（按 ShellDraftTexts 的 Tab 文案）。
    static func button(_ app: XCUIApplication, _ title: String) -> XCUIElement {
        bar(app).buttons[title].firstMatch
    }

    /// 标签栏收起了：标签栏在，但 4 个 Tab 按钮不是都能点。
    static func isMinimized(_ app: XCUIApplication) -> Bool {
        let bar = bar(app)
        guard bar.exists else { return false }
        let buttons = bar.buttons.allElementsBoundByIndex
        return buttons.count < tabCount || buttons.contains { !$0.isHittable }
    }

    /// 点某个 Tab：等标签栏出现，收起时先展开，再点目标按钮。
    static func tap(
        _ app: XCUIApplication, _ title: String, file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertTrue(bar(app).waitForExistence(timeout: 30), "没有系统标签栏", file: file, line: line)
        let target = button(app, title)
        if !(target.exists && target.isHittable) {
            expand(app, allowScroll: true)
        }
        XCTAssertTrue(
            UIWait.until("Tab「\(title)」可点", ceiling: 10, file: file, line: line) {
                target.exists && target.isHittable
            }, file: file, line: line
        )
        target.tap()
    }

    /// 收起时展开标签栏，并等它停稳（4 个按钮都可点、位置连续两次相同）。返回最后是否展开。
    /// `allowScroll` 为 false 时只点胶囊、不拖动页面（截图对齐时不能改滚动位置）。
    @discardableResult
    static func expand(_ app: XCUIApplication, allowScroll: Bool = false) -> Bool {
        let bar = bar(app)
        guard bar.exists, isMinimized(app) else { return settle(app) }
        let selected = bar.buttons.matching(NSPredicate(format: "isSelected == true")).firstMatch
        if selected.exists, selected.isHittable {
            selected.tap()
        } else {
            bar.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.5)).tap()
        }
        if UIWait.untilQuietly(seconds: 3, { !isMinimized(app) }) {
            return settle(app)
        }
        bar.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.5)).tap()
        if UIWait.untilQuietly(seconds: 2, { !isMinimized(app) }) || !allowScroll {
            return settle(app)
        }
        let window = app.windows.firstMatch
        let start = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45))
        start.press(forDuration: 0.05, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6)))
        _ = UIWait.untilQuietly(seconds: 2) { !isMinimized(app) }
        return settle(app)
    }

    /// 页面可见区的下沿：标签栏容器的上沿（玻璃标签栏下的内容看得见但点不到）；没有标签栏时为 nil。
    static func visibleBottom(_ app: XCUIApplication) -> CGFloat? {
        let bar = bar(app)
        guard bar.exists, !bar.frame.isEmpty else { return nil }
        return bar.frame.minY
    }

    /// 读屏遍历时要跳过的外壳标签栏（原先按 `shell.tabBar` 标识判，现在按元素类型判；判据同义）。
    static func isShellTabBar(_ element: XCUIElementSnapshot) -> Bool {
        element.elementType == .tabBar
    }

    /// 展开动画停稳：按钮位置连续两次相同（最多约 2 秒）。
    private static func settle(_ app: XCUIApplication) -> Bool {
        var last: [CGRect] = []
        _ = UIWait.untilQuietly(seconds: 2) {
            let now = bar(app).buttons.allElementsBoundByIndex.map(\.frame)
            defer { last = now }
            return now == last
        }
        return !isMinimized(app)
    }
}

extension UIWait {
    /// 条件等待但不记失败（helper 内部的尝试性等待用）：返回条件在上限内是否成立。
    static func untilQuietly(seconds: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition() {
            guard Date() < deadline else { return false }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        return true
    }
}
