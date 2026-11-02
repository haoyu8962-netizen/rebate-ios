@testable import Couli
import DesignSystem
import Foundation
import SnapshotTesting
import SwiftUI
import UIKit
import XCTest

/// APP-12w-b 整页基准（brief §5；名字尽量与 Android `app/src/test/snapshots/privacy-v/` 同名）：真实 App 组装、privacy-visual-vectors
/// 同一份数据。
/// 默认只比对（缺图失败）；`TEST_RUNNER_COULI_RECORD_SNAPSHOTS=1` 只录缺图，基准由实现者录。容差同「我的」组。每张都等就绪 + 过全黑 / 单色判据。
/// 客服半屏是内容（`CsSheetHarness`），不含系统遮罩与把手；真实 `.sheet` 的整屏图由 `PrivacyVisualUITests` 留附件供 compare。
@MainActor
final class PrivacyVisualSnapshotTests: PrivacyVisualTestCase {
    private let ax3 = DynamicTypeSize.accessibility3

    private func compare(_ image: UIImage, _ name: String, _ canvas: Canvas, file: StaticString = #filePath,
                         testName: String = #function, line: UInt = #line) {
        XCTAssertEqual(image.size, CGSize(width: canvas.width, height: canvas.height), "\(name)：画布尺寸", file: file,
                       line: line)
        let problems = WithdrawVisualRenderJudge.problems(image)
        XCTAssertEqual(problems, [], "\(name)：没有画出页面", file: file, line: line)
        guard problems.isEmpty else { return }
        withSnapshotTesting(record: ProcessInfo.processInfo
            .environment["COULI_RECORD_SNAPSHOTS"] == "1" ? .missing : .never) {
                assertSnapshot(of: image, as: .image(precision: 0.99, perceptualPrecision: 0.98), named: name,
                               file: file, testName: testName, line: line)
            }
    }

    func testPrivacyBoards() async throws {
        let button = "privacy.withdraw.button"
        let enable = "privacy.enableFull.button"
        let tall = Canvas(height: 864)
        try await privacyShot("PrivacyCenter-light", Scene(canvas: tall), button)
        try await privacyShot("privacy-guest-light", Scene(session: "privacy_guest", canvas: tall), button)
        try await privacyShot("privacy-personalization-off-light", Scene(canvas: tall, personalization: false), button)
        try await privacyShot("PrivacyCenterBasic-v2-light",
                              Scene(session: "privacy_basic", canvas: Canvas(height: 844)), enable)
        try await privacyShot("PrivacyCenterBasic-dark",
                              Scene(session: "privacy_basic", canvas: Canvas(height: 844, dark: true)), enable)
        try await privacyShot("PrivacyCenterForceUpdate-light", Scene(session: "privacy_force_update", canvas: tall),
                              button)
        try await privacyShot("PrivacyCenterDark-dark", Scene(canvas: Canvas(height: 864, dark: true)), button)
        try await privacyShot("PrivacyCenter-w840-light", Scene(canvas: Canvas(width: 840, height: 1100)), button)
    }

    func testPrivacyLargeText() async throws {
        let button = "privacy.withdraw.button"
        let enable = "privacy.enableFull.button"
        for width in [CGFloat(390), 320] {
            let canvas = Canvas(width: width, height: 2700, size: ax3)
            try await privacyShot("PrivacyCenter-font200-w\(Int(width))-light", Scene(canvas: canvas), button)
            try await privacyShot("PrivacyCenterBasic-font200-w\(Int(width))-light",
                                  Scene(session: "privacy_basic", canvas: canvas), enable)
        }
    }

    private func privacyShot(
        _ name: String,
        _ scene: Scene,
        _ ready: String,
        testName: String = #function
    ) async throws {
        let image = try await openPrivacy(scene, waitFor: ready)
        compare(image, name, scene.canvas, testName: testName)
    }

    func testPrivacyOverlays() async throws {
        let list: [(String, Canvas)] = [
            ("PrivacyCenterWithdraw-light", Canvas(height: 864)),
            ("PrivacyCenterWithdraw-dark", Canvas(height: 864, dark: true)),
            ("PrivacyCenterWithdraw-font200-w390-light", Canvas(height: 1400, size: ax3)),
            ("PrivacyCenterWithdraw-font200-w320-light", Canvas(width: 320, height: 1400, size: ax3)),
        ]
        for (name, canvas) in list {
            try await openPrivacy(Scene(canvas: canvas))
            try askWithdraw()
            let image = try await privacyFrame("privacy.dialog.withdraw.panel")
            compare(image, name, canvas)
        }
    }

    /// 撤回进行中（按钮 loading）：转圈有动画，容差内；挂住请求，收尾放行。
    func testPrivacyWithdrawing() async throws {
        let canvas = Canvas(height: 864)
        try await openPrivacy(Scene(canvas: canvas), waitFor: "privacy.withdraw.button")
        try XCTUnwrap(page).script.on("POST /v1/consents", .hold)
        try centerActions.confirmWithdraw(askWithdraw())
        await waitUntil("撤回记录没发出") { !WalletStubProtocol.heldIds.isEmpty }
        await quietWindow(0.5)
        let image = try XCTUnwrap(page?.render())
        compare(image, "privacy-withdrawing-light", canvas)
        try WalletStubProtocol.release(XCTUnwrap(WalletStubProtocol.heldIds.first),
                                       with: .envelope(code: 0, data: "{}", headers: [:]))
    }

    func testAboutBoards() async throws {
        try await aboutShot("About-v2-light", filed: true, Canvas(height: 844))
        try await aboutShot("AboutDark-dark", filed: true, Canvas(height: 844, dark: true))
        try await aboutShot("AboutBeforeFiling-light", filed: false, Canvas(height: 844))
        try await aboutShot("About-font200-w390-light", filed: true, Canvas(height: 2000, size: ax3))
        try await aboutShot("About-font200-w320-light", filed: true, Canvas(width: 320, height: 2000, size: ax3))
        try await aboutShot("About-w840-light", filed: true, Canvas(width: 840, height: 844))
    }

    private func aboutShot(_ name: String, filed: Bool, _ canvas: Canvas, testName: String = #function) async throws {
        let image = try await openAbout(filed: filed, canvas: canvas, waitFor: "about.copy.button")
        compare(image, name, canvas, testName: testName)
    }

    /// 带轻提示的两张：等旁路记录到一次再取帧（F-IOS-62）。
    func testAboutToasts() async throws {
        let canvas = Canvas(height: 844)
        for (name, fail) in [("AboutBeforeFiling-copied-light", false), ("about-copy-failed-light", true)] {
            try await openAbout(filed: false, canvas: canvas, waitFor: "about.copy.button")
            try XCTUnwrap(page).fixture.ledgerStore.failWrites = fail
            toasts = []
            try about.copyDiagnostics()
            await waitUntil("\(name)：轻提示没有出现", timeout: 6) { !self.toasts.isEmpty }
            await quietWindow(0.5)
            compare(try XCTUnwrap(page?.render()), name, canvas)
        }
    }

    func testPersonalizationFailureToast() async throws {
        let canvas = Canvas(height: 864)
        try await openPrivacy(Scene(canvas: canvas), waitFor: "privacy.withdraw.button")
        try XCTUnwrap(page).script.fail("POST /v1/consents", 50001)
        toasts = []
        try centerActions.personalization(false)
        await waitUntil("轻提示没有出现", timeout: 6) { !self.toasts.isEmpty }
        await quietWindow(0.5)
        compare(try XCTUnwrap(page?.render()), "privacy-personalization-failed-light", canvas)
    }

    func testCsBoards() async throws {
        let plain = Canvas(height: 620, top: 0)
        let dark = Canvas(height: 620, dark: true, top: 0)
        try await csShot("CsOpenFailed-v2-light", "cs_open_failed", plain)
        try await csShot("CsOpenFailed-dark", "cs_open_failed", dark)
        try await csShot("CsWechatMissing-v2-light", "cs_wechat_missing", plain)
        try await csShot("CsWechatMissingDark-dark", "cs_wechat_missing", dark)
        try await csShot("cs-help-only-light", "cs_help_only", plain)
        try await csShot("cs-handoff-GP02-light", "cs_handoff", plain)
        try await csShot("CsOpenFailed-font200-w390-light", "cs_open_failed", Canvas(height: 1400, size: ax3, top: 0))
        try await csShot("CsOpenFailed-font200-w320-light", "cs_open_failed",
                         Canvas(width: 320, height: 1400, size: ax3, top: 0))
        try await csShot("CsOpenFailed-w840-light", "cs_open_failed", Canvas(width: 840, height: 620, top: 0))
    }

    private func csShot(_ name: String, _ setup: String, _ canvas: Canvas, testName: String = #function) async throws {
        let image = try await openCs(setup, canvas: canvas)
        compare(image, name, canvas, testName: testName)
    }

    func testCsCopied() async throws {
        let canvas = Canvas(height: 620, top: 0)
        try await openCs("cs_wechat_missing", canvas: canvas, waitFor: "cs.copyLink.button")
        try csActions.copyLink()
        let image = try await frame("cs.toast.text")
        compare(image, "cs-copied-in-sheet-light", canvas)
    }
}
