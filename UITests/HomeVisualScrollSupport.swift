import UIKit
import XCTest

@MainActor
extension HomeVisualUITestCase {
    /// isHittable 只保证露出的部分可点；四边点击必须让整个命中框进入列表。
    func revealFullyVisible(_ id: String) throws -> XCUIElement {
        let target = try reveal(id)
        let list = element("home.list")
        for _ in 0..<24 {
            let viewport = list.frame.insetBy(dx: 1, dy: 2)
            let frame = target.frame
            if target.isHittable, viewport.contains(frame) {
                return target
            }
            let delta = frame.minY < viewport.minY ? frame.minY - viewport.minY : frame.maxY - viewport.maxY
            scrollList(by: delta + (delta > 0 ? 24 : -24))
        }
        XCTFail("整个命中框仍未进入列表：\(id)，target=\(target.frame)，list=\(list.frame)")
        return target
    }

    /// 截整视口之前精确对齐目标。页脚按底边对齐，避免内容到底后无法再把它推到顶边。
    func alignForSnapshot(_ id: String, bottom: Bool = false) throws {
        let target = try reveal(id)
        let list = element("home.list")
        var dragSlop: CGFloat = 16
        for _ in 0..<24 {
            let expected = bottom ? list.frame.maxY - 16 : list.frame.minY + 12
            let actual = bottom ? target.frame.maxY : target.frame.minY
            if abs(actual - expected) <= 0.5 {
                XCTAssertTrue(target.isHittable)
                XCTAssertEqual(actual, expected, accuracy: 0.5, "截图锚点：\(id)")
                return
            }
            // 无返利信息流较短，到底后首卡可能无法再顶齐；此时改用精确的页脚底边锚点。
            let footer = element("home.footer")
            if !bottom, actual > expected, footer.exists, footer.isHittable,
               list.frame.contains(target.frame), abs(footer.frame.maxY - (list.frame.maxY - 16)) <= 0.5 {
                XCTAssertTrue(target.isHittable)
                XCTAssertEqual(footer.frame.maxY, list.frame.maxY - 16, accuracy: 0.5, "截图已到内容底部")
                return
            }
            let delta = actual - expected
            let requested = scrollList(by: delta + (delta > 0 ? dragSlop : -dragSlop))
            let moved = actual - (bottom ? target.frame.maxY : target.frame.minY)
            // UIKit 拖动开始有手势识别距离；按本次实际位移校正，末尾不足阈值也能精确对齐。
            dragSlop = abs(moved) > 0.5 ? min(32, max(0, abs(requested) - abs(moved))) : min(32, dragSlop + 8)
        }
        XCTFail("截图锚点未对齐：\(id)，target=\(target.frame)，list=\(list.frame)")
    }

    @discardableResult
    private func scrollList(by delta: CGFloat) -> CGFloat {
        let list = element("home.list")
        let distance = min(max(delta, -list.frame.height * 0.35), list.frame.height * 0.35)
        // 在纵向列表右侧留白拖动，避开商品的横向滚动；结束时按住，消除惯性。
        let start = list.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: 0.5))
        start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: -distance)),
                    withVelocity: .slow, thenHoldForDuration: 0.2)
        return distance
    }
}
