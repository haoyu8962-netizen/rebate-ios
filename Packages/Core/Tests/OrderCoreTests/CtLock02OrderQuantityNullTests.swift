import Foundation
import Generated
@testable import OrderCore
import XCTest

/// CT-LOCK-02：openapi OrderSummary / OrderDetail 的 quantity 由 integer 改为 integer | null（改形状）。
/// 本端按可空读取：null 不丢行、不判坏数据，件数不显示；正整数照旧。
final class CtLock02OrderQuantityNullTests: XCTestCase {
    private func row(quantity: Any?) -> [String: Any] {
        var object: [String: Any] = [
            "order_id": "o-1", "platform": "taobao", "display_status": "PAID", "masked_order_no": "12****89",
            "pay_amount_fen": 4560, "est_rebate_fen": 234, "title": "样例商品",
        ]
        if let quantity {
            object["quantity"] = quantity
        }
        return object
    }

    func testNullQuantityKeepsTheRowInListAndDetail() throws {
        let list = try XCTUnwrap(OrderJSON.listData(["items": [row(quantity: NSNull()), row(quantity: 2)]]))
        XCTAssertEqual(list.items.count, 2)
        XCTAssertEqual(list.dropped, 0)
        XCTAssertNil(list.items[0].quantity)
        XCTAssertEqual(list.items[1].quantity, 2)

        let detail = try XCTUnwrap(OrderJSON.detail(row(quantity: NSNull())))
        XCTAssertNil(detail.summary.quantity)
        XCTAssertEqual(try XCTUnwrap(OrderJSON.detail(row(quantity: 3))).summary.quantity, 3)
    }

    /// null 与缺省同一结果；缓存回写把 nil 写成 null，读回仍是 nil。
    func testNullEqualsMissingAndRoundTripsThroughCacheEncoding() throws {
        let null = try XCTUnwrap(OrderJSON.summary(row(quantity: NSNull())))
        let missing = try XCTUnwrap(OrderJSON.summary(row(quantity: nil)))
        XCTAssertEqual(null, missing)
        let encoded = OrderJSON.encode(null)
        XCTAssertTrue(encoded["quantity"] is NSNull)
        XCTAssertEqual(try XCTUnwrap(OrderJSON.summary(encoded)), null)
    }

    func testSnapshotSchemaAllowsNull() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("contracts/snapshot/contracts/openapi.json")
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let schemas = try XCTUnwrap((root["components"] as? [String: Any])?["schemas"] as? [String: Any])
        for name in ["OrderSummary", "OrderDetail"] {
            let props = try XCTUnwrap((schemas[name] as? [String: Any])?["properties"] as? [String: Any], name)
            let type = (props["quantity"] as? [String: Any])?["type"] as? [String]
            XCTAssertEqual(type, ["integer", "null"], name)
        }
    }
}
