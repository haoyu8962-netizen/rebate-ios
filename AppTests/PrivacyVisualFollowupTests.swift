@testable import Couli
import DesignSystem
import Foundation
import MeCore
import SwiftUI
import XCTest

/// F-IOS-68 ①②（APP-12w-a 评审 r1 S2-3、S2-4，留给本组）：设置一族的三条判据。③ 在 `PrivacyVisualNoticeTests`，④ 在守卫 test-change（交回 §4）。
@MainActor
final class PrivacyVisualFollowupTests: SettingsVisualTestCase {
    /// ① 小于默认字号时【去登录】命中高仍 ≥ 44（现状约 42：`hitBottom` 按基础字号算成常量）。
    func testGuestLinkHitAtExtraSmall() async throws {
        let canvas = SettingsVisualHost.Canvas(height: 900, size: .xSmall)
        try await open(Setup(level: .guest, canvas: canvas), waitFor: "settings.guest.link.hit")
        XCTAssertGreaterThanOrEqual(try rect("settings.guest.link.hit").height, 43.5, "xSmall 命中高")
    }

    /// ① 同上：【去设置】。
    func testGoSettingsHitAtExtraSmall() async throws {
        let canvas = SettingsVisualHost.Canvas(height: 900, size: .xSmall)
        try await openNotify(Setup(canvas: canvas), waitFor: "notify.goSettings.hit")
        XCTAssertGreaterThanOrEqual(try rect("notify.goSettings.hit").height, 43.5, "xSmall 命中高")
    }

    /// ② 动作行 52 ± 1（2026-11-02 14:45 三端以画板为准）。
    func testActionRowHeight() async throws {
        try await open(waitFor: "settings.row.reset_tip")
        assertNear(try rect("settings.row.reset_tip").height, 52, 1, "动作行 52")
    }

    /// ② 协议半屏行 44 ± 1（画板 border-box，不是 52）。
    func testAgreementSheetRowHeight() async throws {
        try await open()
        try tapRow(SettingsItems.idAgreement)
        _ = try await frame("settings.agreement.privacy")
        for type in ["agreement", "privacy"] {
            assertNear(try rect("settings.agreement.\(type)").height, 44, 1, "\(type) 半屏行 44")
        }
    }
}
