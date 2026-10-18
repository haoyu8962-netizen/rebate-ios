import CryptoKit
import Foundation
@testable import HomeCore
import XCTest

/// 公告关闭记录与弹窗计数（G10、G11、G14 ①⑤；共性第 9、19 条）：设备级、不淘汰、上海自然日、清空后旧票据写不进。
@MainActor
final class HomePrefsTests: XCTestCase {
    private var suites: [String] = []

    override func tearDown() async throws {
        for suite in suites {
            UserDefaults().removePersistentDomain(forName: suite)
        }
    }

    private func prefs(_ name: String = "prefs") -> (HomePrefsStore, UserDefaults) {
        let suite = "home-prefs-\(name)-\(UUID().uuidString)"
        suites.append(suite)
        let defaults = UserDefaults(suiteName: suite)!
        return (HomePrefsStore(defaults: defaults), defaults)
    }

    /// 关闭记录是设备级、跨实例保留、不按条数淘汰。
    func testNoticeClosedRecordsAreDeviceLevelAndNeverEvicted() {
        let (store, defaults) = prefs()
        for index in 0..<600 {
            XCTAssertTrue(store.recordClosed("nb|n\(index)|1", ticket: store.ticket(), at: HomeKit.noon))
        }
        let reopened = HomePrefsStore(defaults: defaults)
        let closed = reopened.closedKeys()
        XCTAssertEqual(closed.count, 600)
        XCTAssertTrue(closed.contains("nb|n0|1"), "最早的记录被淘汰了")
        XCTAssertTrue(closed.contains("nb|n599|1"))
    }

    /// 弹窗计数按上海自然日（与 UTC 日界不同：上海 07:00 是 UTC 前一天 23:00）。
    func testPopupCountsFollowShanghaiNaturalDay() throws {
        let (store, defaults) = prefs()
        let morning = try HomeVectors.millis("2026-10-10T07:00:00+08:00")
        XCTAssertTrue(store.recordShown(sectionId: "popup", nowMs: morning, ticket: store.ticket()))
        XCTAssertEqual(
            store.shownToday(sectionId: "popup", nowMs: try HomeVectors.millis("2026-10-10T09:00:00+08:00")),
            1
        )
        XCTAssertEqual(
            store.shownToday(sectionId: "popup", nowMs: try HomeVectors.millis("2026-10-10T23:59:59+08:00")),
            1
        )
        XCTAssertEqual(
            store.shownToday(sectionId: "popup", nowMs: try HomeVectors.millis("2026-10-11T00:00:00+08:00")),
            0
        )
        XCTAssertEqual(store.shownToday(sectionId: "other", nowMs: morning), 0, "按 section id 计")
        XCTAssertTrue(store.recordShown(sectionId: "popup", nowMs: morning + 1000, ticket: store.ticket()))
        XCTAssertEqual(HomePrefsStore(defaults: defaults).shownToday(sectionId: "popup", nowMs: morning + 2000), 2)
    }

    /// 撤回同意 / 切换环境清空两类记录；清理前取的票据之后被拒。
    func testClearAllEmptiesRecordsAndRejectsOlderTickets() throws {
        let (store, defaults) = prefs()
        XCTAssertTrue(store.recordClosed("nb|n1|1", ticket: store.ticket(), at: HomeKit.noon))
        XCTAssertTrue(store.recordShown(sectionId: "popup", nowMs: HomeKit.noon, ticket: store.ticket()))
        let stale = store.ticket()
        try store.clearAll()
        XCTAssertTrue(store.closedKeys().isEmpty)
        XCTAssertEqual(store.shownToday(sectionId: "popup", nowMs: HomeKit.noon), 0)
        XCTAssertFalse(store.recordClosed("nb|n2|1", ticket: stale, at: HomeKit.noon))
        XCTAssertFalse(store.recordShown(sectionId: "popup", nowMs: HomeKit.noon, ticket: stale))
        let reopened = HomePrefsStore(defaults: defaults)
        XCTAssertTrue(reopened.closedKeys().isEmpty)
        XCTAssertEqual(reopened.shownToday(sectionId: "popup", nowMs: HomeKit.noon), 0)
    }

    /// 记录只存组合键与时刻，不存公告正文与图片地址（G11）。
    func testRecordsHoldNoTextOrImageAddresses() {
        let (store, defaults) = prefs()
        XCTAssertTrue(store.recordClosed("nb|n1|1", ticket: store.ticket(), at: HomeKit.noon))
        XCTAssertTrue(store.recordShown(sectionId: "popup", nowMs: HomeKit.noon, ticket: store.ticket()))
        let dump = String(describing: defaults.dictionaryRepresentation())
        XCTAssertFalse(dump.contains("https://"))
        XCTAssertFalse(dump.contains("测试公告"))
    }
}
