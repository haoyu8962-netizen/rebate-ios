@testable import Couli
import DesignSystem
import Foundation
import SwiftUI
import UIKit
import Wallet
import WalletCore
import XCTest

/// APP-09v-a 适配（brief §2.7「大字号 200%」、§4.6；adaptation-a11y-spec §2；AdaptLargeTextWallet）：AX3（≈ 200%）× 390 / 320。
/// 金额不截断、不缩小——尺寸判据（实际宽 ≥ 自然宽、字号 ≥ 设计字号、整段在卡内）加像素判据（字形墨迹铺满测量框，拦父级裁切）；
/// 字号确实放大；数字格纵排；Android 评审 r1 S2-1「窄屏 200% 主卡首行换行后眼睛与『提现记录』命中区重叠」逐条对照。
@MainActor
final class WalletVisualAdaptTests: WalletVisualTestCase {
    private let ax3 = DynamicTypeSize.accessibility3

    /// 390 × AX3：大数、冻结中 / 已提现、预估金额完整且真放大；主卡底部两格纵排；预估与「最早预计」纵排。
    func testAX3W390AmountsWholeAndStacked() async throws {
        try await assertLargeText(summary: "normal", width: 390)
    }

    /// 320 × AX3：同上（AdaptLargeTextWallet 窄屏）。
    func testAX3W320AmountsWholeAndStacked() async throws {
        try await assertLargeText(summary: "normal", width: 320)
    }

    /// 320 × AX3 + 长金额（visualWallet.long_amounts，九位整数元）：仍不截断、不缩字、不出卡（尺寸 + 像素）。
    func testAX3W320LongAmountsNotClipped() async throws {
        try await assertLargeText(summary: "long_amounts", width: 320, height: 1400)
    }

    /// Android 评审 r1 S2-1：窄屏 200% 主卡首行（眼睛 + 「提现记录 ›」）换行后两者命中区 ≥ 44 且互不重叠；也不压【提现】与冻结中问号。
    func testAX3W320EyeAndRecordsHitTargetsSeparate() async throws {
        try await openWallet("normal", canvas: .init(width: 320, size: ax3))
        try assertHit("wallet.hero.eye.hit", covers: "wallet.hero.eye", "眼睛")
        try assertHit("wallet.hero.records.hit", covers: "wallet.hero.records", "提现记录 ›")
        let eye = try rect("wallet.hero.eye.hit")
        let records = try rect("wallet.hero.records.hit")
        assertDisjoint(eye, records, "眼睛 / 提现记录命中区（换行后）")
        for other in ["wallet.hero.withdraw", "wallet.hero.frozen.help.hit"] {
            assertDisjoint(eye, try rect(other), "眼睛 / \(other)")
            assertDisjoint(records, try rect(other), "提现记录 / \(other)")
        }
        let hero = try rect("wallet.hero")
        assertInside(try rect("wallet.hero.records"), hero, "「提现记录 ›」整块在主卡内（换行不出卡）")
    }

    /// 200% 下警告条文字换行不截断（待抵扣两行整段在条内）。
    func testAX3W320NegativeStripWraps() async throws {
        try await openWallet("negative", canvas: .init(width: 320, height: 1200, size: ax3), waitFor: "wallet.negative")
        let strip = try rect("wallet.negative")
        for id in ["wallet.negative.line1", "wallet.negative.line2"] {
            let line = try record(id)
            XCTAssertGreaterThan(line.fontSize, line.baseFontSize * 1.5, "\(id) 真放大")
            assertInside(line.rect, strip, "\(id) 整段在条内")
        }
    }

    // MARK: - 工具

    private func assertLargeText(summary: String, width: CGFloat, height: CGFloat = 1200,
                                 file: StaticString = #filePath, line: UInt = #line) async throws {
        let (_, image) = try await openWallet(summary, canvas: .init(width: width, height: height, size: ax3),
                                              waitFor: "wallet.estimate", file: file, line: line)
        let hero = try rect("wallet.hero", file: file, line: line)
        let card = try rect("wallet.estimate", file: file, line: line)
        let solid = pixel(CouliColor.token("rebate.solid.background"), dark: false)
        let surface = pixel(CouliColor.backgroundSurface, dark: false)
        let checks: [String: (CGRect, ProductVisualPixels.RGB)] = [
            "wallet.hero.amount": (hero, solid),
            "wallet.hero.frozen.value": (hero, solid),
            "wallet.hero.withdrawn.value": (hero, solid),
            "wallet.estimate.left.value": (card, surface),
        ]
        for (id, (container, background)) in checks.sorted(by: { $0.key < $1.key }) {
            let item = try record(id, file: file, line: line)
            XCTAssertGreaterThan(item.fontSize, item.baseFontSize * 1.3, "\(id) 字号真放大（不是只换布局）", file: file,
                                 line: line)
            // a v2（实现交回 T2）：主卡大数单段比卡内可用宽还宽时（如 320 × AX3 的「¥9876543.21」）改核放不下的口径——
            // FU-IOS-NUM-WRAP（D10-1230 判据 1）起是「整段一行、卡内横滑，不截不缩」（见 assertWrappedAmount，名字沿用）；
            // 其余金额与放得下的大数仍按单行判
            let inner = container.width - 2 * 20
            if id == "wallet.hero.amount", item.naturalWidth > inner + 0.5 {
                try await assertWrappedAmount(id, inside: container, image: image, background: background,
                                              "\(width) × AX3 \(id)（放不下：整段一行卡内横滑）", file: file, line: line)
                continue
            }
            try assertWholeAmount(id, inside: container, "\(width) × AX3 \(id)", file: file, line: line)
            try assertAmountInkFillsFrame(id, image: image, background: background, "\(width) × AX3 \(id)", file: file,
                                          line: line)
        }
        let frozen = try rect("wallet.hero.frozen.value", file: file, line: line)
        let withdrawn = try rect("wallet.hero.withdrawn.value", file: file, line: line)
        XCTAssertGreaterThanOrEqual(withdrawn.minY, frozen.maxY - 0.5, "主卡底部两格纵排", file: file, line: line)
        if host?.probes["wallet.estimate.right.value"] != nil {
            let left = try rect("wallet.estimate.left.value", file: file, line: line)
            let right = try rect("wallet.estimate.right.label", file: file, line: line)
            XCTAssertGreaterThanOrEqual(right.minY, left.maxY - 0.5, "预估与「最早预计」纵排（预估在上）", file: file,
                                        line: line)
        }
        let button = try rect("wallet.hero.withdraw", file: file, line: line)
        assertInside(button, hero, "【提现】在主卡内", file: file, line: line)
        let label = try record("wallet.hero.withdraw.label", file: file, line: line)
        XCTAssertGreaterThanOrEqual(label.rect.width + 0.5, label.naturalWidth, "【提现】字不截断", file: file, line: line)
    }
}
