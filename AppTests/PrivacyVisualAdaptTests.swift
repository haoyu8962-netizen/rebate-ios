@testable import Couli
import DesignSystem
import Foundation
import SwiftUI
import UIKit
import XCTest

/// 大字号 / 窄屏 / 大屏（brief §2 第 19 条、§4.6、§4.7；AX3 ≈ 200%）。
/// 确认框是 DS 页内覆盖层，`dynamicTypeSize` 进得去。客服半屏真实是系统 `.sheet`（环境进不去），这里用 `CsSheetHarness` 直接挂生产 `CsSheetView`，所以放大是真的。
@MainActor
final class PrivacyVisualAdaptTests: PrivacyVisualTestCase {
    private let ax3 = DynamicTypeSize.accessibility3
    private let widths: [CGFloat] = [390, 320]

    private func large(_ width: CGFloat, height: CGFloat = 3200) -> Canvas {
        Canvas(width: width, height: height, size: ax3)
    }

    private func assertLarge(_ id: String, _ message: String, file: StaticString = #filePath,
                             line: UInt = #line) throws {
        let item = try record(id, file: file, line: line)
        XCTAssertGreaterThan(item.fontSize, item.baseFontSize * 1.3, "\(message) 真放大", file: file, line: line)
    }

    func testPrivacyMember() async throws {
        for width in widths {
            try await openPrivacy(Scene(canvas: large(width)), waitFor: "privacy.withdraw.button")
            try assertLarge("privacy.row.collect.title", "\(width) 清单行")
            let docs = try rect("privacy.docs")
            try assertWhole("privacy.row.collect.title", inside: docs, "\(width) 清单行")
            try assertWhole("privacy.personalization.subtitle", inside: rect("privacy.personalization.card"),
                            "\(width) 个性化说明")
            try assertDisjoint(rect("privacy.personalization.subtitle"), rect("privacy.personalization.control"),
                               "\(width) 说明 / 开关")
            let screen = CGRect(x: 0, y: 0, width: width, height: 3200)
            try assertWhole("privacy.permissions.title", inside: screen, "\(width) 分节头")
            try assertWhole("privacy.permissions.hint", inside: screen, "\(width) 分节说明")
            let rows = try rect("privacy.permissions.card")
            for type in ["push", "photos"] {
                let id = "privacy.permission.\(type)"
                try assertWhole(id + ".name", inside: rows, "\(width) \(type) 名称")
                try assertWhole(id + ".purpose", inside: rows, "\(width) \(type) 用途")
                try assertWhole(id + ".status", inside: rows, "\(width) \(type) 状态")
            }
            try assertWhole("privacy.withdraw.desc", inside: rect("privacy.withdraw.card"), "\(width) 撤回说明")
        }
    }

    func testPrivacyBasic() async throws {
        for width in widths {
            try await openPrivacy(Scene(session: "privacy_basic", canvas: large(width)),
                                  waitFor: "privacy.enableFull.button")
            try assertWhole("privacy.basic.notice.text", inside: rect("privacy.basic.notice"), "\(width) 提示句")
            try assertWhole("privacy.basic.title", inside: rect("privacy.basic.card"), "\(width) 卡标题")
        }
    }

    /// 确认框：按钮整块换行（`确认撤回` 在下、`取消` 在上，DS 现状，主按钮不换到下方看不见）、正文完整。
    func testDialog() async throws {
        for width in widths {
            try await openPrivacy(Scene(canvas: large(width, height: 1400)))
            try askWithdraw()
            _ = try await privacyFrame("privacy.dialog.withdraw.panel")
            let id = "privacy.dialog.withdraw"
            let panel = try rect(id + ".panel")
            let primary = try rect(id + ".primary")
            let secondary = try rect(id + ".secondary")
            XCTAssertFalse(sameRow(primary, secondary), "\(width) 放不下整块换行")
            assertInside(primary, panel, "\(width) 取消在面板内")
            assertInside(secondary, panel, "\(width) 确认在面板内")
            try assertLarge(id + ".message", "\(width) 正文")
        }
    }

    func testAbout() async throws {
        for width in widths {
            try await openAbout(canvas: large(width, height: 2600), waitFor: "about.copy.desc")
            let screen = CGRect(x: 0, y: 0, width: width, height: 2600)
            try assertLarge("about.versionText", "\(width) 版本")
            try assertWhole("about.versionText", inside: screen, "\(width) 版本")
            try assertWhole("about.filing.title", inside: screen, "\(width) 分组名")
            try assertWhole("about.filing.text", inside: rect("about.filing.card"), "\(width) 公示原文")
            try assertWhole("about.copy.desc", inside: screen, "\(width) 说明")
            try assertWhole("about.copy.label", inside: rect("about.copy.button"), "\(width) 按钮字")
        }
    }

    /// 窗口里内容放不下、真的在滚动的滚动区。
    private func overflowing(in view: UIView?) -> UIScrollView? {
        guard let view else { return nil }
        if let scroller = view as? UIScrollView, scroller.contentSize.height > scroller.bounds.height + 1 {
            return scroller
        }
        return view.subviews.lazy.compactMap { self.overflowing(in: $0) }.first
    }

    /// 半屏 200%：短视口里正文可滚动、按钮固定可见；标题在。v2：画布 620 放得下、逼不出滚动（V31 活），压到 480；400 时固定部分（约 403）也放不下，这时用户拖到大 detent。
    func testCsSheetShortViewport() async throws {
        for width in widths {
            let canvas = Canvas(width: width, height: 480, size: ax3, top: 0, bottom: 0)
            try await openCs("cs_open_failed", canvas: canvas, waitFor: "cs.retry.button")
            try assertLarge("cs.title.text", "\(width) 标题")
            for id in ["cs.retry.button", "cs.copyLink.button", "cs.help.hit"] {
                XCTAssertLessThanOrEqual(try rect(id).maxY, 480.5, "\(width) \(id) 固定可见")
            }
            XCTAssertGreaterThanOrEqual(try rect("cs.title.text").minY, 0, "\(width) 标题可见")
            XCTAssertNotNil(overflowing(in: page?.window), "\(width) 正文确实在滚动（这个画布逼得出来）")
        }
    }

    /// 半屏 200% 长视口：文字不截断不缩小。
    func testCsSheetTexts() async throws {
        for width in widths {
            try await openCs("cs_open_failed", canvas: Canvas(width: width, height: 1500, size: ax3, top: 0),
                             waitFor: "cs.safety.text")
            let panel = try rect("cs.panel")
            try assertWhole("cs.title.text", inside: panel, "\(width) 标题")
            try assertWhole("cs.body.text", inside: panel, "\(width) 说明")
            try assertWhole("cs.safety.text", inside: rect("cs.safety.bar"), "\(width) 安全提示")
            try assertDisjoint(rect("cs.title.text"), rect("cs.close.hit"), "\(width) 标题 / 关闭")
        }
    }

    /// ≥ 600：限宽 600 居中。
    func testWideLayouts() async throws {
        try await openPrivacy(Scene(canvas: Canvas(width: 840, height: 1200)), waitFor: "privacy.docs")
        XCTAssertLessThanOrEqual(try rect("privacy.docs").width, 600.5, "隐私中心限宽 600")
        assertNear(try rect("privacy.docs").midX, 420, 1, "隐私中心居中")
        try await openAbout(canvas: Canvas(width: 840, height: 900), waitFor: "about.copy.button")
        XCTAssertLessThanOrEqual(try rect("about.copy.button").width, 600.5, "关于限宽 600")
        assertNear(try rect("about.copy.button").midX, 420, 1, "关于居中")
        try await openCs("cs_open_failed", canvas: Canvas(width: 840, height: 620, top: 0), waitFor: "cs.retry.button")
        XCTAssertLessThanOrEqual(try rect("cs.retry.button").width, 600.5, "半屏限宽 600")
        assertNear(try rect("cs.retry.button").midX, 420, 1, "半屏居中")
    }
}
