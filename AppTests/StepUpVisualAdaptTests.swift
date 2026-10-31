@testable import Couli
import CouliNetwork
import DesignSystem
import SwiftUI
import UIKit
import Wallet
@testable import WalletCore
import XCTest

/// 适配（AdaptShortStepUp、brief §2.4 / §2.7 / 验收 6）：字号在半屏内真放大（窗口特征，不是环境值，见 Oracle）、不截断不缩字、同时比尺寸与位置；
/// 放不下时整块滚动、标题 / 关闭 / 【验证并提交】都可达；800+ 宽限宽。键盘态只有 UI 测试能测（`StepUpVisualUITests`）。
@MainActor
final class StepUpVisualAdaptTests: StepUpVisualTestCase {
    /// 每个字都在、字真放大、不出面板左右边、数字格不缩。
    private func assertLarge(_ width: CGFloat, file: StaticString = #filePath, line: UInt = #line) async throws {
        try await openSheet(code: "38", canvas: .init(width: width, height: 844), large: Self.ax3,
                            waitFor: "stepUp.cell.5", file: file, line: line)
        XCTAssertEqual(presentedCategory, Self.ax3, "半屏真 200%", file: file, line: line)
        let sheet = try sheetFrame(file: file, line: line)
        for id in ["stepUp.title", "stepUp.sent", "stepUp.countdown"] {
            let item = try record(id, file: file, line: line)
            XCTAssertGreaterThan(item.fontSize, item.baseFontSize * 1.3, "\(id) 真放大", file: file, line: line)
            try assertNotTruncated(id, id, file: file, line: line)
            XCTAssertGreaterThanOrEqual(item.rect.minX, sheet.minX, "\(id) 不出左边", file: file, line: line)
            XCTAssertLessThanOrEqual(item.rect.maxX, sheet.maxX, "\(id) 不出右边", file: file, line: line)
        }
        let cells = try (0..<6).map { try rect("stepUp.cell.\($0)", file: file, line: line) }
        for index in 1..<6 {
            assertNear(cells[index].width, cells[0].width, 0.5, "同宽", file: file, line: line)
            XCTAssertGreaterThanOrEqual(cells[index].minX, cells[index - 1].maxX, "格子不重叠", file: file, line: line)
        }
        XCTAssertGreaterThanOrEqual(logical(cells[0].height), 56, "格高只增不减", file: file, line: line)
        XCTAssertLessThanOrEqual(cells[5].maxX, sheet.maxX, "6 格在一行内放得下", file: file, line: line)
        let digit = try record("stepUp.cell.0", file: file, line: line)
        XCTAssertGreaterThan(digit.fontSize, 0, "格子要报数字字号", file: file, line: line)
        XCTAssertLessThanOrEqual(digit.fontSize * 0.62, cells[0].width, "数字放得进格子", file: file, line: line)
    }

    func testAX3W390() async throws {
        try await assertLarge(390)
    }

    func testAX3W320() async throws {
        try await assertLarge(320)
    }

    /// AX3：倒计时与错误放不下同一行时可换行，但两者都完整、都在格下、都在按钮前，不互相压。
    func testAX3ErrorAndCountdownBothComplete() async throws {
        let (host, _) = try await openSheet(code: "000000", canvas: .init(width: 320, height: 844), large: Self.ax3,
                                            waitFor: "stepUp.countdown")
        host.server.script.on("POST /v1/auth/step-up", Self.wrongCode)
        try panelActions().verify()
        await waitUntil { self.stepUp?.state?.error != nil }
        try await settled(host, waitFor: "stepUp.error.text")
        try assertNotTruncated("stepUp.error.text", "错误")
        try assertNotTruncated("stepUp.countdown", "倒计时")
        try assertDisjoint(rect("stepUp.error.text"), rect("stepUp.countdown"), "不互相压")
        try XCTAssertGreaterThanOrEqual(rect("stepUp.error.text").minY, rect("stepUp.cells").maxY)
    }

    /// 短视口（320×568、667）+ 200%：降级整块滚动（共性第 33 条），标题、关闭、【验证并提交】都在同一滚动内容里、都在面板宽内且不重叠。
    func testShortViewportFallsBackToWholeScroll() async throws {
        for height in [CGFloat(568), 667] {
            let (_, image) = try await openSheet(canvas: .init(width: 320, height: height), large: Self.ax3,
                                                 waitFor: "stepUp.fallback")
            XCTAssertTrue(has("stepUp.fallback"), "h\(height)：切到整块滚动")
            let title = try rect("stepUp.title")
            let cells = try rect("stepUp.cells")
            let submit = try rect("stepUp.submit")
            XCTAssertLessThan(title.maxY, cells.minY, "顺序不乱")
            XCTAssertLessThan(cells.maxY, submit.minY, "顺序不乱")
            XCTAssertEqual(WithdrawVisualRenderJudge.problems(image), [], "画面正常")
            let scroller = try XCTUnwrap(sheetScroller(), "放不下时要有整块滚动")
            XCTAssertGreaterThan(scroller.contentSize.height, scroller.bounds.height, "内容超出、能滚")
            scroller.setContentOffset(CGPoint(x: 0, y: scroller.contentSize.height - scroller.bounds.height),
                                      animated: false)
            await waitUntil("滚到底后按钮要进可见区") {
                guard let frame = self.page?.probes["stepUp.submit"]?.rect,
                      let view = self.page?.window?.rootViewController?.presentedViewController?.view
                else { return false }
                return frame.maxY <= view.convert(view.bounds, to: nil).maxY + 0.5
            }
        }
    }

    /// 默认字号短视口（AdaptShortStepUp 上图 390×667）：三段都在半屏内，不必滚动。
    func testShortViewportDefaultSizeNoFallback() async throws {
        try await openSheet(canvas: .init(height: 667), waitFor: "stepUp.submit")
        XCTAssertFalse(has("stepUp.fallback"), "默认字号放得下")
        try XCTAssertLessThanOrEqual(rect("stepUp.submit").maxY, sheetFrame().maxY, "按钮在半屏内")
    }

    /// 840 宽：内容限宽 ≤ 600、居中（大屏口径）；6 格仍同宽。
    func testW840() async throws {
        try await openSheet(code: "38", canvas: .init(width: 840, height: 1100), waitFor: "stepUp.cell.5")
        let row = try rect("stepUp.cells")
        XCTAssertLessThanOrEqual(row.width, 600.5, "限宽")
        assertNear(row.midX, try sheetFrame().midX, 1, "居中")
    }

    private func sheetScroller() -> UIScrollView? {
        guard let root = page?.window?.rootViewController?.presentedViewController?.view else { return nil }
        var found: [UIScrollView] = []
        func walk(_ view: UIView) {
            if let scroll = view as? UIScrollView, !(view is UITextView), scroll.bounds.height > 60 {
                found.append(scroll)
            }
            view.subviews.forEach(walk)
        }
        walk(root)
        return found.max { $0.bounds.height < $1.bounds.height }
    }
}
