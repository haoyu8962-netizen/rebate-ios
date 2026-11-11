@testable import Couli
import CouliNetwork
import DesignSystem
import Foundation
import Me
import MeCore
import Router
import SwiftUI
import UIKit
import XCTest

/// FU-IOS-NUM-WRAP v4（评审 r1 S2-1 → 实现 r4：风险说明页「进行中的提现」行接共用件）：封禁说明页提现记录行的「金额 · 状态」句
/// 在极端金额 + 大字号下不在数字中间断——放不下时框内横滑，带截断提示（末端渐隐 + 指示器、从开头露出）；常规金额不横滑、没有提示。
/// 页面没有测量钩子：按窗口里能横向滚动的系统滚动视图判「横滑」，像素判渐隐与指示器（`ScrollHintJudge` 同口径，指示器框按
/// 共用件的几何取：可见框下方 3pt、高 3、等宽）。宿主 `BindPhoneLayoutCanvas`（固定浅色）。
@MainActor
final class DigitsWrapRiskRowTests: MeTestCase {
    private func mount(amountFen: Int64, tier: BindPhoneLayoutCanvas.Tier) async throws -> BindPhoneLayoutCanvas {
        script.ok("GET /v1/me", MeSamples.me(risk: "banned", reason: "new_category"))
        let row = WalletSamples.withdrawal("W1").replacingOccurrences(of: "\"amount_fen\":1000",
                                                                      with: "\"amount_fen\":\(amountFen)")
        XCTAssertTrue(row.contains("\(amountFen)"), "前提：提现行金额已换成 \(amountFen) 分")
        script.ok("GET /v1/withdrawals", "{\"items\":[\(row)],\"next_cursor\":null}")
        let fixture = make()
        let entry = try XCTUnwrap(fixture.open("RiskNotice"))
        entry.appeared()
        let controller = try XCTUnwrap(entry.controller() as? RiskNoticeController)
        await waitUntil("提现没到") { !controller.state.withdrawals.isEmpty }
        let canvas = BindPhoneLayoutCanvas(AnyView(RiskNoticeScreen(controller: controller)), tier: tier)
        await canvas.pump(rounds: 12)
        return canvas
    }

    private static func scrollers(_ window: UIWindow) -> [UIScrollView] {
        BindPhoneLayoutCanvas.all(window).compactMap { $0 as? UIScrollView }.filter {
            !($0 is UITextView) && !$0.isHidden && $0.contentSize.width > $0.bounds.width + 1
        }
    }

    func testHugeAmountRowScrollsWithHintAtLargeText() async throws {
        let tiers = [
            BindPhoneLayoutCanvas.Tier(name: "320 宽 + AX3", width: 320, size: .accessibility3),
            BindPhoneLayoutCanvas.Tier(name: "AXXXL（AX5）390", width: 390, size: .accessibility5),
        ]
        for tier in tiers {
            let canvas = try await mount(amountFen: 99_999_999_999_999, tier: tier)
            defer { canvas.close() }
            guard let strip = Self.scrollers(canvas.window).first else {
                XCTFail("[\(tier)] 极端金额行没有横滑（也没有别的不断开排法可判）")
                continue
            }
            // 把横滑条滚进首屏再截图
            if let page = canvas.mainScroll(), page !== strip {
                let local = page.convert(strip.convert(strip.bounds, to: nil), from: nil)
                page.setContentOffset(CGPoint(x: 0, y: max(0, local.minY - BindPhoneLayoutCanvas.top - 40)),
                                      animated: false)
                await canvas.pump()
            }
            let visible = strip.convert(strip.bounds, to: nil)
            XCTAssertTrue(visible.minX >= -0.5 && visible.maxX <= tier.width + 0.5, "[\(tier)] 横滑条在屏内（\(visible)）")
            let text = strip.convert(CGRect(origin: .zero, size: strip.contentSize), to: nil)
            let bar = CGRect(x: visible.minX, y: visible.maxY + 3, width: visible.width, height: 3)
            let hint = CouliLayoutProbeRecord(id: "risk.row.scrollHint", role: "scroll-hint", rect: bar)
            let image = DigitsWrapBindPendingTests.render(canvas.window)
            let problems = ScrollHintJudge.scrolled("[\(tier)] 风险页提现行", text: text, hint: hint, scroll: strip,
                                                    image: image)
            XCTAssertEqual(problems, [], "风险页提现行 \(tier)")
        }
    }

    func testRegularAmountRowDoesNotScroll() async throws {
        for size in [DynamicTypeSize.large, .accessibility3] {
            let tier = BindPhoneLayoutCanvas.Tier(name: "390 \(size)", width: 390, size: size)
            let canvas = try await mount(amountFen: 1000, tier: tier)
            defer { canvas.close() }
            XCTAssertEqual(Self.scrollers(canvas.window).count, 0, "[\(tier)] 常规金额（¥10.00）不横滑、没有提示")
        }
    }
}
