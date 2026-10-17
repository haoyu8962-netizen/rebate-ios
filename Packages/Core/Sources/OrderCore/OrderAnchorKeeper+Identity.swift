import Foundation

public extension OrderAnchorKeeper {
    /// 对齐到点时身份暂时未知（FU-IOS-0712 整体重理）：不挪动、不取消，身份确认后再走 `step` 重新安排。
    func deferAlign() {
        aligning = false
    }
}
