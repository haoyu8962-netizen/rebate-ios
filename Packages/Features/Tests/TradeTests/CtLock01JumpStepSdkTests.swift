import CouliNetwork
import Foundation
@testable import Trade
import TradeJump
import XCTest

/// CT-LOCK-01：`JumpStep` 新增可选 `sdk`（BaichuanOpen）。方案按字典动态读取，新字段一律忽略：步骤、模拟结果、执行结果、交给 SDK 的值、
/// 上报字段与不带 sdk 时完全相同（按 sdk.open_by 执行归百川接入，G05）。
@MainActor
final class CtLock01JumpStepSdkTests: XCTestCase {
    /// 记录交给 SDK 的值；可用、拉起成功。
    private final class RecordingBaichuan: BaichuanAdapter {
        var opened: [String] = []
        var ready: Bool {
            true
        }

        var supportsSdkToken: Bool {
            false
        }

        func initialize() -> Bool {
            true
        }

        func retryInitIfFailed() -> Bool {
            true
        }

        func open(_ value: String) -> BaichuanOpenResult {
            opened.append(value)
            return .launched
        }

        func authorize() async -> BaichuanAuthResult {
            .failed
        }
    }

    private static let sdkObject: TradeObject = [
        "provider": "baichuan", "open_by": "url", "url": "https://s.click.taobao.com/t?e=x",
        "taoke": ["pid": "mm_1_2_3", "relation_id": "r1"],
    ]

    private func plan(withSdk: Bool) -> TradeObject {
        var sdkStep: TradeObject = ["type": "sdk", "value": "https://s.click.taobao.com/t?e=x"]
        var schemeStep: TradeObject = ["type": "scheme", "value": "taobao://x"]
        if withSdk {
            sdkStep["sdk"] = Self.sdkObject
            schemeStep["sdk"] = ["provider": "baichuan", "open_by": "code", "item_id": "123"]
        }
        return [
            "primary": sdkStep, "fallbacks": [schemeStep, ["type": "h5", "value": "https://h5.test/x"]],
            "expire_at": TradeFixtures.future(),
        ]
    }

    func testRunnerStepsAndSimulationIgnoreTheSdkObject() {
        let with = plan(withSdk: true)
        let without = plan(withSdk: false)
        XCTAssertEqual(
            JumpPlanRunner.steps(with).map { TJSON.string($0["type"]) },
            JumpPlanRunner.steps(without).map { TJSON.string($0["type"]) }
        )
        XCTAssertEqual(
            JumpPlanRunner.steps(with).map { TJSON.string($0["value"]) },
            JumpPlanRunner.steps(without).map { TJSON.string($0["value"]) }
        )
        for results in [["launched"], ["sdk_init_failed", "launched"], ["failed", "failed", "launched"], []] {
            XCTAssertEqual(
                JumpPlanRunner.simulate(plan: with, installed: ["app": true], stepResults: results),
                JumpPlanRunner.simulate(plan: without, installed: ["app": true], stepResults: results),
                "\(results)"
            )
        }
    }

    func testExecutorHandsValueToTheSdkAndReportsTheSameFields() async {
        var outcomes: [JumpOutcome] = []
        var opened: [[String]] = []
        var reported: [[TradeObject]] = []
        for withSdk in [true, false] {
            let baichuan = RecordingBaichuan()
            let sink = FakeSink()
            let executor = TradeJumpExecutor(
                ports: FakePorts(), baichuan: baichuan, sink: sink, elapsedMillis: { 7 }
            )
            let outcome = await executor.execute(
                plan: plan(withSdk: withSdk), platform: "taobao", installed: TradeConstants.installedTrue,
                identity: PurchaseIdentity(attemptId: "A1", linkId: "L1")
            )
            outcomes.append(outcome)
            opened.append(baichuan.opened)
            reported.append(sink.events)
        }
        XCTAssertEqual(outcomes[0], outcomes[1])
        XCTAssertEqual(opened[0], ["https://s.click.taobao.com/t?e=x"], "仍把 value 原样交给 SDK，不读 sdk 对象")
        XCTAssertEqual(opened[0], opened[1])
        XCTAssertEqual(reported[0].count, 1)
        XCTAssertEqual(
            reported[0].map { NSDictionary(dictionary: $0) },
            reported[1].map { NSDictionary(dictionary: $0) }
        )
        XCTAssertNil(reported[0].first?["sdk_open_by"], "不上报 sdk_open_by（G05）")
        XCTAssertNil(reported[0].first?["sdk_error_code"])
    }

    func testOpenResultWithSdkInTheJumpMapsToTheSameAction() {
        let context: TradeObject = ["currentPriceFen": 4678, "currentRebateMaxFen": 234]
        let without = TradeFixtures.open(steps: [["type": "sdk", "value": "https://s.click.taobao.com/t?e=x"]])
        var with = without
        var jump = TJSON.object(with["jump"]) ?? [:]
        var primary = TJSON.object(jump["primary"]) ?? [:]
        primary["sdk"] = Self.sdkObject
        jump["primary"] = primary
        with["jump"] = jump
        XCTAssertEqual(
            OpenResponseAction.map(response: ["code": 0, "data": with], context: context),
            OpenResponseAction.map(response: ["code": 0, "data": without], context: context)
        )
    }

    /// open 错误动作：30102 / 30111 带 sharer_auth_invalid 只提示（不授权、不给无返利）；无 reason 照旧授权。
    func testSharerAuthInvalidReasonMakesTheOpenErrorActionPromptOnly() {
        for code in [30102, 30111] {
            let outcome = OpenErrorAction.map(code: code, data: ["reason": "sharer_auth_invalid"])
            XCTAssertEqual(outcome.actionRaw, OpenErrorActions.notice, "\(code)")
            XCTAssertFalse(outcome.offerNoRebate, "\(code)")
            XCTAssertFalse(outcome.offerContact, "\(code)")
            XCTAssertEqual(outcome.textKey, "error.\(code)", "\(code)")
        }
        XCTAssertEqual(OpenErrorAction.map(code: 30102, data: [:]).actionRaw, OpenErrorActions.authSheet)
        XCTAssertEqual(OpenErrorAction.map(code: 30101, data: [:]).actionRaw, OpenErrorActions.authSheet)
        XCTAssertEqual(OpenErrorAction.map(code: 30111, data: [:]).actionRaw, OpenErrorActions.authJump)
        XCTAssertEqual(
            OpenErrorAction.map(code: 30111, data: ["reason": "auth_unavailable"]).actionRaw, OpenErrorActions.authJump,
            "30111 的 auth_unavailable 不在生成表里：动作不变"
        )
        XCTAssertEqual(
            OpenErrorAction.map(code: 30102, data: ["reason": "auth_unavailable"]).actionRaw, OpenErrorActions.notice
        )
    }
}
