@testable import DesignSystem
import SnapshotTesting
import SwiftUI
import XCTest

/// 弹窗与半屏在小屏大字号下的快照（基准图在 __Snapshots__/ModalSnapshotTests/，入库）。
@MainActor
final class ModalSnapshotTests: XCTestCase {
    /// 320×568 + 辅助字号第 2 档 + 长正文：弹窗只有正文滚动，标题与按钮行固定可见。
    func testDialogLongTextSmallScreen() {
        let long = String(repeating: "这是一段很长的弹窗正文，用来验证小屏大字号下只有正文滚动。", count: 12)
        let view = Color.clear
            .couliDialog(isPresented: true) {
                CouliDialog(
                    title: "该商品当前暂无返利，继续购买？",
                    message: long,
                    primary: CouliDialogAction("继续购买") {},
                    secondary: CouliDialogAction("再想想") {}
                )
            }
            .environment(\.dynamicTypeSize, .accessibility2)
        assertSnapshot(
            of: view,
            as: .image(precision: 0.995, perceptualPrecision: 0.98, layout: .fixed(width: 320, height: 568))
        )
    }

    /// 同上，半屏：头部与操作区固定，正文滚动。
    func testSheetLongTextSmallScreen() {
        let long = String(repeating: "半屏正文很长，放不下时只有中段滚动，按钮一直可见。", count: 14)
        let view = Color.clear
            .couliSheet(isPresented: true, dismissOnScrim: nil) {
                CouliSheet(title: "授权说明", closeLabel: "关闭", onClose: {}, content: {
                    Text(verbatim: long).couliFont(.footnote)
                }, actions: {
                    CouliButton("知道了", fillsWidth: true) {}
                })
            }
            .environment(\.dynamicTypeSize, .accessibility2)
        assertSnapshot(
            of: view,
            as: .image(precision: 0.995, perceptualPrecision: 0.98, layout: .fixed(width: 320, height: 568))
        )
    }
}
