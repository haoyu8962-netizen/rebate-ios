@testable import Couli
import CouliNetwork
import Foundation
import MeCore
import Router
import Session
import Wallet
import WalletCore
import XCTest

/// FU-IOS-0712 第 1 轮修复 R1-04：非强更 10405 之后的刷新三种结局，走真实 ApiClient（受限会话 deletion_only、启动屏障刷新先通过），
/// 对照真强更。三种都带原 10405 的码与 trace 到页面，页面按统一错误（error.50001）+ trace6 + 可重试，不进强更、不显示版本文案：
/// - 刷新成功（refresh_only）：会话换新令牌照常可用；
/// - 刷新暂时失败（断连 / 超时）：不清会话；页面不按普通网络错误显示；
/// - 刷新被拒：清会话与登录引导照旧（打开登录页）；结果仍带 10405 + trace + 清会话 Effect，页面映射为统一错误。
/// 覆盖钱包（摘要读取，含钱包页本身）与「我的」（getMe 读取）。
@MainActor
final class FollowupIos0712FixR1RefreshTests: WalletFlowTestCase {
    private static let trace = "stub-trace-0123456789ab"
    private static let trace6 = "6789ab"
    private static let refreshKey = "POST /v1/auth/refresh"

    private enum Outcome: CaseIterable {
        case refreshed
        case transient
        case rejected
        case forced
    }

    private static func tokens(_ suffix: String) -> WalletStubProtocol.Reply {
        .envelope(
            code: 0,
            data: "{\"access_token\":\"at-\(suffix)\",\"refresh_token\":\"rt-\(suffix)\","
                + "\"session_scope\":\"deletion_only\",\"expires_in\":7200}",
            headers: [:]
        )
    }

    /// 业务接口第一次回 10405（受支持 → refresh_only；forced 时最低版本高于本机 → force_update），之后照常成功。
    private func script(_ outcome: Outcome, path: String, okData: String) {
        let minimum = outcome == .forced ? "99.0.0" : "0.0.1"
        script.on(
            path,
            .envelope(code: 10405, data: "{\"min_supported_version\":\"\(minimum)\"}", headers: [:]),
            .envelope(code: 0, data: okData, headers: [:])
        )
        // 第一次刷新是受限会话的启动屏障（通过）；第二次是 10405 refresh_only 触发的刷新（本用例的三种结局）
        switch outcome {
        case .refreshed: script.on(Self.refreshKey, Self.tokens("barrier"), Self.tokens("after"))
        case .transient: script.on(Self.refreshKey, Self.tokens("barrier"), .disconnect)
        case .rejected:
            script.on(Self.refreshKey, Self.tokens("barrier"), .envelope(code: 10404, data: "null", headers: [:]))
        case .forced: script.on(Self.refreshKey, Self.tokens("barrier"))
        }
    }

    /// 网络层结果：三种非强更结局都带原 10405 的码与 trace，Effect 不是强更；真强更 Effect 为 force_update。
    private func assertResult(_ result: ApiResult, _ outcome: Outcome, file: StaticString = #filePath,
                              line: UInt = #line) {
        guard case let .failure(code, _, _, traceId, effect, _) = result else {
            return XCTFail("\(outcome)：应为带 10405 的失败结果，实际 \(result)", file: file, line: line)
        }
        XCTAssertEqual(code, 10405, "\(outcome)", file: file, line: line)
        XCTAssertEqual(traceId, Self.trace, "\(outcome)：原 10405 的 trace", file: file, line: line)
        switch outcome {
        case .refreshed: XCTAssertEqual(effect.kind, .refreshOnly, file: file, line: line)
        case .transient: XCTAssertEqual(effect.kind, .genericError, file: file, line: line)
        case .rejected: XCTAssertEqual(effect.kind, .clearSessionLogin, "清会话 Effect", file: file, line: line)
        case .forced: XCTAssertEqual(effect.kind, .forceUpdate, file: file, line: line)
        }
    }

    /// 会话与引导：成功 / 暂时失败不清会话；被拒清会话并打开登录页；只有真强更进强更。
    private func assertSession(_ tokens: MemorySessionTokens, routing: AppRouting, _ outcome: Outcome,
                               file: StaticString = #filePath, line: UInt = #line) async {
        await settle()
        switch outcome {
        case .refreshed:
            XCTAssertEqual(tokens.accessToken, "at-after", "刷新成功：会话换新令牌", file: file, line: line)
        case .transient:
            XCTAssertEqual(tokens.accessToken, "at-barrier", "暂时失败：不清会话", file: file, line: line)
        case .rejected:
            XCTAssertNil(tokens.accessToken, "被拒：清会话照旧", file: file, line: line)
            XCTAssertEqual(routing.router.path.last?.route, "Login", "被拒：登录引导照旧", file: file, line: line)
        case .forced:
            break
        }
        XCTAssertEqual(routing.mustShowForceUpdate, outcome == .forced, "\(outcome)：只有真强更进强更", file: file, line: line)
    }

    func testWalletSummaryNonForced10405RefreshOutcomesShowUnifiedErrorOnTheRealClient() async {
        for outcome in Outcome.allCases {
            WalletStubProtocol.reset()
            script.install()
            script(outcome, path: "GET /v1/wallet/summary", okData: WalletSamples.summary)
            let fixture = WalletAppFixture.make(
                suiteName: suiteName + "-\(outcome)", defaults: defaults, scope: "deletion_only"
            )
            let result = await fixture.network.client.send(ApiCall(operationId: "getWalletSummary"), isValid: { true })
            assertResult(result, outcome)
            let error = WalletErrors.of(result)
            if outcome == .forced {
                XCTAssertEqual(error.kind, .forceUpdate)
                XCTAssertEqual(error.textKey, "error.10405", "真强更照旧")
            } else {
                XCTAssertEqual(error.kind, .server, "\(outcome)：可重试的统一错误，不是网络错误、不是静默")
                XCTAssertEqual(error.textKey, "error.50001", "\(outcome)")
                XCTAssertNotEqual(error.textKey, WalletErrors.networkKey, "\(outcome)")
                XCTAssertTrue(error.showTrace6, "\(outcome)")
                XCTAssertTrue(
                    error.notice(id: 1).message(WalletDraftTexts()).contains(Self.trace6),
                    "\(outcome)：带 trace6"
                )
            }
            await assertSession(fixture.tokens, routing: fixture.routing, outcome)
        }
    }

    /// 钱包页执行器（WalletController，App 的真实 deps 与同一个真实 ApiClient；受限会话里路由守卫不开钱包页，这里直接按 App 的写法构造
    /// 执行器）：刷新成功 / 暂时失败两种结局显示统一错误 + trace6，【重试】后显示摘要。
    func testWalletPageShowsUnifiedErrorAndRetriesAfterNonForced10405() async throws {
        for outcome in [Outcome.refreshed, .transient] {
            WalletStubProtocol.reset()
            script.install()
            script(outcome, path: "GET /v1/wallet/summary", okData: WalletSamples.summary)
            let fixture = WalletAppFixture.make(
                suiteName: suiteName + "-page-\(outcome)", defaults: defaults, scope: "deletion_only"
            )
            let controller = WalletController(deps: fixture.wallet.deps)
            controller.load()
            await waitUntil("\(outcome)：错误态没有到位") { controller.state.error != nil }
            let error = try XCTUnwrap(controller.state.error)
            XCTAssertEqual(error.key, "error.50001", "\(outcome)")
            XCTAssertTrue(error.message(WalletDraftTexts()).contains(Self.trace6), "\(outcome)：带 trace6")
            XCTAssertFalse(fixture.routing.mustShowForceUpdate, "\(outcome)：不进强更")
            WalletActions.make(controller, controller.state).retry()
            await waitUntil("\(outcome)：重试后摘要没有到位") { controller.state.summary != nil }
            XCTAssertNil(controller.state.error, "\(outcome)")
        }
    }

    func testMeReadNonForced10405RefreshOutcomesShowUnifiedErrorOnTheRealClient() async throws {
        for outcome in Outcome.allCases {
            WalletStubProtocol.reset()
            script.install()
            script(outcome, path: "GET /v1/me", okData: WalletSamples.me)
            let fixture = MeAppFixture.make(
                suiteName: suiteName + "-me-\(outcome)", defaults: defaults, scope: "deletion_only"
            )
            let gate = RetryAfterGate()
            let probe = gate.probe()
            let result = await fixture.client.send(
                ApiCall(operationId: "getMe"), isValid: { true }, sendAllowed: probe.allowed, expected: nil
            )
            assertResult(result, outcome)
            let notice = MeErrors.readFailure(result, probe: probe, gate: gate, id: { 1 })
            if outcome == .forced {
                XCTAssertNil(notice, "真强更：交强更出口，不出错误提示")
                XCTAssertEqual(MeErrors.of(result, probe: probe).kind, .forceUpdate)
            } else {
                let unified = try XCTUnwrap(notice, "\(outcome)：不是静默")
                XCTAssertEqual(unified.key, "error.50001", "\(outcome)")
                XCTAssertTrue(unified.showTrace6, "\(outcome)")
                XCTAssertEqual(unified.traceId, Self.trace, "\(outcome)")
                XCTAssertFalse(gate.active, "\(outcome)：可重试（不启动禁用期）")
            }
            await assertSession(fixture.tokens, routing: fixture.routing, outcome)
        }
    }
}
