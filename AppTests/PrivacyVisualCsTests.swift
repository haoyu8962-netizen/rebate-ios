@testable import Couli
import DesignSystem
import Foundation
import MeCore
import SwiftUI
import UIKit
import XCTest

/// 联系客服半屏（brief §2 第 14–17 条，G-P02、G-P06、G-P07）。内容实量自 CsOpenFailed-v2：
/// 把手区上 28 → 块 56 → 12 → 标题 → 12 → 说明 → 16 → 提示条 → 16 → 按钮纵向 12。
/// 关闭按 2026-10-28 三端口径放标题行右侧（不是右上角）。系统 `.sheet` 的把手、圆角、遮罩不改（系统控件差异），这里只量内容。
@MainActor
final class PrivacyVisualCsTests: PrivacyVisualTestCase {
    private typealias Board = PrivacyVisualData.Board
    private typealias Judge = PrivacyVisualJudge

    /// 头部：图标块在上、标题居中、说明 14 次文字居中。
    func testHeader() async throws {
        let image = try await openCs("cs_open_failed", waitFor: "cs.safety.bar")
        let panel = try rect("cs.panel")
        let badge = try rect("cs.badge")
        let title = try record("cs.title.text")
        let body = try record("cs.body.text")
        assertNear(badge.width, Board.badge, 1, "图标块 56")
        assertNear(badge.height, Board.badge, 1, "图标块 56")
        assertNear(badge.minY - panel.minY, Board.sheetTop, 3, "上 28")
        XCTAssertTrue(Judge.centered(badge, in: panel), "图标块居中")
        assertNear(title.rect.minY - badge.maxY, 12, 2, "块到标题 12")
        assertNear(body.rect.minY - title.rect.maxY, 12, 2, "标题到说明 12")
        XCTAssertEqual(title.text, "暂时打不开客服")
        try assertBase("cs.title.text", 17, "标题 17")
        try assertBase("cs.body.text", 14, "说明 14（现状 17）")
        XCTAssertTrue(Judge.centered(title.rect, in: panel), "标题居中（现状靠左）")
        try assertInk(image, "cs.body.text", CouliColor.textSecondary, "说明次文字（现状主文字）")
        let pixels = ProductVisualPixels(image)
        let ground = pixel(CouliColor.backgroundSurface, dark: false)
        let band = CGRect(x: panel.minX + 4, y: body.rect.minY, width: panel.width - 8, height: 18)
        let left = try XCTUnwrap(inkLeft(pixels, in: band, background: ground), "说明没有墨迹")
        let right = try XCTUnwrap(inkRight(pixels, in: band, background: ground), "说明没有墨迹")
        XCTAssertTrue(SettingsVisualJudge.centered(inkLeft: left, inkRight: right, in: panel, tolerance: 6), "说明文字居中")
    }

    /// 三端口径：关闭在标题行右侧，命中 44，不盖标题；视觉 24。
    func testCloseOnTitleRow() async throws {
        try await openCs("cs_open_failed", waitFor: "cs.close.hit")
        let hit = try rect("cs.close.hit")
        let title = try rect("cs.title.text")
        // v2b：同「去帮助中心」，≥ 44 按屏上算（真 `.sheet` 缩到 0.96），宽高都要约 46
        XCTAssertGreaterThanOrEqual(hit.width, Board.sheetHit - 0.2, "命中宽约 46（屏上 44）")
        XCTAssertGreaterThanOrEqual(hit.height, Board.sheetHit - 0.2, "命中高约 46（屏上 44）")
        XCTAssertTrue(Judge.sameRow(hit, title), "在标题行（不是右上角）")
        assertDisjoint(hit, title, "命中区不盖标题")
        try assertNear(rect("cs.panel").maxX - hit.maxX, 4, 12.5, "靠右")
    }

    /// 图标块色调与图标（G-P06）：打不开 / 只有帮助 = 警告 + 三角；未装 / HANDOFF = muted + 消息。四张同一模板。
    func testBadgeMapping() async throws {
        for name in ["cs_open_failed", "cs_help_only", "cs_help_only_insecure"] {
            try await assertBadge(name, ground: CouliColor.statusWarningBackground, ink: CouliColor.statusWarningText,
                                  symbol: "exclamationmark.triangle")
        }
        for name in ["cs_wechat_missing", "cs_handoff"] {
            try await assertBadge(name, ground: CouliColor.backgroundMuted, ink: CouliColor.textSecondary,
                                  symbol: "bubble.left")
        }
    }

    private func assertBadge(_ name: String, ground: Color, ink: Color, symbol: String, file: StaticString = #filePath,
                             line: UInt = #line) async throws {
        let image = try await openCs(name, waitFor: "cs.badge.icon", file: file, line: line)
        let badge = try rect("cs.badge", file: file, line: line)
        assertFill(image, CGRect(x: badge.minX + 20, y: badge.minY + 3, width: 16, height: 6),
                   pixel(ground, dark: false), "\(name) 底色", file: file, line: line)
        let icon = try rect("cs.badge.icon", file: file, line: line)
        assertNear(icon.width, 32, 1.5, "\(name) 图标 32", file: file, line: line)
        let candidates = ["exclamationmark.triangle", "bubble.left", "info.circle"]
        let found = await nearestSymbol(image, in: icon, candidates: candidates, background: ground, ink: ink)
        XCTAssertEqual(found, symbol, name, file: file, line: line)
    }

    /// 安全提示条：muted 底、圆角 12、内边距 12、盾牌对勾 20、14 主文字；文案 G-P07。
    func testSafetyBar() async throws {
        let image = try await openCs("cs_open_failed", waitFor: "cs.safety.text")
        let body = try rect("cs.body.text")
        let bar = try rect("cs.safety.bar")
        let icon = try rect("cs.safety.icon")
        let safety = try record("cs.safety.text")
        assertNear(bar.minY - body.maxY, 16, 2, "说明到提示条 16")
        assertNear(bar.minX, Board.side, 1, "左 16")
        assertNear(bar.width, Board.width, 1, "通栏")
        assertNear(icon.width, 20, 1, "图标 20")
        assertNear(icon.minX - bar.minX, 12, 1, "内边距 12")
        assertNear(safety.rect.minX - icon.maxX, 8, 1.5, "图标到文字 8")
        XCTAssertEqual(safety.text, try PrivacyVisualData.text("cs", "safetyDraft"), "G-P07")
        try assertBase("cs.safety.text", 14, "14（现状 12）")
        try assertInk(image, "cs.safety.text", CouliColor.textPrimary, "主文字（现状次文字）")
        assertFill(image, CGRect(x: bar.maxX - 10, y: bar.midY - 5, width: 6, height: 10),
                   pixel(CouliColor.backgroundMuted, dark: false), "muted 底", tolerance: 2)
        let candidates = ["checkmark.shield", "info.circle", "exclamationmark.triangle"]
        let found = await nearestSymbol(image, in: icon, candidates: candidates, background: CouliColor.backgroundMuted,
                                        ink: CouliColor.textPrimary)
        XCTAssertEqual(found, "checkmark.shield", "盾牌对勾（现状 info）")
    }

    /// v2 判据自证（先正后反）：生产 `CouliIconView` 的盾牌、info、三角各判回自己。参考图要与生产同画法，v1 的 `nearestIcon` 铺满框，尺度不同把盾牌判成三角。
    func testSymbolJudge() async throws {
        let cases: [(CouliIcon, String)] = [
            (.shieldCheck, "checkmark.shield"), (.info, "info.circle"), (.alert, "exclamationmark.triangle"),
        ]
        let size = CGSize(width: 60, height: 60)
        for (icon, symbol) in cases {
            let view = CouliIconView(icon, size: 20).foregroundColor(CouliColor.textPrimary).couliProbe(
                "icon",
                role: "icon"
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity).background(CouliColor.backgroundMuted)
            let ground = pixel(CouliColor.backgroundMuted, dark: false)
            let (image, records) = await WalletVisualRender.standalone(view, size: size) { pixels in
                pixels.count(in: CGRect(origin: .zero, size: size)) { !$0.near(ground, tolerance: 40) } > 8
            }
            let box = try XCTUnwrap(records["icon"]?.rect)
            let candidates = ["checkmark.shield", "info.circle", "exclamationmark.triangle"]
            let found = await nearestSymbol(
                image,
                in: box,
                candidates: candidates,
                background: CouliColor.backgroundMuted,
                ink: CouliColor.textPrimary
            )
            XCTAssertEqual(found, symbol, "\(icon)")
        }
    }

    /// 打不开：【重试】主 →【复制客服链接】次 →「去帮助中心」文字链接（G-P06 ④）。
    func testOpenFailedButtons() async throws {
        let image = try await openCs("cs_open_failed", waitFor: "cs.help.link")
        let bar = try rect("cs.safety.bar")
        let retry = try rect("cs.retry.button")
        let copy = try rect("cs.copyLink.button")
        assertNear(retry.minY - bar.maxY, 16, 2, "提示条到按钮 16")
        assertNear(copy.minY - retry.maxY, 12, 1.5, "按钮纵向 12")
        for box in [retry, copy] {
            assertNear(box.width, Board.width, 1, "通栏")
            XCTAssertGreaterThanOrEqual(box.height, 47.5, "min 48")
        }
        try assertPrimary(image, "cs.retry.button", "【重试】")
        try assertSecondary(image, "cs.copyLink.button", "【复制客服链接】")
        XCTAssertFalse(has("cs.goHelp.button"), "打不开时不是按钮")
        let link = try record("cs.help.link")
        let hit = try rect("cs.help.hit")
        XCTAssertEqual(link.text, "去帮助中心")
        try assertBase("cs.help.link", 14, "链接 14")
        XCTAssertTrue(try Judge.centered(link.rect, in: rect("cs.panel")), "链接居中")
        XCTAssertLessThanOrEqual(link.rect.height, 24, "视觉高 = 文字行高")
        try assertHit("cs.help.hit", covers: "cs.help.link", "去帮助中心")
        // v2：屏上 ≥ 44（真 `.sheet` 缩到 374/390，屏上判据在 UI 用例真点）。命中外扩、视觉不变：文字位置仍按画板行高 44
        XCTAssertGreaterThanOrEqual(hit.height, Board.sheetHit - 0.2, "命中约 46（屏上 44）")
        XCTAssertLessThanOrEqual(hit.height, 48, "命中不无限外扩")
        assertNear(hit.midY, link.rect.midY, 2, "文字在命中区中")
        assertNear(link.rect.midY - copy.maxY, 34, 2.5, "次按钮下 12 + 行高 44 的中线（视觉不变）")
        assertDisjoint(hit, copy, "命中不盖次按钮")
        try assertInk(image, "cs.help.link", CouliColor.textLink, "链接色", minimum: 5)
        XCTAssertEqual(count(image, in: link.rect, near: pixel(CouliColor.brandPrimary, dark: false), tolerance: 6), 0,
                       "不是实底按钮")
        XCTAssertEqual(outlineInk(image, hit, right: hit.maxX), 0, "不是描边按钮")
    }

    /// 未装微信：【复制客服链接】主 →【去帮助中心】次（描边，不是现状的文字按钮）。
    func testWechatMissingButtons() async throws {
        let image = try await openCs("cs_wechat_missing", waitFor: "cs.goHelp.button")
        XCTAssertEqual(try text("cs.title.text"), "联系客服")
        let texts = try XCTUnwrap(page).fixture.me.deps.texts
        XCTAssertEqual(try text("cs.body.text"), texts.text("cs.wechat_unavailable"))
        try assertPrimary(image, "cs.copyLink.button", "【复制客服链接】")
        try assertSecondary(image, "cs.goHelp.button", "【去帮助中心】")
        XCTAssertFalse(has("cs.help.link"), "未装微信不是链接")
        XCTAssertFalse(has("cs.retry.button"))
    }

    /// 无稿态（G-P02、G-P06）：只有帮助 = 唯一主按钮、无复制；HANDOFF = 首个主、其余次，按钮与去向不变。
    func testHelpOnlyAndHandoff() async throws {
        for name in ["cs_help_only", "cs_help_only_insecure"] {
            let image = try await openCs(name, waitFor: "cs.goHelp.button")
            XCTAssertEqual(try text("cs.title.text"), "暂时打不开客服", "\(name)（G-P06，同打不开标题；现状「联系客服」）")
            try assertPrimary(image, "cs.goHelp.button", name)
            XCTAssertFalse(has("cs.copyLink.button"), "\(name) 不显示复制")
        }
        let image = try await openCs("cs_handoff", waitFor: "cs.goHelp.button")
        try assertPrimary(image, "cs.openWechat.button", "【打开微信】")
        try assertSecondary(image, "cs.goHelp.button", "【先看看帮助中心】")
        XCTAssertEqual(try record("cs.goHelp.button").text.isEmpty, false, "按钮字")
    }

    /// 复制成功：半屏内一行成功色（16 对勾可选），在按钮上方、半屏不关、polite 一次、不走页面轻提示（§9 第 9 条不双播）。
    func testCopiedStaysInSheet() async throws {
        try await openCs("cs_wechat_missing", waitFor: "cs.copyLink.button")
        announcements = []
        toasts = []
        try csActions.copyLink()
        let image = try await frame("cs.toast.text")
        let line = try record("cs.toast.text")
        XCTAssertEqual(line.text, "已复制客服链接")
        XCTAssertNotNil(try cs.sheet, "留在半屏")
        XCTAssertLessThan(line.rect.maxY, try rect("cs.copyLink.button").minY + 0.5, "在按钮上方")
        try assertInk(image, "cs.toast.text", CouliColor.statusSuccessText, "成功色", minimum: 4)
        XCTAssertEqual(announcements.map(\.text), ["已复制客服链接"], "播报一次")
        XCTAssertEqual(announcements.map(\.assertive), [false], "polite")
        XCTAssertTrue(toasts.isEmpty, "不走页面轻提示")
    }

    /// 复制失败：同一行改错误色、不带对勾（编排 15:14 ③：这是缺陷，只改颜色，位置与播报不变）。现状失败也是绿字。
    func testCopyFailedUsesErrorColor() async throws {
        try await openCs("cs_wechat_missing_copy_failed", waitFor: "cs.copyLink.button")
        announcements = []
        try csActions.copyLink()
        let image = try await frame("cs.toast.text")
        let box = try rect("cs.toast.text")
        XCTAssertEqual(try text("cs.toast.text"), try XCTUnwrap(page).fixture.me.deps.texts.text("me.copy_failed"))
        XCTAssertEqual(count(image, in: box, near: pixel(CouliColor.statusSuccessText, dark: false), tolerance: 12), 0,
                       "失败不是成功色")
        try assertInk(image, "cs.toast.text", CouliColor.statusErrorText, "错误色", minimum: 4)
        XCTAssertFalse(has("cs.toast.icon"), "失败不带对勾")
        XCTAssertEqual(announcements.count, 1, "播报一次")
    }
}
