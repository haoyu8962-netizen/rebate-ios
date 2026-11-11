@testable import Couli
import DesignSystem
import Foundation
import SwiftUI
import UIKit
import Wallet
import XCTest

/// FU-IOS-NUM-WRAP / D10-1249 ②（tests v2 补）：提现「放弃上一笔」确认弹窗的灰底明细——上一笔的金额与收款账号（脱敏）
/// 四档下不在数字中间断（`DigitsRunJudge`：整段一行或整段换行、放不下框内横滑，不截不缩，横滑条不裁上下半截）。
/// 走生产路径：压力规则 + 输入 999999999.00 → 提交断连进待确认 → 【放弃上一次提交】弹出确认弹窗。
@MainActor
final class DigitsWrapAbandonTests: WithdrawVisualTestCase {
    func testAbandonDialogDigitsNeverBreakAllTiers() async throws {
        for tier in DigitsRunJudge.tiers {
            let (host, _) = try await openWithdraw(
                "stress", estimate: "stress",
                canvas: .init(width: tier.width, height: tier.accessibility ? 3400 : 1600, dark: tier.dark,
                              size: tier.size)
            )
            try await enterPending(amount: "999999999.00")
            host.flowActions?.askAbandon()
            let shot = await host.stable {
                $0.flow?.state.abandonConfirmKey != nil && $0.probes["abandon.detail.1.value"] != nil
            }
            XCTAssertNotNil(shot, "\(tier.name)：放弃确认弹窗没有稳定画面")
            let amount = try record("abandon.detail.0.value")
            let account = try record("abandon.detail.1.value")
            XCTAssertEqual(amount.text, WithdrawVisualData.money(99_999_999_900), "\(tier.name)：前提——上一笔是压力金额")
            XCTAssertEqual(account.text, "支付宝 138****5678", "\(tier.name)：前提——收款账号（脱敏）")
            let box = try rect("abandon.detail")
            var problems: [String] = []
            for item in [amount, account] {
                problems += DigitsRunJudge.problems(item, container: box, window: host.window, tier: tier)
            }
            XCTAssertEqual(problems, [], "放弃确认弹窗 \(tier.name)")
        }
    }
}
