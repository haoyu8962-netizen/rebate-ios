@testable import Couli
import CouliNetwork
import DesignSystem
import Foundation
@testable import Me
import MeCore
import SwiftUI
import UIKit
import XCTest

/// 轻提示（brief §2 第 8、13 条，G-P12；a 组留下的 K1 / F-IOS-68 ③）：成功带对勾、错误不带；一次一条；位置维持顶部（G-P12）。瞬时提示走记录（F-IOS-62）。
@MainActor
final class PrivacyVisualNoticeTests: PrivacyVisualTestCase {
    private func message(_ key: String) -> CouliToastMessage {
        MeToastMessage.make(MeNotice(key, id: 1), texts: MeDraftTexts())
    }

    /// F-IOS-68 ③ / K1：`about.copy_diagnostics.done` 保勾，删掉 `successKeys` 里这一项要红；页面级错误键不带。
    func testIconMapping() throws {
        XCTAssertEqual(message(AboutController.copiedKey).icon, .success, "关于成功保勾（K1）")
        XCTAssertEqual(message(MeTabController.copyFailed).icon, CouliToastIcon.none, "复制失败不带")
        XCTAssertEqual(message(PrivacyCenterController.failedKey).icon, CouliToastIcon.none, "个性化失败不带")
        for row in try PrivacyVisualData.notices() where row.key != CustomerServiceEntry.copied {
            let expected: CouliToastIcon = row.check ? .success : .none
            XCTAssertEqual(message(row.key).icon, expected, row.key)
        }
    }

    /// 复制成功：真实路径，带对勾，提示一次。
    func testCopyDoneHasTick() async throws {
        try await openAbout(waitFor: nil)
        try about.copyDiagnostics()
        await waitUntil("提示没有出现") { !self.toasts.isEmpty }
        XCTAssertEqual(toasts, ["已复制，可以粘贴给客服"])
        let ticked = await pollFrame { self.toastGreen($0) > 10 }
        XCTAssertTrue(ticked, "带对勾")
    }

    /// 复制失败：不带对勾（K1 修过：现状已不带，加守卫）。iOS 现状 polite（`AboutController` 钉死），brief 写 assertive，见交回「要编排定」。
    func testCopyFailedNoTick() async throws {
        try await openAbout(waitFor: nil)
        try XCTUnwrap(page).fixture.ledgerStore.failWrites = true
        try about.copyDiagnostics()
        await waitUntil("提示没有出现") { !self.toasts.isEmpty }
        XCTAssertEqual(toasts.count, 1, "一次")
        XCTAssertEqual(try about.deps.texts.text("me.copy_failed"), toasts.first)
        let ticked = await pollFrame { self.toastGreen($0) > 10 }
        XCTAssertFalse(ticked, "失败不带对勾")
    }

    /// 个性化切换失败：错误类不带图标，提示一次，不回滚（G03）。
    func testPersonalizationFailureNoTick() async throws {
        try await openPrivacy()
        let host = try XCTUnwrap(page)
        host.script.fail("POST /v1/consents", 50001)
        try centerActions.personalization(false)
        await waitUntil("提示没有出现") { !self.toasts.isEmpty }
        XCTAssertEqual(toasts, [try center.deps.texts.text(PrivacyCenterController.failedKey)])
        XCTAssertFalse(host.fixture.local.personalizationOn, "不回滚")
        let ticked = await pollFrame { self.toastGreen($0) > 10 }
        XCTAssertFalse(ticked, "错误类不带对勾")
    }
}
