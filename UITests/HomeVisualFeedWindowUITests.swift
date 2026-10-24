import XCTest

/// r2 S1-A（D10-270）读屏与点击部分：真实 App（Debug 场景，会员首页，信息流 80 件 = 40 行，超过 10 行窗口化门槛）。
/// 用手势滚到信息流末尾，第一行必须已换成占位（不在读屏树里）；再用手势滚回顶部，这一行恢复成实际商品卡：读屏树里在、
/// 是按钮、读名是这件商品（含「第 0 件」）、可点；点它打开商品详情。位置不跳与卡数上限由 HomeTests/HomeVisualFeedWindowTests 测。
/// 单元测试进程（包测试与 App 宿主测试）拿不到 SwiftUI 读屏树（v5 实测两处都为空），所以读屏与点击只能在这里用 XCUITest 核对。
@MainActor
final class HomeVisualFeedWindowUITests: HomeVisualUITestCase {
    private static let count = 80

    func testRowsRestoredFromPlaceholdersAreReadableAndOpenTheirProduct() throws {
        // 借 no_rebate_feed 场景（App 按普通首页装配、停稳即就绪；launch 不按 4 件信息流核对区段件数），信息流再换成 80 件
        try launch(.standard(scene: "no_rebate_feed", level: "member"),
                   overrides: HomeVisualRequestOverrides(longFeed: Self.count))
        let list = element("home.list")
        let first = element("home.product.feed.0")
        XCTAssertTrue(first.waitForExistence(timeout: 10))

        let last = element("home.product.feed.\(Self.count - 1)")
        for _ in 0..<120 where !(last.exists && last.isHittable) {
            list.swipeUp(velocity: .fast)
        }
        XCTAssertTrue(last.exists && last.isHittable, "滚不到信息流末尾")
        XCTAssertFalse(first.exists, "滚到末尾后第一行必须已换成占位（窗口化生效），否则这个用例没有走到恢复路径")
        keepTree("window-bottom")

        for _ in 0..<120 where !(first.exists && first.isHittable) {
            list.swipeDown(velocity: .fast)
        }
        XCTAssertTrue(first.exists, "滚回顶部后第一行没有恢复成实际商品卡")
        XCTAssertTrue(first.isHittable, "恢复后的第一行不可点")
        XCTAssertEqual(first.elementType, .button, "恢复后的第一行读屏不是按钮")
        XCTAssertTrue(first.label.contains(HomeVisualRequestOverrides.longFeedTitle(0)), "读名不是这件商品：\(first.label)")
        XCTAssertFalse(first.label.contains(HomeVisualRequestOverrides.longFeedTitle(Self.count - 1)))
        XCTAssertTrue(list.frame.intersects(first.frame), "恢复后的第一行不在列表可视区")
        keepTree("window-restored")

        tapImage(of: first, in: list)
        // 商品详情压栈后首页卡片被盖住、不可点；详情页各阶段（加载 / 内容 / 链接过期 / 下架 / 失败）任一标识出现即打开
        // （测试商品的 item_ref 是假签名，详情接口的应答各次可能落在不同阶段）
        let opened = ["product.loading", "product.header", "product.refExpired", "product.offShelf", "product.error"]
            .map(element)
        UIWait.until("点恢复后的商品卡打开商品详情", ceiling: 15) {
            opened.contains { $0.exists } || !first.isHittable
        }
        XCTAssertTrue(opened.contains { $0.waitForExistence(timeout: 5) }, "商品详情页没有出现")
    }

    /// 快速手势带惯性，可能停在卡片只露出一截、或越过它回到页顶：慢速挪到卡片上部（商品图）在列表可视区里，
    /// 停稳后点商品图（点卡片中心可能落在被裁掉的部分或口径 i 按钮上）。
    private func tapImage(of first: XCUIElement, in list: XCUIElement) {
        let imageVisible = {
            first.frame.minY >= list.frame.minY && first.frame.minY + 100 <= list.frame.maxY
        }
        let settled = {
            UIWait.until("列表停稳", ceiling: 10) {
                let before = first.frame
                RunLoop.current.run(until: Date().addingTimeInterval(0.4))
                return first.frame == before
            }
        }
        for _ in 0..<12 {
            settled()
            if imageVisible() {
                break
            }
            if first.frame.minY < list.frame.minY {
                list.swipeDown(velocity: .slow)
            } else {
                list.swipeUp(velocity: .slow)
            }
        }
        XCTAssertTrue(imageVisible(), "第一行的商品图没能露出：\(first.frame) / \(list.frame)")
        first.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 50 / max(first.frame.height, 1))).tap()
    }
}
