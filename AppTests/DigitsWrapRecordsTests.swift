@testable import Couli
import DesignSystem
import Foundation
import SwiftUI
import UIKit
import Wallet
import XCTest

/// FU-IOS-NUM-WRAP 另查（安卓 QA-11 `WithdrawRecordsPaid-v2-font200-w320-light` 同病：键值行右列金额、脱敏账号「138****567 / 8」、
/// 流水号按字符硬折）：提现记录展开卡的大数、键值行右列（金额 / 手续费 / 个税 / 到账、收款账号）与流水号四档下不在中间断
/// （`DigitsRunJudge`）。已到账单（PAID，含脱敏账号）与压力单（STRESS，¥9999999999.99、32 位流水号）都查。
@MainActor
final class DigitsWrapRecordsTests: RecordsVisualTestCase {
    func testRecordDetailDigitsNeverBreakAllTiers() async throws {
        for tier in DigitsRunJudge.tiers {
            let canvas = RecordsVisualHost.Canvas(width: tier.width, height: tier.accessibility ? 3200 : 1600,
                                                  dark: tier.dark, size: tier.size)
            var problems: [String] = []
            for (pageName, id) in [("list", "PAID"), ("stress", "STRESS")] {
                let (page, _) = try await openRecords(pageName, expand: [id], canvas: canvas)
                let card = try rect("records.detail.\(id)")
                let prefix = "records.detail.\(id)"
                var ids = [prefix + ".header.amount", prefix + ".tradeNo.value"]
                for key in ["amount", "fee", "tax", "net", "payout"] {
                    let field = prefix + ".field.\(key).value"
                    if page.probes[field] != nil {
                        ids.append(field)
                    }
                }
                for item in ids {
                    let weight: UIFont.Weight = item.hasSuffix(".header.amount") ? .bold : .regular
                    problems += try DigitsRunJudge.problems(record(item), weight: weight, container: card,
                                                            window: page.window, tier: tier)
                }
            }
            XCTAssertEqual(problems, [], "提现记录 \(tier.name)")
        }
    }

    /// v4（D10-1265，本线定非金额也带提示）：流水号（非金额数字串）横滑的档必须有截断提示，放得下的档没有；至少一档横滑。
    /// 同时钉 D10-1265 ①「先排法」：键值行右列金额 / 账号放不下同行时先整段换到下一行（独占一行），这时**不**横滑、没有提示——
    /// 四档里至少出现一次「值在标签下方独占一行、没横滑」。
    func testTradeNoScrollHintAndOwnLineBeforeScrolling() async throws {
        var tradeScrolled: [String] = []
        var ownLine: [String] = []
        for tier in DigitsRunJudge.tiers {
            let canvas = RecordsVisualHost.Canvas(
                width: tier.width,
                height: tier.accessibility ? 2600 : 1600, // 截图不超渲染上限
                dark: tier.dark,
                size: tier.size
            )
            var problems: [String] = []
            for (pageName, id) in [("list", "PAID"), ("stress", "STRESS")] {
                let (page, image) = try await openRecords(pageName, expand: [id], canvas: canvas)
                let shot = ScrollHintJudge.Shot(image: image, window: page.window)
                let prefix = "records.detail.\(id)"
                let card = try rect(prefix)
                let trade = try ScrollHintJudge.judge("\(tier.name) \(id) 流水号", text: rect(prefix + ".tradeNo.value"),
                                                      hint: page.probes[prefix + ".tradeNo.value.scrollHint"],
                                                      container: card, shot: shot)
                problems += trade.problems
                if trade.scrolled {
                    tradeScrolled.append("\(tier.name) \(id)")
                }
                for key in ["amount", "fee", "tax", "net", "payout"] {
                    let value = prefix + ".field.\(key).value"
                    guard let item = page.probes[value], let label = page.probes[prefix + ".field.\(key).label"] else {
                        continue
                    }
                    let outcome = ScrollHintJudge.judge("\(tier.name) \(value)", text: item.rect,
                                                        hint: page.probes[value + ".scrollHint"], container: card,
                                                        shot: shot)
                    problems += outcome.problems
                    if !outcome.scrolled, item.rect.minY >= label.rect.maxY - 0.5 {
                        ownLine.append("\(tier.name) \(value)")
                    }
                }
            }
            XCTAssertEqual(problems, [], "提现记录截断提示 \(tier.name)")
        }
        XCTAssertFalse(tradeScrolled.isEmpty, "前提：流水号四档里至少一档横滑")
        XCTAssertFalse(ownLine.isEmpty, "先排法：四档里应至少一次「值整段换到标签下方独占一行、没横滑」")
    }
}
