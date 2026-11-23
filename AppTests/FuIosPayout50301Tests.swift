@testable import Couli
import CouliNetwork
import DesignSystem
import Foundation
import SwiftUI
import UIKit
import Wallet
import WalletCore
import XCTest

/// FU-IOS-PAYOUT-50301 写测（独立写测方，编排 D10-2774）：真实 App 组装 + 生产收款账号页 / 提现页 + 生产执行器，替身只有传输层。
/// 保存 / 提交收到 50301：页面错误是 error.50001 + trace6，不出现「维护中」；5xxxx 键结束、下次用新键（改前规则）；其他 5xxxx 文案不变。
@MainActor
final class FuIosPayout50301Tests: PayoutVisualTestCase {
    /// 假服务外壳的 trace_id（WalletStubServer.swift `stub-trace-0123456789ab`）末 6 位。
    private let stubTrace6 = "6789ab"

    /// 收款账号保存：50301 → 页顶错误条文字不含「维护中」、含 trace6，键 error.50001；再保存（50302）用新键、文案照旧 error.50302。
    func testPayoutSave50301ShowsUnifiedErrorWithTrace6() async throws {
        let host = try await openAndSave(.envelope(code: 50301, data: "null", headers: [:]))
        _ = await host.stable { $0.flow?.state.error != nil && $0.probes["payout.flowError.text"] != nil }
        XCTAssertEqual(host.flow?.state.error?.key, "error.50001", "50301 回落 error.50001")
        XCTAssertEqual(host.flow?.state.error?.showTrace6, true, "附 trace6")
        let shown = try text("payout.flowError.text")
        XCTAssertFalse(shown.contains("维护中"), "错误条不出现「维护中」，实得「\(shown)」")
        XCTAssertTrue(shown.contains(stubTrace6), "错误条附 trace6，实得「\(shown)」")
        XCTAssertEqual(saves.count, 1, "保存恰一次")
        let firstKey = saves.first?.header("Idempotency-Key")

        // 回归钉：键结束、下次新键；其他 5xxxx 文案不变
        host.server.script.on("PUT /v1/me/payout-account", .envelope(code: 50302, data: "null", headers: [:]))
        host.grantStepUp()
        host.payoutActions?.save()
        await waitUntil("再保存没有发出") { self.saves.count == 2 }
        _ = await host.stable {
            $0.flow?.state.error?.key == "error.50302" && $0.probes["payout.flowError.text"] != nil
        }
        XCTAssertEqual(host.flow?.state.error?.key, "error.50302", "50302 文案键不变")
        XCTAssertNotNil(firstKey, "前提：首次保存带幂等键")
        XCTAssertNotEqual(saves.last?.header("Idempotency-Key"), firstKey, "5xxxx 键结束，下次用新键（改前规则）")
    }

    /// 提现提交：50301 → flow 错误键 error.50001、统一消息含 trace6 不含「维护中」；再提交（50001）用新键、文案照旧。
    func testWithdrawSubmit50301ShowsUnifiedErrorWithTrace6() async throws {
        let (host, _) = try await openWithdraw(amount: "10", estimate: "estimated")
        host.server.script.on(
            "POST /v1/withdrawals",
            .envelope(code: 50301, data: "null", headers: [:]), .envelope(code: 50001, data: "null", headers: [:])
        )
        host.actions?.submit()
        _ = await host.stable { $0.flow?.state.error != nil && $0.probes["withdraw.flowError"] != nil }
        let error = try XCTUnwrap(host.flow?.state.error, "50301 要有页面错误")
        XCTAssertEqual(error.key, "error.50001", "50301 回落 error.50001")
        XCTAssertTrue(error.showTrace6, "附 trace6")
        let message = error.message(texts)
        XCTAssertFalse(message.contains("维护中"), "不出现「维护中」，实得「\(message)」")
        XCTAssertTrue(message.contains(stubTrace6), "附 trace6，实得「\(message)」")
        XCTAssertEqual(host.controller?.state.amountText, "10", "输入保留")
        XCTAssertEqual(submits.count, 1, "提交恰一次")
        let firstKey = submits.first?.header("Idempotency-Key")

        host.actions?.submit()
        await waitUntil("再提交没有发出") { self.submits.count == 2 }
        await waitUntil("再提交没有落定") { host.flow?.state.error?.id != error.id }
        XCTAssertEqual(host.flow?.state.error?.key, "error.50001", "50001 文案键不变")
        XCTAssertNotNil(firstKey, "前提：首次提交带幂等键")
        XCTAssertNotEqual(submits.last?.header("Idempotency-Key"), firstKey, "5xxxx 键结束，下次用新键（改前规则）")
    }
}
