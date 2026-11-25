import Combine
import Foundation
@testable import HomeCore
import XCTest

/// 金刚区徽标的 expire_at（FU-IOS-HOME-ENTRY-OBJECT-FIELDS；契约 $defs/badge.expire_at = $defs/instant；
/// D10-2998 (a)、D10-3076 (2)、D10-3082、D10-3092）。
/// 解析：只认 `YYYY-MM-DDTHH:MM:SS(.1–6 位)+08:00` 且是真实日历时刻，换算到绝对毫秒（小数截断）；不合法只丢徽标。
/// 到期：now >= expire_at 隐藏徽标、保留条目、不重拉页面；未到期的到期时刻并进重算计时（与公告条共用一个计时）。
/// 计时断言用无端口的包内页启动（没有 1500 ms 兜底计时），`clock.scheduled` 只数首页自己的重算；
/// 只经 HomeItemUi 与替身时钟断言，不引用实现方新增的符号。
@MainActor
final class LockIosHomeEntryBadgeExpiryTests: HomeRigTestCase {
    private typealias JSONObject = [String: Any]

    /// 换一套时钟停在 now、没有端口的设备，冷启动显示这一页（来源是包内页）。
    private func bundled(_ page: JSONObject, at now: Int64) async -> HomeController {
        rig.tearDown()
        rig = HomeRig(port: nil, clock: ManualClock(now))
        rig.bundled = HomeVectors.data(page)
        let controller = rig.controller()
        await rig.start(controller)
        XCTAssertEqual(controller.state.source, .bundled, "前提：显示的是包内页")
        return controller
    }

    private func titles(_ controller: HomeController) -> [String] {
        controller.state.section("icons")?.items.compactMap(\.title) ?? []
    }

    private func badge(_ controller: HomeController, _ title: String) -> String? {
        controller.state.section("icons")?.items.first { $0.title == title }?.badge
    }

    /// 带 expire_at 的徽标在 expected − 1 毫秒显示、恰好 expected 不显示（两次各自冷启动，钉住换算到毫秒）。
    private func assertExpires(_ iso: String, at expected: Int64, line: UInt = #line) async {
        let page = ExpiryKit.page([ExpiryKit.entry("甲", ExpiryKit.text("新", expire: iso)), ExpiryKit.entry("乙")])
        let before = await bundled(page, at: expected - 1)
        XCTAssertEqual(titles(before), ["甲", "乙"], "\(iso)：条目保留", line: line)
        XCTAssertEqual(badge(before, "甲"), "新", "\(iso)：到期前 1 毫秒应显示", line: line)
        let atExpiry = await bundled(page, at: expected)
        XCTAssertEqual(titles(atExpiry), ["甲", "乙"], "\(iso)：到点条目保留", line: line)
        XCTAssertNil(badge(atExpiry, "甲"), "\(iso)：恰好到期（now == expire_at）应隐藏", line: line)
    }

    // MARK: - 解析：合法格式换算到毫秒

    /// 无小数、1 位、3 位、4 位、6 位小数：小数取前 3 位截断为毫秒（不四舍五入）。
    func testExpireAtFractionIsTruncatedToMilliseconds() async {
        let minute = HomeKit.noon + 60000
        await assertExpires("2026-10-10T12:01:00+08:00", at: minute)
        await assertExpires("2026-10-10T12:01:00.5+08:00", at: minute + 500)
        await assertExpires("2026-10-10T12:01:00.123+08:00", at: minute + 123)
        await assertExpires("2026-10-10T12:01:00.9999+08:00", at: minute + 999)
        await assertExpires("2026-10-10T12:01:00.123999+08:00", at: minute + 123)
        await assertExpires("2026-10-10T12:01:00.000001+08:00", at: minute)
    }

    /// 日历边界（期望值另用 python datetime 独立算出）：0000 / 0001 / 0004 / 0099 年（照鸿蒙 E09 及其 r2 N2）、
    /// 闰年 02-29（2000、2028）、9999 年末。
    func testExpireAtCalendarEdgesConvertExactly() async {
        await assertExpires("0000-02-29T00:00:00+08:00", at: -62_162_150_400_000)
        await assertExpires("0001-01-01T00:00:00+08:00", at: -62_135_625_600_000)
        await assertExpires("0001-01-01T08:00:00+08:00", at: -62_135_596_800_000)
        await assertExpires("0004-02-29T12:34:56.789+08:00", at: -62_035_874_703_211)
        await assertExpires("0099-12-31T23:59:59.999+08:00", at: -59_011_488_000_001)
        await assertExpires("2000-02-29T23:59:59+08:00", at: 951_839_999_000)
        await assertExpires("2028-02-29T00:00:00+08:00", at: 1_835_366_400_000)
        await assertExpires("9999-12-31T23:59:59.999999+08:00", at: 253_402_271_999_999)
    }

    // MARK: - 解析：不合法只丢徽标

    /// D10-3076 四条（Z、其他偏移、缺秒、7 位小数）与 null、非真实日期等 → 只丢徽标、条目保留；对照条（合法 expire_at）照常显示。
    func testInvalidExpireAtDropsOnlyTheBadge() async {
        let values: [Any] = [
            "2027-01-01T00:00:00Z", "2027-01-01T00:00:00+09:00", "2027-01-01T00:00+08:00",
            "2027-01-01T00:00:00.1234567+08:00", NSNull(), "2027-02-30T00:00:00+08:00", "2027-13-01T00:00:00+08:00",
            "2027-02-29T00:00:00+08:00", "2100-02-29T00:00:00+08:00", "2027-04-31T00:00:00+08:00",
            "2027-00-10T00:00:00+08:00", "2027-01-00T00:00:00+08:00", "2027-01-01T24:00:00+08:00",
            "2027-01-01T23:60:00+08:00", "2027-01-01T23:59:60+08:00", "2027-01-01T00:00:00.+08:00",
            "2027-01-01 00:00:00+08:00", "2027-1-01T00:00:00+08:00", "2027-01-01T00:00:00+0800",
            "2027-01-01T00:00:00-08:00", "", 1_798_732_800_000,
        ]
        var entries = values.enumerated().map { index, expire in
            ExpiryKit.entry("格\(index)", ExpiryKit.text("新", expire: expire))
        }
        entries.append(ExpiryKit.entry("对照", ExpiryKit.text("新", expire: "2027-01-01T00:00:00+08:00")))
        let controller = await bundled(ExpiryKit.page(entries), at: HomeKit.noon)
        XCTAssertEqual(titles(controller), entries.compactMap { $0["title"] as? String }, "只丢徽标，条目都在")
        XCTAssertEqual(badge(controller, "对照"), "新", "对照条：合法 expire_at 未到期应显示")
        for (index, value) in values.enumerated() {
            XCTAssertNil(badge(controller, "格\(index)"), "expire_at \(value) 不合法，应只丢徽标")
        }
    }

    // MARK: - 到期重算

    /// 未到期显示；时钟走到到期并触发后隐藏，条目与图片不变、页面没有重拉（网络版启动）。
    func testBadgeHidesAtExpiryWithoutRefetch() async throws {
        let page = ExpiryKit.page([
            ExpiryKit.entry("甲", ExpiryKit.text("新", expire: "2026-10-10T12:01:00+08:00")), ExpiryKit.entry("乙"),
        ])
        let controller = await show(page)
        XCTAssertEqual(badge(controller, "甲"), "新", "未到期显示 text")
        let images = controller.state.section("icons")?.items.map(\.image)
        let fetches = try XCTUnwrap(rig.port?.pageCalls.count)
        rig.clock.advance(59999)
        await controller.whenIdle()
        XCTAssertEqual(badge(controller, "甲"), "新", "差 1 毫秒仍显示")
        rig.clock.advance(1)
        await controller.whenIdle()
        XCTAssertNil(badge(controller, "甲"), "到点由排好的重算隐藏徽标")
        XCTAssertEqual(titles(controller), ["甲", "乙"], "条目保留")
        XCTAssertEqual(controller.state.section("icons")?.items.map(\.image), images, "图片不变")
        XCTAssertEqual(rig.port?.pageCalls.count, fetches, "到期重算不重拉页面")
    }

    /// 排的等待时长 = 到期时刻 − now（为正）：启动在 12:00:15、到期 12:01:00 → 45 秒。
    func testScheduledWaitEqualsRemainingTime() async {
        let page = ExpiryKit.page([ExpiryKit.entry("甲", ExpiryKit.text("新", expire: "2026-10-10T12:01:00+08:00"))])
        let controller = await bundled(page, at: HomeKit.noon + 15000)
        XCTAssertEqual(rig.clock.scheduled, 1, "为未到期徽标排一次重算")
        rig.clock.advance(0)
        XCTAssertEqual(badge(controller, "甲"), "新", "等待为正：不立刻触发")
        rig.clock.advance(44999)
        XCTAssertEqual(badge(controller, "甲"), "新", "剩余 1 毫秒仍显示")
        XCTAssertEqual(rig.clock.scheduled, 1)
        rig.clock.advance(1)
        XCTAssertNil(badge(controller, "甲"), "等满 45 秒隐藏")
        XCTAssertEqual(titles(controller), ["甲"], "条目保留")
        XCTAssertEqual(rig.clock.scheduled, 0, "到期后没有别的到期时刻，不再排")
    }

    /// 30 天后到期（D10-3082）：首个等待 = 30 天的毫秒数、不立刻触发、触发前不重算、徽标仍在；到点隐藏、条目保留。
    func testThirtyDayExpiryWaitsTheFullRemainingTime() async {
        let page = ExpiryKit.page([
            ExpiryKit.entry("甲", ExpiryKit.text("新", expire: "2026-11-09T12:00:00+08:00")), ExpiryKit.entry("乙"),
        ])
        let controller = await bundled(page, at: HomeKit.noon)
        XCTAssertEqual(badge(controller, "甲"), "新", "30 天后到期，现在显示")
        XCTAssertEqual(rig.clock.scheduled, 1, "排了一次重算")
        let counter = PublishCounter()
        let subscription = controller.$state.dropFirst().sink { _ in MainActor.assumeIsolated { counter.value += 1 } }
        defer { subscription.cancel() }
        rig.clock.advance(0)
        XCTAssertEqual(counter.value, 0, "不立刻触发（等待不是 0）")
        rig.clock.advance(2_592_000_000 - 1)
        XCTAssertEqual(counter.value, 0, "首个等待 = 30 天：到期前 1 毫秒内没有任何重算")
        XCTAssertEqual(badge(controller, "甲"), "新", "触发前徽标仍在")
        rig.clock.advance(1)
        XCTAssertGreaterThan(counter.value, 0, "到点重算")
        XCTAssertNil(badge(controller, "甲"), "到点隐藏徽标")
        XCTAssertEqual(titles(controller), ["甲", "乙"], "条目保留")
    }

    /// 两个徽标先后到期依次隐藏，条目都在。
    func testTwoBadgesHideOneAfterAnother() async {
        let page = ExpiryKit.page([
            ExpiryKit.entry("甲", ExpiryKit.text("新", expire: "2026-10-10T12:01:00+08:00")),
            ExpiryKit.entry("乙", ExpiryKit.text("热", expire: "2026-10-10T12:02:00+08:00")),
        ])
        let controller = await bundled(page, at: HomeKit.noon)
        XCTAssertEqual([badge(controller, "甲"), badge(controller, "乙")], ["新", "热"])
        rig.clock.advance(60000)
        XCTAssertEqual([badge(controller, "甲"), badge(controller, "乙")], [nil, "热"], "先到期的先隐藏")
        XCTAssertEqual(rig.clock.scheduled, 1, "接着为第二个到期时刻排重算")
        rig.clock.advance(60000)
        XCTAssertEqual([badge(controller, "甲"), badge(controller, "乙")], [nil, nil], "第二个到期也隐藏")
        XCTAssertEqual(titles(controller), ["甲", "乙"], "条目保留")
        XCTAssertEqual(rig.clock.scheduled, 0)
    }

    /// 已过期与恰好到期的徽标一开始就不显示、不为它们排定时。
    func testAlreadyExpiredBadgesAreHiddenAndNotScheduled() async {
        let page = ExpiryKit.page([
            ExpiryKit.entry("甲", ExpiryKit.text("新", expire: "2026-10-10T11:59:59+08:00")),
            ExpiryKit.entry("乙", ExpiryKit.text("热", expire: "2026-10-10T12:00:00+08:00")),
        ])
        let controller = await bundled(page, at: HomeKit.noon)
        XCTAssertEqual(titles(controller), ["甲", "乙"], "过期徽标的条目保留")
        XCTAssertNil(badge(controller, "甲"), "已过 expire_at")
        XCTAssertNil(badge(controller, "乙"), "恰好到点也隐藏")
        XCTAssertEqual(rig.clock.scheduled, 0, "已过期的不排定时")
    }

    /// 已过期、恰好到期与差 1 毫秒到期混排：只为差 1 毫秒的那个排定时，1 毫秒后它也隐藏。
    func testOnlyFutureExpiryIsScheduledAmongExpiredOnes() async {
        let page = ExpiryKit.page([
            ExpiryKit.entry("甲", ExpiryKit.text("新", expire: "2026-10-10T11:59:59+08:00")),
            ExpiryKit.entry("乙", ExpiryKit.text("热", expire: "2026-10-10T12:00:00+08:00")),
            ExpiryKit.entry("丙", ExpiryKit.text("惠", expire: "2026-10-10T12:00:00.001+08:00")),
        ])
        let controller = await bundled(page, at: HomeKit.noon)
        XCTAssertEqual([badge(controller, "甲"), badge(controller, "乙"), badge(controller, "丙")], [nil, nil, "惠"])
        XCTAssertEqual(rig.clock.scheduled, 1, "只为未到期的丙排定时")
        rig.clock.advance(1)
        XCTAssertNil(badge(controller, "丙"), "1 毫秒后丙到期隐藏")
        XCTAssertEqual(titles(controller), ["甲", "乙", "丙"])
    }

    /// 没有 expire_at 的徽标一直显示、不排定时；与公告条同页时只有公告的 end_at 定时，公告照常到期。
    func testBadgeWithoutExpiryIsNotScheduledAndNoticeTimerIsUnaffected() async {
        let entries = [ExpiryKit.entry("甲", ExpiryKit.text("新", expire: nil)), ExpiryKit.entry("乙")]
        let alone = await bundled(ExpiryKit.page(entries), at: HomeKit.noon)
        XCTAssertEqual(badge(alone, "甲"), "新")
        XCTAssertEqual(rig.clock.scheduled, 0, "没有 expire_at 不排定时")

        let notice = HomeKit.noticeItem("n1", closable: false, end: "2026-10-10T12:10:00+08:00")
        let controller = await bundled(ExpiryKit.page(entries, notices: [notice]), at: HomeKit.noon)
        XCTAssertEqual(controller.state.section("nb")?.items.count, 1, "前提：公告显示")
        XCTAssertEqual(rig.clock.scheduled, 1, "只有公告 end_at 一个定时")
        rig.clock.advance(600_000 - 1)
        XCTAssertEqual(controller.state.section("nb")?.items.count, 1)
        rig.clock.advance(1)
        XCTAssertNil(controller.state.section("nb"), "公告照常到点隐藏")
        XCTAssertEqual(badge(controller, "甲"), "新", "无 expire_at 的徽标不受影响")
        XCTAssertEqual(titles(controller), ["甲", "乙"])
    }

    /// 徽标与公告共用一个重算计时：先到期的徽标先隐藏、公告还在；再到公告 end_at 公告隐藏、条目都在。
    func testBadgeExpiryAndNoticeEndShareTheRecomputeTimer() async {
        let entries = [ExpiryKit.entry("甲", ExpiryKit.text("新", expire: "2026-10-10T12:01:00+08:00"))]
        let notice = HomeKit.noticeItem("n1", closable: false, end: "2026-10-10T12:02:00+08:00")
        let controller = await bundled(ExpiryKit.page(entries, notices: [notice]), at: HomeKit.noon)
        XCTAssertEqual(badge(controller, "甲"), "新")
        rig.clock.advance(60000)
        XCTAssertNil(badge(controller, "甲"), "徽标先到期")
        XCTAssertEqual(controller.state.section("nb")?.items.count, 1, "公告还没到 end_at")
        rig.clock.advance(60000)
        XCTAssertNil(controller.state.section("nb"), "公告到 end_at 隐藏")
        XCTAssertEqual(titles(controller), ["甲"])
    }
}

/// 状态发布次数（重算会写 state.sections，每次重算都发布）。
@MainActor
private final class PublishCounter {
    var value = 0
}

/// 本文件的页面夹具（金刚区一张卡 id = icons；可再带一张静态公告条 id = nb）。
private enum ExpiryKit {
    typealias JSONObject = [String: Any]

    /// text 徽标；expire 为 nil 时不带 expire_at 键，NSNull 写成 JSON null。
    static func text(_ text: String, expire: Any?) -> JSONObject {
        var badge: JSONObject = ["kind": "text", "text": text]
        if let expire {
            badge["expire_at"] = expire
        }
        return badge
    }

    static func entry(_ title: String, _ badge: JSONObject? = nil) -> JSONObject {
        var json: JSONObject = ["icon": "https://img.example.com/plain.png", "title": title]
        json["action"] = ["route": "Help"]
        if let badge {
            json["badge"] = badge
        }
        return json
    }

    static func page(_ entries: [JSONObject], notices: [JSONObject] = []) -> JSONObject {
        var sections: [JSONObject] = [[
            "id": "icons", "type": "icon_grid", "version": 1, "props": ["columns": 4],
            "data_source": ["kind": "static", "items": entries],
        ]]
        if !notices.isEmpty {
            sections.append(HomeKit.notice("nb", items: notices))
        }
        return HomeKit.page(version: 71, sections)
    }
}
