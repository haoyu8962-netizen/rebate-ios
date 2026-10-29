@testable import Couli
import DesignSystem
import Foundation
import SwiftUI
import UIKit
import Wallet
import WalletCore
import XCTest

/// APP-09v-a 钱包页深色令牌、加载骨架（新结构）与 ≥ 600 宽限宽（brief §2.1-9、§2.7「大屏」）。
@MainActor
final class WalletVisualStateTests: WalletVisualTestCase {
    // MARK: - 深色、骨架、大屏

    /// WalletDark：主卡狸橙不变、预估金额用深色返利令牌、卡片深色面。
    func testDarkTokens() async throws {
        let (_, image) = try await openWallet("normal", canvas: .init(height: 1181, dark: true),
                                              waitFor: "wallet.estimate")
        let hero = try rect("wallet.hero")
        XCTAssertGreaterThan(share(image, in: hero.insetBy(dx: 24, dy: 24),
                                   near: pixel(CouliColor.token("rebate.solid.background"), dark: true)), 0.5)
        let value = try rect("wallet.estimate.left.value")
        XCTAssertGreaterThan(count(image, in: value, near: pixel(CouliColor.rebateText, dark: true)), 30, "深色返利色")
        let card = try rect("wallet.estimate")
        let corner = CGRect(x: card.minX + 4, y: card.maxY - 10, width: 8, height: 6)
        XCTAssertGreaterThan(share(image, in: corner, near: pixel(CouliColor.backgroundSurface, dark: true)), 0.8,
                             "卡片深色面")
    }

    /// 加载骨架按新结构（brief §2.1-9；Android 评审 r1 S2-3：逐块验位置与可见像素，不能靠总量凑数）。
    func testLoadingSkeletonBlocks() async throws {
        let page = try fresh()
        WalletVisualScript.hold(page.script)
        try await page.showWallet()
        let blocks = ["hero.title", "hero.records", "hero.amount", "hero.button", "hero.frozen", "hero.withdrawn",
                      "estimate.left", "estimate.right", "entry.0", "entry.1"]
        let rendered = await page.stable { host in
            host.controller?.state.phase == .loading && host.probes["wallet.skeleton"] != nil
        }
        let image = try XCTUnwrap(rendered)
        let muted = pixel(CouliColor.backgroundMuted, dark: false)
        let hero = try rect("wallet.skeleton.hero")
        for block in blocks {
            let frame = try rect("wallet.skeleton.\(block)")
            XCTAssertGreaterThan(frame.width * frame.height, 40, "\(block) 有实际尺寸")
            XCTAssertGreaterThan(share(image, in: frame.insetBy(dx: 1, dy: 1), near: muted, tolerance: 6), 0.8,
                                 "\(block) 至少 80% 是骨架底色")
            if block.hasPrefix("hero.") {
                assertInside(frame, hero, "\(block) 在主卡骨架内")
            }
        }
        XCTAssertTrue(sameRow(try rect("wallet.skeleton.hero.title"), try rect("wallet.skeleton.hero.records")))
        XCTAssertTrue(sameRow(try rect("wallet.skeleton.hero.frozen"), try rect("wallet.skeleton.hero.withdrawn")))
        XCTAssertTrue(sameRow(try rect("wallet.skeleton.estimate.left"), try rect("wallet.skeleton.estimate.right")))
    }

    /// ≥ 600 宽：内容限宽 600 居中，主卡、预估卡、入口卡同一列。
    func testW840ContentColumn600() async throws {
        try await openWallet("normal", canvas: .init(width: 840, height: 1000), waitFor: "wallet.entries")
        let content = try rect("wallet.content")
        assertNear(content.width, 600, 1, "限宽 600")
        assertNear(content.midX, 420, 1, "居中")
        for id in ["wallet.hero", "wallet.estimate", "wallet.entries"] {
            let card = try rect(id)
            assertInside(card, content, "\(id) 在 600 列内")
            assertNear(card.width, 568, 1.5, "\(id) 宽 = 600 − 左右 16")
        }
    }
}
