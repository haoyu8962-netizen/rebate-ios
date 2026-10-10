/*
 实现前测试；只读输出，未编译运行。

 接线约定：
 - OrderCore 提供下列同步纯函数；测试 target 依赖 OrderCore、Generated。
 - 本测试使用 JSON 边界接线：JSONObject = [String: Any]，仅承载 JSON 值，
   null 使用 NSNull；金额为可空整数分，不接受金额字符串或浮点元。
   可以由生产强类型模型提供同名 JSON 入参重载，不在测试中实现业务规则。
 - 以下 Swift 方法参数均无外部标签，顺序与题定 API 相同：
   OrderQuery.initial(String?) -> OrderQuery，nil 表示没有路由 scope；
   query.apply(String, String?) 原地修改；params() -> JSONObject；
   sendsRequest() -> Bool。set_q 表示搜索提交/清空，不表示每次键入。
   next_page 把 step.nextCursor 原样作为 apply 的第二个参数；其余用 value。
 - 以下 of 返回 JSONObject：
   OrderMonthOptions.of(String?, Int64)；
   OrderNumberDisplay.of(JSONObject)；OrderTitleImage.of(JSONObject)；
   OrderStatusText.of(String)；OrderAmountCells.of(JSONObject, Bool)；
   CreditPeriodText.of(String, String?, Int64)；
   WhyNoRebate.of(JSONObject)；
   PriceCompareEntry.of(JSONObject, JSONObject?, [String: RouteSpec])；
   OrderDetailActions.of(JSONObject)；ViewProductEntry.of(JSONObject)。
 - OrderTimelineView.of(String, [JSONObject], Int64) -> [JSONObject]；
   PendingTrackCards.of([JSONObject], String, String, Bool) -> [JSONObject]。
 - PendingTrackDismiss.request(JSONObject) -> JSONObject；
   PendingTrackDismiss.onOutcome(JSONObject) -> JSONObject。
 - OrderErrorAction.map(String, Int?, Bool, [String: String], String?, Bool, Bool)
   -> JSONObject；顺序为 target/code/transport/headers/traceId/hasCache/filtered。
 - OrderStaleCache.isCacheable(String, JSONObject?) -> Bool；
   OrderStaleCache.clearsOn(String) -> Bool。
 - 结果对象字段与向量结构同名。查询状态如需返回，字段为
   scope/statusGroup/platform/paidMonth/q；当前向量以精确 params 检查清空。
 - nowMs 从向量 +08:00 ISO 时刻解析，不读系统时钟；金额渲染沿用 CouliFormat，
   此处只测字段选择、空值、固定零、负号标记及隐藏，不复制 format-vectors。
 - expect 缺字段不判定；显式 null 接受 nil/NSNull。
   params/request/buttons/cards 精确比较，其余对象允许未判定字段。
   数组逐项有序比较，绝不按集合比较。
 - G11 超长策略未定，只断言真正发送的 q 不超过 40 个 Unicode 码点；
   fixture 不含多码点字素，不把码点/字素的未决问题锁死。
 - 不连接网络、不访问权限/剪贴板、不落盘缓存；
   gaps 中的执行层验收不能由这些纯函数测试代替。
 */

import Foundation
import XCTest
import Generated
@testable import OrderCore

private typealias JSONObject = [String: Any]

final class OrderVectorTests: XCTestCase {
    private let groups = [
        "query", "monthOptions", "orderNumber", "titleImage", "statusText",
        "amountCells", "creditPeriod", "timeline", "whyNoRebate",
        "priceCompareEntry", "detailActions", "viewProduct", "pendingTracks",
        "pendingDismiss", "errorAction", "cachePolicy", "cacheClear",
    ]

    func testManifest() throws {
        let root = try vectors()
        let version: Int = try field(root, "version")
        let sources: [String] = try field(root, "sources")
        let gaps: [String] = try field(root, "gaps")
        XCTAssertEqual(version, 1)
        XCTAssertFalse(sources.isEmpty)
        XCTAssertFalse(gaps.isEmpty)

        for group in groups {
            let rows: [JSONObject] = try field(root, group)
            XCTAssertFalse(rows.isEmpty, group)
            var names = Set<String>()
            for row in rows {
                let name: String = try field(row, "name")
                XCTAssertFalse(name.isEmpty, group)
                XCTAssertTrue(names.insert(name).inserted, "\(group).\(name)")
                let _: JSONObject = try field(row, "expect")
            }
        }

        for route in [
            "OrderList", "OrderDetail", "FindOrder", "ProductDetail", "Help",
            "Ledger", "Withdraw", "Appeal", "AuthManage",
        ] {
            XCTAssertNotNil(Routes.all[route], "生成路由表缺少 \(route)")
        }

        let queries: [JSONObject] = try field(root, "query")
        for row in queries {
            let name: String = try field(row, "name")
            if name == "G11_unicode_40" || name == "G11_over40_policy_unspecified" {
                let steps: [JSONObject] = try field(row, "steps")
                let value: String = try field(steps[1], "value")
                if name == "G11_unicode_40" {
                    XCTAssertEqual(value.unicodeScalars.count, 40, name)
                    XCTAssertGreaterThan(value.utf16.count, 40, name)
                } else {
                    XCTAssertGreaterThan(value.unicodeScalars.count, 40, name)
                }
            }
        }
    }

    func testOrderVectors() throws {
        let root = try vectors()
        for group in groups {
            let rows: [JSONObject] = try field(root, group)
            for row in rows {
                let name: String = try field(row, "name")
                let label = "\(group).\(name)"
                do {
                    let actual = try run(group, row, label)
                    let expected: JSONObject = try field(row, "expect")
                    try match(actual, expected, label)
                } catch {
                    XCTFail("\(label): \(error)")
                }
            }
        }
    }

    private func run(
        _ group: String, _ row: JSONObject, _ label: String
    ) throws -> JSONObject {
        switch group {
        case "query":
            var query: OrderQuery?
            let steps: [JSONObject] = try field(row, "steps")
            XCTAssertFalse(steps.isEmpty, label)
            for step in steps {
                let op: String = try field(step, "op")
                if op == "init" {
                    query = OrderQuery.initial(try optionalText(step, "value"))
                } else {
                    guard var current = query else {
                        throw failure("\(label): apply 前没有 init")
                    }
                    let value = try optionalText(
                        step, op == "next_page" ? "nextCursor" : "value"
                    )
                    current.apply(op, value)
                    query = current
                }
            }
            let current = try XCTUnwrap(query, label)
            let params = current.params()
            if current.sendsRequest(), let q = try optionalText(params, "q") {
                XCTAssertLessThanOrEqual(q.unicodeScalars.count, 40, "\(label).q")
            }
            return ["params": params, "sendsRequest": current.sendsRequest()]

        case "monthOptions":
            return OrderMonthOptions.of(
                try optionalText(row, "earliestVisibleDate"), try nowMs(row)
            )
        case "orderNumber":
            return OrderNumberDisplay.of(try field(row, "item"))
        case "titleImage":
            return OrderTitleImage.of(try field(row, "item"))
        case "statusText":
            return OrderStatusText.of(try field(row, "displayStatus"))
        case "amountCells":
            return OrderAmountCells.of(
                try field(row, "item"), try boolean(row, "masked", false)
            )
        case "creditPeriod":
            return CreditPeriodText.of(
                try field(row, "displayStatus"),
                try optionalText(row, "period"),
                try nowMs(row)
            )
        case "timeline":
            return [
                "rows": OrderTimelineView.of(
                    try field(row, "displayStatus"),
                    try field(row, "nodes"),
                    try nowMs(row)
                ),
            ]
        case "whyNoRebate":
            return WhyNoRebate.of(try field(row, "detail"))
        case "priceCompareEntry":
            return PriceCompareEntry.of(
                try field(row, "detail"),
                try optionalObject(row, "helpLinks"),
                Routes.all
            )
        case "detailActions":
            return OrderDetailActions.of(try field(row, "detail"))
        case "viewProduct":
            return ViewProductEntry.of(try field(row, "detail"))
        case "pendingTracks":
            return [
                "cards": PendingTrackCards.of(
                    try field(row, "items"),
                    try field(row, "session"),
                    try field(row, "notification"),
                    try field(row, "requestedBefore")
                ),
            ]
        case "pendingDismiss":
            let card: JSONObject = try field(row, "card")
            let outcome: JSONObject = try field(row, "outcome")
            var result = PendingTrackDismiss.onOutcome(outcome)
            result["request"] = PendingTrackDismiss.request(card)
            return result
        case "errorAction":
            let code: Int? = row["code"] == nil ? nil : try field(row, "code")
            let headers: [String: String] =
                row["headers"] == nil ? [:] : try field(row, "headers")
            return OrderErrorAction.map(
                try field(row, "target"),
                code,
                try boolean(row, "transport", false),
                headers,
                try optionalText(row, "traceId"),
                try field(row, "hasCache"),
                try boolean(row, "filtered", false)
            )
        case "cachePolicy":
            return [
                "cacheable": OrderStaleCache.isCacheable(
                    try field(row, "kind"), try optionalObject(row, "query")
                ),
            ]
        case "cacheClear":
            return ["clear": OrderStaleCache.clearsOn(try field(row, "event"))]
        default:
            throw failure("没有执行器：\(group)")
        }
    }

    private func match(
        _ actual: Any?, _ expected: Any, _ path: String, _ exact: Bool = false
    ) throws {
        if expected is NSNull {
            XCTAssertTrue(actual == nil || actual is NSNull, "\(path): 应无值")
            return
        }
        if let expectedObject = expected as? JSONObject {
            let actualObject = try XCTUnwrap(actual as? JSONObject, "\(path): 应为对象")
            if exact {
                XCTAssertEqual(
                    Set(actualObject.keys), Set(expectedObject.keys), "\(path): 键集合"
                )
            }
            for key in expectedObject.keys.sorted() {
                let value = try XCTUnwrap(expectedObject[key])
                let childExact = exact || ["params", "request", "buttons", "cards"].contains(key)
                try match(actualObject[key], value, "\(path).\(key)", childExact)
            }
            return
        }
        if let expectedArray = expected as? [Any] {
            let actualArray = try XCTUnwrap(actual as? [Any], "\(path): 应为数组")
            XCTAssertEqual(actualArray.count, expectedArray.count, "\(path): 数量")
            guard actualArray.count == expectedArray.count else { return }
            for index in expectedArray.indices {
                try match(actualArray[index], expectedArray[index], "\(path)[\(index)]", exact)
            }
            return
        }
        let value = try XCTUnwrap(actual, "\(path): 缺字段")
        XCTAssertEqual(
            try canonical(value), try canonical(expected), path
        )
    }

    private func canonical(_ value: Any) throws -> String {
        let data = try JSONSerialization.data(
            withJSONObject: value, options: [.sortedKeys, .fragmentsAllowed]
        )
        return String(decoding: data, as: UTF8.self)
    }

    private func nowMs(_ row: JSONObject) throws -> Int64 {
        let iso: String = try field(row, "nowIso")
        XCTAssertTrue(iso.hasSuffix("+08:00"), "nowIso 必须明确 +08:00")
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let date = try XCTUnwrap(formatter.date(from: iso), "非法 nowIso：\(iso)")
        return Int64((date.timeIntervalSince1970 * 1000).rounded())
    }

    private func field<T>(_ object: JSONObject, _ key: String) throws -> T {
        try XCTUnwrap(object[key] as? T, "\(key): 缺失或类型错误")
    }

    private func optionalText(_ object: JSONObject, _ key: String) throws -> String? {
        guard let value = object[key], !(value is NSNull) else { return nil }
        return try XCTUnwrap(value as? String, "\(key): 应为 string/null")
    }

    private func optionalObject(_ object: JSONObject, _ key: String) throws -> JSONObject? {
        guard let value = object[key], !(value is NSNull) else { return nil }
        return try XCTUnwrap(value as? JSONObject, "\(key): 应为 object/null")
    }

    private func boolean(
        _ object: JSONObject, _ key: String, _ defaultValue: Bool
    ) throws -> Bool {
        guard object[key] != nil else { return defaultValue }
        return try field(object, key)
    }

    private func vectors() throws -> JSONObject {
        let file = try repositoryRoot().appendingPathComponent("specs/order-vectors.json")
        return try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? JSONObject,
            "\(file.path): 根必须为对象"
        )
    }

    private func repositoryRoot() throws -> URL {
        var directory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().standardizedFileURL
        while true {
            if FileManager.default.fileExists(
                atPath: directory.appendingPathComponent("contract.lock").path
            ) {
                return directory
            }
            let parent = directory.deletingLastPathComponent()
            guard parent.path != directory.path else {
                throw failure("从 \(#filePath) 向上找不到 contract.lock")
            }
            directory = parent
        }
    }

    private func failure(_ message: String) -> NSError {
        NSError(
            domain: "OrderVectorTests", code: 1,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }
}
