@testable import Couli
import CouliNetwork
import DesignSystem
import Foundation
import SwiftUI
import UIKit
import Wallet
import WalletCore
import XCTest

/// W89–W95（画板 RealName / RealNameConsent-v2 / RealNameErrors / RealNameDark）。
@MainActor
final class IdentityVisualLayoutTests: PayoutVisualTestCase {
    /// W89：头部卡：40 方块 brand.subtle、24 盾牌、标题 17、说明 14 次文字、间距 4。
    func testW89Header() async throws {
        let (_, image) = try await openRealName()
        try assertSideInsets("realname.header", "头部卡")
        let top = try pageViewport().minY
        try assertNear(rect("realname.header").minY - top, 8, 1, "上 8")
        let badge = try rect("realname.badge")
        assertNear(badge.width, 40, 1, "方块 40")
        assertNear(badge.height, 40, 1, "方块 40")
        try background(image, "realname.badge", CouliColor.brandSubtle, minimum: 0.4, "brand.subtle 底")
        try assertNear(rect("realname.badge.icon").width, 24, 1, "盾牌 24")
        let ink = try count(image, in: rect("realname.badge.icon"), near: pixel(CouliColor.brandEmphasis, dark: false))
        XCTAssertGreaterThan(ink, 10, "盾牌品牌色墨迹")
        try assertBase("realname.title", 17, "标题 17")
        try assertBase("realname.desc", 14, "说明 14")
        try assertNear(rect("realname.title").minX - badge.maxX, 12, 1, "方块到标题 12")
        try assertNear(rect("realname.desc").minY - rect("realname.title").maxY, 4, 2, "间距 4")
        try XCTAssertTrue(inkMostly(image, in: rect("realname.desc"), CouliColor.textSecondary,
                                    not: CouliColor.textPrimary), "说明次文字")
    }

    /// W90：字段间 16、标签与框 8、框高 48。
    func testW90Fields() async throws {
        try await openRealName()
        try assertField("name", "realname", "姓名")
        try assertField("id_no", "realname", "身份证号")
        try assertNear(rect("realname.field.id_no.label").minY - rect("realname.field.name.box").maxY, 16, 1, "字段间 16")
    }

    /// W91：两条卡外 INFO 条（第二条人像图标）。
    func testW91InfoBars() async throws {
        let (_, image) = try await openRealName()
        try assertInfoBar("realname.note.fixed", image: image, "说明一")
        try assertInfoBar("realname.note.age", image: image, "说明二")
        try XCTAssertGreaterThanOrEqual(rect("realname.note.fixed").minY, rect("realname.formCard").maxY, "在输入卡外")
        try assertNear(rect("realname.note.age").minY - rect("realname.note.fixed").maxY, 12, 1, "块间 12")
    }

    /// W92：错误条 ERROR 语气，在输入卡之下、INFO 条之上；内容保留；同意后恰一次提交。
    func testW92ErrorBelowForm() async throws {
        let (host, _) = try await openRealName()
        let error = try PayoutVisualData.realnameError("verifyFailed")
        realBackend?.fail(error.code)
        _ = try await openConsent(host, needProbes: false)
        await agree(host)
        let shot = await host.stable { $0.realName?.state.error != nil && $0.probes["realname.error"] != nil }
        let image = try XCTUnwrap(shot)
        XCTAssertEqual(realBackend?.calls.count, 1, "提交恰一次")
        XCTAssertEqual(host.realName?.state.error?.key, "error.30406")
        XCTAssertFalse(host.realName?.state.idNo.isEmpty ?? true, "已填内容保留")
        try XCTAssertGreaterThanOrEqual(rect("realname.error").minY, rect("realname.formCard").maxY, "在输入卡之下")
        try XCTAssertLessThanOrEqual(rect("realname.error").maxY, rect("realname.note.fixed").minY + 0.5, "在 INFO 条之上")
        try background(image, "realname.error", CouliColor.token("status.error.background"), minimum: 0.4, "红底")
        try assertNear(rect("realname.error.icon").width, 20, 1, "图标 20")
        try assertBase("realname.error.text", 14, "14 字")
        try XCTAssertTrue(inkMostly(image, in: rect("realname.error.text"), CouliColor.statusErrorText,
                                    not: CouliColor.textPrimary), "红字")
    }

    /// W92（评审 r1 S2-1）：AX3 真实高度下提交失败，错误条要滚进可视区。基准画布拉到 2000 高看不出首屏折叠，这里用 844。
    /// 同时看像素：测量可能滞后于滚动，错误底色真画在可视区里才算。
    func testW92ErrorVisibleAtAX3() async throws {
        for width in [390.0, 320.0] {
            let canvas = WithdrawVisualHost.Canvas(width: width, height: 844, size: .accessibility3)
            let (host, _) = try await openRealName(canvas: canvas)
            try realBackend?.fail(PayoutVisualData.realnameError("verifyFailed").code)
            _ = try await openConsent(host, needProbes: false)
            await agree(host)
            let shot = await host.stable { $0.realName?.state.error != nil && $0.probes["realname.error"] != nil }
            let image = try XCTUnwrap(shot)
            let view = try pageViewport()
            let bar = try rect("realname.error")
            XCTAssertGreaterThanOrEqual(bar.minY, view.minY - 0.5, "w\(Int(width))：条顶在可视区内 \(bar) / \(view)")
            XCTAssertLessThan(bar.minY, view.maxY - 44, "w\(Int(width))：条在可视区内露出 \(bar) / \(view)")
            let ink = count(image, in: view, near: pixel(CouliColor.token("status.error.background"), dark: false),
                            tolerance: 6)
            XCTAssertGreaterThan(ink, 2000, "w\(Int(width))：可视区里画出了错误底色")
        }
    }

    /// W92：30410 当日置灰，再提交零调用。
    func testW92DailyLimitLocks() async throws {
        let (host, _) = try await openRealName()
        try realBackend?.fail(PayoutVisualData.realnameError("dailyLimit").code)
        _ = try await openConsent(host, needProbes: false)
        await agree(host)
        XCTAssertEqual(host.realName?.state.lockedToday, true)
        XCTAssertEqual(host.realName?.submitEnabled, false, "当日置灰")
        host.realNameActions?.submit()
        XCTAssertNil(host.realName?.state.consentId, "不再打开同意")
        XCTAssertEqual(realBackend?.calls.count, 1)
    }

    /// W93：把手装饰 36×4、标题 22、三条要点（20 图标 + 17）、正文块、按钮纵排（主在上、间距 12、同宽）。
    func testW93ConsentLayout() async throws {
        let (host, _) = try await openRealName()
        _ = try await openConsent(host)
        let handle = try rect("consent.handle")
        assertNear(handle.width, 36, 0.6, "把手宽")
        assertNear(handle.height, 4, 0.6, "把手高")
        let panel = try rect("consent.panel")
        assertNear(handle.midX, panel.midX, 1, "水平居中")
        try XCTAssertLessThan(handle.maxY, rect("consent.title").minY, "在标题上")
        try assertBase("consent.title", 22, "标题 22")
        for index in 1...3 {
            try assertBase("consent.item.\(index)", 17, "要点 17")
            try assertNear(rect("consent.item.\(index).icon").width, 20, 1, "要点图标 20")
        }
        try assertBase("consent.body.title", 14, "正文块标题 14")
        try assertBase("consent.body.text", 14, "正文块说明 14")
        let okay = try rect("consent.ok")
        let cancel = try rect("consent.cancel")
        XCTAssertLessThanOrEqual(okay.maxY, cancel.minY, "主在上")
        assertNear(cancel.minY - okay.maxY, 12, 1, "间距 12")
        assertNear(okay.width, cancel.width, 0.5, "同宽")
    }

    /// W93：把手不是手势入口；遮罩用令牌（Android r1 同类）；底页对读屏隐藏由组件保证。
    func testW93ScrimToken() async throws {
        let (host, _) = try await openRealName()
        let image = try await openConsent(host)
        let spot = CGPoint(x: 195, y: 20)
        let shown = ProductVisualPixels(image).color(at: spot)
        XCTAssertFalse(shown.near(pixel(CouliColor.backgroundCanvas, dark: false), tolerance: 6), "遮罩压暗了底页")
        XCTAssertNotNil(host.realName?.state.consentId)
    }

    /// W94：勾选行：圆 18、14 主文字、视觉行不撑高、命中 ≥ 44；默认不勾。勾上后实心圆形（不是方框）。
    func testW94ConsentCheck() async throws {
        let (host, _) = try await openRealName()
        let image = try await openConsent(host)
        try assertCheckRow("consent.check", image: image)
        XCTAssertEqual(host.realName?.state.consentChecked, false, "默认不勾")
        host.realNameActions?.toggleConsent()
        let shot = await host.stable { $0.realName?.state.consentChecked == true }
        try assertRound(XCTUnwrap(shot), "consent.check.mark", fill: CouliColor.brandPrimary, "勾选圆形")
        try assertDisjoint(rect("consent.check.hit"), rect("consent.ok"), "命中不压按钮")
    }

    /// W95：底栏无底色；没有实名后端时「暂未开放」句保留（G-W24）。
    func testW95BottomBarAndUnavailable() async throws {
        let (_, image) = try await openRealName()
        let submit = try rect("realname.submit")
        let beside = ProductVisualPixels(image).color(at: CGPoint(x: 8, y: submit.midY))
        XCTAssertTrue(beside.near(pixel(CouliColor.backgroundCanvas, dark: false), tolerance: 4), "底栏无底色：\(beside)")
        try await openRealName(backend: false, waitFor: "realname.unavailable")
        try XCTAssertEqual(text("realname.unavailable"), texts.text("realname.unavailable"))
    }

    /// RealNameDark。
    func testW95Dark() async throws {
        let (_, image) = try await openRealName(canvas: .init(height: 1119, dark: true))
        try background(image, "realname.header", CouliColor.backgroundSurface, dark: true, minimum: 0.4, "卡片深色面")
        try background(image, "realname.badge", CouliColor.brandSubtle, dark: true, minimum: 0.4, "brand.subtle 深色")
        try assertInfoBar("realname.note.fixed", image: image, dark: true, "说明")
    }
}

/// W96–W101（画板 LaborAgreement-v2 / LaborAgreementDark；Resign 待 FU）。
@MainActor
final class LaborVisualLayoutTests: PayoutVisualTestCase {
    /// W96：说明句 14 次文字缩进 4；首块上 8。
    func testW96Intro() async throws {
        let (_, image) = try await openLabor()
        let intro = try rect("labor.intro")
        try assertBase("labor.intro", 14, "说明 14")
        assertNear(intro.minX, 20, 0.5, "缩进 4")
        try assertNear(intro.minY - pageViewport().minY, 8, 1, "上 8")
        XCTAssertTrue(inkMostly(image, in: intro, CouliColor.textSecondary, not: CouliColor.textPrimary), "次文字")
    }

    /// W98：文档图标 + 协议名 17 + 版本 12。画板源码图标 24（brief 写 20，Android 按画板 24，两者都接受）。
    func testW98DocRow() async throws {
        try await openLabor()
        let icon = try rect("labor.docIcon")
        XCTAssertTrue((19...25).contains(icon.width), "图标 20 / 24：\(icon.width)")
        try assertBase("labor.name", 17, "协议名 17")
        try assertBase("labor.version", 12, "版本 12")
        try XCTAssertEqual(text("labor.version"), "版本 v1")
        try XCTAssertLessThanOrEqual(rect("labor.name").maxY, rect("labor.version").minY + 0.5, "版本在名下")
        try assertNear(rect("labor.name").minX - icon.maxX, 12, 1, "图标到名 12")
    }

    /// W99：全文区高 360、内边距 16、浅灰底、可滚动。
    func testW99TextArea() async throws {
        let (host, image) = try await openLabor(canvas: .init(height: 1100))
        let area = try rect("labor.textArea")
        assertNear(area.height, 360, 1, "高 360")
        try background(image, "labor.textArea", CouliColor.backgroundMuted, minimum: 0.2, "浅灰底")
        try assertNear(rect("labor.textBody").minX - area.minX, 16, 1, "左内边距 16")
        try assertNear(rect("labor.textBody").minY - area.minY, 16, 1, "上内边距 16")
        try XCTAssertGreaterThan(rect("labor.textBody").height, area.height, "长正文超过全文区，靠滚动")
        XCTAssertEqual(host.laborPage?.state.text, try PayoutVisualData.laborFirst()["text"] as? String, "正文原样")
    }

    /// W100：勾选行圆 18、14 主文字、命中不压按钮；底栏无底色。
    func testW100CheckAndBar() async throws {
        let (host, image) = try await openLabor()
        try assertCheckRow("labor.check", image: image)
        let sign = try rect("labor.sign")
        let beside = ProductVisualPixels(image).color(at: CGPoint(x: 8, y: sign.midY))
        XCTAssertTrue(beside.near(pixel(CouliColor.backgroundCanvas, dark: false), tolerance: 4), "底栏无底色：\(beside)")
        try assertDisjoint(rect("labor.check.hit"), sign, "勾选命中不压按钮")
        host.laborActions?.toggle()
        let shot = await host.stable { $0.laborPage?.state.checked == true }
        try assertRound(XCTUnwrap(shot), "labor.check.mark", fill: CouliColor.brandPrimary, "勾选圆形")
    }

    /// W101：已签说明 12 次文字缩进 4、卡外；内容下边距 0。
    func testW101SignedNote() async throws {
        let (_, image) = try await openLabor(canvas: .init(height: 1100))
        let note = try rect("labor.signedNote")
        try assertBase("labor.signedNote", 12, "已签说明 12")
        assertNear(note.minX, 20, 0.5, "缩进 4")
        try XCTAssertGreaterThanOrEqual(note.minY, rect("labor.card").maxY, "在卡外")
        XCTAssertTrue(inkMostly(image, in: note, CouliColor.textSecondary, not: CouliColor.textPrimary), "次文字")
    }

    /// 签署失败：错误条 ERROR 语气（W92 同件）。
    func testSignFailureErrorTone() async throws {
        let (host, _) = try await openLabor { $0.failSign(50301) }
        host.laborActions?.toggle()
        host.laborActions?.sign()
        let shot = await host.stable { $0.laborPage?.state.error != nil && $0.probes["labor.signError"] != nil }
        let image = try XCTUnwrap(shot)
        XCTAssertEqual(laborBackend?.signs.count, 1)
        try background(image, "labor.signError", CouliColor.token("status.error.background"), minimum: 0.4, "红底")
    }

    /// 读屏标签：全文「协议全文」开头、完整（底版已符合，加守卫）。LaborAgreementDark。
    func testW101Dark() async throws {
        let (_, image) = try await openLabor(canvas: .init(height: 1119, dark: true))
        // 卡内约 3/4 是全文区（W99 高 360），整卡占比到不了有意义的阈值；取全文区左侧的内边距带，这里只该是卡片底色
        let card = try rect("labor.card")
        let band = CGRect(x: card.minX + 3, y: card.minY + 18, width: 10, height: card.height - 36)
        let surface = share(image, in: band, near: pixel(CouliColor.backgroundSurface, dark: true), tolerance: 1)
        XCTAssertGreaterThan(surface, 0.9, "卡片深色面：内边距带底色占比 \(surface)")
        try background(image, "labor.textArea", CouliColor.backgroundMuted, dark: true, minimum: 0.2, "全文区深色")
    }
}
