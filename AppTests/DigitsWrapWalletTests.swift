@testable import Couli
import DesignSystem
import Foundation
import SwiftUI
import UIKit
import Wallet
import XCTest

/// FU-IOS-NUM-WRAP ②（QA-11 iOS #2：`state-long-font200-w320-light` 可提现大数「¥9876543 / .21」）：钱包红色主卡大数、冻结中 / 已提现、
/// 预估卡金额四档下不在中间断（判据见 `DigitsRunJudge`；放不下只能整段换行、上下排或框内横滑，不缩字）。
@MainActor
final class DigitsWrapWalletTests: WalletVisualTestCase {
    func testWalletBalanceDigitsNeverBreakAllTiers() async throws {
        for tier in DigitsRunJudge.tiers {
            let canvas = WalletVisualHost.Canvas(width: tier.width, height: tier.accessibility ? 2600 : 1400,
                                                 dark: tier.dark, size: tier.size)
            let (page, _) = try await openWallet("long_amounts", canvas: canvas, waitFor: "wallet.hero.amount")
            let hero = try rect("wallet.hero")
            var problems: [String] = []
            for id in ["wallet.hero.amount", "wallet.hero.frozen.value", "wallet.hero.withdrawn.value"] {
                problems += try DigitsRunJudge.problems(record(id), weight: .semibold, container: hero,
                                                        window: page.window, tier: tier)
            }
            if page.probes["wallet.estimate.left.value"] != nil {
                problems += try DigitsRunJudge.problems(record("wallet.estimate.left.value"), weight: .semibold,
                                                        container: rect("wallet.estimate"), window: page.window,
                                                        tier: tier)
            }
            XCTAssertEqual(problems, [], "钱包 \(tier.name)")
        }
    }

    /// v4（D10-1265）：主卡大数横滑的档必须有截断提示（末端渐隐 + 指示器、从开头露出）；冻结中 / 已提现 / 预估等放得下的金额没有提示。
    /// 四档里至少一档主卡大数确实横滑（不空过），正常档不横滑。
    func testHeroScrollHintOnlyWhenScrolling() async throws {
        var scrolledTiers: [String] = []
        for tier in DigitsRunJudge.tiers {
            let canvas = WalletVisualHost.Canvas(width: tier.width, height: tier.accessibility ? 2600 : 1400,
                                                 dark: tier.dark, size: tier.size)
            let (page, image) = try await openWallet("long_amounts", canvas: canvas, waitFor: "wallet.hero.amount")
            let shot = ScrollHintJudge.Shot(image: image, window: page.window)
            let hero = try rect("wallet.hero")
            var problems: [String] = []
            var ids = ["wallet.hero.amount", "wallet.hero.frozen.value", "wallet.hero.withdrawn.value"]
            if page.probes["wallet.estimate.left.value"] != nil {
                ids.append("wallet.estimate.left.value")
            }
            for id in ids {
                let container = try id.hasPrefix("wallet.estimate") ? rect("wallet.estimate") : hero
                let outcome = try ScrollHintJudge.judge("\(tier.name) \(id)", text: rect(id),
                                                        hint: page.probes[id + ".scrollHint"], container: container,
                                                        shot: shot)
                problems += outcome.problems
                if outcome.scrolled, id == "wallet.hero.amount" {
                    scrolledTiers.append(tier.name)
                }
                if !tier.accessibility, outcome.scrolled {
                    problems.append("\(tier.name) \(id)：正常档不该横滑")
                }
            }
            XCTAssertEqual(problems, [], "钱包截断提示 \(tier.name)")
        }
        XCTAssertFalse(scrolledTiers.isEmpty, "前提：四档里至少一档主卡大数横滑（否则提示没被测到）")
    }
}
