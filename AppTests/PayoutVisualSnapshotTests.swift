@testable import Couli
import CouliNetwork
import DesignSystem
import Foundation
import SnapshotTesting
import SwiftUI
import UIKit
import Wallet
import WalletCore
import XCTest

/// APP-09v-e 整页基准（brief §2.7、§5）：真实 App 组装、visualPayout 同一份数据、与画板同宽。名字与 Android
/// `app/src/test/snapshots/payout-v/`、`identity-v/` 一一对应（56 张；§1.1 E 有效 20 张里 LaborAgreementResign 待 FU 不拍）。
/// 默认只比对（缺图失败）；`TEST_RUNNER_COULI_RECORD_SNAPSHOTS=1` 只录缺图。基准由实现者录。每张都等「两帧一致」+ 就绪条件，比对前判全黑。
@MainActor
final class PayoutVisualSnapshotTests: PayoutVisualTestCase {
    private typealias Arrive = @MainActor (PayoutVisualSnapshotTests) async throws -> WithdrawVisualHost
    private struct Shot {
        let name: String
        var motion = false
        let ready: String
        let arrive: Arrive
    }

    private static let ax = DynamicTypeSize.accessibility3

    private func run(_ shots: [Shot], file: StaticString = #filePath, testName: String = #function,
                     line: UInt = #line) async throws {
        for shot in shots {
            await releaseHeld()
            realBackend?.release()
            laborBackend?.release()
            pendingBackend = MemoryPendingKeyBackend()
            let host = try await shot.arrive(self)
            let ready = shot.ready
            let image = await host.stable(motion: shot.motion, file: file, line: line) { $0.probes[ready] != nil }
            let frame = try XCTUnwrap(image, "\(shot.name)：没有稳定画面", file: file, line: line)
            XCTAssertEqual(WithdrawVisualRenderJudge.problems(frame), [], shot.name, file: file, line: line)
            withSnapshotTesting(record: ProcessInfo.processInfo
                .environment["COULI_RECORD_SNAPSHOTS"] == "1" ? .missing : .never) {
                    assertSnapshot(of: frame, as: .image(precision: 0.99, perceptualPrecision: 0.98), named: shot.name,
                                   file: file, testName: testName, line: line)
                }
        }
    }

    private func save(_ name: String, height: CGFloat = 1000) async throws -> WithdrawVisualHost {
        let error = try PayoutVisualData.saveError(name)
        let (host, _) = try await openPayout(canvas: .init(height: height))
        host.server.script.on("PUT /v1/me/payout-account", .envelope(code: error.code, data: error.data, headers: [:]))
        host.grantStepUp()
        try fillAlipay(host)
        host.payoutActions?.save()
        await waitUntil { host.flow?.state.error != nil }
        return host
    }

    /// 待确认：已绑定换账号 → 断连 → 待确认卡。
    private func pending(dark: Bool = false) async throws -> WithdrawVisualHost {
        let (host, _) = try await openPayout("boundAlipay", editing: true,
                                             canvas: .init(height: 980, dark: dark), waitFor: "payout.intro")
        host.server.script.on("PUT /v1/me/payout-account", .disconnect)
        host.grantStepUp()
        try fillAlipay(host)
        host.payoutActions?.save()
        await waitUntil("没进待确认") { host.flow?.state.pending != nil }
        try await pinPendingTime(host)
        return host
    }

    /// 待确认卡的「提交时间」来自生产 `PendingKeyStore` 的墙钟（`AppNetwork.swift:79`），测试换不掉；显示时钟却是 fixture 的 10:30，
    /// 不处理的话基准里是录制当天的日期和分钟（T4）。这里把本机未决记录改成 fixture 时钟前 2 分钟，再走生产的重读路径。
    private func pinPendingTime(_ host: WithdrawVisualHost) async throws {
        let fixed = try PayoutVisualData.nowMillis() - 120_000
        for var record in pendingBackend.list(account: "user-a") {
            record.createdAtMillis = fixed
            try pendingBackend.write(record)
        }
        host.payout?.start()
        await waitUntil("提交时间没有换成固定值") { host.flow?.state.pending?.createdAtMillis == fixed }
    }

    /// T4：待确认卡的时间与真实日期无关，显示「今天 10:28」。
    func testPendingTimeIsFixed() async throws {
        let host = try await pending()
        let shown = try CouliFormat.timeListPast(epochMillis: XCTUnwrap(host.flow?.state.pending?.createdAtMillis),
                                                 nowEpochMillis: XCTUnwrap(host.payout?.displayNowMillis()))
        XCTAssertEqual(shown, "今天 10:28")
    }

    private func risk(dark: Bool) async throws -> WithdrawVisualHost {
        let (host, _) = try await openPayout(canvas: .init(dark: dark))
        host.server.script.on("PUT /v1/me/payout-account", .envelope(code: 44001, data: "null", headers: [:]))
        host.grantStepUp()
        try fillAlipay(host)
        host.payoutActions?.save()
        await waitUntil { host.flow?.state.riskDialog != nil }
        return host
    }

    private func realError(_ name: String, dark: Bool = false) async throws -> WithdrawVisualHost {
        let (host, _) = try await openRealName(canvas: .init(height: 1001, dark: dark))
        let error = try PayoutVisualData.realnameError(name)
        realBackend?.fail(error.code, data: error.data)
        _ = try await openConsent(host, needProbes: false)
        await agree(host)
        return host
    }

    func testPayoutBoards() async throws {
        try await run([
            Shot(name: "PayoutAccount-light", ready: "payout.saveNote") { try await $0.openPayout().0 },
            Shot(name: "PayoutAccount-dark", ready: "payout.saveNote") {
                try await $0.openPayout(canvas: .init(dark: true)).0
            },
            Shot(name: "PayoutAccountBank-v2-light", ready: "payout.field.card_no.box") {
                try await $0.openPayout(method: WalletJSON.bankCard, canvas: .init(height: 1073),
                                        waitFor: "payout.field.card_no.box").0
            },
            Shot(name: "PayoutAccountBound-light", ready: "payout.note") { try await $0.openPayout("boundAlipay").0 },
            Shot(name: "PayoutAccountBoundBank-light", ready: "payout.note") { try await $0.openPayout("boundBank").0 },
            Shot(name: "PayoutAccountBound-exhausted-light", ready: "payout.note") {
                try await $0.openPayout("boundExhausted").0
            },
            Shot(name: "PayoutAccountBoundDark-dark", ready: "payout.note") {
                try await $0.openPayout("boundAlipay", canvas: .init(height: 1119, dark: true)).0
            },
            Shot(name: "PayoutAccountBlocked-light", ready: "flow.dialog.primary") { try await $0.risk(dark: false) },
            Shot(name: "PayoutAccountBlocked-dark", ready: "flow.dialog.primary") { try await $0.risk(dark: true) },
            Shot(name: "PayoutAccount-validation-light", ready: "payout.fieldError.alipay_logon_id.text") { test in
                let (host, _) = try await test.openPayout()
                host.payoutActions?.save()
                return host
            },
        ])
    }

    func testPayoutErrors() async throws {
        try await run([
            Shot(name: "PayoutAccountErrors-1-change_limit-light", ready: "payout.flowError") {
                try await $0.save("changeLimit")
            },
            Shot(name: "PayoutAccountErrors-2-verify_limit-light", ready: "payout.flowError") {
                try await $0.save("verifyLimit")
            },
            Shot(name: "PayoutAccountErrors-3-payee_mismatch-light", ready: "payout.fieldError.payee_name.text") {
                try await $0.save("payeeMismatch")
            },
            Shot(name: "PayoutAccountErrors-4-account_taken-light", ready: "payout.fieldError.alipay_logon_id.text") {
                try await $0.save("accountTaken")
            },
            Shot(name: "PayoutAccountErrors-5-busy-light", ready: "payout.flowError") { try await $0.save("busy") },
        ])
    }

    func testPayoutPending() async throws {
        try await run([
            Shot(name: "PayoutAccountPendingConfirm-light", ready: "pending.alert") { try await $0.pending() },
            Shot(name: "PayoutAccountPendingAbandonConfirm-light", ready: "flow.dialog.primary") { test in
                let host = try await test.pending()
                host.flowActions?.askAbandon()
                return host
            },
            Shot(name: "PayoutAccountPendingBusy-light", motion: true, ready: "pending.busy") { test in
                let host = try await test.pending()
                host.server.script.on("PUT /v1/me/payout-account", .hold)
                host.flowActions?.confirm()
                return host
            },
            Shot(name: "PayoutAccountPendingStill-light", ready: "pending.noticeBlock") { test in
                let host = try await test.pending()
                host.server.script.on("PUT /v1/me/payout-account", .disconnect)
                host.flowActions?.confirm()
                return host
            },
            Shot(name: "state-payout-error-light", ready: "payout.error") {
                try await $0.openPayout(read: .envelope(code: 50001, data: "null", headers: [:]),
                                        waitFor: "payout.error").0
            },
            Shot(name: "state-payout-loading-light", motion: true, ready: "payout.loading") {
                try await $0.openPayout(read: .hold, waitFor: "payout.loading").0
            },
        ])
    }

    func testRealName() async throws {
        try await run([
            Shot(name: "RealName-light", ready: "realname.note.age") { try await $0.openRealName(filled: false).0 },
            Shot(name: "RealNameDark-dark", ready: "realname.note.age") {
                try await $0.openRealName(filled: false, canvas: .init(height: 1119, dark: true)).0
            },
            Shot(name: "RealNameConsent-v2-light", ready: "consent.check.mark") { test in
                let (host, _) = try await test.openRealName()
                _ = try await test.openConsent(host)
                return host
            },
            Shot(name: "RealNameConsent-v2-dark", ready: "consent.check.mark") { test in
                let (host, _) = try await test.openRealName(canvas: .init(height: 1119, dark: true))
                _ = try await test.openConsent(host)
                return host
            },
            Shot(name: "RealNameErrors-1-verify_failed-light", ready: "realname.error") {
                try await $0.realError("verifyFailed")
            },
            Shot(name: "RealNameErrors-1-verify_failed-dark", ready: "realname.error") {
                try await $0.realError("verifyFailed", dark: true)
            },
            Shot(name: "RealNameErrors-2-id_taken-light", ready: "realname.error") { try await $0.realError("idTaken")
            },
            Shot(name: "RealNameErrors-3-age-light", ready: "realname.error") { try await $0.realError("age") },
            Shot(name: "RealNameErrors-4-daily_limit-light", ready: "realname.error") {
                try await $0.realError("dailyLimit")
            },
            Shot(name: "state-realname-50301-light", ready: "realname.error") { try await $0.realError("server") },
            Shot(name: "state-realname-validation-light", ready: "realname.fieldError.id_no") {
                try await $0.realError("fields")
            },
            Shot(name: "state-realname-unavailable-light", ready: "realname.unavailable") {
                try await $0.openRealName(backend: false, waitFor: "realname.unavailable").0
            },
            Shot(name: "state-realname-submitting-light", motion: true, ready: "realname.submit") { test in
                let (host, _) = try await test.openRealName()
                test.realBackend?.hold()
                _ = try await test.openConsent(host, needProbes: false)
                host.realNameActions?.toggleConsent()
                host.realNameActions?.agree()
                await waitUntil { host.realName?.state.submitting == true }
                return host
            },
        ])
    }

    func testLabor() async throws {
        try await run([
            Shot(name: "LaborAgreement-v2-light", ready: "labor.check.mark") { try await $0.openLabor().0 },
            Shot(name: "LaborAgreement-v2-checked-light", ready: "labor.check.mark") { test in
                let (host, _) = try await test.openLabor()
                host.laborActions?.toggle()
                return host
            },
            Shot(name: "LaborAgreementDark-dark", ready: "labor.check.mark") {
                try await $0.openLabor(canvas: .init(height: 1119, dark: true)).0
            },
            Shot(name: "state-labor-unavailable-light", ready: "labor.intro") {
                try await $0.openLabor(backend: false, phase: .unavailable).0
            },
            Shot(name: "state-labor-error-light", ready: "labor.intro") {
                try await $0.openLabor(phase: .error) { $0.failRead(50001) }.0
            },
            Shot(name: "state-labor-loading-light", motion: true, ready: "labor.intro") {
                try await $0.openLabor(phase: .loading, motion: true) { $0.holdRead() }.0
            },
            Shot(name: "state-labor-sign-failed-light", ready: "labor.signError") { test in
                let (host, _) = try await test.openLabor { $0.failSign(50301) }
                host.laborActions?.toggle()
                host.laborActions?.sign()
                return host
            },
            Shot(name: "state-labor-sign-failed-dark", ready: "labor.signError") { test in
                let (host, _) = try await test.openLabor(canvas: .init(height: 1119, dark: true)) { $0.failSign(50301) }
                host.laborActions?.toggle()
                host.laborActions?.sign()
                return host
            },
            Shot(name: "state-labor-signing-light", motion: true, ready: "labor.sign") { test in
                let (host, _) = try await test.openLabor { $0.holdSign() }
                host.laborActions?.toggle()
                host.laborActions?.sign()
                await waitUntil { host.laborPage?.state.signing == true }
                return host
            },
        ])
    }
}

extension PayoutVisualSnapshotTests {
    func testAdaptation() async throws {
        let ax = Self.ax
        try await run([
            Shot(name: "PayoutAccountBound-font200-w390", ready: "payout.note") {
                try await $0.openPayout("boundStress", canvas: .init(height: 2000, size: ax)).0
            },
            Shot(name: "PayoutAccountBound-font200-w320", ready: "payout.note") {
                try await $0.openPayout("boundStress", canvas: .init(width: 320, height: 2600, size: ax)).0
            },
            Shot(name: "PayoutAccount-font200-w320", ready: "payout.saveNote") {
                try await $0.openPayout(canvas: .init(width: 320, height: 2600, size: ax)).0
            },
            Shot(name: "PayoutAccount-w840", ready: "payout.saveNote") {
                try await $0.openPayout(canvas: .init(width: 840, height: 1000)).0
            },
            Shot(name: "RealName-font200-w390", ready: "realname.note.age") {
                try await $0.openRealName(canvas: .init(height: 2000, size: ax)).0
            },
            Shot(name: "RealName-font200-w320", ready: "realname.note.age") {
                try await $0.openRealName(canvas: .init(width: 320, height: 2600, size: ax)).0
            },
            Shot(name: "RealName-w840", ready: "realname.note.age") {
                try await $0.openRealName(canvas: .init(width: 840, height: 1000)).0
            },
            Shot(name: "RealNameConsent-v2-font200", ready: "consent.check.mark") { test in
                let (host, _) = try await test.openRealName(canvas: .init(size: ax))
                _ = try await test.openConsent(host)
                return host
            },
            Shot(name: "LaborAgreement-font200-w390", ready: "labor.check.mark") {
                try await $0.openLabor(canvas: .init(height: 2000, size: ax)).0
            },
            Shot(name: "LaborAgreement-font200-w320", ready: "labor.check.mark") {
                try await $0.openLabor(canvas: .init(width: 320, height: 2600, size: ax)).0
            },
            Shot(name: "LaborAgreement-w840", ready: "labor.check.mark") {
                try await $0.openLabor(canvas: .init(width: 840, height: 1000)).0
            },
        ])
    }
}
