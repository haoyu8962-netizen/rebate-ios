@testable import Couli
import DesignSystem
import Foundation
import SwiftUI
import UIKit
import XCTest

/// FU-IOS-NUM-WRAP ②（QA-11 iOS #2：`Me-font200-w320-light` 可提现大数「¥99999.9 / 9」）：「我的」红色主卡大数与预估四档下不在中间断
/// （判据见 `DigitsRunJudge`）。主卡与钱包是同一种组件，修在共用处两页一起生效。
@MainActor
final class DigitsWrapMeTests: MeVisualTestCase {
    func testMeHeroDigitsNeverBreakAllTiers() async throws {
        for tier in DigitsRunJudge.tiers {
            let canvas = MeVisualHost.Canvas(width: tier.width, height: tier.accessibility ? 2800 : 1400,
                                             dark: tier.dark, size: tier.size)
            let (host, _) = try await open(Setup(profile: "me_long", canvas: canvas), waitFor: "me.hero.amount")
            let hero = try rect("me.hero")
            var problems: [String] = []
            for id in ["me.hero.amount", "me.estimate.value"] {
                problems += try DigitsRunJudge.problems(record(id), weight: .semibold, container: hero,
                                                        window: host.window, tier: tier)
            }
            XCTAssertEqual(problems, [], "我的 \(tier.name)")
        }
    }

    /// v4（D10-1265）：「我的」主卡大数横滑的档必须有截断提示，预估等放得下的金额没有；至少一档横滑，正常档不横滑。
    func testHeroScrollHintOnlyWhenScrolling() async throws {
        var scrolledTiers: [String] = []
        for tier in DigitsRunJudge.tiers {
            // 截图物理像素不超过渲染上限（8192，超了整张黑），像素判提示的用例画布高取 2600
            let canvas = MeVisualHost.Canvas(width: tier.width, height: tier.accessibility ? 2600 : 1400,
                                             dark: tier.dark, size: tier.size)
            let (host, image) = try await open(Setup(profile: "me_long", canvas: canvas), waitFor: "me.hero.amount")
            let shot = ScrollHintJudge.Shot(image: image, window: host.window)
            let hero = try rect("me.hero")
            var problems: [String] = []
            for id in ["me.hero.amount", "me.estimate.value"] {
                let outcome = try ScrollHintJudge.judge("\(tier.name) \(id)", text: rect(id),
                                                        hint: host.probes[id + ".scrollHint"], container: hero,
                                                        shot: shot)
                problems += outcome.problems
                if outcome.scrolled, id == "me.hero.amount" {
                    scrolledTiers.append(tier.name)
                }
                if !tier.accessibility, outcome.scrolled {
                    problems.append("\(tier.name) \(id)：正常档不该横滑")
                }
            }
            XCTAssertEqual(problems, [], "我的截断提示 \(tier.name)")
        }
        XCTAssertFalse(scrolledTiers.isEmpty, "前提：四档里至少一档主卡大数横滑")
    }
}
