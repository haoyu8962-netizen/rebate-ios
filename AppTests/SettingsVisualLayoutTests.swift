@testable import Couli
import DesignSystem
import Foundation
import MeCore
import UIKit
import XCTest

/// APP-12w-a 设置主页与弹层的结构 / 几何（brief §2 第 1–9 条，G-S03、04、05、07、08；iOS 命中区 44）。测量全部来自生产组件上报（编号见交回 §4）。
/// 容差：位置 ±1～1.5，块间距 ±3（字体度量差异）。字重量不出来，交基准与 compare。
@MainActor
final class SettingsVisualLayoutTests: SettingsVisualTestCase {
    private let chevronRows = ["nickname", "auth", "delete_account", "privacy_center", "agreement", "notify",
                               "clear_cache", "help", "about"]

    private func publicSetup() throws -> Setup {
        try Setup(routes: publicRoutes())
    }

    // MARK: - 分组与卡片

    /// 内容左右 16、导航栏下 8；分组名 12 号缩进 4、名到卡 8、组间 20；三组固定顺序。
    func testGroupsAndCards() async throws {
        try await open(publicSetup(), waitFor: "settings.group.general")
        let names = ["account", "privacy", "general"]
        var above: CGRect?
        for name in names {
            let id = "settings.group.\(name)"
            let card = try rect(id)
            let label = try record(id + ".title")
            assertNear(card.minX, 16, 1, "\(name) 卡左边距")
            assertNear(card.width, 358, 1, "\(name) 卡通栏")
            try assertBase(id + ".title", 12, "\(name) 分组名")
            assertNear(label.rect.minX, 20, 1, "\(name) 分组名左缩进 4")
            assertNear(card.minY - label.rect.maxY, 8, 2, "\(name) 名到卡 8")
            if let above {
                assertNear(label.rect.minY - above.maxY, 20, 2, "\(name) 组间 20")
            }
            above = card
        }
        try assertNear(rect("settings.group.account.title").minY - navBottom(), 8, 2, "内容上边距 8（现状 16）")
    }

    /// 行：标题 17、值 14、箭头 20、值到箭头 4、与卡内边距齐（卡内上下 4 左右 16）。
    /// 行高按 Settings-v2 PNG 实量（v2）：分隔线 y = 188 / 241 / 294，节距 53（行 52 + 线 1）；账号卡 132…351 = 219 = 4 + 52×4 + 1×3 + 4。
    /// 容差：行高 ±1、节距 ±1.5、卡高 ±3（字体度量差异）。「重新显示下单须知」不锁，见 v2 交回。
    func testRowMetrics() async throws {
        try await open(publicSetup(), waitFor: "settings.row.clear_cache.chevron")
        let card = try rect("settings.group.general")
        let id = "settings.row.clear_cache"
        let row = try rect(id)
        assertNear(row.height, 52, 1, "单行高 52（min 44 + 上下 4，Settings-v2 实量）")
        try assertNear(rect("settings.row.help").minY - row.minY, 53, 1.5, "行节距 53（行 52 + 分隔线 1）")
        assertNear(row.minX - card.minX, 16, 1, "左内边距 16")
        assertNear(card.maxX - row.maxX, 16, 1, "右内边距 16")
        try assertBase(id + ".title", 17, "标题")
        try assertBase(id + ".value", 14, "值")
        XCTAssertEqual(try text(id + ".value"), CacheSize.text(try SettingsVisualData.cacheBytes()), "值走 CacheSize")
        let chevron = try rect(id + ".chevron")
        assertNear(chevron.width, 20, 1, "箭头 20")
        assertNear(chevron.maxX, row.maxX, 1, "箭头贴行右")
        assertNear(try chevron.minX - rect(id + ".value").maxX, 4, 1.5, "值到箭头 4")
        let first = try rect("settings.row.nickname")
        let account = try rect("settings.group.account")
        assertNear(first.minY - account.minY, 4, 1, "卡内上 4")
        let last = try rect("settings.row.delete_account")
        assertNear(account.maxY - last.maxY, 4, 1, "卡内下 4")
        assertNear(account.height, 219, 3, "账号卡四行 219")
    }

    /// 分隔线只在行之间：n 行 n-1 条，高约 1，左右与卡内边距齐（现状 Divider 只缩左边）。
    func testDividersBetweenRows() async throws {
        try await open(publicSetup(), waitFor: "settings.group.privacy.divider.0")
        let card = try rect("settings.group.privacy")
        let line = try rect("settings.group.privacy.divider.0")
        assertNear(line.minX - card.minX, 16, 1, "分隔线左齐")
        assertNear(card.maxX - line.maxX, 16, 1, "分隔线右齐")
        XCTAssertLessThanOrEqual(line.height, 1.01, "1 像素线")
        let upper = try rect("settings.row.privacy_center")
        let lower = try rect("settings.row.agreement")
        assertNear(line.midY - upper.maxY, 0.5, 1, "线贴上一行")
        assertNear(lower.minY - upper.maxY, 1, 1, "两行之间只隔这条线")
        XCTAssertFalse(has("settings.group.privacy.divider.1"), "两行一条")
        XCTAssertTrue(has("settings.group.account.divider.2"), "公开版账号组四行三条")
        XCTAssertFalse(has("settings.group.account.divider.3"), "最后一行下没有线")
    }

    /// 动作行、不可点行不画箭头（先正后反：导航行都有）；看测量也看像素，防只撤测量不撤图标。
    func testChevronOnlyOnNavigationRows() async throws {
        let (_, image) = try await open(publicSetup(), waitFor: "settings.row.notify.chevron")
        for name in chevronRows {
            XCTAssertTrue(has("settings.row.\(name).chevron"), "\(name) 有箭头")
        }
        for name in ["reset_tip", "phone"] {
            XCTAssertFalse(has("settings.row.\(name).chevron"), "\(name) 不画箭头（BR-ATTR-21 / 现状不可点）")
        }
        let action = try rect("settings.row.reset_tip")
        let corner = CGRect(x: action.maxX - 24, y: action.minY + 8, width: 24, height: action.height - 16)
        XCTAssertEqual(count(image, in: corner, near: pixel(CouliColor.textSecondary, dark: false), tolerance: 40), 0,
                       "「重新显示下单须知」右侧没有箭头墨迹")
    }

    /// G-S04：手机号维持「已绑定 / 未绑定」，不拼脱敏号。
    func testPhoneValueKeepsBoundText() async throws {
        try await open(waitFor: "settings.row.phone.value")
        XCTAssertEqual(try text("settings.row.phone.value"), "已绑定")
        XCTAssertFalse(allTexts.contains { $0.contains("****") })
        try await open(Setup(profile: "settings_unbound"), waitFor: "settings.row.phone.chevron")
        XCTAssertEqual(try text("settings.row.phone.value"), "未绑定")
    }

    /// G-S05：公开版有「注销账号」且标题是字（现状 `settingsKeys` 没有这一行，标题空），内测版没有这一行；顺序在账号组末尾。
    func testDeleteRowFollowsRoutes() async throws {
        try await open(publicSetup(), waitFor: "settings.row.delete_account.title")
        XCTAssertEqual(try text("settings.row.delete_account.title"), "注销账号")
        let delete = try rect("settings.row.delete_account")
        XCTAssertGreaterThan(delete.minY, try rect("settings.row.auth").maxY - 1, "在授权管理之后")
        try await open(Setup(routes: SettingsVisualData.routes("routes_beta")), waitFor: "settings.row.auth")
        XCTAssertFalse(has("settings.row.delete_account"), "内测版没有注销行")
    }

    // MARK: - 剪贴板开关行（G-S11、G-S12）

    /// 标题 17 + 副标题 12、纵向 2、上下 8；开关靠右垂直居中，不挤压文字。
    func testClipboardRow() async throws {
        try await open(waitFor: "settings.row.clipboard_auto.subtitle")
        let id = "settings.row.clipboard_auto"
        let row = try rect(id)
        let title = try rect(id + ".title")
        let subtitle = try rect(id + ".subtitle")
        let toggle = try rect(id + ".switch")
        try assertBase(id + ".title", 17, "标题")
        try assertBase(id + ".subtitle", 12, "副标题")
        assertNear(subtitle.minY - title.maxY, 2, 1.5, "标题到副标题 2（现状 4）")
        assertNear(title.minY - row.minY, 8, 1.5, "上内边距 8（现状 12）")
        assertNear(row.maxY - subtitle.maxY, 8, 1.5, "下内边距 8")
        assertNear(toggle.maxX, row.maxX, 1, "开关靠右")
        assertNear(toggle.midY, row.midY, 1.5, "开关垂直居中")
        XCTAssertLessThanOrEqual(subtitle.maxX, toggle.minX + 0.5, "副标题不进开关")
        XCTAssertGreaterThanOrEqual(toggle.minX - subtitle.maxX, 8, "文字与开关留间距")
    }

    // MARK: - 底部（G-S08）

    /// 已登录：通栏次按钮，距上一张卡 20，高 48。
    func testLogoutButton() async throws {
        try await open(waitFor: "settings.logout.button")
        let button = try rect("settings.logout.button")
        assertNear(button.minX, 16, 1, "左边距")
        assertNear(button.width, 358, 1, "通栏")
        XCTAssertGreaterThanOrEqual(button.height, 47.5, "高 48")
        try assertNear(button.minY - rect("settings.group.general").maxY, 20, 2, "距上一张卡 20")
    }

    /// 游客：说明 14 居中 + 文字链接（命中 44、视觉不撑高、间距 8、不是主按钮）。条目顺序按 G-S03 不改。
    func testGuestFooterIsLink() async throws {
        let (_, image) = try await open(Setup(level: .guest), waitFor: "settings.guest.link")
        XCTAssertEqual(try settings.model().groups.flatMap(\.rows).map(\.id), [
            SettingsItems.idPrivacy, SettingsItems.idAgreement, SettingsItems.idAbout, SettingsItems.idClipboard,
            SettingsItems.idClearCache, SettingsItems.idHelp,
        ], "G-S03 顺序不改")
        let copy = try rect("settings.guest.text")
        let link = try record("settings.guest.link")
        try assertNear(rect("settings.row.about").height, 52, 1, "游客行高同已登录")
        try assertBase("settings.guest.text", 14, "说明")
        try assertBase("settings.guest.link", 14, "链接")
        XCTAssertEqual(link.text, "去登录")
        assertNear(copy.midX, 195, 1.5, "说明居中")
        assertNear(link.rect.midX, 195, 1.5, "链接居中")
        assertNear(link.rect.minY - copy.maxY, 8, 3, "说明到链接 8")
        XCTAssertLessThanOrEqual(link.rect.height, 24, "视觉高 = 文字行高")
        try assertHit("settings.guest.link.hit", covers: "settings.guest.link", "去登录")
        try assertDisjoint(rect("settings.guest.link.hit"), copy, "命中区不盖说明")
        XCTAssertEqual(count(image, in: link.rect, near: pixel(CouliColor.brandPrimary, dark: false), tolerance: 6), 0,
                       "不是实底按钮")
        XCTAssertGreaterThan(count(image, in: link.rect, near: pixel(CouliColor.textLink, dark: false)), 5, "链接色")
    }

    /// 基本模式：提示条（muted 底、圆角 12、内边距 12、info 20、14）+ 通栏主按钮。条目顺序按 G-S03 不改。
    func testBasicNoticeAndButton() async throws {
        let (_, image) = try await open(Setup(level: .basic), waitFor: "settings.basic.notice")
        XCTAssertEqual(try settings.model().groups.flatMap(\.rows).map(\.id), [
            SettingsItems.idPrivacy, SettingsItems.idAgreement, SettingsItems.idAbout, SettingsItems.idHelp,
        ], "G-S03 顺序不改")
        let bar = try rect("settings.basic.notice")
        let icon = try rect("settings.basic.notice.icon")
        let body = try record("settings.basic.notice.text")
        let button = try rect("settings.enableFull.button")
        XCTAssertEqual(body.text, try settings.deps.texts.text("privacy.basic_mode.notice"))
        try assertNear(rect("settings.row.about").height, 52, 1, "基本模式行高同已登录")
        try assertBase("settings.basic.notice.text", 14, "提示句")
        assertNear(bar.minX, 16, 1, "左边距")
        assertNear(bar.width, 358, 1, "通栏")
        assertNear(icon.width, 20, 1, "info 20")
        assertNear(icon.minX - bar.minX, 12, 1, "内边距 12")
        assertNear(icon.minY - bar.minY, 12, 2, "内边距 12")
        assertNear(body.rect.minX - icon.maxX, 8, 1.5, "图标到文字 8")
        try assertNear(bar.minY - rect("settings.group.main").maxY, 20, 2, "距卡 20")
        assertNear(button.minY - bar.maxY, 20, 2, "提示条到按钮 20")
        assertNear(button.width, 358, 1, "通栏主按钮")
        let edge = CGRect(x: bar.minX + 2, y: bar.midY - 6, width: 6, height: 12)
        XCTAssertGreaterThan(share(image, in: edge, near: pixel(CouliColor.backgroundMuted, dark: false), tolerance: 2),
                             0.8, "muted 底")
    }

    // MARK: - 协议半屏（G-S08）

    /// 半屏两条列表行（17、箭头 20、分隔线、≥44），不再是次按钮；把手、标题 17、上圆角面板通栏。
    func testAgreementSheetRows() async throws {
        try await open(waitFor: nil)
        try tapRow(SettingsItems.idAgreement)
        let image = try await frame("settings.agreement.privacy.title")
        let panel = try rect("settings.sheet.panel")
        assertNear(panel.width, 390, 1, "面板通栏")
        XCTAssertGreaterThanOrEqual(panel.maxY, 1065, "贴底（面板内容止于安全区，底色铺到屏底）")
        assertNear(try rect("settings.sheet.handle").width, 36, 1, "把手 36")
        try assertBase("settings.sheet.title", 17, "标题")
        XCTAssertEqual(try text("settings.sheet.title"), "用户协议与隐私政策")
        for (type, title) in [("agreement", "用户协议"), ("privacy", "隐私政策")] {
            let id = "settings.agreement.\(type)"
            let row = try rect(id)
            XCTAssertGreaterThanOrEqual(row.height, 43.5, "\(type) 行 ≥ 44")
            assertNear(row.minX, 16, 1, "\(type) 左边距")
            assertNear(row.width, 358, 1, "\(type) 通栏")
            XCTAssertEqual(try text(id + ".title"), title)
            try assertBase(id + ".title", 17, "\(type) 标题")
            assertNear(try rect(id + ".chevron").width, 20, 1, "\(type) 箭头")
        }
        let upper = try rect("settings.agreement.agreement")
        let line = try rect("settings.agreement.divider")
        assertNear(line.minX, upper.minX, 1, "分隔线齐")
        assertNear(line.midY, upper.maxY, 1.5, "分隔线在两行之间")
        // v2：只看上下边、避开箭头（v1 全行计数，4 个箭头抗锯齿像素误红）；判据有 Oracle.testOutlineJudge 证明真描边判红
        for type in ["agreement", "privacy"] {
            let id = "settings.agreement.\(type)"
            let chevron = try rect(id + ".chevron")
            XCTAssertEqual(outlineInk(image, try rect(id), right: chevron.minX - 2), 0, "\(type) 不是次按钮描边")
        }
    }

    // MARK: - 确认框（G-S07）

    private func assertTitleCentered(_ prefix: String, _ image: UIImage, file: StaticString = #filePath,
                                     line: UInt = #line) throws {
        let panel = try rect(prefix + ".panel", file: file, line: line)
        let title = try rect(prefix + ".title", file: file, line: line)
        let pixels = ProductVisualPixels(image)
        let ground = pixel(CouliColor.backgroundSurface, dark: false)
        let band = CGRect(x: panel.minX + 4, y: title.minY, width: panel.width - 8, height: title.height)
        let left = try XCTUnwrap(inkLeft(pixels, in: band, background: ground), "标题没有墨迹", file: file, line: line)
        let right = try XCTUnwrap(inkRight(pixels, in: band, background: ground), "标题没有墨迹", file: file, line: line)
        XCTAssertTrue(SettingsVisualJudge.centered(inkLeft: left, inkRight: right, in: panel),
                      "标题居中：墨迹 \(left)…\(right)，面板 \(panel)", file: file, line: line)
    }

    /// 清缓存：标题居中、正文 14、次左主右、左右 24、内边距 20、元素间 16。
    func testClearCacheDialog() async throws {
        try await open(waitFor: nil)
        try tapRow(SettingsItems.idClearCache)
        let image = try await frame("settings.dialog.clear.panel")
        let prefix = "settings.dialog.clear"
        let panel = try rect(prefix + ".panel")
        try assertTitleCentered(prefix, image)
        assertNear(panel.minX, 24, 1, "左右 24")
        assertNear(panel.width, 342, 1, "面板宽")
        let title = try rect(prefix + ".title")
        let message = try rect(prefix + ".message")
        let secondary = try rect(prefix + ".secondary")
        let primary = try rect(prefix + ".primary")
        try assertBase(prefix + ".message", 14, "正文")
        assertNear(title.minY - panel.minY, 20, 2, "内边距 20")
        assertNear(message.minY - title.maxY, 16, 3, "元素间 16")
        assertNear(secondary.minY - message.maxY, 16, 3, "元素间 16")
        XCTAssertTrue(sameRow(secondary, primary), "并排")
        XCTAssertLessThan(secondary.maxX, primary.minX, "次左主右")
        assertNear(primary.minX - secondary.maxX, 12, 1, "按钮间 12")
    }

    /// 退出：只有一句标题，没有正文块。
    func testLogoutDialog() async throws {
        try await open(waitFor: nil)
        try actions.askLogout()
        let image = try await frame("settings.dialog.logout.panel")
        let prefix = "settings.dialog.logout"
        try assertTitleCentered(prefix, image)
        XCTAssertEqual(try text(prefix + ".title"), "确定退出登录？")
        XCTAssertFalse(has(prefix + ".message"), "没有正文")
        let primary = try rect(prefix + ".primary")
        assertNear(try primary.minY - rect(prefix + ".title").maxY, 16, 3, "标题到按钮 16（不留空正文块）")
    }

    /// 确认框打开期间底层不可操作（覆盖层），点取消零动作（守卫，现状已符合）。
    func testDialogCancelZeroAction() async throws {
        let (host, _) = try await open(waitFor: nil)
        try tapRow(SettingsItems.idClearCache)
        let dialog = try XCTUnwrap(try settings.state.dialog)
        try actions.cancelDialog(dialog)
        await settle()
        XCTAssertNil(try settings.state.dialog)
        XCTAssertEqual(host.fixture.system.cleared, 0)
    }
}
