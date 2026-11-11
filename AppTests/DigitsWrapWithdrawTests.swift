@testable import Couli
import DesignSystem
import Foundation
import SwiftUI
import UIKit
import Wallet
import XCTest

/// FU-IOS-NUM-WRAP ③（QA-11 iOS #3：`Withdraw-stress-font200-w320-dark` 余额「¥999999 / 999.99」、预计到账「¥87654321 / 0.98」、
/// 金额输入框撑成两行高「999999 / 999.00」）：提现页四档——余额卡大数、预计到账金额、收款账号（脱敏）不在中间断（`DigitsRunJudge`）；
/// 金额输入是单行系统框（`UITextField`，不是纵向可折行的 `UITextView`）、框高不超过一行、不缩字。
/// ADAPT-CHECK ①：【全部提现】大字号下折行或换到框下时要像按钮（`TextButtonJudge`）。
@MainActor
final class DigitsWrapWithdrawTests: WithdrawVisualTestCase {
    /// `height`：像素判提示的用例取 2600（截图物理像素不超过渲染上限 8192，超了整张黑）。
    private func openStress(_ tier: DigitsRunJudge.Tier,
                            height: CGFloat? = nil) async throws -> (WithdrawVisualHost, UIImage) {
        try await openWithdraw("stress", amount: "999999999.00", estimate: "stress",
                               canvas: .init(width: tier.width, height: height ?? (tier.accessibility ? 3400 : 1600),
                                             dark: tier.dark, size: tier.size),
                               waitFor: "withdraw.estimate")
    }

    func testWithdrawDigitsNeverBreakAllTiers() async throws {
        for tier in DigitsRunJudge.tiers {
            let (page, _) = try await openStress(tier)
            var problems: [String] = []
            problems += try DigitsRunJudge.problems(record("withdraw.balance.amount"), weight: .semibold,
                                                    container: rect("withdraw.balance"), window: page.window,
                                                    tier: tier)
            // 预计到账金额：测量框是整句（金额与括号说明同一段文字），按金额字号、字重量金额段必须 ≤ 整句最宽一行
            problems += try DigitsRunJudge.problems(record("withdraw.estimate.net"), weight: .semibold,
                                                    container: rect("withdraw.estimate.row"), window: page.window,
                                                    tier: tier)
            if page.probes["withdraw.payout.value"] != nil {
                problems += try DigitsRunJudge.problems(
                    record("withdraw.payout.value"),
                    container: rect("withdraw.payout"),
                    window: page.window,
                    tier: tier
                )
            }
            XCTAssertEqual(problems, [], "提现 \(tier.name)")
        }
    }

    func testInputStaysOneLineSystemFieldAllTiers() async throws {
        for tier in DigitsRunJudge.tiers {
            let (page, _) = try await openStress(tier)
            let box = try rect("withdraw.amount.box")
            let input = try record("withdraw.amount.input")
            XCTAssertEqual(input.text, "999999999.00", "\(tier.name)：前提——框里是压力金额")
            let line = DigitsRunJudge.lineHeight(input.fontSize, weight: .semibold)
            XCTAssertLessThan(input.rect.height, line * 1.8,
                              "\(tier.name)：金额输入撑成多行（高 \(input.rect.height)，单行行高 \(line)）")
            XCTAssertLessThan(
                box.height,
                max(line * 1.8, CouliHitTarget.minimum + CouliSpacing.s3) + CouliSpacing.s2 * 2,
                "\(tier.name)：金额框被撑高（\(box.height)）"
            )
            if tier.accessibility {
                XCTAssertGreaterThan(input.fontSize, input.baseFontSize * 1.3, "\(tier.name)：金额框字号真放大")
            }
            let controls = DigitsRunJudge.inputs(in: box, window: page.window)
            XCTAssertEqual(controls.areas.count, 0, "\(tier.name)：金额输入背后不能是可折行的 UITextView（axis: .vertical）")
            XCTAssertEqual(controls.fields.count, 1, "\(tier.name)：金额输入是恰一个单行 UITextField")
            for field in controls.fields {
                XCTAssertFalse(field.adjustsFontSizeToFitWidth, "\(tier.name)：不缩字（adjustsFontSizeToFitWidth）")
                XCTAssertGreaterThanOrEqual((field.font?.pointSize ?? 0) + 0.5, input.fontSize,
                                            "\(tier.name)：系统框实际字号不小于上报字号")
            }
        }
    }

    /// 【全部提现】：320 / 390 + 200%。所属行 = 金额框；折行或掉到框下时要有描边或底色，命中 ≥ 44。
    func testAllButtonLooksLikeButtonAtLargeText() async throws {
        for width: CGFloat in [320, 390] {
            let (_, image) = try await openWithdraw("normal", amount: "10", estimate: "estimated",
                                                    canvas: .init(width: width, height: 2600, size: .accessibility3),
                                                    waitFor: "withdraw.estimate")
            let label = try record("withdraw.all.label")
            let problems = try TextButtonJudge.problems(
                label: label, hit: rect("withdraw.all.hit"),
                anchorRow: rect("withdraw.amount.box"), image: image, name: "【全部提现】\(Int(width)) + 200%"
            )
            XCTAssertEqual(problems, [])
        }
    }

    /// v4（D10-1265）：提现页余额、预计到账金额、金额框（未聚焦时的横滑显示 `withdraw.amount.readout`）横滑的档必须有截断提示，
    /// 放得下的档没有；收款账号（非金额，本线定同样带提示）同判。余额、预计到账、金额框各至少一档横滑，正常档都不横滑。
    func testScrollHintOnlyWhenScrolling() async throws {
        var scrolled: [String: [String]] = [:]
        for tier in DigitsRunJudge.tiers {
            let (page, image) = try await openStress(tier, height: tier.accessibility ? 2600 : 1600)
            let shot = ScrollHintJudge.Shot(image: image, window: page.window)
            var problems: [String] = []
            var checks = [
                ("withdraw.balance.amount", "withdraw.balance"),
                ("withdraw.estimate.net", "withdraw.estimate.row"),
            ]
            if page.probes["withdraw.payout.value"] != nil {
                checks.append(("withdraw.payout.value", "withdraw.payout"))
            }
            for (id, box) in checks {
                let outcome = try ScrollHintJudge.judge("\(tier.name) \(id)", text: rect(id),
                                                        hint: page.probes[id + ".scrollHint"], container: rect(box),
                                                        shot: shot)
                problems += outcome.problems
                if outcome.scrolled {
                    scrolled[id, default: []].append(tier.name)
                }
            }
            // 金额框：没有文字测量，按框里那条能横滑的滚动视图判
            let box = try rect("withdraw.amount.box")
            let hint = page.probes["withdraw.amount.readout.scrollHint"]
            if let scroll = ScrollHintJudge.scroller(inside: box, window: page.window) {
                let text = scroll.convert(CGRect(origin: .zero, size: scroll.contentSize), to: nil)
                problems += ScrollHintJudge.scrolled("\(tier.name) 金额框", text: text, hint: hint, scroll: scroll,
                                                     image: image)
                scrolled["withdraw.amount.readout", default: []].append(tier.name)
            } else if let hint {
                problems.append("\(tier.name) 金额框：放得下却有截断提示 \(hint.rect)")
            }
            if !tier.accessibility {
                // 金额框例外：框本身窄，999999999.00 正常字号也放不下，横滑是对的
                problems += scrolled.filter { $0.key != "withdraw.amount.readout" && $0.value.contains(tier.name) }
                    .map { "\(tier.name) \($0.key)：正常档不该横滑" }
            }
            XCTAssertEqual(problems, [], "提现截断提示 \(tier.name)")
        }
        for id in ["withdraw.balance.amount", "withdraw.estimate.net", "withdraw.amount.readout"] {
            XCTAssertFalse(scrolled[id, default: []].isEmpty, "前提：\(id) 四档里至少一档横滑（\(scrolled)）")
        }
    }
}
