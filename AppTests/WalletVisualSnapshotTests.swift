@testable import Couli
import Foundation
import SnapshotTesting
import SwiftUI
import UIKit
import Wallet
import WalletCore
import XCTest

/// APP-09v-a 钱包页整页基准（brief §2.7、§5）：真实 App 组装、visualWallet 同一份数据、与画板同宽同高。名字与 Android
/// `app/src/test/snapshots/wallet-v/` 同名（30 张里的三张问号说明半屏在 UITests/WalletVisualUITests 里拍——进程内宿主点不到 SwiftUI 按钮）。
/// 默认只比对（缺图失败）；`TEST_RUNNER_COULI_RECORD_SNAPSHOTS=1` 只录缺图（`.missing`），不覆盖已有基准。
/// 每张都等「两帧一致」+ 就绪条件（执行器阶段 + 该状态特有的测量）；没有就绪条件的镜头不允许（APP-08v 测试 v3 S2-2 教训）。
@MainActor
final class WalletVisualSnapshotTests: WalletVisualTestCase {
    enum Source {
        case summary(String)
        case stale(String)
        case loading
        case error
    }

    struct Shot {
        let name: String
        let source: Source
        var canvas = WalletVisualHost.Canvas()
        var hidden = false
        var earnings = false
        /// 就绪条件：该状态特有的测量编号（必须给）。
        let ready: String
    }

    func testArtboardsLight() async throws {
        try await run([
            Shot(name: "Wallet-light", source: .summary("normal"), ready: "wallet.paused"),
            Shot(name: "WalletFrozen-light", source: .summary("frozen"), ready: "wallet.hero.frozen.value"),
            Shot(name: "WalletNegative-v2-light", source: .summary("negative"), ready: "wallet.negative"),
            Shot(name: "WalletRiskFrozen-v2-light", source: .summary("risk"), ready: "wallet.risk"),
            Shot(name: "WalletRiskFrozenTap-entry-GW02-light", source: .summary("risk"), ready: "wallet.risk"),
            Shot(name: "WalletHidden-light", source: .summary("normal"), canvas: .init(height: 1055), hidden: true,
                 ready: "wallet.paused"),
            Shot(name: "WalletEarningsEntry-light", source: .summary("normal"), earnings: true,
                 ready: "wallet.entry.Earnings"),
            Shot(name: "WalletStale-GW05-light", source: .stale("normal"), ready: "wallet.stale"),
        ])
    }

    /// WalletStates 证据稿 ①–⑤：每一项渲染完整真实钱包（不是把证据稿当成一个生产长页）。
    func testWalletStates() async throws {
        try await run([
            Shot(name: "WalletStates-01-disabled-light", source: .summary("disabled"), ready: "wallet.disabledReason"),
            Shot(name: "WalletStates-02-risk-no-expiry-light", source: .summary("risk"), ready: "wallet.risk"),
            Shot(name: "WalletStates-03-no-month-light", source: .summary("no_month"), ready: "wallet.paused"),
            Shot(name: "WalletStates-04-overdue-light", source: .summary("overdue"), ready: "wallet.estimate.right"),
            Shot(name: "WalletStates-05-received-zero-GW04-light", source: .summary("received_zero"),
                 ready: "wallet.estimate.left.note"),
        ])
    }

    func testDarkAndDerived() async throws {
        try await run([
            Shot(name: "WalletDark-dark", source: .summary("normal"), canvas: .init(height: 1181, dark: true),
                 ready: "wallet.paused"),
            Shot(name: "state-negative-dark", source: .summary("negative"), canvas: .init(dark: true),
                 ready: "wallet.negative"),
            Shot(name: "state-risk-dark", source: .summary("risk"), canvas: .init(dark: true), ready: "wallet.risk"),
            Shot(name: "state-negative-hidden-light", source: .summary("negative"), hidden: true,
                 ready: "wallet.negative"),
            Shot(name: "WalletStale-GW05-dark", source: .stale("normal"), canvas: .init(dark: true),
                 ready: "wallet.stale"),
        ])
    }

    /// 页面级状态（无稿）：加载骨架、无缓存出错（ErrorState + trace6）。
    func testPageStates() async throws {
        try await run([
            Shot(name: "state-loading-light", source: .loading, ready: "wallet.skeleton"),
            Shot(name: "state-loading-dark", source: .loading, canvas: .init(dark: true), ready: "wallet.skeleton"),
            Shot(name: "state-error-light", source: .error, ready: "wallet.error"),
            Shot(name: "state-error-dark", source: .error, canvas: .init(dark: true), ready: "wallet.error"),
        ])
    }

    /// 适配：AX3（≈ 200%）× 390 / 320、长金额、840 大屏。
    func testAdaptation() async throws {
        let ax = DynamicTypeSize.accessibility3
        try await run([
            Shot(name: "Wallet-font200-w390-light", source: .summary("overdue"), canvas: .init(height: 1200, size: ax),
                 ready: "wallet.estimate.right"),
            Shot(name: "Wallet-font200-w390-dark", source: .summary("overdue"),
                 canvas: .init(height: 1200, dark: true, size: ax), ready: "wallet.estimate.right"),
            Shot(name: "Wallet-font200-w320-light", source: .summary("overdue"),
                 canvas: .init(width: 320, height: 1300, size: ax), ready: "wallet.estimate.right"),
            Shot(name: "state-long-font200-w320-light", source: .summary("long_amounts"),
                 canvas: .init(width: 320, height: 1400, size: ax), ready: "wallet.paused"),
            Shot(name: "Wallet-w840-light", source: .summary("normal"), canvas: .init(width: 840, height: 1000),
                 ready: "wallet.entries"),
        ])
    }

    // MARK: - 执行

    private func run(_ shots: [Shot], file: StaticString = #filePath, testName: String = #function,
                     line: UInt = #line) async throws {
        for shot in shots {
            try await take(shot, file: file, testName: testName, line: line)
        }
    }

    private func take(_ shot: Shot, file: StaticString, testName: String, line: UInt) async throws {
        XCTAssertFalse(shot.ready.isEmpty, "\(shot.name)：必须给就绪条件", file: file, line: line)
        let page = try fresh()
        page.setHidden(shot.hidden)
        let phase: WalletSnapshot.Phase
        switch shot.source {
        case let .summary(name):
            try WalletVisualScript.summary(page.script, name)
            phase = .content
            if shot.earnings {
                await page.showWalletWithEarnings(shot.canvas)
            } else {
                try await page.showWallet(shot.canvas)
            }
        case let .stale(name):
            try await page.prepareStale(summary: name, shot.canvas, file: file, line: line)
            phase = .content
        case .loading:
            WalletVisualScript.hold(page.script)
            phase = .loading
            try await page.showWallet(shot.canvas)
        case .error:
            try WalletVisualScript.serverError(page.script)
            phase = .error
            try await page.showWallet(shot.canvas)
        }
        let ready = shot.ready
        guard let image = await page.stable(file: file, line: line, until: { host in
            host.controller?.state.phase == phase && host.probes[ready] != nil
        }) else { return }
        XCTAssertEqual(image.size, CGSize(width: shot.canvas.width, height: shot.canvas.height),
                       "\(shot.name)：画布尺寸", file: file, line: line)
        withSnapshotTesting(record: ProcessInfo.processInfo
            .environment["COULI_RECORD_SNAPSHOTS"] == "1" ? .missing : .never) {
                assertSnapshot(of: image, as: .image(precision: 0.99, perceptualPrecision: 0.98), named: shot.name,
                               file: file, testName: testName, line: line)
            }
    }
}
