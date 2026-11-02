@testable import Couli
import DesignSystem
import Foundation
import MeCore
import SwiftUI
import UIKit
import XCTest

/// 隐私中心版式（brief §2 第 1–7 条）。数值从画板像素实量（交回 §1），不是读 min-height：隐私中心列表行是 border-box，节距 44；权限行上下 12。
/// 隐私中心全部行共用「一张卡 + 外框」：量外框不量内容盒（APP-12w-a T1）。测量编号见交回 §4。
@MainActor
final class PrivacyVisualLayoutTests: PrivacyVisualTestCase {
    private typealias Board = PrivacyVisualData.Board
    private let documentRows = [
        ("collect", "个人信息收集清单"), ("share", "第三方共享清单"), ("policy", "隐私政策"), ("agreement", "用户协议"),
    ]

    // MARK: - 清单与协议卡

    func testDocumentCard() async throws {
        try await openPrivacy(waitFor: "privacy.docs")
        let card = try rect("privacy.docs")
        try assertNear(card.minY - navBottom(), 8, 1.5, "内容上边距 8（现状 16）")
        assertNear(card.minX, Board.side, 1, "左边距")
        assertNear(card.width, Board.width, 1, "通栏")
        assertNear(card.height, Board.documentCard + 1.5, 3, "卡高：4 + 44 × 4 + 4，线可另占 1")
        try assertNear(rect("privacy.row.collect").minY - card.minY, 4, 1, "卡内上 4")
        try assertNear(card.maxY - rect("privacy.row.agreement").maxY, 4, 1, "卡内下 4")
    }

    func testDocumentRows() async throws {
        try await openPrivacy(waitFor: "privacy.row.agreement.chevron")
        var previous: CGRect?
        for (name, title) in documentRows {
            let id = "privacy.row.\(name)"
            let row = try rect(id)
            assertNear(row.height, Board.documentRow, 1, "\(name) 行高 44（画板 border-box；不是设置页的 52）")
            assertNear(row.minX, 32, 1, "\(name) 卡内左 16")
            assertNear(row.width, Board.width - 32, 1, "\(name) 卡内右 16")
            XCTAssertEqual(try text(id + ".title"), title)
            try assertBase(id + ".title", 17, "\(name) 标题")
            let chevron = try rect(id + ".chevron")
            assertNear(chevron.width, 20, 1, "\(name) 箭头 20")
            assertNear(chevron.maxX, row.maxX, 1, "\(name) 箭头贴行右")
            if let previous {
                assertNear(row.minY - previous.minY, Board.documentRow + 0.5, 1, "\(name) 节距 44（线可另占 1）")
            }
            previous = row
        }
    }

    func testDocumentDividers() async throws {
        try await openPrivacy(waitFor: "privacy.docs.divider.2")
        for (index, name) in ["collect", "share", "policy"].enumerated() {
            let line = try rect("privacy.docs.divider.\(index)")
            let row = try rect("privacy.row.\(name)")
            assertNear(line.minX, row.minX, 1, "线与内边距齐（现状只缩左）")
            assertNear(line.width, row.width, 1, "线不通到卡边")
            XCTAssertLessThanOrEqual(line.height, 1.5, "1 像素")
            assertNear(line.midY, row.maxY, 1.5, "线贴上一行")
        }
        XCTAssertFalse(has("privacy.docs.divider.3"), "最后一行下没有线")
    }

    // MARK: - 块间距

    /// 画板 gap 12；「系统权限」分节头上另有 8（共 20）。
    func testSectionGaps() async throws {
        try await openPrivacy(waitFor: "privacy.withdraw.card")
        let docs = try rect("privacy.docs")
        let personal = try rect("privacy.personalization.card")
        let heading = try rect("privacy.permissions.title")
        let hint = try rect("privacy.permissions.hint")
        let rows = try rect("privacy.permissions.card")
        let withdraw = try rect("privacy.withdraw.card")
        assertNear(personal.minY - docs.maxY, Board.cardGap, 1.5, "清单 → 个性化 12")
        assertNear(heading.minY - personal.maxY, Board.sectionTop, 2, "个性化 → 分节头 12 + 8")
        assertNear(rows.minY - hint.maxY, Board.cardGap, 1.5, "说明 → 权限卡 12")
        assertNear(withdraw.minY - rows.maxY, Board.cardGap, 1.5, "权限卡 → 撤回卡 12")
    }

    // MARK: - 个性化卡

    func testPersonalizationCard() async throws {
        try await openPrivacy(waitFor: "privacy.personalization.subtitle")
        let card = try rect("privacy.personalization.card")
        let title = try rect("privacy.personalization.title")
        let subtitle = try rect("privacy.personalization.subtitle")
        let control = try rect("privacy.personalization.control")
        assertNear(card.width, Board.width, 1, "通栏")
        assertNear(title.minX - card.minX, 16, 1, "内边距左 16")
        assertNear(title.minY - card.minY, 16, 2, "内边距上 16")
        assertNear(card.maxY - subtitle.maxY, 16, 2, "内边距下 16")
        assertNear(subtitle.minY - title.maxY, 4, 1.5, "标题到说明 4")
        try assertBase("privacy.personalization.title", 17, "标题")
        try assertBase("privacy.personalization.subtitle", 12, "说明（现状 14）")
        XCTAssertEqual(try text("privacy.personalization.subtitle"), "关闭后，首页推荐不再参考你的浏览、搜索和点击记录")
        assertNear(control.maxX, card.maxX - 16, 1, "开关靠右")
        assertNear(control.midY, card.midY, 2, "开关垂直居中")
        XCTAssertGreaterThanOrEqual(control.minX - subtitle.maxX, 8, "开关不挤压文字")
    }

    // MARK: - 系统权限

    func testPermissionHeader() async throws {
        try await openPrivacy(waitFor: "privacy.permissions.hint")
        let heading = try rect("privacy.permissions.title")
        let hint = try rect("privacy.permissions.hint")
        assertNear(heading.minX, 20, 1, "分节头缩进 4")
        assertNear(hint.minX, 20, 1, "说明缩进 4")
        assertNear(hint.minY - heading.maxY, 4, 1.5, "标题到说明 4（现状 8）")
        try assertBase("privacy.permissions.title", 14, "标题 14")
        try assertBase("privacy.permissions.hint", 12, "说明 12（现状 14）")
    }

    /// 权限行（G-P16）：图标 20 + 名称 17 / 用途 12 + 状态 14 + 箭头 20，上下 12；名称用已有草稿 `privacy_center.permission.*`。
    func testPermissionRows() async throws {
        try await openPrivacy(waitFor: "privacy.permission.photos.chevron")
        let texts = try center.deps.texts
        let names = ["push": "通知", "photos": "相册（仅保存图片）"]
        let statuses = ["push": "not_asked", "photos": "granted"]
        for type in ["push", "photos"] {
            let id = "privacy.permission.\(type)"
            let box = try rect(id)
            let icon = try rect(id + ".icon")
            let name = try rect(id + ".name")
            let purpose = try rect(id + ".purpose")
            let status = try rect(id + ".status")
            let chevron = try rect(id + ".chevron")
            XCTAssertEqual(try text(id + ".name"), names[type])
            let statusKey = "privacy.system_permissions.status." + (statuses[type] ?? "")
            XCTAssertEqual(try text(id + ".status"), texts.text(statusKey))
            assertNear(box.minX, 32, 1, "\(type) 卡内左 16")
            assertNear(box.width, Board.width - 32, 1, "\(type) 卡内右 16")
            assertNear(icon.width, 20, 1, "\(type) 图标 20")
            assertNear(icon.minX, box.minX, 1, "\(type) 图标贴行左")
            assertNear(name.minX - icon.maxX, 12, 1.5, "\(type) 图标到文字 12")
            assertNear(name.minY - box.minY, 12, 2, "\(type) 上 12")
            assertNear(box.maxY - purpose.maxY, 12, 2, "\(type) 下 12")
            assertNear(purpose.minY - name.maxY, 2, 1.5, "\(type) 名称到用途 2")
            try assertBase(id + ".name", 17, "\(type) 名称")
            try assertBase(id + ".purpose", 12, "\(type) 用途")
            try assertBase(id + ".status", 14, "\(type) 状态")
            assertNear(chevron.width, 20, 1, "\(type) 箭头 20")
            assertNear(chevron.maxX, box.maxX, 1, "\(type) 箭头贴行右")
            assertNear(chevron.minX - status.maxX, 4, 1.5, "\(type) 状态到箭头 4")
            XCTAssertGreaterThanOrEqual(box.height, 43.5, "\(type) 命中 ≥ 44")
        }
        // v2：画板通知在前（PrivacyCenter、Basic-v2、Dark 三张）；契约与模型是相册在前，只有视图调序，模型不动
        XCTAssertEqual(try center.model().permissionRows.map(\.type), ["photos", "push"], "模型顺序不动")
        try XCTAssertLessThan(
            rect("privacy.permission.push").maxY,
            rect("privacy.permission.photos").minY + 0.5,
            "通知在前"
        )
        try assertNear(rect("privacy.permissions.card").minY, rect("privacy.permission.push").minY, 1, "卡内上 0")
        XCTAssertTrue(has("privacy.permissions.divider.0"))
        XCTAssertFalse(has("privacy.permissions.divider.1"), "两行一条线")
    }

    /// G-P16：push 用途是画板短句（草稿键，W-06 回写前），photos 沿用契约 purpose_key；不再把长句当标题。
    func testPermissionPurposeTexts() async throws {
        try await openPrivacy(waitFor: "privacy.permission.photos.purpose")
        let texts = try center.deps.texts
        XCTAssertEqual(try text("privacy.permission.push.purpose"), "跟单成功、返利结算和提现到账时提醒你")
        XCTAssertEqual(texts.text("privacy.system_permissions.purpose.push"), "跟单成功、返利结算和提现到账时提醒你")
        XCTAssertEqual(try text("privacy.permission.photos.purpose"), texts.text("perm.photos.system_purpose"))
    }

    /// 图标走系统图标集（D10-559）：铃铛、相册图。只比「离谁近」。
    func testPermissionIcons() async throws {
        let image = try await openPrivacy(waitFor: "privacy.permission.photos.icon")
        let background = CouliColor.backgroundSurface
        for (type, symbol) in [("push", "bell"), ("photos", "photo")] {
            let box = try rect("privacy.permission.\(type).icon")
            let found = await nearestSymbol(image, in: box, candidates: ["bell", "photo", "info.circle"],
                                            background: background, ink: CouliColor.textSecondary)
            XCTAssertEqual(found, symbol, type)
        }
    }

    // MARK: - 撤回卡

    /// 通栏次按钮（G-P17：不是危险样式）。
    func testWithdrawCard() async throws {
        let image = try await openPrivacy(waitFor: "privacy.withdraw.button")
        let card = try rect("privacy.withdraw.card")
        let title = try rect("privacy.withdraw.title")
        let desc = try rect("privacy.withdraw.desc")
        let button = try rect("privacy.withdraw.button")
        assertNear(card.width, Board.width, 1, "通栏")
        assertNear(title.minY - card.minY, 16, 2, "内边距 16")
        assertNear(desc.minY - title.maxY, 4, 1.5, "标题到说明 4（现状 12）")
        assertNear(button.minY - desc.maxY, 12, 1.5, "说明到按钮 12")
        assertNear(card.maxY - button.maxY, 16, 1.5, "下 16")
        try assertBase("privacy.withdraw.title", 17, "标题")
        try assertBase("privacy.withdraw.desc", 14, "说明 14（现状 12）")
        assertNear(button.width, Board.width - 32, 1, "通栏")
        XCTAssertGreaterThanOrEqual(button.height, 47.5, "min 48")
        try assertSecondary(image, "privacy.withdraw.button", "【撤回同意】")
        XCTAssertEqual(count(image, in: button, near: pixel(CouliColor.statusErrorText, dark: false), tolerance: 12), 0,
                       "不是危险色（G-P17）")
        try assertInk(image, "privacy.withdraw.desc", CouliColor.textSecondary, "说明次文字")
    }

    /// 撤回进行中：按钮 loading，按钮还在、尺寸不变（无稿）。
    func testWithdrawingKeepsButton() async throws {
        try await openPrivacy(waitFor: "privacy.withdraw.button")
        let before = try rect("privacy.withdraw.button")
        try XCTUnwrap(page).script.on("POST /v1/consents", .hold)
        try centerActions.confirmWithdraw(askWithdraw())
        await waitUntil("撤回记录没发出") { !WalletStubProtocol.heldIds.isEmpty }
        // v2：转圈一直动，`stable` 等不到两帧相同（同 `testPrivacyWithdrawing`）
        await quietWindow(0.5)
        XCTAssertTrue(try center.withdrawing, "还在撤回中")
        try assertNear(rect("privacy.withdraw.button").height, before.height, 1, "高度不变")
        try WalletStubProtocol.release(XCTUnwrap(WalletStubProtocol.heldIds.first),
                                       with: .envelope(code: 0, data: "{}", headers: [:]))
    }

    // MARK: - 基本模式

    /// 提示条（muted 底、圆角 12、内边距 12、info 20、14 主文字，现状警告字色小字）+ 卡（标题 → 主按钮，无副句，G-P08）。
    func testBasicMode() async throws {
        let image = try await openPrivacy(Scene(session: "privacy_basic"), waitFor: "privacy.enableFull.button")
        let bar = try rect("privacy.basic.notice")
        let icon = try rect("privacy.basic.notice.icon")
        let body = try record("privacy.basic.notice.text")
        let docs = try rect("privacy.docs")
        let card = try rect("privacy.basic.card")
        let title = try rect("privacy.basic.title")
        let button = try rect("privacy.enableFull.button")
        try assertNear(bar.minY - navBottom(), 8, 1.5, "内容上边距 8")
        assertNear(bar.width, Board.width, 1, "通栏")
        assertNear(icon.width, 20, 1, "info 20")
        assertNear(icon.minX - bar.minX, 12, 1, "内边距 12")
        assertNear(body.rect.minX - icon.maxX, 8, 1.5, "图标到文字 8")
        XCTAssertEqual(body.text, try center.deps.texts.text("privacy.basic_mode.notice"))
        try assertBase("privacy.basic.notice.text", 14, "提示句 14")
        try assertInk(image, "privacy.basic.notice.text", CouliColor.textPrimary, "主文字")
        let edge = CGRect(x: bar.minX + 2, y: bar.midY - 6, width: 6, height: 12)
        assertFill(image, edge, pixel(CouliColor.backgroundMuted, dark: false), "muted 底", tolerance: 2)
        assertNear(docs.minY - bar.maxY, Board.cardGap, 1.5, "提示条 → 清单 12")
        assertNear(title.minY - card.minY, 16, 2, "卡内边距 16")
        assertNear(button.minY - title.maxY, 12, 1.5, "标题 → 按钮 12（无副句）")
        assertNear(card.maxY - button.maxY, 16, 1.5, "下 16")
        try assertBase("privacy.basic.title", 17, "标题")
        assertNear(button.width, Board.width - 32, 1, "通栏")
        try assertPrimary(image, "privacy.enableFull.button", "【开启完整功能】")
        XCTAssertFalse(allTexts.contains(try center.deps.texts.text("privacy_center.basic_desc")), "G-P08")
        XCTAssertTrue(has("privacy.permissions.title"), "基本模式保留系统权限")
    }

    // MARK: - 强更上下文

    func testForceUpdateContext() async throws {
        try await openPrivacy(Scene(session: "privacy_force_update"), waitFor: "privacy.withdraw.button")
        let docs = try rect("privacy.docs")
        try assertNear(rect("privacy.withdraw.card").minY - docs.maxY, Board.cardGap, 1.5, "清单 → 撤回 12")
        XCTAssertFalse(has("privacy.personalization.card"))
        XCTAssertFalse(has("privacy.permissions.title"))
        XCTAssertFalse(has("privacy.enableFull.button"))
    }

    // MARK: - 确认框（G-P09）

    /// DS 页内覆盖层（brief §7 写的 `.alert` 不准，a 组已核）：标题居中、正文 14 主文字、次左主右。
    func testWithdrawDialog() async throws {
        try await openPrivacy()
        try askWithdraw()
        let image = try await privacyFrame("privacy.dialog.withdraw.panel")
        let id = "privacy.dialog.withdraw"
        let panel = try rect(id + ".panel")
        assertNear(panel.width, Board.dialogWidth, 1, "DS 确认框宽")
        // v2：DS 覆盖层在内容区（导航栏以下、安全区以上）居中，不是窗口中线；判据从 ±40 收到 ±2
        let canvas = try XCTUnwrap(page?.canvas)
        try assertNear(panel.midY, (navBottom() + canvas.height - canvas.bottom) / 2, 2, "内容区垂直居中")
        let pixels = ProductVisualPixels(image)
        let ground = pixel(CouliColor.backgroundSurface, dark: false)
        let title = try rect(id + ".title")
        let band = CGRect(x: panel.minX + 4, y: title.minY, width: panel.width - 8, height: title.height)
        let left = try XCTUnwrap(inkLeft(pixels, in: band, background: ground), "标题没有墨迹")
        let right = try XCTUnwrap(inkRight(pixels, in: band, background: ground), "标题没有墨迹")
        XCTAssertTrue(SettingsVisualJudge.centered(inkLeft: left, inkRight: right, in: panel), "标题墨迹居中（现状靠左）")
        try assertBase(id + ".message", 14, "正文 14")
        try assertInk(image, id + ".message", CouliColor.textPrimary, "正文主文字")
        let primary = try record(id + ".primary")
        let secondary = try record(id + ".secondary")
        XCTAssertEqual(primary.text, "取消", "主 = 取消")
        XCTAssertEqual(secondary.text, "确认撤回", "次 = 确认撤回")
        XCTAssertLessThan(secondary.rect.maxX, primary.rect.minX + 0.5, "次左主右")
        XCTAssertTrue(sameRow(primary.rect, secondary.rect), "同一行")
        XCTAssertGreaterThanOrEqual(primary.rect.height, 47.5, "主 min 48")
        XCTAssertGreaterThanOrEqual(secondary.rect.height, 47.5, "次 min 48")
        try assertPrimary(image, id + ".primary", "取消是主按钮")
        try assertSecondary(image, id + ".secondary", "确认撤回是普通次按钮（G-P17）")
    }
}
