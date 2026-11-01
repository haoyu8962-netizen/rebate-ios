@testable import Couli
import DesignSystem
import Foundation
import MeCore
import SwiftUI
import UIKit
import XCTest

/// APP-12v「我的」结构 / 几何（brief §2，M1–M11、M13、M14 的 iOS 对应项；命中区 44pt，brief §4.3）。测量全部来自生产组件经 `couliProbe` 上报，
/// 文字取测量里的显示文字。字重量不出来，交快照基准与 compare（交回 §6）。容差：位置 ±1～1.5，块间距 ±3（字体度量差异）。
@MainActor
final class MeVisualLayoutTests: MeVisualTestCase {
    // MARK: - 页面骨架（M1）

    /// 左右 16、标题栏高 44、标题栏下 8、块间 12；标题 22 号左对齐。
    func testPageFrame() async throws {
        try await open()
        let bar = try rect("me.titleBar")
        assertNear(bar.height, 44, 1, "标题栏高 44")
        try assertBase("me.title", 22, "标题")
        assertNear(try rect("me.title").minX, 16, 1, "标题左对齐 16")
        let identity = try rect("me.identity")
        assertNear(identity.minY - bar.maxY, 8, 1, "标题栏下内容上边距 8（现状 12）")
        assertNear(identity.minX, 16, 1, "左边距 16")
        assertNear(identity.maxX, 374, 1, "右边距 16")
        let hero = try rect("me.hero")
        assertNear(hero.minY - identity.maxY, 12, 1, "身份卡 → 余额卡 12")
        var above = hero
        for group in ["orders_wallet", "promo", "more"] {
            let card = try rect("me.grid.\(group)")
            assertNear(card.minY - above.maxY, 12, 1, "\(group) 与上一块 12")
            assertNear(card.width, 358, 1, "\(group) 通栏")
            above = card
        }
    }

    /// 铃铛：视觉 24、命中 44 以图标为中心；不画未读红点（G-M09）。
    func testBellNoUnreadDot() async throws {
        let (_, image) = try await open()
        try assertHitCentered("me.bell.hit", covers: "me.bell.icon", visual: 24, "铃铛")
        let dot = try rect("me.bell.icon").insetBy(dx: -6, dy: -6)
        XCTAssertEqual(
            count(image, in: dot, near: pixel(CouliColor.brandPrimary, dark: false), tolerance: 30),
            0,
            "没有未读字段，不画红点"
        )
    }

    // MARK: - 通知引导条（M3、M4，G-M10）

    /// 中性底（background.muted，现状警告底）、次文字色铃铛 20、圆角 12、内边距 4/4/4/12；正文 14；关闭视觉 20、命中 44；两个目标不重叠。
    func testGuideBarNeutral() async throws {
        let (_, image) = try await open(Setup(hidden: true, guide: true), waitFor: "me.guideBar")
        let bar = try rect("me.guideBar")
        assertNear(bar.minX, 16, 1, "左边距 16")
        assertNear(bar.width, 358, 1, "通栏")
        assertNear(try rect("me.identity").minY - bar.maxY, 12, 1, "引导条 → 身份卡 12")
        try assertNear(bar.minY - rect("me.titleBar").maxY, 8, 1, "标题栏下 8")
        let icon = try rect("me.guideBar.icon")
        assertNear(icon.width, 20, 1, "铃铛 20")
        assertNear(icon.minX - bar.minX, 12, 1, "左内边距 12")
        try assertBase("me.guideBar.text", 14, "正文")
        try assertHitCentered("me.guideBar.close.hit", covers: "me.guideBar.close", visual: 20, "关闭")
        let close = try rect("me.guideBar.close.hit")
        assertNear(bar.maxX - close.maxX, 4, 1.5, "右内边距 4")
        XCTAssertGreaterThanOrEqual(close.minY - bar.minY, 3, "上内边距 ≥ 4")
        XCTAssertGreaterThanOrEqual(bar.maxY - close.maxY, 3, "下内边距 ≥ 4")
        let body = try rect("me.guideBar.open.hit")
        XCTAssertGreaterThanOrEqual(body.height, 43.5, "正文命中 ≥ 44")
        assertDisjoint(body, close, "正文 / 关闭 命中区")
        let edge = CGRect(x: bar.minX + 2, y: bar.midY - 8, width: 6, height: 16)
        XCTAssertGreaterThan(
            share(image, in: edge, near: pixel(CouliColor.backgroundMuted, dark: false), tolerance: 2),
            0.8,
            "底色是 background.muted"
        )
        XCTAssertLessThan(count(image, in: icon, near: pixel(CouliColor.statusWarningText, dark: false)), 5, "铃铛不再是警告色")
        XCTAssertGreaterThan(count(image, in: icon, near: pixel(CouliColor.textSecondary, dark: false)), 5, "铃铛次文字色")
    }

    /// 「去开启」链接样式：测量给出尾段文字，整句文字不变；链接色墨迹落在尾段框内。
    func testGuideBarLinkTail() async throws {
        let (host, image) = try await open(Setup(hidden: true, guide: true), waitFor: "me.guideBar.cta")
        XCTAssertEqual(try text("me.guideBar.text"), host.texts.text("perm.push.guide_bar"), "整句")
        XCTAssertEqual(try text("me.guideBar.cta"), "去开启", "最后一个句号之后的尾段")
        let cta = try rect("me.guideBar.cta")
        assertInside(cta, try rect("me.guideBar.text"), "尾段在正文框内")
        XCTAssertGreaterThan(count(image, in: cta, near: pixel(CouliColor.textLink, dark: false)), 20, "链接色")
    }

    /// G-M10 切分（走生产页面，测试不实现切分）：尾 1 / 8 字切；无句号、句尾空、尾 9 字回退整句普通样式（先正后反）。
    func testGuideBarSplitCases() async throws {
        let cases: [(String, String?)] = [
            ("通知没有开启。去", "去"),
            ("通知没有开启。一二三四五六七八", "一二三四五六七八"),
            ("第一句。第二句。去开启", "去开启"),
            ("通知没有开启去开启", nil),
            ("通知没有开启。", nil),
            ("通知没有开启。一二三四五六七八九", nil),
        ]
        for (sentence, tail) in cases {
            let setup = Setup(hidden: true, guide: true, custom: true,
                              overrides: ["perm.push.guide_bar": sentence])
            try await open(setup, waitFor: "me.guideBar.text")
            XCTAssertEqual(try text("me.guideBar.text"), sentence, "整句不丢字")
            if let tail {
                XCTAssertEqual(try text("me.guideBar.cta"), tail, sentence)
            } else {
                XCTAssertFalse(has("me.guideBar.cta"), "\(sentence)：回退整句普通样式")
            }
        }
    }

    /// 切分结论不残留（APP-08v-a r1 S2-1）：同一页面文案换成不可切后，上一份的链接样式清除。
    func testGuideBarSplitNotStale() async throws {
        let setup = Setup(hidden: true, guide: true, custom: true,
                          overrides: ["perm.push.guide_bar": "通知没有开启。去开启"])
        let (host, _) = try await open(setup, waitFor: "me.guideBar.cta")
        host.custom?.texts?.set("perm.push.guide_bar", "通知没有开启")
        host.fixture.me.mask.set(false)
        _ = try await frame { !$0.probes.records.keys.contains("me.guideBar.cta") }
        XCTAssertEqual(try text("me.guideBar.text"), "通知没有开启")
    }

    // MARK: - 身份卡（M5–M8）

    /// 内边距 16、横向 12、头像 56 + 人形 32、昵称 17、纵向 4；卡高 88（56 + 上下 16）。
    func testIdentityCardGeometry() async throws {
        try await open(waitFor: "me.avatar")
        let card = try rect("me.identity")
        let avatar = try rect("me.avatar")
        assertNear(avatar.width, 56, 0.5, "头像宽")
        assertNear(avatar.height, 56, 0.5, "头像高")
        assertNear(try rect("me.avatar.icon").width, 32, 1, "人形 32")
        assertNear(avatar.minX - card.minX, 16, 1, "左内边距 16")
        assertNear(card.height, 88, 3, "卡高 = 头像 + 上下 16")
        let name = try rect("me.nickname")
        assertNear(name.minX - avatar.maxX, 12, 1, "横向 12")
        try assertBase("me.nickname", 17, "昵称")
        XCTAssertEqual(try text("me.nickname"), "凑狸用户")
        assertNear(try rect("me.invite.row").minY - name.maxY, 4, 1.5, "右栏纵向 4")
    }

    /// M8：一条流式行，12 号；码紧随标签；复制紧随码（视觉 16、命中 44 以图标为中心、不撑高本行：行高 18）；默认宽度下邀请人同行。
    func testInviteRowFlow() async throws {
        let (_, image) = try await open(waitFor: "me.invite.row")
        let row = try rect("me.invite.row")
        assertNear(row.height, 18, 1.5, "行高 18（命中区不撑高）")
        try assertBase("me.invite.label", 12, "「我的邀请码」")
        try assertBase("me.invite.code", 12, "码")
        try assertBase("me.invite.inviter", 12, "邀请人")
        XCTAssertEqual(try text("me.invite.code"), "K7M3QX")
        XCTAssertEqual(try text("me.invite.inviter"), "邀请人：已绑定")
        try assertSameLine("me.invite.code", "me.invite.inviter", "默认宽度同一行")
        try assertSameLine("me.invite.code", "me.invite.copy", "复制同一行")
        let code = try rect("me.invite.code")
        let copy = try rect("me.invite.copy")
        XCTAssertGreaterThanOrEqual(copy.minX, code.maxX - 0.5, "复制在码之后")
        XCTAssertLessThanOrEqual(copy.minX - code.maxX, 10, "复制紧随码末字")
        XCTAssertGreaterThanOrEqual(try rect("me.invite.inviter").minX - copy.maxX, 11, "项间 12")
        try assertHitCentered("me.invite.copy.hit", covers: "me.invite.copy", visual: 16, "复制")
        XCTAssertGreaterThan(count(image, in: copy, near: pixel(CouliColor.textLink, dark: false)), 5, "复制图标链接色")
    }

    /// G-M08 / G05：invite_code=null 整段邀请码不显示、不显示原因；邀请人仍在；「推广与邀请」组照常（不按 null 推断未成年）。
    func testNoInviteCodeHidesOnlyTheCode() async throws {
        let (host, _) = try await open(Setup(profile: "me_no_invite_code"), waitFor: "me.invite.inviter")
        for id in ["me.invite.label", "me.invite.code", "me.invite.copy", "me.invite.copy.hit"] {
            XCTAssertFalse(has(id), "\(id) 不显示")
        }
        XCTAssertTrue(host.controller.view(host.repo.state, masked: false).grid.contains { $0.item == "邀请好友" })
        XCTAssertTrue(has("me.grid.promo"), "推广与邀请组照常（G-M08）")
    }

    /// 可补填数据下身份卡「未绑定」、码 R8T4WN、¥0；补填条不显示（G-M06）。
    func testBackfillEligibleStillNoStrip() async throws {
        try await open(Setup(profile: "me_new_user"), waitFor: "me.invite.inviter")
        XCTAssertEqual(try text("me.invite.inviter"), "邀请人：未绑定")
        XCTAssertEqual(try text("me.invite.code"), "R8T4WN")
        XCTAssertFalse(allTexts.contains { $0.contains("补填") || $0.contains("去填写") }, "G-M06 不显示补填条")
    }

    // MARK: - 余额卡（M9–M11）

    /// 内边距 20、首行紧凑（≤ 24，不被眼睛 44 命中撑高）、眼睛 20 间距 4、行距 12。
    func testHeroHeaderCompact() async throws {
        try await open(waitFor: "me.hero.titleRow")
        let hero = try rect("me.hero")
        let row = try rect("me.hero.titleRow")
        XCTAssertLessThanOrEqual(row.height, 24, "首行视觉高")
        assertNear(row.minY - hero.minY, 20, 1.5, "上内边距 20")
        let title = try rect("me.hero.title")
        assertNear(title.minX - hero.minX, 20, 1, "左内边距 20")
        try assertBase("me.hero.title", 14, "可提现余额")
        XCTAssertEqual(try text("me.hero.title"), "可提现余额")
        try assertHitCentered("me.hero.eye.hit", covers: "me.hero.eye", visual: 20, "眼睛")
        assertNear(try rect("me.hero.eye").minX - title.maxX, 4, 1.5, "眼睛紧贴标题 4")
    }

    /// 大数 34、【提现】最小宽 96 视觉高 48、同行；与首行 12、与预估块 12。
    func testHeroAmountRow() async throws {
        try await open(waitFor: "me.hero.withdraw")
        try assertBase("me.hero.amount", 34, "大数")
        let amount = try rect("me.hero.amount")
        let button = try rect("me.hero.withdraw")
        XCTAssertGreaterThanOrEqual(button.width, 95.5, "最小宽 96")
        assertNear(button.height, 48, 1, "视觉高 48")
        XCTAssertTrue(sameRow(amount, button), "同行")
        assertNear(try rect("me.hero").maxX - button.maxX, 20, 1, "右内边距 20")
        let rowTop = min(amount.minY, button.minY)
        let rowBottom = max(amount.maxY, button.maxY)
        try assertNear(rowTop - rect("me.hero.titleRow").maxY, 12, 3, "首行 → 第二行 12")
        assertNear(try rect("me.estimate").minY - rowBottom, 12, 3, "第二行 → 预估块 12")
    }

    /// M11：钟表 14 + 标签 14、数值 22、纵向 2；到卡底 20；不出现无字段的两行（G-M02）。
    func testEstimateBlock() async throws {
        try await open(waitFor: "me.estimate")
        assertNear(try rect("me.estimate.clock").width, 14, 1, "钟表 14（现状 16）")
        try assertBase("me.estimate.label", 14, "预估收益")
        try assertBase("me.estimate.value", 22, "数值")
        XCTAssertEqual(try text("me.estimate.label"), "预估收益")
        try assertNear(try rect("me.estimate.value").minY - rect("me.estimate.label").maxY, 2, 1.5, "纵向 2")
        try assertNear(try rect("me.hero").maxY - rect("me.estimate").maxY, 20, 1.5, "下内边距 20")
        XCTAssertFalse(allTexts.contains { $0.contains("其中已收货") || $0.contains("最早预计") }, "G-M02 不显示")
    }

    /// 金额隐藏：眼睛换带斜线（判据只比「离谁近」）；显示态是睁眼。
    func testHiddenEyeIcon() async throws {
        let solid = CouliColor.token("rebate.solid.background")
        let white = CouliColor.token("rebate.solid.text")
        let candidates = ["eye", "eye.slash"]
        let (_, shown) = try await open(waitFor: "me.hero.eye")
        let opened = await nearestIcon(shown, in: try rect("me.hero.eye"), candidates: candidates, background: solid,
                                       ink: white)
        XCTAssertEqual(opened, "eye")
        let (_, hidden) = try await open(Setup(hidden: true), waitFor: "me.hero.eye")
        let closed = await nearestIcon(hidden, in: try rect("me.hero.eye"), candidates: candidates, background: solid,
                                       ink: white)
        XCTAssertEqual(closed, "eye.slash")
    }
}

extension MeVisualLayoutTests {
    // MARK: - 宫格（M14）

    /// 每组一张白卡：左右下 8、上 16、标题缩进 8、标题 17、4 列、格高 ≥ 72、图标 24；顺序照 brief §2.8；无收藏夹 / 分享赚（G-M07）。
    func testGridGeometryAndOrder() async throws {
        try await open(waitFor: "me.grid.more")
        let groups: [(String, [String])] = [
            ("orders_wallet", ["我的订单", "钱包", "余额流水", "找回订单"]),
            ("promo", ["邀请好友"]),
            ("more", ["帮助中心", "联系客服", "授权管理", "设置"]),
        ]
        for (group, items) in groups {
            let card = try rect("me.grid.\(group)")
            let title = try rect("me.grid.\(group).title")
            try assertBase("me.grid.\(group).title", 17, "\(group) 标题")
            assertNear(title.minY - card.minY, 16, 2, "\(group) 上 16")
            assertNear(title.minX - card.minX, 16, 1, "\(group) 标题 = 卡内 8 + 缩进 8")
            var left = card.minX + 8
            for item in items {
                let cell = try rect("me.cell.\(item)")
                assertNear(cell.minX, left, 1, "\(item) 顺次排列、卡内左 8")
                assertNear(cell.width, (358 - 16) / 4, 1, "\(item) 4 列")
                XCTAssertGreaterThanOrEqual(cell.height, 71.5, "\(item) 格高 ≥ 72")
                assertInside(try rect("me.cell.\(item).icon"), cell, "\(item) 图标在格内")
                assertNear(try rect("me.cell.\(item).icon").width, 24, 1, "\(item) 图标 24")
                left = cell.maxX
            }
            try assertNear(card.maxY - rect("me.cell.\(items[0])").maxY, 8, 1.5, "\(group) 下 8")
        }
        for gone in ["收藏夹", "分享赚", "收益看板"] {
            XCTAssertFalse(has("me.cell.\(gone)"), "\(gone) 不显示（G-M07，内测路由）")
        }
    }

    /// 公开版：收益看板紧跟邀请好友、图标是柱状图（G-M17，现状 trend）；开关或路由任一不满足都不显示。
    func testEarningsCellBarChart() async throws {
        let routes = try MeVisualData.routes("routes_public")
        let (_, image) = try await open(Setup(custom: true, routes: routes, earnings: true),
                                        waitFor: "me.cell.收益看板.icon")
        assertNear(try rect("me.cell.收益看板").minX, try rect("me.cell.邀请好友").maxX, 1, "缺格顺次前移")
        let nearest = await nearestIcon(image, in: try rect("me.cell.收益看板.icon"),
                                        candidates: ["chart.bar", "chart.line.uptrend.xyaxis"],
                                        background: CouliColor.backgroundSurface, ink: CouliColor.textPrimary)
        XCTAssertEqual(nearest, "chart.bar", "收益看板 = 柱状图")
        let beta = try MeVisualData.routes("routes_beta")
        for (name, available, flag) in [("开关关", routes, false), ("路由缺", beta, true)] {
            try await open(Setup(custom: true, routes: available, earnings: flag), waitFor: "me.cell.邀请好友")
            XCTAssertFalse(has("me.cell.收益看板"), name)
        }
    }

    // MARK: - 游客（M13）

    /// 内边距 16、行与按钮 16、标题 17、说明 14、通栏【登录 / 注册】视觉 48；无铃铛、余额卡、引导条；只有「更多服务」两格。
    func testGuestCard() async throws {
        let setup = Setup(profile: nil, canvas: .init(height: 844), guest: true, phase: nil)
        let (host, _) = try await open(setup, waitFor: "me.guest.login")
        let card = try rect("me.guest")
        let avatar = try rect("me.avatar")
        assertNear(card.minX, 16, 1, "左边距 16")
        assertNear(avatar.minX - card.minX, 16, 1, "内边距 16")
        assertNear(avatar.minY - card.minY, 16, 1, "内边距 16")
        assertNear(avatar.width, 56, 0.5, "头像 56")
        try assertBase("me.guest.title", 17, "标题")
        try assertBase("me.guest.desc", 14, "说明")
        let login = try rect("me.guest.login")
        assertNear(login.height, 48, 1, "按钮视觉 48")
        assertNear(login.minX - card.minX, 16, 1, "按钮通栏")
        assertNear(card.maxX - login.maxX, 16, 1, "按钮通栏")
        assertNear(login.minY - avatar.maxY, 16, 1.5, "行与按钮 16")
        assertNear(card.maxY - login.maxY, 16, 1, "下内边距 16")
        assertNear(try rect("me.titleBar").height, 44, 1, "标题栏高 44")
        try assertNear(card.minY - rect("me.titleBar").maxY, 8, 1, "标题栏下 8")
        for id in ["me.bell.icon", "me.hero", "me.guideBar", "me.identity", "me.grid.orders_wallet", "me.grid.promo"] {
            XCTAssertFalse(has(id), "游客没有 \(id)")
        }
        assertNear(try rect("me.grid.more").minY - card.maxY, 12, 1, "更多服务在下方 12")
        XCTAssertTrue(has("me.cell.帮助中心"))
        XCTAssertTrue(has("me.cell.设置"))
        XCTAssertFalse(has("me.cell.联系客服"))
        XCTAssertEqual(host.repo.state.phase, .idle, "游客不读 getMe")
    }
}
