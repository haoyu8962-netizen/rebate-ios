@testable import Couli
import CouliNetwork
import DesignSystem
import Foundation
import SwiftUI
import UIKit
import Wallet
import WalletCore
import XCTest

/// W79–W82、W83–W85（画板 PayoutAccountErrors ①–⑤、Pending 一族）。错误只换显示位置与语气，`SensitiveOutcome` 分类、键、请求次数都不动。
@MainActor
final class PayoutVisualErrorTests: PayoutVisualTestCase {
    private func failing(_ name: String) throws -> WalletStubProtocol.Reply {
        let error = try PayoutVisualData.saveError(name)
        return .envelope(code: error.code, data: error.data, headers: [:])
    }

    /// W79：30303 次数类是 WARNING 条（警告浅底、警告字色 14、20 三角），分类与键不变，保存恰一次。
    func testW79LimitsAreWarningBars() async throws {
        for (name, key) in [("changeLimit", "error.30303.payout_account_change_limit"),
                            ("verifyLimit", "error.30303.payout_account_verify_limit")] {
            let host = try await openAndSave(failing(name))
            let shot = await host.stable { $0.flow?.state.error != nil && $0.probes["payout.flowError"] != nil }
            let image = try XCTUnwrap(shot)
            XCTAssertEqual(host.flow?.state.error?.key, key, "键不变")
            XCTAssertEqual(saves.count, 1, "保存恰一次")
            try background(image, "payout.flowError", CouliColor.statusWarningBackground, minimum: 0.4, "\(key)：警告底")
            try assertNear(rect("payout.flowError.icon").width, 20, 1, "20 三角")
            try assertBase("payout.flowError.text", 14, "14 字")
            try XCTAssertTrue(inkMostly(image, in: rect("payout.flowError.text"), CouliColor.statusWarningText,
                                        not: CouliColor.textPrimary), "\(key)：警告字色")
            try XCTAssertEqual(text("payout.flowError.text"), texts.text(key))
        }
    }

    /// W80 / G-W13：30307 在收款人字段下，30308 在账号字段下：框红、14 红 + 16 三角，页顶不重复；键不变、不改成 20001、输入保留。
    func testW80ErrorsUnderFields() async throws {
        for (name, code, field) in [("payeeMismatch", "error.30307", PayoutAccountForm.payeeName),
                                    ("accountTaken", "error.30308", PayoutAccountForm.alipayLogonId)] {
            let host = try await openAndSave(failing(name))
            let probe = "payout.fieldError.\(field).text"
            let shot = await host.stable { $0.flow?.state.error != nil && $0.probes[probe] != nil }
            let image = try XCTUnwrap(shot)
            XCTAssertEqual(host.flow?.state.error?.key, code, "SensitiveOutcome 分类不变")
            XCTAssertNil(host.flow?.state.fieldErrorKey, "不改成 20001 字段错误")
            XCTAssertFalse(has("payout.flowError"), "\(code)：页顶不重复")
            XCTAssertEqual(saves.count, 1, "保存恰一次")
            XCTAssertFalse(host.payout?.state.form.alipayLogonId.isEmpty ?? true, "保留输入")
            try XCTAssertEqual(text(probe), texts.text(code))
            try assertBase(probe, 14, "字段错误 14")
            try assertNear(rect("payout.fieldError.\(field).icon").width, 16, 1, "16 三角")
            let box = try rect("payout.field.\(field).box")
            try XCTAssertLessThanOrEqual(box.maxY, rect(probe).minY + 0.5, "\(code)：紧贴本字段下")
            let border = ProductVisualPixels(image).row(at: box.midY, from: box.minX - 1, to: box.minX + 2)
            XCTAssertTrue(border.contains { $0.near(pixel(CouliColor.statusErrorText, dark: false), tolerance: 30) },
                          "\(code)：框描边红")
        }
    }

    /// W80：银行卡时 30308 在卡号字段下、开户行之上。
    func testW80BankCardNumberField() async throws {
        let (host, _) = try await openPayout()
        host.server.script.on("PUT /v1/me/payout-account", try failing("accountTaken"))
        host.grantStepUp()
        try fillBank(host)
        host.payoutActions?.save()
        let probe = "payout.fieldError.\(PayoutAccountForm.cardNo).text"
        _ = await host.stable { $0.flow?.state.error != nil && $0.probes[probe] != nil }
        XCTAssertEqual(host.flow?.state.error?.key, "error.30308")
        try XCTAssertLessThanOrEqual(rect(probe).maxY, rect("payout.field.bank_name.label").minY + 0.5, "在开户行之上")
    }

    /// G-W13 反面：白名单外（50001）仍在页顶。
    func testNonFieldErrorStaysOnTop() async throws {
        let host = try await openAndSave(.envelope(code: 50001, data: "null", headers: [:]))
        _ = await host.stable { $0.flow?.state.error != nil && $0.probes["payout.flowError"] != nil }
        XCTAssertTrue(has("payout.flowError"), "白名单外在页顶")
        XCTAssertFalse(has("payout.fieldError.\(PayoutAccountForm.payeeName).text"), "不进字段")
    }

    /// G-W13：改了收款人后，旧的 30307 不再按当前输入显示（c r1 S2-2 同类：错误挂在字段下会被读成针对当前内容）；执行器 flow.error 不动，再保存恰一次。
    func testW80StaleErrorClearsOnEdit() async throws {
        let host = try await openAndSave(failing("payeeMismatch"))
        let probe = "payout.fieldError.\(PayoutAccountForm.payeeName).text"
        _ = await host.stable { $0.probes[probe] != nil }
        XCTAssertTrue(has(probe), "前提：错误已显示")
        host.payoutActions?.payee("测试四")
        await waitUntil("改了内容后字段下的旧错误应消失") { !self.has(probe) }
        XCTAssertFalse(has("payout.flowError"), "不挪到页顶")
        XCTAssertEqual(saves.count, 1, "改内容零写")
        host.grantStepUp()
        host.payoutActions?.save()
        await waitUntil { self.saves.count == 2 }
    }

    /// W81 / G-W22：40901 中性（或警告）条，不是红底；没有转圈；按钮恢复；只发一次，不自动重发。
    func testW81BusyIsNeutral() async throws {
        let host = try await openAndSave(failing("busy"))
        let shot = await host.stable { $0.flow?.state.error != nil && $0.probes["payout.flowError"] != nil }
        let image = try XCTUnwrap(shot)
        XCTAssertEqual(host.flow?.state.error?.key, "error.40901")
        let bar = try rect("payout.flowError")
        let danger = pixel(CouliColor.token("status.error.background"), dark: false)
        XCTAssertLessThan(share(image, in: bar, near: danger, tolerance: 6), 0.1, "G-W22：不用红底")
        let muted = share(image, in: bar, near: pixel(CouliColor.backgroundMuted, dark: false), tolerance: 6)
        let warning = share(image, in: bar, near: pixel(CouliColor.statusWarningBackground, dark: false), tolerance: 6)
        XCTAssertGreaterThan(max(muted, warning), 0.4, "中性或警告底")
        try XCTAssertFalse(inkMostly(image, in: rect("payout.flowError.text"), CouliColor.statusErrorText,
                                     not: CouliColor.textPrimary), "字不是错误红")
        XCTAssertFalse(has("payout.flowError.spinner"), "不加常转圈")
        XCTAssertTrue(host.flow?.state.canSubmit ?? false, "按钮恢复")
        await quietWindow(0.6)
        XCTAssertEqual(saves.count, 1, "不自动重发")
    }

    /// W82 共用字段错误样式 + 本地校验：错误在本字段下、零写。
    func testW82LocalValidationStaysInField() async throws {
        let (host, _) = try await openPayout()
        host.payoutActions?.save()
        let probe = "payout.fieldError.\(PayoutAccountForm.alipayLogonId).text"
        _ = await host.stable { $0.probes[probe] != nil }
        try XCTAssertEqual(rect("payout.fieldError.\(PayoutAccountForm.alipayLogonId).icon").width.rounded(), 16)
        XCTAssertEqual(saves.count, 0, "本地校验零写")
        try XCTAssertLessThanOrEqual(rect("payout.field.alipay_logon_id.box").maxY, rect(probe).minY + 0.5)
    }

    /// W83：待确认摘要只显示本地脱敏值（银行卡只露尾号、姓名脱敏），不显示请求体明文。
    func testW83PendingShowsMaskedOnly() async throws {
        let (host, _) = try await openPayout(needProbes: false)
        host.server.script.on("PUT /v1/me/payout-account", .disconnect)
        host.grantStepUp()
        try fillBank(host)
        host.payoutActions?.save()
        await waitUntil("没进待确认") { host.flow?.state.pending != nil }
        _ = await host.stable { $0.probes["pending.detail"] != nil }
        let form = try PayoutVisualData.form("bank")
        let card = try XCTUnwrap(form["cardNo"])
        XCTAssertFalse(pageTexts.contains { $0.contains(card) }, "完整卡号不上屏")
        XCTAssertFalse(host.flow?.state.pending?.summary.contains(card) ?? true, "摘要不含完整卡号")
        XCTAssertFalse(host.flow?.state.pending?.summary.contains("张三") ?? true, "摘要不含完整姓名")
    }

    /// W83 / 共性第 2、67、76 条：收款账号读取失败时待确认卡照常可用：确认恰一次原键。
    func testW83PendingUsableWhenReadFails() async throws {
        let (host, _) = try await openPayout(needProbes: false)
        host.server.script.on("PUT /v1/me/payout-account", .disconnect)
        host.grantStepUp()
        try fillAlipay(host)
        host.payoutActions?.save()
        await waitUntil("没进待确认") { host.flow?.state.pending != nil }
        let key = saves.last?.header("Idempotency-Key")
        payoutServer?.setRead(.envelope(code: 50001, data: "null", headers: [:]))
        host.payoutActions?.retry()
        await waitUntil("读取失败态") { host.payout?.state.phase == .error }
        XCTAssertNotNil(host.flow?.state.pending, "待确认不随读取失败消失")
        host.server.script.on("PUT /v1/me/payout-account", .envelope(code: 0, data: "{}", headers: [:]))
        let before = saves.count
        host.flowActions?.confirm()
        await waitUntil("确认没有发出") { self.saves.count == before + 1 }
        XCTAssertEqual(saves.last?.header("Idempotency-Key"), key, "原键")
        await quietWindow(0.3)
        XCTAssertEqual(saves.count, before + 1, "恰一次")
    }
}
