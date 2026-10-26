import Foundation
import Generated
@testable import OrderCore
import XCTest

/// APP-08v 三端共用视觉 fixture（`specs/order-vectors.json` 的 `visualOrders`，G-O11，与 Android 逐字节相同）：
/// 每份列表报文经生产严格解析零丢行；列表不带锁定契约没有的字段（G-O02：不臆造 actual / clawback / 区间 / 预计月份）；
/// 非零 est 哨兵在位（防「没数据所以没泄露」的空断言）。
final class OrderVisualFixtureTests: XCTestCase {
    private typealias JSONObject = [String: Any]

    private func visual() throws -> JSONObject {
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while !FileManager.default.fileExists(atPath: directory.appendingPathComponent("contract.lock").path) {
            directory = directory.deletingLastPathComponent()
        }
        let data = try Data(contentsOf: directory.appendingPathComponent("specs/order-vectors.json"))
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? JSONObject)
        return try XCTUnwrap(root["visualOrders"] as? JSONObject, "缺 visualOrders 组")
    }

    func testClockIsFixedShanghai1030AndStale0930() throws {
        let clock = try XCTUnwrap(visual()["clock"] as? JSONObject)
        XCTAssertEqual(clock["now"] as? String, "2026-10-12T10:30:00+08:00")
        XCTAssertEqual((clock["nowMillis"] as? NSNumber)?.int64Value, 1_791_772_200_000)
        XCTAssertEqual((clock["staleAtMillis"] as? NSNumber)?.int64Value, 1_791_768_600_000)
        XCTAssertEqual(clock["zone"] as? String, "Asia/Shanghai")
    }

    func testEveryListPageParsesStrictlyWithoutDroppedRows() throws {
        let root = try visual()
        let pages = try XCTUnwrap(root["pages"] as? JSONObject)
        let statusPages = try XCTUnwrap(root["statusPages"] as? JSONObject)
        XCTAssertEqual(pages.count, 13)
        XCTAssertEqual(statusPages.count, 12)
        for (name, raw) in pages.merging(statusPages, uniquingKeysWith: { lhs, _ in lhs }) {
            let object = try XCTUnwrap(raw as? JSONObject, name)
            let rows = try XCTUnwrap(object["items"] as? [JSONObject], name)
            let parsed = try XCTUnwrap(OrderJSON.listData(object), "\(name) 解析失败")
            XCTAssertEqual(parsed.dropped, 0, "\(name) 有行被当坏数据丢弃")
            XCTAssertEqual(parsed.items.count, rows.count, name)
            for row in rows {
                for field in ["actual_fen", "clawback_fen", "rebate_min_fen", "rebate_max_fen",
                              "expected_credit_period"] {
                    XCTAssertNil(row[field], "\(name).\(row["order_id"] ?? "?") 列表不得带契约外字段 \(field)（G-O02）")
                }
            }
        }
    }

    func testListSelfMatchesBriefSamplesAndKeepsSentinels() throws {
        let pages = try XCTUnwrap(visual()["pages"] as? JSONObject)
        let page = try XCTUnwrap(pages["list_self"] as? JSONObject)
        let parsed = try XCTUnwrap(OrderJSON.listData(page))
        XCTAssertEqual(parsed.items.map(\.orderId), ["A", "B", "M", "C", "J"])
        XCTAssertEqual(parsed.items.map(\.displayStatus), [.paid, .depositPaid, .unknown, .waiting, .invalid])
        XCTAssertEqual(parsed.items.map(\.payAmountFen), [4560, 3000, 1990, 3990, 8900])
        XCTAssertEqual(parsed.items[0].orderNo, "3741234567890123456")
        XCTAssertNotNil(parsed.nextCursor, "list_self 带下一页（上拉加载更多）")
        XCTAssertEqual(parsed.items[2].estRebateFen, 987_654, "UNKNOWN 带非零 est 哨兵")
        XCTAssertEqual(parsed.items[4].estRebateFen, 765_432, "INVALID 带非零 est 哨兵")
        XCTAssertEqual(page["claim_entry_pinned"] as? Bool, false)
        XCTAssertEqual((pages["list_self_pinned"] as? JSONObject)?["claim_entry_pinned"] as? Bool, true)
        let share = try XCTUnwrap(OrderJSON.listData(pages["list_share"]))
        XCTAssertEqual(share.items.map(\.orderId), ["E", "OTHER", "F", "G"])
        XCTAssertTrue(share.items.allSatisfy { $0.orderNo == nil && $0.maskedOrderNo != nil }, "分享单只有脱敏号")
        XCTAssertTrue(share.items[1].isOtherProduct)
    }
}
