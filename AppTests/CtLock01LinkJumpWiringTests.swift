import ClientCore
@testable import Couli
import CouliNetwork
import Foundation
import Generated
import Trade
import XCTest

/// CT-LOCK-01：events.yaml v2 在 link_jump 的 link_id 与 duration_ms 之间插入可选 sdk_open_by / sdk_error_code。Swift 的生成函数
/// 全部带参数标签，唯一调用处 `AppLinkJumpSink.event` 按标签传参，不会错位。经真实上报口（执行器字段 → LinkJumpEvents.build →
/// AppLinkJumpSink → TrackerEvents.linkJump）证明 duration_ms / installed 落在原字段、不带新字段、事件不丢（G05：不上报 sdk_open_by）。
@MainActor
final class CtLock01LinkJumpWiringTests: XCTestCase {
    func testPurchaseStepKeepsDurationAndInstalledInTheirOwnFields() throws {
        var tracked: [(TrackEvent, TrackAttribution?)] = []
        let owner = RequestOwnership(account: "user-a", generation: 0, epoch: 0)
        let sink = AppLinkJumpSink(track: { tracked.append(($0, $1)) }, ownership: { owner })
        let step: TradeObject = [
            "phase": "purchase", "union_platform": "taobao", "step": "sdk", "result": "launched",
            "duration_ms": 42, "installed": "true",
            // 执行器不会带这些键；即使带了也不进事件（LinkJumpEvents 白名单）
            "sdk_open_by": "url", "sdk_error_code": "E1",
        ]
        for fields in LinkJumpEvents.build(attemptId: "A7", linkId: "L1", steps: [step], isAuthJump: false) {
            sink.report(fields, owner: owner)
        }
        XCTAssertEqual(tracked.count, 1, "事件不丢")
        let event = try XCTUnwrap(tracked.first?.0)
        XCTAssertEqual(event.name, "link_jump")
        XCTAssertTrue(event.missingRequired.isEmpty)
        XCTAssertEqual(event.fields["duration_ms"], .integer(42))
        XCTAssertEqual(event.fields["installed"], .string("true"))
        XCTAssertEqual(event.fields["attempt_id"], .string("A7"))
        XCTAssertEqual(event.fields["link_id"], .string("L1"))
        XCTAssertEqual(event.fields["step"], .string("sdk"))
        XCTAssertEqual(event.fields["result"], .string("launched"))
        XCTAssertNil(event.fields["sdk_open_by"])
        XCTAssertNil(event.fields["sdk_error_code"])
        XCTAssertEqual(TrackerEvents.version, "2")
    }

    func testStartupStepHasNoPurchaseFields() throws {
        let event = try XCTUnwrap(AppLinkJumpSink.event([
            "phase": "startup", "union_platform": "taobao", "step": "sdk", "result": "sdk_init_failed",
        ]))
        XCTAssertTrue(event.missingRequired.isEmpty)
        XCTAssertNil(event.fields["duration_ms"])
        XCTAssertNil(event.fields["installed"])
        XCTAssertNil(event.fields["sdk_open_by"])
        XCTAssertNil(event.fields["sdk_error_code"])
    }
}
