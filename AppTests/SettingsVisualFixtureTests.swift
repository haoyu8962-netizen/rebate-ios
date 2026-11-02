@testable import Couli
import MeCore
import XCTest

/// visualSettings 夹具自检（brief §6、G-S18）：报文过生产解析（锁定契约形状），画板要的压力值都在。
@MainActor
final class SettingsVisualFixtureTests: XCTestCase {
    func testProfilesPassProductionParser() throws {
        for name in ["settings_member", "settings_long_nickname", "settings_unbound"] {
            XCTAssertNotNil(try MeJson.me(SettingsVisualData.profile(name)), "\(name) 过不了生产解析")
        }
        XCTAssertEqual(
            try XCTUnwrap(MeJson.me(SettingsVisualData.profile("settings_long_nickname"))).nickname.count,
            16
        )
    }

    func testNicknameInputsMatchRules() throws {
        let original = try SettingsVisualData.nickname("original")
        func check(_ input: String) -> NicknameCheck {
            NicknameInput.model(current: original, input: input)
        }
        XCTAssertFalse(check(try SettingsVisualData.nickname("tooLong")).saveEnabled, "17 字不可保存")
        XCTAssertEqual(check(try SettingsVisualData.nickname("tooLong")).length, 17)
        XCTAssertTrue(check(try SettingsVisualData.nickname("stress")).saveEnabled, "16 字可保存")
        XCTAssertEqual(check(try SettingsVisualData.nickname("grapheme")).length, 16, "按字素算")
        XCTAssertTrue(check(try SettingsVisualData.nicknameInput("limit")).saveEnabled)
        XCTAssertTrue(check(try SettingsVisualData.nicknameInput("sensitive")).saveEnabled)
    }

    func testClockCacheAndRoutes() throws {
        XCTAssertEqual(try SettingsVisualData.nowMillis(), try MeVisualData.millis("2026-10-12T02:30:00Z"))
        XCTAssertEqual(try SettingsVisualData.cacheBytes(), 12 * 1024 * 1024, "12 MB")
        XCTAssertTrue(try SettingsVisualData.routes("routes_public").contains(SettingsController.deleteAccount))
        XCTAssertFalse(try SettingsVisualData.routes("routes_beta").contains(SettingsController.deleteAccount))
    }

    /// 每个错误键都不带对勾、成功键都带（G-S06 的数据，映射本身在 `SettingsVisualNoticeTests`）。
    func testNoticeTable() throws {
        let table = try SettingsVisualData.notices()
        XCTAssertEqual(table.count, 7)
        for row in table {
            XCTAssertEqual(row.check, !(row.key.hasPrefix("error.") || row.key == "notify.switch_failed"), row.key)
        }
    }
}
