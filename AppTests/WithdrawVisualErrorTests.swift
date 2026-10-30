@testable import Couli
import CouliNetwork
import DesignSystem
import Foundation
import SwiftUI
import UIKit
import Wallet
import WalletCore
import XCTest

/// W49 / W50 / G-W13（WithdrawPageStates ⑫⑬）：金额类提交错误的显示位置。只动视图：`SensitiveOutcome` 分类、输入、提交次数都不变。
@MainActor
final class WithdrawVisualErrorTests: WithdrawVisualTestCase {
    /// W49 / W50 / G-W13：金额类提交错误在金额框下（14 红 + 16 图标、框描边红），页顶不重复；输入保留。
    func testW49W50AmountErrorsBelowBox() async throws {
        let reasons: [String?] = [nil, "below_min", "not_multiple", "above_max", "above_method_max", "net_too_small"]
        for reason in reasons {
            let code = reason == nil ? 30301 : 30303
            let key = reason.map { "error.30303.\($0)" } ?? "error.30301"
            let (host, _) = try await openWithdraw(amount: "10", estimate: "estimated")
            let data = reason.map { "{\"reason\":\"\($0)\"}" } ?? "null"
            host.server.script.fail("POST /v1/withdrawals", code, data: data)
            host.actions?.submit()
            let shot = await host.stable { $0.flow?.state.error != nil && $0.probes["withdraw.fieldError.text"] != nil }
            XCTAssertEqual(host.flow?.state.error?.key, key, "分类不变（SensitiveOutcome 不动）")
            XCTAssertNil(host.flow?.state.fieldErrorKey, "不被改成 20001 字段错误")
            XCTAssertEqual(host.controller?.state.amountText, "10", "输入保留")
            XCTAssertEqual(submits.count, 1, "\(key)：提交恰一次")
            XCTAssertFalse(has("withdraw.flowError"), "\(key)：页顶不重复")
            let error = try rect("withdraw.fieldError")
            try XCTAssertLessThanOrEqual(rect("withdraw.amount.box").maxY, error.minY + 0.5, "\(key)：在金额框下")
            try assertInside(error, rect("withdraw.amountCard"), "\(key)：在金额卡内")
            try assertBase("withdraw.fieldError.text", 14, key)
            try assertNear(rect("withdraw.fieldError.icon").width, 16, 1, "图标 16")
            let image = try XCTUnwrap(shot)
            XCTAssertTrue(try inkMostly(image, in: rect("withdraw.fieldError.text"), CouliColor.statusErrorText,
                                        not: CouliColor.textPrimary), "\(key)：错误色")
            let box = try rect("withdraw.amount.box")
            let border = ProductVisualPixels(image).row(at: box.midY, from: box.minX - 1, to: box.minX + 2)
            XCTAssertTrue(border.contains { $0.near(pixel(CouliColor.statusErrorText, dark: false), tolerance: 30) },
                          "\(key)：框描边红")
        }
    }

    /// G-W13 反面：白名单外仍在页顶（账户冻结、payee_daily_users、self_purchase_required）。
    func testW49NonAmountErrorsStayOnTop() async throws {
        for reason in ["account_frozen", "payee_daily_users", "self_purchase_required"] {
            let (host, _) = try await openWithdraw(amount: "10", estimate: "estimated")
            host.server.script.fail("POST /v1/withdrawals", 30303, data: "{\"reason\":\"\(reason)\"}")
            host.actions?.submit()
            _ = await host.stable { $0.flow?.state.error != nil && $0.probes["withdraw.flowError"] != nil }
            XCTAssertFalse(has("withdraw.fieldError"), "\(reason) 不下移")
            try XCTAssertLessThan(rect("withdraw.flowError").maxY, rect("withdraw.balance").minY + 0.5, "\(reason) 在页顶")
        }
    }

    /// 20001 字段错误（既有路径）样式同 W50，仍在金额框下、仍只一次提交。
    func testW50FieldError20001Style() async throws {
        let (host, _) = try await openWithdraw(amount: "10", estimate: "estimated")
        host.server.script.fail("POST /v1/withdrawals", 20001, data: "{\"fields\":[\"amount_fen\"]}")
        host.actions?.submit()
        _ = await host.stable { $0.flow?.state.fieldErrorKey != nil && $0.probes["withdraw.fieldError.text"] != nil }
        try assertBase("withdraw.fieldError.text", 14, "14（底版 14 无图标）")
        try assertNear(rect("withdraw.fieldError.icon").width, 16, 1, "图标 16")
    }

    /// G-W13 / 评审 r1 S2-2（测试 v3）：金额类提交错误说的是提交时的金额，改金额后错误行、红框及时消失，页顶也不冒出来，不发写请求；
    /// `flow.error` 不动（只管显示）；再提交失败错误重新出现。先正（报错时都在）后反。
    func testW49AmountErrorClearsOnEdit() async throws {
        let reasons: [String?] = [nil, "below_min", "not_multiple", "above_max", "above_method_max", "net_too_small"]
        for reason in reasons {
            let key = reason.map { "error.30303.\($0)" } ?? "error.30301"
            let (host, _) = try await openWithdraw(amount: "10", estimate: "estimated")
            let data = reason.map { "{\"reason\":\"\($0)\"}" } ?? "null"
            host.server.script.fail("POST /v1/withdrawals", reason == nil ? 30301 : 30303, data: data)
            host.actions?.submit()
            let before = await host
                .stable { $0.flow?.state.error != nil && $0.probes["withdraw.fieldError.text"] != nil }
            try XCTAssertTrue(boxIsRed(XCTUnwrap(before)), "\(key)：前提，框是红的")
            let written = writes
            host.actions?.amount("11")
            await waitUntil("\(key)：改金额后错误行没有消失", timeout: 2) { !self.has("withdraw.fieldError") }
            let after = await host
                .stable { $0.controller?.state.estimate != .calculating && $0.probes["withdraw.fieldError"] == nil }
            XCTAssertFalse(has("withdraw.fieldError.text"), "\(key)：错误字消失")
            XCTAssertFalse(has("withdraw.flowError"), "\(key)：不挪到页顶")
            try XCTAssertFalse(boxIsRed(XCTUnwrap(after)), "\(key)：红框消失")
            XCTAssertEqual(host.controller?.state.amountText, "11", "\(key)：金额是新值")
            XCTAssertEqual(host.flow?.state.error?.key, key, "\(key)：只管显示，`flow.error` 不动")
            XCTAssertEqual(writes, written, "\(key)：改金额不发写请求")
            host.actions?.submit()
            _ = await host.stable { $0.probes["withdraw.fieldError.text"] != nil }
            XCTAssertEqual(submits.count, 2, "\(key)：再提交恰一次")
            XCTAssertEqual(try text("withdraw.fieldError.text"), texts.text(key), "\(key)：新一次失败错误重新出现")
        }
    }

    /// 反面：非金额类错误不随改金额消失（账户冻结这类跟金额无关，不能被顺手清掉）。
    func testW49NonAmountErrorSurvivesEdit() async throws {
        let (host, _) = try await openWithdraw(amount: "10", estimate: "estimated")
        host.server.script.fail("POST /v1/withdrawals", 30303, data: "{\"reason\":\"account_frozen\"}")
        host.actions?.submit()
        _ = await host.stable { $0.flow?.state.error != nil && $0.probes["withdraw.flowError"] != nil }
        host.actions?.amount("11")
        _ = await host
            .stable { $0.controller?.state.amountText == "11" && $0.controller?.state.estimate != .calculating }
        XCTAssertTrue(has("withdraw.flowError"), "页顶错误还在")
    }

    /// 金额框左缘有错误色描边。
    private func boxIsRed(_ image: UIImage) throws -> Bool {
        let box = try rect("withdraw.amount.box")
        return ProductVisualPixels(image).row(at: box.midY, from: box.minX - 1, to: box.minX + 2)
            .contains { $0.near(pixel(CouliColor.statusErrorText, dark: false), tolerance: 30) }
    }
}
