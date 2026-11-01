@testable import Couli
import CouliNetwork
import DesignSystem
import Foundation
import SwiftUI
import UIKit
import Wallet
import WalletCore
import XCTest

/// 大字号 / 窄屏 / 大屏（brief §2.7、§4 第 6、7 条）。同意半屏是页内浮层（`couliSheet`，不是系统 `.sheet`），`.dynamicTypeSize` 能传进去、没有
/// 374/390 缩放；若实现改成系统 `.sheet`，这里的字号断言会红（d 组教训），要改走窗口 traitOverrides 并换算令牌。
@MainActor
final class PayoutVisualAdaptTests: PayoutVisualTestCase {
    private let ax = DynamicTypeSize.accessibility3

    private func assertEnlarged(_ id: String, _ message: String, file: StaticString = #filePath,
                                line: UInt = #line) throws {
        let item = try record(id, file: file, line: line)
        XCTAssertGreaterThan(item.fontSize, item.baseFontSize * 1.3, "\(message)：字号没真放大（\(item.fontSize)）",
                             file: file, line: line)
    }

    private func assertInWindow(_ id: String, width: CGFloat, _ message: String, file: StaticString = #filePath,
                                line: UInt = #line) throws {
        let box = try rect(id, file: file, line: line)
        XCTAssertGreaterThanOrEqual(box.minX, 15.5, "\(message)：左缘 \(box)", file: file, line: line)
        XCTAssertLessThanOrEqual(box.maxX, width - 15.5, "\(message)：右缘 \(box)", file: file, line: line)
    }

    /// 已绑定（含压力长邮箱）× AX3 × 390 / 320：账号不截断、字号真放大、明细不截断、按钮在卡内。
    func testBoundLargeText() async throws {
        for (width, name) in [(390.0, "boundAlipay"), (320.0, "boundAlipay"), (390.0, "boundStress"),
                              (320.0, "boundStress")] {
            try await openPayout(name, canvas: .init(width: width, height: 2400, size: ax))
            let tag = "\(name) w\(Int(width))"
            try assertEnlarged("payout.bound.account", tag)
            try assertNotTruncated("payout.bound.account", tag)
            try assertInWindow("payout.bound.account", width: width, tag)
            try assertNotTruncated("payout.bound.payee.value", tag)
            try assertNotTruncated("payout.bound.remaining.value", tag)
            try assertInWindow("payout.change", width: width, tag)
            try assertNotTruncated("payout.note.text", tag)
        }
    }

    /// 表单 × AX3：单选说明、说明句、INFO 不截断；单选命中不重叠；边距 16（c r1 S1-2 撑页同类）。
    func testFormLargeText() async throws {
        for width in [390.0, 320.0] {
            try await openPayout(canvas: .init(width: width, height: 2400, size: ax))
            let tag = "w\(Int(width))"
            try assertSideInsets("payout.methodCard", width: width, tag)
            try assertSideInsets("payout.formCard", width: width, tag)
            try assertNotTruncated("payout.intro", tag)
            try assertNotTruncated("payout.method.bank.desc", tag)
            try assertNotTruncated("payout.saveNote.text", tag)
            try assertEnlarged("payout.method.bank.title", tag)
            try assertDisjoint(rect("payout.method.alipay.hit"), rect("payout.method.bank.hit"), tag)
            try assertInWindow("payout.save", width: width, tag)
        }
    }

    /// 实名 × AX3：头部方块不压字、输入卡边距 16、INFO 不截断。
    func testRealNameLargeText() async throws {
        for width in [390.0, 320.0] {
            try await openRealName(canvas: .init(width: width, height: 2400, size: ax))
            let tag = "w\(Int(width))"
            try assertSideInsets("realname.formCard", width: width, tag)
            try assertNotTruncated("realname.desc", tag)
            try assertNotTruncated("realname.note.age.text", tag)
            try assertDisjoint(rect("realname.badge"), rect("realname.title"), tag)
            try assertEnlarged("realname.title", tag)
        }
    }

    /// 同意半屏 × AX3：页内真放大、标题完整、整块可滚动、按钮可达。
    func testConsentLargeText() async throws {
        let (host, _) = try await openRealName(canvas: .init(height: 844, size: ax))
        _ = try await openConsent(host)
        try assertEnlarged("consent.title", "标题")
        try assertNotTruncated("consent.title", "标题")
        try assertEnlarged("consent.check.text", "勾选句")
        try assertHit("consent.check.hit", covers: "consent.check.mark", "勾选命中")
        let okay = try rect("consent.ok")
        let cancel = try rect("consent.cancel")
        XCTAssertLessThanOrEqual(cancel.maxY, 844, "按钮在屏内")
        XCTAssertLessThanOrEqual(okay.maxY, cancel.minY, "主在上")
    }

    /// 劳务 × AX3：全文区仍可滚动、勾选句不截断、签署按钮在屏内。
    func testLaborLargeText() async throws {
        for width in [390.0, 320.0] {
            try await openLabor(canvas: .init(width: width, height: 2400, size: ax))
            let tag = "w\(Int(width))"
            try assertEnlarged("labor.intro", tag)
            try assertNotTruncated("labor.intro", tag)
            try assertNotTruncated("labor.check.text", tag)
            try assertInWindow("labor.sign", width: width, tag)
            try XCTAssertGreaterThan(rect("labor.textBody").height, rect("labor.textArea").height, "\(tag)：靠滚动")
            try assertDisjoint(rect("labor.check.hit"), rect("labor.sign"), tag)
        }
    }

    /// 840：内容限宽 600 居中，三页同口径；底栏铺满（无底色时按按钮宽 568 判）。
    func testWideScreen() async throws {
        let canvas = WithdrawVisualHost.Canvas(width: 840, height: 1000)
        try await openPayout(canvas: canvas)
        try assertNear(rect("payout.formCard").width, 568, 1, "收款账号卡 568")
        try assertNear(rect("payout.formCard").midX, 420, 1, "居中")
        try assertNear(rect("payout.save").width, 568, 1, "保存 568")
        try assertNear(rect("payout.intro").minX, 140, 1, "说明句缩进 4（列 120 + 边距 16 + 缩进 4）")
        try await openRealName(canvas: canvas)
        try assertNear(rect("realname.formCard").width, 568, 1, "实名卡 568")
        try assertNear(rect("realname.submit").midX, 420, 1, "按钮居中")
        try await openLabor(canvas: canvas)
        try assertNear(rect("labor.card").width, 568, 1, "劳务卡 568")
        try assertNear(rect("labor.sign").midX, 420, 1, "按钮居中")
    }
}
