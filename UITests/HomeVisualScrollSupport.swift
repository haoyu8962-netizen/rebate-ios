import UIKit
import XCTest

@MainActor
extension HomeVisualUITestCase {
    /// isHittable 只保证露出的部分可点；四边点击必须让整个命中框进入列表。
    func revealFullyVisible(_ id: String) throws -> XCUIElement {
        let target = try reveal(id)
        for _ in 0..<24 {
            let viewport = visibleList().insetBy(dx: 1, dy: 2)
            let frame = target.frame
            if target.isHittable, viewport.contains(frame) {
                return target
            }
            let delta = frame.minY < viewport.minY ? frame.minY - viewport.minY : frame.maxY - viewport.maxY
            scrollList(by: delta + (delta > 0 ? 24 : -24))
        }
        XCTFail("整个命中框仍未进入列表：\(id)，target=\(target.frame)，list=\(visibleList())")
        return target
    }

    /// 截整视口之前精确对齐目标。页脚按底边对齐，避免内容到底后无法再把它推到顶边。
    ///
    /// FU-IOS-0732（F-IOS-40）：合成拖动并不总按请求的距离停下——实测请求 16pt 的短拖常带惯性滑出 120–140pt，偶尔一次整屏级
    /// 的拖动也会甩出 1000–1800pt（`home.product.grid.0` 等上方元素同步移动，是滚动偏移变了，不是布局变了）。旧循环只有 24 次、
    /// 每次最多 0.35 屏，320 宽 AX3 下视口只剩约 463pt、卡高 580pt，被甩远一次就追不回来。现在：① 每次拖完等位置稳定再读；
    /// ② 只用不短于 `minimumDrag` 的拖动，余量不足时先反向退开再一大步回来；③ 甩出（实际位移明显大于请求）不当作手势识别距离
    /// 来学习；④ 单次可拖到约 0.6 屏，追回被甩远的距离；⑤ 对齐判据（±0.5pt、整卡顶边 / 页脚底边、可命中）不变。
    func alignForSnapshot(_ id: String, bottom: Bool = false) throws {
        let target = try reveal(id)
        // #24 test-change（FU-IOS-NATIVE-TABBAR v2，D10-826 ⑤）：系统标签栏是悬浮玻璃，首页列表铺到窗口底、iOS 26 还会随滚动收起。
        // 对齐前先展开标签栏（只点胶囊、不拖页面），列表的可见区下沿取标签栏容器上沿（原来列表就止于自绘底栏上沿，同义）；
        // 对齐到位后再确认一次标签栏是展开的，截图里的标签栏状态固定。判据（±0.5pt、整卡顶边 / 页脚底边、可命中）不变。
        ShellTabBar.expand(app)
        let list = visibleList()
        // UIKit 拖动开始有手势识别距离（本机实测约 10pt）；按「请求 − 实际」学习，只采信没被甩出的拖动。
        var dragSlop: CGFloat = 10
        var history: [String] = []
        var expandTries = 0
        for _ in 0..<40 {
            let frame = settledFrame(of: target)
            let expected = bottom ? list.maxY - 16 : list.minY + 12
            let actual = bottom ? frame.maxY : frame.minY
            if abs(actual - expected) <= 0.5 {
                if expandBeforeShot(id, tries: &expandTries) {
                    continue
                }
                XCTAssertTrue(target.isHittable)
                XCTAssertEqual(actual, expected, accuracy: 0.5, "截图锚点：\(id)")
                return
            }
            // 无返利信息流较短，到底后首卡可能无法再顶齐；此时改用精确的页脚底边锚点。
            let footer = element("home.footer")
            if !bottom, actual > expected, footer.exists, footer.isHittable,
               list.contains(frame), abs(footer.frame.maxY - (list.maxY - 16)) <= 0.5 {
                if expandBeforeShot(id, tries: &expandTries) {
                    continue
                }
                XCTAssertTrue(target.isHittable)
                XCTAssertEqual(footer.frame.maxY, list.maxY - 16, accuracy: 0.5, "截图已到内容底部")
                return
            }
            let delta = actual - expected
            if abs(delta) < Self.minimumDrag {
                // 余量太短：先反向退开一大步（退不动——已到内容边界——就顺向越过去），下一轮再用一次长拖动精确回到锚点。
                let away = delta > 0 ? -Self.minimumDrag * 2 : Self.minimumDrag * 2
                var moved = backOff(target, by: away, bottom: bottom)
                if abs(moved) < Self.minimumDrag / 2 {
                    moved = backOff(target, by: -away, bottom: bottom)
                }
                history.append("退开\(Int(moved))")
                continue
            }
            let requested = scrollList(by: delta + (delta > 0 ? dragSlop : -dragSlop))
            let after = settledFrame(of: target)
            let moved = actual - (bottom ? after.maxY : after.minY)
            history.append("\(Int(requested))→\(Int(moved))")
            // 同向且没有越过请求距离的拖动才用来校正手势识别距离；甩出或没动都不学习，保留上次的值。
            let shortfall = abs(requested) - abs(moved)
            if moved * requested > 0, shortfall >= 0, shortfall <= 32 {
                dragSlop = shortfall
            }
        }
        XCTFail("截图锚点未对齐：\(id)，target=\(target.frame)，list=\(list)，拖动（请求→实际）：\(history)")
    }

    /// 对齐到位、截图之前：标签栏收起了就展开（最多两次），返回 true 表示展开过、要重新核对齐；展不开则记失败。
    private func expandBeforeShot(_ id: String, tries: inout Int) -> Bool {
        if ShellTabBar.isMinimized(app), tries < 2 {
            tries += 1
            ShellTabBar.expand(app)
            return true
        }
        XCTAssertFalse(ShellTabBar.isMinimized(app), "截图前标签栏应展开：\(id)")
        return false
    }

    /// 首页列表的可见区：列表框，下沿截到标签栏容器上沿（玻璃下的内容看得见但点不到）。
    func visibleList() -> CGRect {
        let frame = element("home.list").frame
        guard let bottom = ShellTabBar.visibleBottom(app), bottom < frame.maxY,
              bottom > frame.minY else { return frame }
        return CGRect(x: frame.minX, y: frame.minY, width: frame.width, height: bottom - frame.minY)
    }

    /// 单次拖动下限：实测短于约 30pt 的合成拖动常带惯性滑出，留足余量。
    private static let minimumDrag: CGFloat = 60

    private func backOff(_ target: XCUIElement, by distance: CGFloat, bottom: Bool) -> CGFloat {
        let before = settledFrame(of: target)
        scrollList(by: distance)
        let after = settledFrame(of: target)
        return bottom ? before.maxY - after.maxY : before.minY - after.minY
    }

    /// 连续两次读到同一位置（±0.5pt）才算停稳；最多等约 10 次读取（每次读取本身要取一次无障碍快照）。
    private func settledFrame(of target: XCUIElement) -> CGRect {
        var last = target.frame
        for _ in 0..<10 {
            let next = target.frame
            if abs(next.minY - last.minY) <= 0.5, abs(next.maxY - last.maxY) <= 0.5 {
                return next
            }
            last = next
        }
        return last
    }

    @discardableResult
    private func scrollList(by delta: CGFloat) -> CGFloat {
        let list = element("home.list")
        let distance = min(max(delta, -list.frame.height * 0.6), list.frame.height * 0.6)
        // 在纵向列表右侧留白拖动，避开商品的横向滚动；结束时按住，消除惯性。起点放在拖动方向的另一端（上推从 0.8 处、下拉从 0.2 处），
        // 单次最多约 0.6 屏，手指始终留在列表内。
        let start = list.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: distance > 0 ? 0.8 : 0.2))
        start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: -distance)),
                    withVelocity: .slow, thenHoldForDuration: 0.2)
        return distance
    }
}
