@testable import Couli
import CouliNetwork
import Foundation
import SnapshotTesting
import SwiftUI
import UIKit
import Wallet
import WalletCore
import XCTest

/// APP-09v-c 提现页整页基准（brief §2.7、§5）：真实 App 组装、visualWithdraw 同一份数据、与画板同宽。名字与 Android
/// `app/src/test/snapshots/withdraw-v/` 对应；WithdrawNoteNet 在 UI 测试拍（进程内点不到 SwiftUI 问号）。
/// 默认只比对（缺图失败）；`TEST_RUNNER_COULI_RECORD_SNAPSHOTS=1` 只录缺图（`.missing`）。基准由实现者录。
/// 每张都等「两帧一致」+ 就绪条件；没有就绪条件的镜头不允许（APP-08v 测试 v3 S2-2）。
@MainActor
final class WithdrawVisualSnapshotTests: WithdrawVisualTestCase {
    enum Scene {
        case page(String, amount: String? = nil, estimate: String? = nil, help: Bool = true, sla: String? = nil,
                  payout: String = "bound")
        case calculating
        case loading
        case readError
        case submitting
        case risk
        case pending
        case busy
        case still
        case abandon
        case amountError(String)

        /// 画面里有转圈（帧帧不同）：只比测量，不比像素。
        var spins: Bool {
            switch self {
            case .calculating, .loading, .submitting, .busy: true
            default: false
            }
        }
    }

    struct Shot {
        let name: String
        let scene: Scene
        var canvas = WithdrawVisualHost.Canvas()
        let ready: String
    }

    func testBoardsLight() async throws {
        try await run(Self.boards(dark: false))
    }

    func testBoardsDark() async throws {
        try await run(Self.boards(dark: true))
    }

    private static func boards(dark: Bool) -> [Shot] {
        let suffix = dark ? "dark" : "light"
        let canvas = WithdrawVisualHost.Canvas(height: dark ? 1119 : 844, dark: dark)
        let tall = WithdrawVisualHost.Canvas(height: 1128, dark: dark)
        let main = dark ? "WithdrawDark" : "Withdraw"
        return [
            Shot(name: "\(main)-\(suffix)", scene: .page("normal", amount: "10", estimate: "estimated"), canvas: canvas,
                 ready: "withdraw.estimate"),
            Shot(
                name: "WithdrawCalculating-GW12-\(suffix)",
                scene: .calculating,
                canvas: canvas,
                ready: "withdraw.calculating"
            ),
            Shot(name: "WithdrawEstimateFailed-\(suffix)", scene: .page("normal", amount: "10"), canvas: canvas,
                 ready: "withdraw.payout"),
            Shot(
                name: "WithdrawRealName-\(suffix)",
                scene: .page("blocked_30304"),
                canvas: canvas,
                ready: "withdraw.guide.button"
            ),
            Shot(
                name: "WithdrawSubmitting-\(suffix)",
                scene: .submitting,
                canvas: canvas,
                ready: "withdraw.submit.label"
            ),
            Shot(name: "WithdrawBlocked-\(suffix)", scene: .risk, canvas: canvas, ready: "flow.dialog.primary"),
            Shot(name: "WithdrawPendingConfirm-\(suffix)", scene: .pending, canvas: tall, ready: "pending.alert"),
            Shot(name: "WithdrawPendingBusy-\(suffix)", scene: .busy, canvas: tall, ready: "pending.busy"),
            Shot(name: "WithdrawPendingStill-\(suffix)", scene: .still, canvas: tall, ready: "pending.noticeBlock"),
            Shot(name: "WithdrawAbandonConfirm-\(suffix)", scene: .abandon, canvas: tall, ready: "flow.dialog.primary"),
            Shot(name: "state-withdraw-loading-\(suffix)", scene: .loading, canvas: canvas, ready: "withdraw.loading"),
            Shot(name: "state-withdraw-error-\(suffix)", scene: .readError, canvas: canvas, ready: "withdraw.error"),
        ]
    }

    /// WithdrawPageStates 证据稿：全部 21 个 code / reason、时效两态、提交后字段错误。
    func testPageStates() async throws {
        var shots = try WithdrawVisualData.pageStates().map {
            Shot(
                name: "WithdrawPageStates-\($0)-light",
                scene: .page($0),
                canvas: .init(height: 1000),
                ready: "withdraw.guide.text"
            )
        }
        shots += [
            Shot(name: "WithdrawPageStates-sla_default-light", scene: .page("normal"), ready: "withdraw.sla.text"),
            Shot(name: "WithdrawPageStates-sla_auto-GW27-light", scene: .page("normal", sla: "预计几分钟内到账"),
                 ready: "withdraw.sla.text"),
            Shot(
                name: "WithdrawPageStates-above_max-light",
                scene: .amountError("above_max"),
                ready: "withdraw.fieldError"
            ),
            Shot(
                name: "WithdrawPageStates-amount_error-light",
                scene: .amountError("30301"),
                ready: "withdraw.fieldError"
            ),
        ]
        try await run(shots)
    }

    /// 适配：AX3 × 390 / 320（普通、压力）、840。
    func testAdaptation() async throws {
        let ax = DynamicTypeSize.accessibility3
        try await run([
            Shot(name: "Withdraw-font200-w390-light", scene: .page("normal", amount: "10", estimate: "estimated"),
                 canvas: .init(height: 2000, size: ax), ready: "withdraw.estimate"),
            Shot(name: "Withdraw-font200-w320-light", scene: .page("normal", amount: "10", estimate: "estimated"),
                 canvas: .init(width: 320, height: 2400, size: ax), ready: "withdraw.estimate"),
            Shot(
                name: "Withdraw-stress-font200-w390-light",
                scene: .page("stress", amount: "999999999.00", estimate: "stress"),
                canvas: .init(height: 2400, size: ax),
                ready: "withdraw.estimate"
            ),
            Shot(
                name: "Withdraw-stress-font200-w320-dark",
                scene: .page("stress", amount: "999999999.00", estimate: "stress"),
                canvas: .init(width: 320, height: 2700, dark: true, size: ax),
                ready: "withdraw.estimate"
            ),
            Shot(name: "Withdraw-w840-light", scene: .page("normal", amount: "10", estimate: "estimated"),
                 canvas: .init(width: 840, height: 1000), ready: "withdraw.estimate"),
        ])
    }

    private func run(_ shots: [Shot], file: StaticString = #filePath, testName: String = #function,
                     line: UInt = #line) async throws {
        for shot in shots {
            try await take(shot, file: file, testName: testName, line: line)
        }
    }

    private func take(_ shot: Shot, file: StaticString, testName: String, line: UInt) async throws {
        let ready = shot.ready
        // v2 / T2：上一镜挂起的提交放行后结果未知，写进未决记录；每镜一份干净后端，不串到下一镜
        await releaseHeld()
        pendingBackend = MemoryPendingKeyBackend()
        let host = try await arrive(shot, file: file, line: line)
        let image = await host.stable(motion: shot.scene.spins, file: file, line: line) { $0.probes[ready] != nil }
        let shotImage = try XCTUnwrap(image, "\(shot.name)：没有稳定画面", file: file, line: line)
        // v2 / T3：全黑图判红（比对之前判：录基准时同样拦住）；v2 / T2：镜头状态对得上才比
        XCTAssertEqual(WithdrawVisualRenderJudge.problems(shotImage), [], shot.name, file: file, line: line)
        assertSceneState(shot, host, file: file, line: line)
        withSnapshotTesting(record: ProcessInfo.processInfo
            .environment["COULI_RECORD_SNAPSHOTS"] == "1" ? .missing : .never) {
                assertSnapshot(of: shotImage, as: .image(precision: 0.99, perceptualPrecision: 0.98), named: shot.name,
                               file: file, testName: testName, line: line)
            }
    }

    /// 就绪测量之外再核执行器状态：不是待确认的镜头不能带未决记录（T2 正是这样错图）。
    private func assertSceneState(_ shot: Shot, _ host: WithdrawVisualHost, file: StaticString, line: UInt) {
        let state = host.flow?.state
        switch shot.scene {
        case .pending, .busy, .still:
            XCTAssertNotNil(state?.pending, "\(shot.name)：应待确认", file: file, line: line)
        case .abandon:
            XCTAssertNotNil(state?.abandonConfirmKey, "\(shot.name)：应有放弃确认", file: file, line: line)
        case .risk:
            XCTAssertNotNil(state?.riskDialog, "\(shot.name)：应有 44001 弹窗", file: file, line: line)
            XCTAssertNil(state?.pending, "\(shot.name)：不能串入上一镜的未决记录", file: file, line: line)
        default:
            XCTAssertNil(state?.pending, "\(shot.name)：不能串入上一镜的未决记录", file: file, line: line)
        }
    }

    private func arrive(_ shot: Shot, file: StaticString, line: UInt) async throws -> WithdrawVisualHost {
        switch shot.scene {
        case let .page(rules, amount, estimate, help, sla, payout):
            return try await openWithdraw(
                rules,
                amount: amount,
                estimate: estimate,
                help: help,
                sla: sla,
                payout: payout,
                canvas: shot.canvas,
                waitFor: shot.ready,
                file: file,
                line: line
            ).0
        case .calculating:
            let host = try await freshPage(estimate: "estimated")
            host.server.setEstimateReply(.hold)
            try await host.show(WalletRoutes.withdraw, shot.canvas)
            await waitUntil(file: file, line: line) { host.controller?.state.phase == .content }
            host.actions?.amount("10")
            return host
        case .loading:
            return try await reading(.hold, shot)
        case .readError:
            return try await reading(.envelope(code: 50001, data: "null", headers: [:]), shot)
        case .submitting:
            return try await submitting(.hold, shot, file: file, line: line)
        case .risk:
            return try await submitting(
                .envelope(code: 44001, data: "null", headers: [:]),
                shot,
                file: file,
                line: line
            )
        case let .amountError(which):
            let code = Int(which) ?? 30303
            let data = code == 30303 ? "{\"reason\":\"\(which)\"}" : "null"
            return try await submitting(.envelope(code: code, data: data, headers: [:]), shot, file: file, line: line)
        case .pending, .busy, .still, .abandon:
            let host = try await openWithdraw(estimate: "estimated", canvas: shot.canvas, file: file, line: line).0
            try await enterPending(file: file, line: line)
            await pendingStep(shot.scene, host)
            return host
        }
    }

    private func reading(_ reply: WalletStubProtocol.Reply, _ shot: Shot) async throws -> WithdrawVisualHost {
        let host = try await freshPage()
        host.server.setFirst(reply)
        try await host.show(WalletRoutes.withdraw, shot.canvas)
        return host
    }

    private func submitting(_ reply: WalletStubProtocol.Reply, _ shot: Shot, file: StaticString,
                            line: UInt) async throws -> WithdrawVisualHost {
        let host = try await openWithdraw(
            amount: "10",
            estimate: "estimated",
            canvas: shot.canvas,
            file: file,
            line: line
        ).0
        host.server.script.on("POST /v1/withdrawals", reply)
        host.actions?.submit()
        return host
    }

    private func pendingStep(_ scene: Scene, _ host: WithdrawVisualHost) async {
        switch scene {
        case .busy:
            host.server.script.on("POST /v1/withdrawals", .hold)
            host.flowActions?.confirm()
        case .still:
            host.server.script.fail("POST /v1/withdrawals", 40901)
            host.flowActions?.confirm()
        case .abandon:
            host.flowActions?.askAbandon()
        default:
            break
        }
    }
}
