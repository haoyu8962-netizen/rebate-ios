import Foundation
@testable import MeCore
import XCTest

/// APP-13a-1-ios 写测（独立写测方）：getDeletion / 写请求 data 的手写解析（`DeletionJson`）。
///
/// 依据：契约 openapi `Deletion`（7 个字段全部 required，additionalProperties false；status 取 deletion_status 四值；cancel_reason 取
/// user / negative_balance 或 null；三个时间字段 date-time，可空的为 string | null）、`DeletionResponse.data` 为 Deletion | null（null =
/// 从未申请）；
/// 三端任务书 §2 第 1 项（必填缺失或类型不符整条按坏数据、不补默认值；不认识的 status 按坏数据、不当初始态；不认识的 cancel_reason 只当 cancelled、
/// 不显示原因）；30416 data.amount_fen（拍板第二批 §8 ADD-07）。
final class App13a1DeletionJsonTests: XCTestCase {
    /// 2026-10-02T09:30:00+08:00 / 2026-10-09T09:30:00+08:00 / 2026-10-03T10:00:00+08:00 的毫秒。
    private let applyAt: Int64 = 1_790_904_600_000
    private let coolingUntil: Int64 = 1_791_509_400_000
    private let cancelledAt: Int64 = 1_790_992_800_000

    private func object(_ overrides: [String: Any] = [:], removing: String? = nil) -> [String: Any] {
        var base: [String: Any] = [
            "status": "cooling",
            "apply_at": "2026-10-02T09:30:00+08:00",
            "cooling_until": "2026-10-09T09:30:00+08:00",
            "can_cancel": true,
            "cancelled_at": NSNull(),
            "cancel_reason": NSNull(),
            "processed_at": NSNull(),
        ]
        for (key, value) in overrides {
            base[key] = value
        }
        if let removing {
            base[removing] = nil
        }
        return base
    }

    private func data(_ value: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed])
    }

    // MARK: - null 与四种 status

    /// data 为 null、缺失或空：从未申请（不是坏数据）。
    func testNullMeansNeverApplied() {
        XCTAssertEqual(DeletionJson.read(nil as Data?), DeletionRead.none)
        XCTAssertEqual(DeletionJson.read(Data("null".utf8)), DeletionRead.none)
        XCTAssertEqual(DeletionJson.read(value: NSNull()), DeletionRead.none)
        XCTAssertEqual(DeletionJson.read(value: nil), DeletionRead.none)
    }

    /// 契约示例（cooling）：逐字段取值，时间换成毫秒，can_cancel 原样（客户端不推算）。
    func testCoolingExample() throws {
        let read = DeletionJson.read(try data(object()))
        let deletion = try XCTUnwrap(read.deletion)
        XCTAssertEqual(deletion.status, Deletion.cooling)
        XCTAssertEqual(deletion.applyAtMillis, applyAt)
        XCTAssertEqual(deletion.coolingUntilMillis, coolingUntil)
        XCTAssertTrue(deletion.canCancel)
        XCTAssertNil(deletion.cancelledAtMillis)
        XCTAssertNil(deletion.cancelReason)
        XCTAssertNil(deletion.processedAtMillis)
    }

    /// 四种 status 都认得。
    func testAllFourStatuses() throws {
        for status in ["cooling", "processing", "done", "cancelled"] {
            let read = DeletionJson.read(try data(object(["status": status, "can_cancel": status == "cooling"])))
            XCTAssertEqual(read.deletion?.status, status, status)
        }
    }

    /// cancelled（契约 cancelDeletion 示例）：cancelled_at 与 cancel_reason 取值。
    func testCancelledExample() throws {
        let read = DeletionJson.read(try data(object([
            "status": "cancelled", "can_cancel": false, "cancelled_at": "2026-10-03T10:00:00+08:00",
            "cancel_reason": "user",
        ])))
        let deletion = try XCTUnwrap(read.deletion)
        XCTAssertEqual(deletion.cancelledAtMillis, cancelledAt)
        XCTAssertEqual(deletion.cancelReason, Deletion.reasonUser)
        XCTAssertFalse(deletion.canCancel)
    }

    /// 系统按负余额撤销：cancel_reason = negative_balance。
    func testNegativeBalanceReason() throws {
        let read = DeletionJson.read(try data(object([
            "status": "cancelled", "can_cancel": false, "cancelled_at": "2026-10-03T10:00:00+08:00",
            "cancel_reason": "negative_balance",
        ])))
        XCTAssertEqual(read.deletion?.cancelReason, Deletion.reasonNegative)
    }

    /// done 带 processed_at。
    func testProcessedAt() throws {
        let read = DeletionJson.read(try data(object([
            "status": "done", "can_cancel": false, "processed_at": "2026-10-09T09:30:00+08:00",
        ])))
        XCTAssertEqual(read.deletion?.processedAtMillis, coolingUntil)
    }

    // MARK: - 不认识的值

    /// 不认识的 status：整条坏数据，不当初始态（brief §2 第 1 项）。
    func testUnknownStatusIsBad() throws {
        for status in ["pending", "COOLING", ""] {
            XCTAssertEqual(DeletionJson.read(try data(object(["status": status]))), .bad, status)
        }
    }

    /// 不认识的 cancel_reason：只当 cancelled，不显示原因（不判坏数据）。
    func testUnknownCancelReasonKeepsRecordWithoutReason() throws {
        let read = DeletionJson.read(try data(object([
            "status": "cancelled", "can_cancel": false, "cancelled_at": "2026-10-03T10:00:00+08:00",
            "cancel_reason": "fraud_review",
        ])))
        let deletion = try XCTUnwrap(read.deletion, "不认识的撤销原因不是坏数据")
        XCTAssertEqual(deletion.status, Deletion.cancelled)
        XCTAssertNil(deletion.cancelReason, "不显示不认识的原因")
    }

    // MARK: - 必填缺失、类型不符

    /// 7 个字段任一缺失（可空的三项也必须出现）：整条坏数据，不补默认值。
    func testMissingRequiredIsBad() throws {
        for key in [
            "status",
            "apply_at",
            "cooling_until",
            "can_cancel",
            "cancelled_at",
            "cancel_reason",
            "processed_at",
        ] {
            XCTAssertEqual(DeletionJson.read(try data(object(removing: key))), .bad, "缺 \(key)")
        }
    }

    /// 类型不符：整条坏数据。
    func testTypeMismatchIsBad() throws {
        let cases: [(String, Any)] = [
            ("status", 1),
            ("apply_at", 1_790_904_600),
            ("apply_at", "2026-10-02 09:30"),
            ("cooling_until", NSNull()),
            ("can_cancel", "true"),
            ("can_cancel", 1),
            ("can_cancel", NSNull()),
            ("cancelled_at", 0),
            ("cancelled_at", "yesterday"),
            ("cancel_reason", 3),
            ("cancel_reason", true),
            ("processed_at", false),
        ]
        for (key, value) in cases {
            XCTAssertEqual(DeletionJson.read(try data(object([key: value]))), .bad, "\(key) = \(value)")
        }
    }

    /// data 不是对象（数组、字符串、数字）：坏数据；解析不了的字节也是坏数据（都不是「从未申请」）。
    func testNonObjectDataIsBad() throws {
        XCTAssertEqual(DeletionJson.read(try data([object()])), .bad)
        XCTAssertEqual(DeletionJson.read(try data("cooling")), .bad)
        XCTAssertEqual(DeletionJson.read(try data(0)), .bad)
        XCTAssertEqual(DeletionJson.read(Data("{not json".utf8)), .bad)
    }

    // MARK: - 时间

    /// 小数秒、Z 时区都按 RFC 3339 解析到毫秒。
    func testFractionalSecondsAndZulu() throws {
        let fractional = DeletionJson.read(try data(object(["apply_at": "2026-10-02T09:30:00.123+08:00"])))
        XCTAssertEqual(fractional.deletion?.applyAtMillis, applyAt + 123)
        let zulu = DeletionJson.read(try data(object(["apply_at": "2026-10-02T01:30:00Z"])))
        XCTAssertEqual(zulu.deletion?.applyAtMillis, applyAt)
        let both = DeletionJson.read(try data(object(["cooling_until": "2026-10-09T01:30:00.500Z"])))
        XCTAssertEqual(both.deletion?.coolingUntilMillis, coolingUntil + 500)
    }

    // MARK: - 资金、phone_bound、30416 金额

    /// 钱包摘要只用三项（G11），整数分；缺任一项或不是整数 → 读取失败（不当 0）。
    func testFunds() {
        let full: [String: Any] = [
            "withdrawable_fen": 1000,
            "estimated_total_fen": 1019,
            "negative_fen": 0,
            "frozen_fen": 200,
        ]
        XCTAssertEqual(
            DeletionJson.funds(full), DeletionFunds(withdrawableFen: 1000, estimatedFen: 1019, negativeFen: 0)
        )
        for key in ["withdrawable_fen", "estimated_total_fen", "negative_fen"] {
            var broken = full
            broken[key] = nil
            XCTAssertNil(DeletionJson.funds(broken), "缺 \(key)")
            broken[key] = 1.5
            XCTAssertNil(DeletionJson.funds(broken), "\(key) 不是整数")
            broken[key] = "100"
            XCTAssertNil(DeletionJson.funds(broken), "\(key) 是字符串")
            broken[key] = true
            XCTAssertNil(DeletionJson.funds(broken), "\(key) 是布尔")
        }
    }

    func testPhoneBound() {
        XCTAssertEqual(DeletionJson.phoneBound(["phone_bound": true]), true)
        XCTAssertEqual(DeletionJson.phoneBound(["phone_bound": false]), false)
        XCTAssertNil(DeletionJson.phoneBound(["phone_bound": 1]), "不是布尔 = 未知")
        XCTAssertNil(DeletionJson.phoneBound([:]), "缺失 = 未知")
    }

    /// 30416 的 data.amount_fen：有就取（整数分）；缺失、0、字符串、小数都按缺金额（用不带金额的兜底句）。
    func testAmount30416() throws {
        XCTAssertEqual(DeletionJson.amountFen(try data(["amount_fen": 567])), 567)
        XCTAssertNil(DeletionJson.amountFen(try data([String: Any]())))
        XCTAssertNil(DeletionJson.amountFen(try data(["amount_fen": 0])))
        XCTAssertNil(DeletionJson.amountFen(try data(["amount_fen": "567"])))
        XCTAssertNil(DeletionJson.amountFen(try data(["amount_fen": 5.67])))
        XCTAssertNil(DeletionJson.amountFen(nil))
    }
}
