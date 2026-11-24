@testable import Couli
import CouliNetwork
import Foundation
import SwiftUI
import UIKit
import Wallet
import WalletCore
import XCTest

/// FU-IOS-SNAPSHOT-STALE-TEXT 文字级回归钉（编排 D10-2877，独立写测方）：截图容差 0.99 / 0.98 放得过一整行字，图与字会分家。
/// 这里在与 `PayoutVisualSnapshotTests` / `WithdrawVisualSnapshotTests` 拍图**同一夹具、同一宿主、同一画布**下，断言错误条 /
/// 阻断提示实际渲染的文字（测量桥上报的 `.text`）。期望值 = 运行时文案字典（`deps.texts`，契约优先、草稿兜底）取**钉死的键** +
/// 夹具值拼的 trace6，不写中文；钉死的键不经生产映射推出，错误码映射改回旧键会红。
@MainActor
final class SnapshotStateTextPinTests: PayoutVisualTestCase {
    /// 统一错误键（钱包 50301 回落，6ead8ba / 1e6edad）。
    private let unifiedKey = "error.50001"

    /// 截图用例每镜之前的清场（与 `PayoutVisualSnapshotTests.run` 同一顺序）。
    private func resetShot() async {
        await releaseHeld()
        realBackend?.release()
        laborBackend?.release()
        pendingBackend = MemoryPendingKeyBackend()
    }

    /// 夹具失败结果（`visualFailure`）里的 trace_id：trace6 按它的末 6 位拼。
    private func fixtureTraceId(_ code: Int, data: String = "{}") throws -> String {
        guard case let .failure(_, _, _, traceId, _, _) = visualFailure(code, data: data) else {
            XCTFail("visualFailure 不再返回 failure，夹具变了")
            return ""
        }
        return try XCTUnwrap(traceId, "夹具失败结果缺 trace_id")
    }

    /// 统一错误消息：钉死键 + 夹具 trace6（与页面同一份「契约优先、草稿兜底」字典）。
    private func message(_ key: String, _ texts: WalletTexts, traceId: String) -> String {
        ErrorTrace.message(key: key, traceId: traceId, append: true) { texts.format($0, $1) }
    }

    private func laborSignFailedCode() throws -> Int {
        let labor = try XCTUnwrap(PayoutVisualData.root()["labor"] as? [String: Any], "visualPayout 缺 labor")
        let failed = try XCTUnwrap(labor["signFailed"] as? [String: Any], "visualPayout.labor 缺 signFailed")
        return try XCTUnwrap(failed["code"] as? Int, "visualPayout.labor.signFailed 缺 code")
    }

    // MARK: - 劳务协议签署失败（testLabor.state-labor-sign-failed-light / -dark）

    /// 错误条 `labor.signError.text` = error.50001 + 夹具 trace6；不是旧图上的 error.50301 回落句。
    func testLaborSignFailedErrorBarText() async throws {
        let code = try laborSignFailedCode()
        XCTAssertEqual(code, 50301, "前提：向量与截图用例 failSign(50301) 同码（PayoutVisualSnapshotTests.swift:254、260）")
        let shots: [(name: String, canvas: WithdrawVisualHost.Canvas)] = [
            ("state-labor-sign-failed-light", .init()),
            ("state-labor-sign-failed-dark", .init(height: 1119, dark: true)),
        ]
        let traceId = try fixtureTraceId(code)
        for shot in shots {
            await resetShot()
            let (host, _) = try await openLabor(canvas: shot.canvas) { $0.failSign(code) }
            host.laborActions?.toggle()
            host.laborActions?.sign()
            let frame = await host.stable { $0.probes["labor.signError.text"] != nil }
            XCTAssertNotNil(frame, "\(shot.name)：签署失败错误条没有出现")
            let texts = host.wallet.deps.texts
            let expected = message(unifiedKey, texts, traceId: traceId)
            let stale = message("error.\(code)", texts, traceId: traceId)
            XCTAssertNotEqual(expected, stale, "\(shot.name)：前提：新旧两句可分")
            XCTAssertEqual(try text("labor.signError.text"), expected, "\(shot.name)：错误条文字")
        }
    }

    // MARK: - 实名 50301（testRealName.state-realname-50301-light）

    /// 错误条 `realname.error.text` = error.50001 + 夹具 trace6（D10-887 ②）；不是旧图上的 error.50301 回落句。
    /// 注：实名页 50301 有两层兜底（SensitiveOutcome.serverKey 与 RealNameController.notice 的 50301 分支），两处都改回旧键这里才红；
    /// 只改一处时页面字不变、图也不会过时（独立评审 r1 S3-1）。
    func testRealName50301ErrorBarText() async throws {
        await resetShot()
        let error = try PayoutVisualData.realnameError("server")
        XCTAssertEqual(error.code, 50301, "前提：visualPayout.realname.errors.server 仍是 50301")
        // 与截图用例 realError("server") 同一画布与步骤（PayoutVisualSnapshotTests.swift:101–108、214）
        let (host, _) = try await openRealName(canvas: .init(height: 1001))
        realBackend?.fail(error.code, data: error.data)
        _ = try await openConsent(host, needProbes: false)
        await agree(host)
        let frame = await host.stable { $0.probes["realname.error.text"] != nil }
        XCTAssertNotNil(frame, "实名 50301：错误条没有出现")
        let texts = host.wallet.deps.texts
        let traceId = try fixtureTraceId(error.code, data: error.data)
        let expected = message(unifiedKey, texts, traceId: traceId)
        XCTAssertNotEqual(expected, message("error.\(error.code)", texts, traceId: traceId), "前提：新旧两句可分")
        XCTAssertEqual(try text("realname.error.text"), expected, "实名 50301：错误条文字")
    }

    // MARK: - 提现页 blocked_payee_daily_count（testPageStates.WithdrawPageStates-blocked_payee_daily_count-light）

    /// 阻断提示 `withdraw.guide.text` = 契约子键 error.<block_code>.<block_reason>（4e08d82）；不是旧图上的 error.<block_code> 回落句。
    func testWithdrawBlockedPayeeDailyCountGuideText() async throws {
        let name = "blocked_payee_daily_count"
        let rules = try WithdrawVisualData.rules(name)
        let code = try XCTUnwrap(rules["block_code"] as? Int, "\(name) 缺 block_code")
        let reason = try XCTUnwrap(rules["block_reason"] as? String, "\(name) 缺 block_reason")
        // 与截图用例同一规则与画布（WithdrawVisualSnapshotTests.swift:95–101）
        let (host, _) = try await openWithdraw(name, canvas: .init(height: 1000), waitFor: "withdraw.guide.text")
        let texts = host.wallet.deps.texts
        let key = "error.\(code).\(reason)"
        XCTAssertTrue(texts.has(key), "前提：字典有 \(key)（缺键时页面回落 error.\(code)）")
        let expected = texts.text(key)
        XCTAssertFalse(expected.isEmpty, "前提：\(key) 非空")
        XCTAssertNotEqual(expected, texts.text("error.\(code)"), "前提：子键与回落句可分")
        XCTAssertEqual(try text("withdraw.guide.text"), expected, "\(name)：阻断提示文字")
    }
}
