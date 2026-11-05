@testable import Couli
import CouliNetwork
import DesignSystem
import SwiftUI
import UIKit
import Wallet
@testable import WalletCore
import XCTest

/// W63–W68 版式（画板 WithdrawStepUp-v2 / WithdrawStepUpDark，brief §2.4）。测量编号见交回 §2；全部相对系统半屏的实际框。视觉断言先正后反。
@MainActor
final class StepUpVisualLayoutTests: StepUpVisualTestCase {
    private func surface(dark: Bool = false) -> ProductVisualPixels.RGB {
        pixel(CouliColor.backgroundSurface, dark: dark)
    }

    /// 第 `index` 格的描边宽（半屏逻辑点）。
    private func stroke(_ image: UIImage, _ index: Int, dark: Bool = false) throws -> CGFloat {
        try logical(strokeWidth(image, cell: rect("stepUp.cell.\(index)"), surface: surface(dark: dark)))
    }

    private func contentLeft() throws -> CGFloat {
        try sheetFrame().minX + 16 * sheetScale
    }

    private func contentRight() throws -> CGFloat {
        try sheetFrame().maxX - 16 * sheetScale
    }

    // MARK: - W63 把手

    /// 36×4、水平居中、`border.subtle`、在标题之上，浅深两档。
    func testW63Handle() async throws {
        for dark in [false, true] {
            let (_, image) = try await openSheet(canvas: .init(height: dark ? 1119 : 844, dark: dark),
                                                 waitFor: "stepUp.handle")
            let sheet = try sheetFrame()
            let handle = try rect("stepUp.handle")
            assertNear(logical(handle.width), 36, 0.5, "把手宽")
            assertNear(logical(handle.height), 4, 0.5, "把手高")
            assertNear(handle.midX, sheet.midX, 0.75, "水平居中")
            XCTAssertGreaterThanOrEqual(logical(handle.minY - sheet.minY), 6, "在半屏内")
            XCTAssertLessThanOrEqual(logical(handle.minY - sheet.minY), 24, "贴顶（画板内边距 20）")
            try XCTAssertLessThan(handle.maxY, rect("stepUp.title").minY, "在标题之上")
            let color = pixel(CouliColor.borderSubtle, dark: dark)
            XCTAssertGreaterThan(share(image, in: handle.insetBy(dx: 3, dy: 1), near: color, tolerance: 8), 0.6,
                                 "令牌色 border.subtle（dark=\(dark)）")
        }
    }

    // MARK: - W64 / W65 标题区

    /// 标题 17/600，键仍是 error.10003（G-W19，文案随契约，不写画板新句）；【×】靠右，命中 ≥ 44，与标题同在顶行。
    func testW64TitleAndClose() async throws {
        try await openSheet()
        XCTAssertEqual(try text("stepUp.title"), texts.text("error.10003"), "标题取 error.10003")
        try assertBase("stepUp.title", 17, "标题")
        try assertNear(rect("stepUp.title").minX, contentLeft(), 1, "标题左缘")
        try assertHit("stepUp.close.hit", covers: "stepUp.close", "关闭")
        let close = try rect("stepUp.close.hit")
        XCTAssertLessThanOrEqual(close.maxX, try sheetFrame().maxX - 4, "关闭靠右")
        try assertDisjoint(close, rect("stepUp.title"), "关闭命中区不压标题")
    }

    /// 说明挪到标题区（G16）：14 次文字，紧贴标题下（画板 8），左缘同标题，在验证码格之上；不显示号码，不做业务摘要（G-W19）。
    func testW65SentLineInTitleArea() async throws {
        let (_, image) = try await openSheet(waitFor: "stepUp.cells")
        XCTAssertEqual(try text("stepUp.sent"), texts.text("step_up.sent"))
        try assertBase("stepUp.sent", 14, "说明")
        let title = try rect("stepUp.title")
        let sent = try rect("stepUp.sent")
        assertNear(sent.minX, title.minX, 1, "左缘同标题")
        assertNear(logical(sent.minY - title.maxY), 8, 2.5, "标题与说明间距")
        try XCTAssertLessThan(sent.maxY, rect("stepUp.cells").minY, "在格子之上")
        let ink = count(image, in: sent, near: pixel(CouliColor.textSecondary, dark: false))
        XCTAssertGreaterThan(ink, 20, "次文字色")
        for forbidden in ["138", "5678", "****", "¥", "收款账号", "支付宝"] {
            XCTAssertFalse(pageTextsInSheet.contains { $0.contains(forbidden) }, "半屏不显示 \(forbidden)（G16 / G-W19）")
        }
    }

    private var pageTextsInSheet: [String] {
        page?.probes.records.filter { $0.key.hasPrefix("stepUp.") }.values.map(\.text).filter { !$0.isEmpty } ?? []
    }

    // MARK: - W66 六格

    /// 6 格同宽、等高 56、间距 8，铺满内容宽；输入的数字进对应格。
    func testW66SixCellsGeometry() async throws {
        try await openSheet(code: "38", waitFor: "stepUp.cell.5")
        let cells = try (0..<6).map { try rect("stepUp.cell.\($0)") }
        XCTAssertEqual(page?.probes.ids(prefix: "stepUp.cell.").count, 6, "恰 6 格")
        let left = try contentLeft()
        let right = try contentRight()
        assertNear(cells[0].minX, left, 1, "首格贴内容左缘")
        assertNear(cells[5].maxX, right, 1, "末格贴内容右缘")
        for index in 0..<6 {
            assertNear(logical(cells[index].height), 56, 0.5, "第 \(index) 格高（组件令牌 56，不取画板 52，brief §2.4）")
            assertNear(cells[index].width, cells[0].width, 0.5, "第 \(index) 格同宽")
            XCTAssertTrue(sameRow(cells[index], cells[0]), "同一行")
            if index > 0 {
                assertNear(logical(cells[index].minX - cells[index - 1].maxX), 8, 0.5, "间距 8")
            }
        }
        XCTAssertEqual(try text("stepUp.cell.0"), "3")
        XCTAssertEqual(try text("stepUp.cell.1"), "8")
        XCTAssertEqual(try text("stepUp.cell.2"), "")
        try assertInside(cells[0], rect("stepUp.cells"), "格子在行内")
    }

    /// 当前格 2 描边，其余 1；随输入前移（真量像素）。
    func testW66CurrentCellStroke() async throws {
        let (_, empty) = try await openSheet(waitFor: "stepUp.cell.5")
        assertNear(try stroke(empty, 0), 2, 0.5, "空码：首格是当前格")
        assertNear(try stroke(empty, 1), 1, 0.5, "其余 1")
        try enterCode("38")
        let host = try XCTUnwrap(page)
        await waitUntil { self.page?.probes["stepUp.cell.1"]?.text == "8" }
        let typed = try await settled(host, waitFor: "stepUp.cell.5")
        assertNear(try stroke(typed, 2), 2, 0.5, "已输 2 位：第 3 格当前")
        assertNear(try stroke(typed, 0), 1, 0.5, "已填格 1")
        assertNear(try stroke(typed, 3), 1, 0.5, "后面的格 1")
    }

    // MARK: - W67 格下一行

    /// 倒计时：措辞「48 秒后可重新获取」、14 次文字、靠右，紧贴格下（在中段，不在底部操作区），在【验证并提交】之上。
    func testW67CountdownRow() async throws {
        let (_, image) = try await openSheet(waitFor: "stepUp.countdown")
        XCTAssertEqual(try text("stepUp.countdown"), "48 秒后可重新获取", "键 login.code.countdown（G-W19）")
        // #24 test-change（升锁 00deded0ef6f）：契约文案占位符 {sec} → {n}，代入名随契约改，判据不变
        XCTAssertEqual(texts.format("login.code.countdown", ["n": "48"]), "48 秒后可重新获取", "钱包文案表有这条草稿")
        try assertBase("stepUp.countdown", 14, "倒计时")
        let countdown = try rect("stepUp.countdown")
        try assertNear(countdown.maxX, contentRight(), 1, "靠右")
        let cells = try rect("stepUp.cells")
        assertNear(logical(countdown.midY - cells.maxY), 12 + 10.5, 6, "紧贴格下一行")
        try XCTAssertLessThan(countdown.maxY, rect("stepUp.submit").minY, "在按钮之上")
        XCTAssertGreaterThan(count(image, in: countdown, near: pixel(CouliColor.textSecondary, dark: false)), 20)
    }

    /// 错误与倒计时同一行：左错误（14 红字 + 图标）、右倒计时。错误出现时格子和按钮不跳（行高预留）。
    func testW67ErrorAndCountdownSameRow() async throws {
        let (host, _) = try await openSheet(code: "000000", waitFor: "stepUp.countdown")
        let submitBefore = try rect("stepUp.submit")
        let cellsBefore = try rect("stepUp.cells")
        host.server.script.on("POST /v1/auth/step-up", Self.wrongCode)
        try panelActions().verify()
        await waitUntil("错误没出现") { self.stepUp?.state?.error != nil }
        let image = try await settled(host, waitFor: "stepUp.error.text")
        XCTAssertEqual(try text("stepUp.error.text"), texts.text("error.20002"))
        try assertBase("stepUp.error.text", 14, "错误")
        let error = try rect("stepUp.error.text")
        let icon = try rect("stepUp.error.icon")
        let countdown = try rect("stepUp.countdown")
        XCTAssertTrue(sameRow(error, countdown), "同一行：\(error) / \(countdown)")
        XCTAssertLessThan(error.maxX, countdown.minX, "左错误右倒计时")
        XCTAssertLessThanOrEqual(icon.maxX, error.minX + 0.5, "图标在错误文字左")
        try assertNear(icon.minX, contentLeft(), 1, "错误行贴内容左缘")
        assertNear(logical(icon.width), 16, 1.5, "图标 16")
        XCTAssertGreaterThan(count(image, in: error, near: pixel(CouliColor.statusErrorText, dark: false)), 20, "红字")
        XCTAssertGreaterThan(count(image, in: icon, near: pixel(CouliColor.statusErrorText, dark: false)), 6, "红图标")
        try assertNear(rect("stepUp.cells").minY, cellsBefore.minY, 0.5, "格子不跳")
        try assertNear(rect("stepUp.submit").minY, submitBefore.minY, 0.5, "按钮不跳（一行错误不改高度）")
    }

    /// 发码失败回退：【重新获取】与错误同行；视觉行不被 44 命中区撑高（§9 第 7 条），命中区不压格子和按钮。
    func testW67ResendRowAndHit() async throws {
        _ = try await openSheet(sms: Self.serverDown, waitFor: "stepUp.resend")
        let row = try rect("stepUp.row")
        let visual = try rect("stepUp.resend")
        // 错误文字可能折行，行高只跟文字走；命中区 44 不得撑高这一行
        let error = try rect("stepUp.error.text")
        XCTAssertLessThanOrEqual(logical(row.height), max(logical(error.height), 21) + 1, "行高不被命中区撑高")
        XCTAssertLessThanOrEqual(logical(visual.height), 28, "视觉高")
        try assertBase("stepUp.resend.label", 14, "【重新获取】字号")
        try assertHit("stepUp.resend.hit", covers: "stepUp.resend", "重新获取")
        try XCTAssertTrue(sameRow(rect("stepUp.error.text"), visual), "左错误右【重新获取】")
        try assertNear(visual.maxX, contentRight(), 1.5, "靠右")
        let hit = try rect("stepUp.resend.hit")
        try assertDisjoint(hit, rect("stepUp.cells"), "命中区不压格子")
        try assertDisjoint(hit, rect("stepUp.submit"), "命中区不压按钮")
    }

    /// 发码中：行里是「正在发送验证码…」，没有【重新获取】和倒计时。
    func testW67SendingInRow() async throws {
        let host = try await openWithdraw(amount: "10", estimate: "estimated", needProbes: false).0
        host.wallet.clock = { Self.frozenMillis }
        host.server.script.on("POST /v1/withdrawals", Self.need)
        host.server.script.on("POST /v1/auth/sms-codes", .hold)
        host.actions?.submit()
        await waitUntil { self.stepUp?.state?.phase == .sending }
        _ = await host.stable { $0.probes["stepUp.sending"] != nil }
        XCTAssertEqual(try text("stepUp.sending"), texts.text("step_up.sending"))
        try XCTAssertLessThan(rect("stepUp.sending").maxY, rect("stepUp.submit").minY)
        try XCTAssertGreaterThan(rect("stepUp.sending").minY, rect("stepUp.cells").maxY, "在格下一行")
        XCTAssertFalse(has("stepUp.countdown"))
        XCTAssertFalse(has("stepUp.resend"))
    }

    /// 取不到号码：说明位换成 no_phone，不发码、无倒计时无重发、按钮置灰、格子不可输入。
    func testNoPhoneState() async throws {
        let host = try await panelOnWithdraw(phone: false)
        _ = await host.stable { $0.probes["stepUp.title"] != nil }
        XCTAssertEqual(try text("stepUp.sent"), texts.text("step_up.no_phone"))
        XCTAssertEqual(smsSends.count, 0, "不发码")
        XCTAssertFalse(has("stepUp.countdown"))
        XCTAssertFalse(has("stepUp.resend"))
        // 这一行此时没有任何内容，预留高才比得到（有倒计时时比不到，变异 M16）
        XCTAssertGreaterThanOrEqual(try logical(rect("stepUp.row").height), 20.5, "空行也预留一行")
    }

    // MARK: - W68 三段布局

    /// 从上到下：把手 → 标题区 → 格子 → 格下一行 → 【验证并提交】通栏；间距按画板（块间 16、格与行 12）。
    func testW68ThreeSections() async throws {
        try await openSheet(waitFor: "stepUp.submit")
        let sent = try rect("stepUp.sent")
        let cells = try rect("stepUp.cells")
        let row = try rect("stepUp.row")
        let submit = try rect("stepUp.submit")
        assertNear(logical(cells.minY - sent.maxY), 16, 2.5, "说明到格子")
        assertNear(logical(row.minY - cells.maxY), 12, 2.5, "格子到错误行")
        XCTAssertGreaterThanOrEqual(logical(row.height), 20.5, "空行也预留一行（画板 min-height 21）")
        XCTAssertGreaterThanOrEqual(logical(submit.minY - row.maxY), 12, "错误行到按钮")
        XCTAssertLessThanOrEqual(logical(submit.minY - row.maxY), 20, "错误行到按钮")
        try assertNear(submit.minX, contentLeft(), 1, "通栏")
        try assertNear(submit.maxX, contentRight(), 1, "通栏")
        XCTAssertGreaterThanOrEqual(logical(submit.height), 47.5, "按钮高")
        XCTAssertLessThanOrEqual(submit.maxY, try sheetFrame().maxY, "在半屏内")
        XCTAssertFalse(has("stepUp.fallback"), "放得下时不是整块滚动")
    }

    /// 深色：面板底、标题、次文字走令牌（WithdrawStepUpDark）。
    func testW68DarkTokens() async throws {
        let (_, image) = try await openSheet(code: "38", canvas: .init(height: 1119, dark: true),
                                             waitFor: "stepUp.cell.5")
        let sheet = try sheetFrame()
        let body = CGRect(x: sheet.midX - 60, y: try rect("stepUp.submit").maxY + 8, width: 120, height: 8)
        XCTAssertGreaterThan(share(image, in: body, near: surface(dark: true), tolerance: 6), 0.9, "深色面板底")
        let primary = pixel(CouliColor.textPrimary, dark: true)
        let secondary = pixel(CouliColor.textSecondary, dark: true)
        XCTAssertGreaterThan(try count(image, in: rect("stepUp.title"), near: primary), 20, "深色主文字")
        XCTAssertGreaterThan(try count(image, in: rect("stepUp.sent"), near: secondary), 20, "深色次文字")
        assertNear(try stroke(image, 2, dark: true), 2, 0.5, "深色当前格")
    }
}
