@testable import Couli
import DesignSystem
import Foundation
import ObjectiveC
import SwiftUI
import UIKit
import Wallet
import WalletCore
import XCTest

/// APP-09v-b 修复轮 r1 的测试补充（测试 v3；`impl-b-ios-r1-handback.md` §4）：
/// - r1 ①（S2-1）：用户惯性滚动 / 手指按住期间内容变化（这里是翻页结果到达），不做锚点恢复、不把列表拉回；
/// - r1 ④（三端口径）：已知通道「打款中」展开卡有客服行，微信 / 未知通道 / 已到账没有——元素存在性断言，不靠快照。
@MainActor
final class RecordsVisualR1Tests: RecordsVisualTestCase {
    // MARK: - r1 ① 惯性中翻页到达不拉回

    /// 进程内驱动真实的记录列表 UIScrollView：把它的 `isDecelerating` 读成 true（动态子类，测试结束还原），再按衰减速度逐帧推偏移，模拟
    /// 松手后的惯性；途中滚到页脚触发真实翻页（假服务按游标回第 2 页）。断言：
    /// - 翻页恰好一次、结果在「惯性」中到达；
    /// - 每一帧读回的偏移都等于测试上一帧设的偏移（没有任何一帧被锚点恢复改写 = 没被拉回，也没有硬停）；
    /// - 到达之后继续前进 300 以上（停止位置在到达点之后，不回跳）。
    /// 对照：同一流程不设 `isDecelerating`（程序滚动）时，翻页追加仍按锚点保持，见 `RecordsVisualPagingTests.testLoadMoreKeepsAnchor`。
    func testMomentumPageArrivalNotPulledBack() async throws {
        let page = try freshRecords()
        try page.server.setPage(items: RecordsVisualData.sameMonth(20), next: "p2")
        try page.server.setPage("p2", items: RecordsVisualData.sameMonth(20, start: 21), next: nil)
        try await page.show()
        _ = await page.stable { $0.controller?.state.phase == .content && $0.scroller != nil }
        let scroller = try XCTUnwrap(page.scroller, "记录页没有可滚动的列表")
        let oldMax = page.maxOffset
        XCTAssertGreaterThan(oldMax, 600, "前提：第 1 页内容远超一屏")
        page.scroll(to: oldMax - 500)
        _ = await page.stable(seconds: 3) { _ in true }
        XCTAssertEqual(RecordsVisualServer.moreRequests, 0, "前提：离底 500 时还没翻页")

        let restore = try Self.forceDecelerating(scroller)
        defer { restore() }
        XCTAssertTrue(scroller.isDecelerating, "前提：滚动视图读作惯性减速中")
        var velocity: CGFloat = 40
        var last = page.offset
        var arrivedAt: CGFloat?
        var rewritten: [String] = []
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(5))
        while clock.now < deadline {
            page.scroll(to: last + velocity)
            last = page.offset
            try? await Task.sleep(for: .milliseconds(16))
            let now = page.offset
            if abs(now - last) > 0.5 {
                rewritten.append("\(Int(last))→\(Int(now))")
                last = now
            }
            if arrivedAt == nil, page.controller?.state.items.count == 40 {
                arrivedAt = last
            }
            velocity = max(velocity * 0.97, 8)
            if let arrivedAt, last > arrivedAt + 300 {
                break
            }
        }
        // 到达后再静观 1 秒（锚点恢复窗口是 1 秒 / 8 次）：期间偏移不被改写
        let settled = last
        await quietWindow(1.0)
        let after = page.offset
        restore()

        let arrival = try XCTUnwrap(arrivedAt, "惯性中没有翻页或翻页结果没到达（第 2 页没追加）")
        XCTAssertEqual(RecordsVisualServer.moreRequests, 1, "翻页恰好一次")
        XCTAssertEqual(rewritten, [], "惯性中翻页结果到达后，列表偏移被改写（锚点恢复把列表拉回 / 硬停，r1 ①）")
        XCTAssertGreaterThan(settled, arrival + 300, "到达后惯性继续前进，停止位置不回跳到到达点")
        assertNear(after, settled, 0.5, "惯性结束后的 1 秒内也不被拉回")
    }

    /// 把这个滚动视图的 `isDecelerating` 读成 true（换成一个动态子类，只覆写这一个读取）；返回还原闭包（换回原类）。
    private static func forceDecelerating(_ view: UIScrollView) throws -> () -> Void {
        let original: AnyClass = try XCTUnwrap(object_getClass(view))
        let name = "CouliTestDecelerating_" + NSStringFromClass(original)
            .replacingOccurrences(of: ".", with: "_")
        let subclass: AnyClass
        if let existing = NSClassFromString(name) {
            subclass = existing
        } else {
            let made: AnyClass = try XCTUnwrap(objc_allocateClassPair(original, name, 0), "建不出动态子类")
            let selector = #selector(getter: UIScrollView.isDecelerating)
            let method = try XCTUnwrap(class_getInstanceMethod(UIScrollView.self, selector))
            let block: @convention(block) (AnyObject) -> Bool = { _ in true }
            class_addMethod(made, selector, imp_implementationWithBlock(block), method_getTypeEncoding(method))
            objc_registerClassPair(made)
            subclass = made
        }
        object_setClass(view, subclass)
        return { [weak view] in
            if let view {
                object_setClass(view, original)
            }
        }
    }

    // MARK: - r1 ④ 客服行显示条件

    /// 已知通道打款中（PAYING，支付宝；含自动审核等待打款 AUTO_WAITING）展开卡有客服行（说明 +【联系客服】）；已到账、微信零钱、
    /// 打款中但通道不认识（把 PAYING 单的通道换成 wechat）都没有。只看测量 / 元素存在性。
    func testServiceRowForKnownChannelPayingOnly() async throws {
        for (name, id) in [("paying", "PAYING"), ("auto_waiting", "AUTO_WAITING")] {
            try await openRecords(name, expand: [id])
            let prefix = "records.detail.\(id)."
            XCTAssertNotNil(records?.probes[prefix + "service"], "\(id)（打款中、支付宝）有客服行")
            XCTAssertEqual(try text(prefix + "service.link.label"), texts.text("withdraw_detail.cs"), "\(id)【联系客服】")
        }
        for (name, id) in [("paid", "PAID"), ("wechat", "WECHAT")] {
            try await openRecords(name, expand: [id])
            XCTAssertNotNil(records?.probes["records.detail.\(id).header.amount"], "\(id) 展开卡照常")
            XCTAssertNil(records?.probes["records.detail.\(id).service"], "\(id) 没有客服行")
        }
        // 打款中 + 不认识的通道
        let page = try freshRecords()
        var item = try XCTUnwrap((RecordsVisualData.page("paying")["items"] as? [[String: Any]])?.first)
        var detail = try RecordsVisualData.detail("paying")
        item["payout_channel"] = "wechat"
        detail["payout_channel"] = "wechat"
        item["payout_channel_name"] = "微信零钱"
        detail["payout_channel_name"] = "微信零钱"
        try page.server.setPage(items: [item], next: nil)
        try page.server.setDetails(["PAYING": detail])
        try await page.show()
        _ = await page.stable { $0.controller?.state.phase == .content }
        try page.toggle("PAYING")
        _ = await page.stable { host in
            host.controller?.state.details["PAYING"] != nil && host.probes["records.detail.PAYING"] != nil
        }
        XCTAssertNotNil(records?.probes["records.detail.PAYING.header.amount"], "通道不认识的打款中展开卡照常")
        XCTAssertNil(records?.probes["records.detail.PAYING.service"], "通道不认识的打款中没有客服行")
    }
}
