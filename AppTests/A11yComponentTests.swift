import DesignSystem
import Foundation
import SwiftUI
import UIKit
import XCTest

/// FU-IOS-A11Y-02（组件层）：DS `CouliSheet` 根上接读屏「返回」手势，与关闭键走同一个出口（`onClose`）；一次擦除只关一次。
/// 页面层（搜索价格、订单平台 / 月份、钱包 / 提现问号）见各页用例。拦截设施自检也放这里（与业务页无关的最小场景）。
@MainActor
final class A11yComponentTests: XCTestCase {
    private final class Counter {
        var value = 0
    }

    func testCouliSheetEscapeGoesThroughOnClose() async throws {
        try A11yTree.enable(self)
        let closed = Counter()
        let view = Color.clear.couliSheet(isPresented: true, dismissOnScrim: nil) {
            CouliSheet(title: "半屏标题", closeLabel: "关闭", onClose: { closed.value += 1 },
                       content: { Text(verbatim: "正文").accessibilityIdentifier("a11y.sheet.body") },
                       actions: { EmptyView() })
        }
        let canvas = A11yCanvas(AnyView(view))
        defer { canvas.close() }
        let ready = await canvas.wait { $0.contains { $0.id == "a11y.sheet.body" } }
        XCTAssertTrue(ready, "半屏正文没进无障碍树")
        let body = try XCTUnwrap(A11yTree.node("a11y.sheet.body", in: canvas.root))
        XCTAssertTrue(A11yTree.escape(from: body.object), "CouliSheet 没有接住读屏「返回」手势")
        await canvas.pump(0.3)
        XCTAssertEqual(closed.value, 1, "擦除走 onClose，且只走一次")
    }

    /// 设施自检：拦截装得上、DS 礼貌播报拦得到、读屏开关替身生效、还原后不再记录。
    func testPostTapSelfCheck() {
        A11yAudit.installTap(self, voiceOver: true)
        UIAccessibility.post(notification: .announcement, argument: "测试包内直接播报")
        XCTAssertTrue(A11yPostTap.announcements.contains { $0.text == "测试包内直接播报" && !$0.queued })
        A11yPostTap.uninstall()
        XCTAssertFalse(UIAccessibility.isVoiceOverRunning, "还原后读屏开关回到真实值（模拟器没有读屏）")
    }
}
