@testable import Couli
import CouliNetwork
import DesignSystem
import Foundation
import SwiftUI
import UIKit
import Wallet
import WalletCore
import XCTest

/// W69–W78、W86 版式（画板 PayoutAccount / Bank-v2 / Bound / BoundBank）。先正后反；缺测量即红（交回 §4 测量桥）。
@MainActor
final class PayoutVisualLayoutTests: PayoutVisualTestCase {
    /// W69：内容上 8、左右 16、块间 12（表单态）。
    func testW69FormInsets() async throws {
        try await openPayout()
        let top = try pageViewport().minY
        let intro = try rect("payout.intro")
        assertNear(intro.minY - top, 8, 1, "首块距导航栏 8")
        try assertSideInsets("payout.methodCard", "单选卡")
        try assertSideInsets("payout.formCard", "表单卡")
        try assertNear(rect("payout.methodCard").minY - intro.maxY, 12, 1, "块间 12")
        try assertNear(rect("payout.formCard").minY - rect("payout.methodCard").maxY, 12, 1, "两卡间 12")
    }

    /// W69：已绑定卡上 8。
    func testW69BoundInsets() async throws {
        try await openPayout("boundAlipay")
        let card = try rect("payout.boundCard")
        try assertNear(card.minY - pageViewport().minY, 8, 1, "已绑定卡距导航栏 8")
        try assertSideInsets("payout.boundCard", "已绑定卡")
        try assertNear(rect("payout.note").minY - card.maxY, 12, 1, "卡外 INFO 间距 12")
    }

    /// W70：说明句卡外、14 次文字、缩进 4（左缘 20）。
    func testW70IntroOutsideCard() async throws {
        let (_, image) = try await openPayout()
        let intro = try rect("payout.intro")
        try assertBase("payout.intro", 14, "说明句")
        assertNear(intro.minX, 20, 0.5, "缩进 4")
        try XCTAssertLessThanOrEqual(intro.maxY, rect("payout.methodCard").minY + 0.5, "在单选卡之上（卡外）")
        XCTAssertTrue(inkMostly(image, in: intro, CouliColor.textSecondary, not: CouliColor.textPrimary), "次文字")
    }

    /// W71：单选独立成卡；圈 24；选中品牌描边 7 + 白心；未选控件边；标题 17；说明 12；项间分隔线；命中不重叠。
    func testW71MethodCard() async throws {
        let (_, image) = try await openPayout()
        let card = try rect("payout.methodCard")
        let alipay = try rect("payout.method.alipay.radio")
        let bank = try rect("payout.method.bank.radio")
        assertNear(alipay.width, 24, 1, "圈 24")
        assertNear(bank.width, 24, 1, "圈 24")
        XCTAssertTrue(PayoutVisualJudges.isThickRing(
            image, alipay, ring: pixel(CouliColor.brandPrimary, dark: false),
            center: pixel(CouliColor.backgroundSurface, dark: false)
        ), "选中：品牌描边 7、白心（不是实心 + 小白点）")
        let ring = ProductVisualPixels(image).color(at: CGPoint(x: bank.midX, y: bank.minY + 5))
        XCTAssertFalse(ring.near(pixel(CouliColor.brandPrimary, dark: false), tolerance: 40), "未选不带品牌色")
        try assertBase("payout.method.alipay.title", 17, "标题 17")
        try assertBase("payout.method.bank.title", 17, "标题 17")
        try assertBase("payout.method.alipay.desc", 12, "说明 12")
        try assertBase("payout.method.bank.desc", 12, "说明 12")
        try assertBase("payout.method.label", 14, "「收款方式」14")
        let divider = try rect("payout.method.divider")
        assertNear(divider.height, 1, 0.6, "分隔线 1")
        try XCTAssertGreaterThanOrEqual(divider.minY, rect("payout.method.alipay").maxY - 0.5)
        try XCTAssertLessThanOrEqual(divider.maxY, rect("payout.method.bank").minY + 0.5)
        try assertHit("payout.method.alipay.hit", covers: "payout.method.alipay.radio", "支付宝命中")
        try assertHit("payout.method.bank.hit", covers: "payout.method.bank.radio", "银行卡命中")
        try assertDisjoint(rect("payout.method.alipay.hit"), rect("payout.method.bank.hit"), "两项命中不重叠")
        try assertInside(rect("payout.method.bank.hit"), card, "命中在卡内")
    }

    /// W71：换选中后描边跟着走，表单切到银行卡字段（G-W29 只有两项、只写文字）。
    func testW71SwitchMovesRing() async throws {
        let (host, _) = try await openPayout()
        host.payoutActions?.method(WalletJSON.bankCard)
        let shot = await host.stable { $0.probes["payout.field.card_no.box"] != nil }
        let image = try XCTUnwrap(shot)
        try XCTAssertTrue(PayoutVisualJudges.isThickRing(
            image, rect("payout.method.bank.radio"), ring: pixel(CouliColor.brandPrimary, dark: false),
            center: pixel(CouliColor.backgroundSurface, dark: false)
        ), "选中移到银行卡")
        XCTAssertFalse(has("payout.field.alipay_logon_id.box"), "支付宝字段收起")
        XCTAssertEqual(host.payout?.state.form.method, WalletJSON.bankCard)
        XCTAssertFalse(pageTexts.contains { $0.contains("微信") }, "G-W29：不出微信")
    }

    /// W72：标签与框 8、框高 48、字段间 16。
    func testW72FieldSpacing() async throws {
        try await openPayout()
        try assertField("alipay_logon_id", "payout", "支付宝账号")
        try assertField("payee_name", "payout", "收款人")
        try assertNear(rect("payout.field.payee_name.label").minY - rect("payout.field.alipay_logon_id.box").maxY,
                       16, 1, "字段间 16")
    }

    /// W73：「须与实名认证的姓名一致」紧贴姓名框下 12 次文字。
    func testW73PayeeNote() async throws {
        let (_, image) = try await openPayout()
        let note = try rect("payout.payeeNote")
        try assertBase("payout.payeeNote", 12, "提示 12")
        try assertNear(note.minY - rect("payout.field.payee_name.box").maxY, 8, 1, "紧贴框下 8")
        try assertInside(note, rect("payout.formCard"), "在表单卡内")
        XCTAssertTrue(inkMostly(image, in: note, CouliColor.textSecondary, not: CouliColor.textPrimary), "次文字")
    }

    /// W74：保存说明是卡外 INFO 条。
    func testW74SaveNote() async throws {
        let (_, image) = try await openPayout()
        try XCTAssertEqual(text("payout.saveNote.text"), "保存时需要短信验证")
        try assertInfoBar("payout.saveNote", image: image, "保存说明")
        try XCTAssertGreaterThanOrEqual(rect("payout.saveNote").minY, rect("payout.formCard").maxY, "在表单卡之外")
    }

    /// W75 / G-W23：银行卡保留开户行输入；说明同为「保存时需要短信验证」，不承诺三要素核验。
    func testW75BankForm() async throws {
        try await openPayout(method: WalletJSON.bankCard, waitFor: "payout.field.card_no.box")
        try assertField("card_no", "payout", "卡号")
        try assertField("bank_name", "payout", "开户行")
        try assertField("payee_name", "payout", "收款人")
        try XCTAssertEqual(text("payout.saveNote.text"), "保存时需要短信验证", "G-W23")
        XCTAssertFalse(pageTexts.contains { $0.contains("是否一致") }, "不再承诺三要素核验")
    }

    /// W76：底栏无底色（按钮外侧是画布色）、【保存】通栏。
    func testW76BottomBar() async throws {
        let (_, image) = try await openPayout()
        let save = try rect("payout.save")
        assertNear(save.height, 48, 1, "保存高 48")
        assertNear(save.minX, 16, 0.5, "保存左 16")
        let beside = ProductVisualPixels(image).color(at: CGPoint(x: 8, y: save.midY))
        XCTAssertTrue(beside.near(pixel(CouliColor.backgroundCanvas, dark: false), tolerance: 4),
                      "底栏无底色：按钮外侧应是画布色，实际 \(beside)")
    }

    /// W77：标题行 + 中性胶囊（支付宝）；账号 22 等宽；分隔线；两端对齐；描边次按钮；卡外 INFO。
    func testW77BoundAlipay() async throws {
        let (_, image) = try await openPayout("boundAlipay")
        let card = try rect("payout.boundCard")
        let label = try rect("payout.bound.currentLabel")
        let tag = try rect("payout.bound.methodTag")
        try assertBase("payout.bound.currentLabel", 14, "标题 14")
        XCTAssertTrue(sameRow(label, tag), "标题与胶囊同行")
        assertNear(card.maxX - tag.maxX, 16, 1, "胶囊贴卡右内边距")
        try assertBase("payout.bound.methodTag", 12, "胶囊 12")
        XCTAssertTrue(inkMostly(image, in: tag, CouliColor.textSecondary, not: CouliColor.brandPrimary), "中性胶囊")
        try background(image, "payout.bound.methodTag", CouliColor.backgroundMuted, minimum: 0.4, "胶囊浅灰底")
        try assertBase("payout.bound.account", 22, "账号 22")
        try XCTAssertEqual(text("payout.bound.account"), "138****5678", "只显示服务端脱敏值")
        try assertNotTruncated("payout.bound.account", "账号")
        let divider = try rect("payout.bound.divider")
        try XCTAssertGreaterThanOrEqual(divider.minY, rect("payout.bound.account").maxY - 0.5, "账号在分隔线上")
        try assertNear(rect("payout.bound.payee.label").minX - card.minX, 16, 1, "标签靠左")
        try assertNear(card.maxX - rect("payout.bound.payee.value").maxX, 16, 1, "值靠右")
        try assertNear(card.maxX - rect("payout.bound.remaining.value").maxX, 16, 1, "值靠右")
        try XCTAssertEqual(text("payout.bound.payee.value"), "**三")
        try XCTAssertEqual(text("payout.bound.remaining.value"), "2 次")
        try background(image, "payout.change", CouliColor.backgroundSurface, minimum: 0.5, "描边次按钮白底")
        try XCTAssertEqual(text("payout.note.text"), texts.text("payout.bound_note"))
        try assertInfoBar("payout.note", image: image, "不能解绑")
        try XCTAssertGreaterThanOrEqual(rect("payout.note").minY, card.maxY, "INFO 在卡外")
    }

    /// W77：银行卡（招商银行 尾号 1234）大字与胶囊。
    func testW77BoundBank() async throws {
        try await openPayout("boundBank")
        try XCTAssertEqual(text("payout.bound.methodTag"), texts.text("payout.channel.bank_card"))
        try assertBase("payout.bound.account", 22, "账号 22")
        let line = try text("payout.bound.account")
        XCTAssertTrue(line.contains("招商银行") && line.contains("尾号 1234"), line)
        try assertNotTruncated("payout.bound.account", "账号")
    }

    /// W78 / G-W21：次数 0 画成置灰：同一位置的按钮字迹与可点态不同（同字同版式，只差可用态）。
    func testW78ExhaustedLooksDisabled() async throws {
        let (_, normal) = try await openPayout("boundAlipay", waitFor: "payout.change.label")
        let enabled = try rect("payout.change.label")
        let (_, spent) = try await openPayout("boundExhausted", waitFor: "payout.change.label")
        try XCTAssertEqual(text("payout.bound.remaining.value"), "0 次")
        let label = try rect("payout.change.label")
        XCTAssertEqual(label, enabled, "前提：两态版式相同")
        XCTAssertNotEqual(ProductVisualPixels(normal).row(at: label.midY, from: label.minX, to: label.maxX),
                          ProductVisualPixels(spent).row(at: label.midY, from: label.minX, to: label.maxX),
                          "次数 0 应置灰（G-W21）")
    }

    /// W86：待确认时已绑定卡在待确认卡之下、【更换】置灰、点了不进表单（底版已符合，加位置断言）。
    func testW86PendingAboveBound() async throws {
        let (host, _) = try await openPayout("boundAlipay", editing: true, waitFor: "payout.intro")
        host.server.script.on("PUT /v1/me/payout-account", .disconnect)
        host.grantStepUp()
        try fillAlipay(host)
        host.payoutActions?.save()
        await waitUntil("没进待确认") { host.flow?.state.pending != nil }
        _ = await host.stable { $0.probes["pending.card"] != nil && $0.probes["payout.boundCard"] != nil }
        try XCTAssertLessThanOrEqual(rect("pending.card").maxY, rect("payout.boundCard").minY + 0.5, "待确认卡在上")
        XCTAssertFalse(has("payout.intro"), "表单收起")
    }

    /// W71 / W77 深色令牌（PayoutAccountBoundDark）。
    func testW87BoundDark() async throws {
        let (_, image) = try await openPayout("boundAlipay", canvas: .init(height: 1119, dark: true))
        try background(image, "payout.boundCard", CouliColor.backgroundSurface, dark: true, minimum: 0.5, "卡片深色面")
        try assertInfoBar("payout.note", image: image, dark: true, "不能解绑")
        try background(image, "payout.bound.methodTag", CouliColor.backgroundMuted, dark: true, minimum: 0.4, "胶囊")
    }
}
