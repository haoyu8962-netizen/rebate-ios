import ClientCore
@testable import Couli
import CouliNetwork
import Foundation
import Generated
import Trade
import XCTest

/// LOCK-ios 段 1（D10-1682 ①，契约 d47f660e5 / events.yaml v6）：link_jump.result 只取 requested / failed / unknown，
/// failed 必带 failure_reason（sdk_init_failed / step_failed）。执行器仍用自己的结果词，经 `AppLinkJumpSink.linkJumpResult`
/// 映射；这里逐个钉住映射表，再经真实上报口（`AppLinkJumpSink.event` / `report`）看事件里的 result 与 failure_reason。
@MainActor
final class LockIosLinkJumpMappingTests: XCTestCase {
    private typealias Result = TrackerEvents.LinkJump.ResultValue
    private typealias Reason = TrackerEvents.LinkJump.FailureReasonValue

    private struct Case<Value> {
        let raw: String
        let result: Value
        let reason: String?
    }

    // MARK: - 映射表

    func testExecutorWordsMapToContractValues() throws {
        let cases: [Case<Result>] = [
            Case(raw: JumpTypes.launched, result: .requested, reason: nil),
            Case(raw: JumpTypes.copied, result: .requested, reason: nil),
            Case(raw: JumpTypes.failed, result: .failed, reason: Reason.stepFailed.rawValue),
            Case(raw: JumpTypes.sdkInitFailed, result: .failed, reason: Reason.sdkInitFailed.rawValue),
        ]
        for item in cases {
            let mapped = try XCTUnwrap(AppLinkJumpSink.linkJumpResult(item.raw), item.raw)
            XCTAssertEqual(mapped.0, item.result, item.raw)
            XCTAssertEqual(mapped.1?.rawValue, item.reason, item.raw)
        }
    }

    func testContractValuesPassThrough() throws {
        let requested = try XCTUnwrap(AppLinkJumpSink.linkJumpResult("requested"))
        XCTAssertEqual(requested.0, .requested)
        XCTAssertNil(requested.1)
        let unknown = try XCTUnwrap(AppLinkJumpSink.linkJumpResult("unknown"))
        XCTAssertEqual(unknown.0, .contractUnknown)
        XCTAssertNil(unknown.1)
    }

    /// nil、空串、未知词、大小写不同、failure_reason 的取值本身都不上报（不臆造）。
    func testNilAndUnknownWordsAreNotReported() {
        XCTAssertNil(AppLinkJumpSink.linkJumpResult(nil))
        for raw in ["", "opened", "LAUNCHED", "Requested", "success", "step_failed", "cancelled", " launched"] {
            XCTAssertNil(AppLinkJumpSink.linkJumpResult(raw), "「\(raw)」不该上报")
        }
    }

    /// 失败一律带 failure_reason、绝不记成 requested；反过来 requested / unknown 不带 failure_reason。
    func testFailedAlwaysCarriesReasonAndNeverBecomesRequested() {
        let words = [JumpTypes.launched, JumpTypes.copied, JumpTypes.failed, JumpTypes.sdkInitFailed] +
            Result.allCases.map(\.rawValue)
        for raw in words {
            guard case let (result, reason)? = AppLinkJumpSink.linkJumpResult(raw) else {
                XCTFail("\(raw) 应能映射")
                continue
            }
            if result == .failed {
                XCTAssertNotNil(reason, "\(raw) → failed 必须带 failure_reason")
            } else {
                XCTAssertNil(reason, "\(raw) → \(result.rawValue) 不得带 failure_reason")
            }
        }
        for raw in [JumpTypes.failed, JumpTypes.sdkInitFailed] {
            XCTAssertNotEqual(AppLinkJumpSink.linkJumpResult(raw)?.0, .requested, "\(raw) 绝不映射成 requested")
        }
    }

    // MARK: - 经上报口构造的事件

    private func startup(_ result: String) -> TrackEvent? {
        AppLinkJumpSink.event(["phase": "startup", "union_platform": "taobao", "step": "sdk", "result": result])
    }

    func testEventFieldsCarryMappedResultAndReason() throws {
        let cases: [Case<String>] = [
            Case(raw: JumpTypes.launched, result: "requested", reason: nil),
            Case(raw: JumpTypes.copied, result: "requested", reason: nil),
            Case(raw: JumpTypes.failed, result: "failed", reason: "step_failed"),
            Case(raw: JumpTypes.sdkInitFailed, result: "failed", reason: "sdk_init_failed"),
            Case(raw: "requested", result: "requested", reason: nil),
            Case(raw: "unknown", result: "unknown", reason: nil),
        ]
        for item in cases {
            let (raw, result, reason) = (item.raw, item.result, item.reason)
            let event = try XCTUnwrap(startup(raw), raw)
            XCTAssertEqual(event.name, "link_jump", raw)
            XCTAssertTrue(event.missingRequired.isEmpty, "\(raw)：\(event.missingRequired)")
            XCTAssertEqual(event.fields["result"], .string(result), raw)
            XCTAssertEqual(event.fields["failure_reason"], reason.map(TrackValue.string), raw)
        }
    }

    func testEventIsDroppedForNilOrUnknownWord() {
        XCTAssertNil(AppLinkJumpSink.event(["phase": "startup", "union_platform": "taobao", "step": "sdk"]))
        XCTAssertNil(startup("opened"))
        XCTAssertNil(startup("step_failed"))
    }

    /// 购买流程经 LinkJumpEvents.build → report：失败步骤的事件带 failed + step_failed，未知词的步骤不上报。
    func testPurchaseFlowThroughSink() throws {
        var tracked: [TrackEvent] = []
        let owner = RequestOwnership(account: "user-a", generation: 0, epoch: 0)
        let sink = AppLinkJumpSink(track: { event, _ in tracked.append(event) }, ownership: { owner })
        let steps: [TradeObject] = [
            ["phase": "purchase", "union_platform": "taobao", "step": "sdk", "result": JumpTypes.failed,
             "duration_ms": 10, "installed": "true"],
            ["phase": "purchase", "union_platform": "taobao", "step": "copy_tpwd", "result": JumpTypes.copied,
             "duration_ms": 5, "installed": "true"],
            ["phase": "purchase", "union_platform": "taobao", "step": "h5", "result": "opened",
             "duration_ms": 5, "installed": "true"],
        ]
        for fields in LinkJumpEvents.build(attemptId: "A1", linkId: "L1", steps: steps, isAuthJump: false) {
            sink.report(fields, owner: owner)
        }
        let byStep = Dictionary(tracked.compactMap { event -> (String, TrackEvent)? in
            guard case let .string(step)? = event.fields["step"] else { return nil }
            return (step, event)
        }, uniquingKeysWith: { first, _ in first })
        let failed = try XCTUnwrap(byStep["sdk"], "失败步骤的事件不丢")
        XCTAssertEqual(failed.fields["result"], .string("failed"))
        XCTAssertEqual(failed.fields["failure_reason"], .string("step_failed"))
        let copied = try XCTUnwrap(byStep["copy_tpwd"], "已复制口令的事件不丢")
        XCTAssertEqual(copied.fields["result"], .string("requested"))
        XCTAssertNil(copied.fields["failure_reason"])
        XCTAssertNil(byStep["h5"], "未知结果词不上报")
        for event in tracked {
            XCTAssertNotEqual(event.fields["result"], .string("launched"))
            XCTAssertNotEqual(event.fields["result"], .string("copied"))
        }
    }
}
