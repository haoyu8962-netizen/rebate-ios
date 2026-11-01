@testable import Couli
import Foundation
import MeCore
import XCTest

/// visualMe 夹具自检（brief §6、G-M18）：照 Android 合入版逐字节，报文能过生产解析（锁定契约形状），画板要的压力值都在。
final class MeVisualFixtureTests: XCTestCase {
    private func profile(_ name: String) throws -> [String: Any] {
        try MeVisualData.profile(name)
    }

    func testProfilesPassProductionParser() throws {
        let names = ["me_member", "me_new_user", "me_bound_user", "me_no_invite_code", "me_negative", "me_frozen",
                     "me_long", "me_no_sum"]
        for name in names {
            let me = try XCTUnwrap(MeJson.me(profile(name)), "\(name) 过不了生产解析")
            XCTAssertEqual(
                try XCTUnwrap(profile(name)["balance"] as? [String: Any]).count,
                3,
                "\(name) 只有三个金额字段（G-M02）"
            )
            XCTAssertFalse(me.nickname.isEmpty, name)
        }
    }

    func testStressAndTrapValues() throws {
        XCTAssertEqual(try XCTUnwrap(MeJson.me(profile("me_long"))).nickname.count, 16, "长昵称 16 字")
        XCTAssertEqual(try XCTUnwrap(MeJson.me(profile("me_long"))).withdrawableFen, 9_999_999)
        XCTAssertEqual(try XCTUnwrap(MeJson.me(profile("me_long"))).estimatedTotalFen, 99_999_999)
        let trap = try XCTUnwrap(profile("me_no_sum")["balance"] as? [String: Any])
        XCTAssertNotEqual(trap["available_fen"] as? Int, trap["withdrawable_fen"] as? Int, "me_no_sum 故意对不上")
        XCTAssertNil(try XCTUnwrap(MeJson.me(profile("me_no_invite_code"))).inviteCode)
        XCTAssertEqual(try XCTUnwrap(MeJson.me(profile("me_frozen"))).riskState, "frozen")
    }

    func testClockAndLocalStates() throws {
        XCTAssertEqual(
            try MeVisualData.nowMillis(),
            try MeVisualData.millis("2026-10-12T02:30:00Z"),
            "固定时钟 10:30 +08:00"
        )
        let guide = try MeVisualData.local("me_hidden_guide")
        let denied = try MeVisualData.millis(XCTUnwrap(guide["deniedAt"] as? String))
        XCTAssertGreaterThanOrEqual(try MeVisualData.nowMillis() - denied, NotifyGuideBar.denyWaitMillis, "被拒满 48 小时")
        XCTAssertTrue(guide["closedAt"] is NSNull, "从未关闭")
        XCTAssertTrue(try MeVisualData.routes("routes_public").contains(MeView.earnings))
        XCTAssertFalse(try MeVisualData.routes("routes_beta").contains(MeView.earnings))
    }
}
