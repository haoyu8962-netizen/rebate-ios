@testable import Couli
import CouliNetwork
import Foundation
import SnapshotTesting
import SwiftUI
import UIKit
import Wallet
@testable import WalletCore
import XCTest

/// APP-09v-d 半屏基准（brief §2.7；名字与 Android `snapshots/stepup-v/` 对应）。真实半屏进程内截图（无键盘，键盘态在 UI 测试）。默认只比对，缺图失败；
/// `TEST_RUNNER_COULI_RECORD_SNAPSHOTS=1` 只录缺图，基准由实现者录。每张都过 `WithdrawVisualRenderJudge`（全黑 / 单色判红）与就绪条件；200% 走窗口特征。
/// 面板聚焦后软键盘把半屏抬高（844 窗口里 688，收键盘回 421），截图不含键盘，下方是空白：只比内容，整屏对画板看 compare。
@MainActor
final class StepUpVisualSnapshotTests: StepUpVisualTestCase {
    private func compare(_ image: UIImage, _ name: String, file: StaticString = #filePath, testName: String = #function,
                         line: UInt = #line) {
        XCTAssertEqual(WithdrawVisualRenderJudge.problems(image), [], name, file: file, line: line)
        withSnapshotTesting(record: ProcessInfo.processInfo
            .environment["COULI_RECORD_SNAPSHOTS"] == "1" ? .missing : .never) {
                assertSnapshot(of: image, as: .image(precision: 0.99, perceptualPrecision: 0.98), named: name,
                               file: file, testName: testName, line: line)
            }
    }

    func testBoards() async throws {
        var shot = try await openSheet(code: "38", waitFor: "stepUp.cell.5")
        compare(shot.1, "WithdrawStepUp-v2-light")
        shot = try await openSheet(code: "38", canvas: .init(height: 1119, dark: true), waitFor: "stepUp.cell.5")
        compare(shot.1, "WithdrawStepUpDark-dark")
    }

    func testStates() async throws {
        for dark in [false, true] {
            let suffix = dark ? "dark" : "light"
            let canvas = WithdrawVisualHost.Canvas(height: dark ? 1119 : 844, dark: dark)
            let empty = try await openSheet(canvas: canvas, waitFor: "stepUp.cell.5")
            compare(empty.1, "WithdrawStepUp-empty-\(suffix)")
            try await compare(wrongCodeShot(canvas), "WithdrawStepUp-error-\(suffix)")
        }
        let resend = try await openSheet(sms: Self.serverDown, waitFor: "stepUp.resend")
        compare(resend.1, "WithdrawStepUp-resend-light")
        let (host, _) = try await openSheet(code: "123456", waitFor: "stepUp.cell.5")
        host.server.script.on("POST /v1/auth/step-up", .hold)
        try panelActions().verify()
        await waitUntil { self.stepUp?.state?.phase == .verifying }
        try await compare(settled(host, waitFor: "stepUp.submit", motion: true), "WithdrawStepUp-verifying-light")
    }

    private func wrongCodeShot(_ canvas: WithdrawVisualHost.Canvas) async throws -> UIImage {
        let (host, _) = try await openSheet(code: "000000", canvas: canvas, waitFor: "stepUp.cell.5")
        host.server.script.on("POST /v1/auth/step-up", Self.wrongCode)
        try panelActions().verify()
        await waitUntil { self.stepUp?.state?.error != nil }
        return try await settled(host, waitFor: "stepUp.error.text")
    }

    func testAdaptation() async throws {
        var shot = try await openSheet(code: "38", canvas: .init(width: 390, height: 844), large: Self.ax3,
                                       waitFor: "stepUp.cell.5")
        compare(shot.1, "WithdrawStepUp-font200-w390-light")
        shot = try await openSheet(code: "38", canvas: .init(width: 320, height: 844), large: Self.ax3,
                                   waitFor: "stepUp.cell.5")
        compare(shot.1, "WithdrawStepUp-font200-w320-light")
        shot = try await openSheet(code: "38", canvas: .init(width: 320, height: 568), large: Self.ax3,
                                   waitFor: "stepUp.cell.5")
        compare(shot.1, "WithdrawStepUp-font200-short-light")
        shot = try await openSheet(code: "38", canvas: .init(width: 840, height: 1100), waitFor: "stepUp.cell.5")
        compare(shot.1, "WithdrawStepUp-w840-light")
    }

    /// 宿主二：收款账号页。换手机号 / 注销无页面（交回 §6），不出宿主图。
    func testHostPayout() async throws {
        let host = try await panelOnPayout()
        try enterCode("38")
        try await compare(settled(host, waitFor: "stepUp.cell.5"), "WithdrawStepUp-host-payout-light")
    }
}
