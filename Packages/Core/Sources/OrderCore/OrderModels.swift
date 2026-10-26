import Foundation
import Generated

/// JSON 值（JSONSerialization 的结果）里取值的小工具。只认真正的类型：字符串不当数字、布尔不当整数、小数不当整数。
enum JSONPick {
    static func string(_ value: Any?) -> String? {
        value as? String
    }

    static func nonEmpty(_ value: Any?) -> String? {
        (value as? String).flatMap { $0.isEmpty ? nil : $0 }
    }

    static func bool(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }

    static func int64(_ value: Any?) -> Int64? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let integer = number.int64Value
        return NSNumber(value: integer) == number ? integer : nil
    }

    /// 金额字段要么缺失 / null，要么是整数；字符串、小数、布尔按坏数据。
    static func fenValid(_ object: [String: Any], _ key: String) -> Bool {
        guard let value = object[key], !(value is NSNull) else { return true }
        return int64(value) != nil
    }

    static func object(_ value: Any?) -> [String: Any]? {
        value as? [String: Any]
    }

    static func parse(_ data: Data?) -> Any? {
        guard let data, !data.isEmpty else { return nil }
        return try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    }

    static func text(_ object: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        else { return "{}" }
        return String(bytes: data, encoding: .utf8) ?? "{}"
    }

    static func value(_ text: String?) -> Any {
        text.map { $0 as Any } ?? NSNull()
    }

    static func value(_ fen: Int64?) -> Any {
        fen.map { NSNumber(value: $0) as Any } ?? NSNull()
    }
}

/// 订单列表的一行（openapi OrderSummary；详情在它之上加 `OrderDetail` 的字段）。金额一律可空的整数分（null 为未知：不显示、不补 0、
/// 不由别的字段推算）。`orderNo` 与 `maskedOrderNo` 恰好一个（自购单完整、分享单脱敏，BR-TEXT-02 细则「订单号的显示」）。
/// `actualFen` / `clawbackFen` 只在详情响应里有（锁定契约的 OrderSummary 没有，rule-gaps A01）。
public struct OrderSummary: Equatable, Sendable, Identifiable {
    public var orderId: String
    public var platform: String
    public var title: String?
    public var imageUrl: String?
    public var payAmountFen: Int64?
    public var quantity: Int?
    public var orderNo: String?
    public var maskedOrderNo: String?
    public var displayStatusRaw: String
    public var reason: String?
    public var estRebateFen: Int64?
    public var paidAt: String?
    public var isOtherProduct: Bool
    public var actualFen: Int64?
    public var clawbackFen: Int64?

    public var id: String {
        orderId
    }

    /// 显示用的状态：契约 11 个编码之外（含大小写不同、空串）一律 UNKNOWN（「状态更新中」）。
    public var displayStatus: DisplayStatus {
        OrderJSON.status(displayStatusRaw)
    }

    /// 分享单（只有脱敏单号）：金额前缀用「预估推广收益 / 推广收益」，没有复制。
    public var isShare: Bool {
        maskedOrderNo != nil && orderNo == nil
    }
}

/// 时间线的一个节点（openapi OrderTimelineItem）：`at` 为 null 表示还没发生或平台不给时间（置灰）；`period` 只在 credit_expected 上。
public struct OrderTimelineItem: Equatable, Sendable {
    public var nodeRaw: String
    public var at: String?
    public var period: String?

    public var node: OrderTimelineNode {
        OrderTimelineNode.allCases.first { $0.rawValue == nodeRaw } ?? .unknown
    }
}

/// 订单详情（openapi OrderDetail）：列表行的字段 + 详情字段。
public struct OrderDetail: Equatable, Sendable {
    public var summary: OrderSummary
    public var productKey: String?
    public var reasonAction: [String]
    public var timeline: [OrderTimelineItem]
    public var expectedCreditPeriod: String?
    public var creditOverdue: Bool
    public var appealPending: Bool
    /// null（平台的判定字段还没验证通过）按「不是比价订单」处理（BR-TEXT-03）。
    public var isPriceCompare: Bool?
}

/// 待跟单卡的一项（openapi PendingTrack）：按尝试（attempt_id）显示与关闭（BR-ATTR-21 细则「完成与关闭按尝试」）。
public struct PendingTrack: Equatable, Sendable {
    public var linkId: String
    public var attemptId: String
    public var platform: String
    public var jumpedAt: String
    public var showClaimEntry: Bool
    public var dismissed: Bool
}

/// 列表一页（openapi OrderListData）。`dropped`：按坏数据丢弃的行数（只记日志，不显示任何单号）。
public struct OrderListData: Equatable, Sendable {
    public var items: [OrderSummary]
    public var nextCursor: String?
    public var earliestVisibleDate: String?
    public var dropped = 0
    /// 「未跟单？去找回」置顶（锁定契约 `claim_entry_pinned`，只 scope=self、服务端按 BR-ATTR-17 计算；G-O04）。只认 JSON 布尔 true，
    /// 缺失 / null / 其他类型一律 false。断网缓存不写这个字段（与当时时间有关；读回为 false）。
    public var claimEntryPinned = false
}

/// 日志出口（App 接到系统日志；不写订单号、金额与任何个人信息）。缺省丢弃。
public enum OrderLog {
    public nonisolated(unsafe) static var sink: (String) -> Void = { _ in }

    static func warn(_ message: String) {
        sink(message)
    }
}

/// 订单接口的手写解析（照 TradeJSON 的先例，openapi 的订单模型没有生成）。
/// - `summary` / `detail` / `pendingTrack`：严格解析网络数据，必填字段缺失或类型不对、order_no 与 masked_order_no 两个都有或都没有的
///   整条按坏数据丢弃（返回 nil，记日志，不显示任何单号）；
/// - `lenientSummary` / `lenientDetail`：显示规则的 JSON 入参（三端向量）用，缺字段按空值，不判定行是否合法。
public enum OrderJSON {
    /// 显示状态：只认契约里的 11 个编码（区分大小写），其余（含空串）为 UNKNOWN。
    public static func status(_ raw: String?) -> DisplayStatus {
        DisplayStatus.allCases.first { $0.rawValue == raw } ?? .unknown
    }

    public static func listData(_ data: Any?) -> OrderListData? {
        guard let root = data as? [String: Any], let rows = root["items"] as? [Any] else { return nil }
        let items = rows.compactMap { ($0 as? [String: Any]).flatMap(summary) }
        let dropped = rows.count - items.count
        if dropped > 0 {
            OrderLog.warn("orders: dropped \(dropped) malformed rows")
        }
        return OrderListData(
            items: items,
            nextCursor: JSONPick.nonEmpty(root["next_cursor"]),
            earliestVisibleDate: JSONPick.nonEmpty(root["earliest_visible_date"]),
            dropped: dropped,
            claimEntryPinned: JSONPick.bool(root["claim_entry_pinned"]) == true
        )
    }

    /// 严格解析一行；坏数据返回 nil。
    public static func summary(_ object: [String: Any]) -> OrderSummary? {
        guard let orderId = JSONPick.nonEmpty(object["order_id"]), let platform = JSONPick.nonEmpty(object["platform"]),
              let status = JSONPick.string(object["display_status"])
        else { return nil }
        let orderNo = JSONPick.nonEmpty(object["order_no"])
        let masked = JSONPick.nonEmpty(object["masked_order_no"])
        guard (orderNo == nil) != (masked == nil) else { return nil }
        guard JSONPick.fenValid(object, "pay_amount_fen"),
              JSONPick.fenValid(object, "est_rebate_fen") else { return nil }
        var row = lenientSummary(object)
        row.orderId = orderId
        row.platform = platform
        row.displayStatusRaw = status
        return row
    }

    /// 显示规则用的宽松解析：缺字段按空值（不判定合法性；合法性由 OrderNumberDisplay 等各自判定）。
    public static func lenientSummary(_ object: [String: Any]) -> OrderSummary {
        OrderSummary(
            orderId: JSONPick.string(object["order_id"]) ?? "",
            platform: JSONPick.string(object["platform"]) ?? "",
            title: JSONPick.string(object["title"]),
            imageUrl: JSONPick.nonEmpty(object["image_url"]),
            payAmountFen: JSONPick.int64(object["pay_amount_fen"]),
            quantity: JSONPick.int64(object["quantity"]).flatMap { $0 >= 1 ? Int($0) : nil },
            orderNo: JSONPick.nonEmpty(object["order_no"]),
            maskedOrderNo: JSONPick.nonEmpty(object["masked_order_no"]),
            displayStatusRaw: JSONPick.string(object["display_status"]) ?? "",
            reason: JSONPick.string(object["reason"]),
            estRebateFen: JSONPick.int64(object["est_rebate_fen"]),
            paidAt: JSONPick.string(object["paid_at"]),
            isOtherProduct: JSONPick.bool(object["is_other_product"]) == true,
            actualFen: JSONPick.int64(object["actual_fen"]),
            clawbackFen: JSONPick.int64(object["clawback_fen"])
        )
    }

    /// 严格解析详情；坏数据返回 nil。
    public static func detail(_ object: [String: Any]) -> OrderDetail? {
        guard let summary = summary(object) else { return nil }
        var detail = lenientDetail(object)
        detail.summary = summary
        return detail
    }

    public static func lenientDetail(_ object: [String: Any]) -> OrderDetail {
        OrderDetail(
            summary: lenientSummary(object),
            productKey: JSONPick.nonEmpty(object["product_key"]),
            reasonAction: (object["reason_action"] as? [Any] ?? []).compactMap { $0 as? String },
            timeline: (object["timeline"] as? [Any] ?? []).compactMap { ($0 as? [String: Any]).flatMap(timelineItem) },
            expectedCreditPeriod: JSONPick.string(object["expected_credit_period"]),
            creditOverdue: JSONPick.bool(object["credit_overdue"]) == true,
            appealPending: JSONPick.bool(object["appeal_pending"]) == true,
            isPriceCompare: JSONPick.bool(object["is_price_compare"])
        )
    }

    public static func timelineItem(_ object: [String: Any]) -> OrderTimelineItem? {
        guard let node = JSONPick.string(object["node"]) else { return nil }
        return OrderTimelineItem(
            nodeRaw: node,
            at: JSONPick.string(object["at"]),
            period: JSONPick.string(object["period"])
        )
    }

    public static func pendingTracks(_ data: Any?) -> [PendingTrack]? {
        guard let rows = (data as? [String: Any])?["items"] as? [Any] else { return nil }
        return rows.compactMap { ($0 as? [String: Any]).flatMap(pendingTrack) }
    }

    /// 待跟单卡一项：缺 link_id / attempt_id / platform 的丢弃（关闭请求带不出正确的尝试）。
    public static func pendingTrack(_ object: [String: Any]) -> PendingTrack? {
        guard let linkId = JSONPick.nonEmpty(object["link_id"]),
              let attemptId = JSONPick.nonEmpty(object["attempt_id"]),
              let platform = JSONPick.nonEmpty(object["platform"])
        else { return nil }
        return PendingTrack(
            linkId: linkId, attemptId: attemptId, platform: platform,
            jumpedAt: JSONPick.string(object["jumped_at"]) ?? "",
            showClaimEntry: JSONPick.bool(object["show_claim_entry"]) == true,
            dismissed: JSONPick.bool(object["dismissed"]) == true
        )
    }

    // MARK: - 序列化（缓存落盘；只写契约里的字段）

    public static func encode(_ item: OrderSummary) -> [String: Any] {
        var out: [String: Any] = [
            "order_id": item.orderId,
            "platform": item.platform,
            "title": JSONPick.value(item.title),
            "image_url": JSONPick.value(item.imageUrl),
            "pay_amount_fen": JSONPick.value(item.payAmountFen),
            "quantity": item.quantity.map { $0 as Any } ?? NSNull(),
            "display_status": item.displayStatusRaw,
            "reason": JSONPick.value(item.reason),
            "est_rebate_fen": JSONPick.value(item.estRebateFen),
            "paid_at": JSONPick.value(item.paidAt),
            "is_other_product": item.isOtherProduct,
        ]
        if let orderNo = item.orderNo {
            out["order_no"] = orderNo
        }
        if let masked = item.maskedOrderNo {
            out["masked_order_no"] = masked
        }
        if let actual = item.actualFen {
            out["actual_fen"] = actual
        }
        if let clawback = item.clawbackFen {
            out["clawback_fen"] = clawback
        }
        return out
    }

    public static func encode(_ detail: OrderDetail) -> [String: Any] {
        var out = encode(detail.summary)
        out["product_key"] = JSONPick.value(detail.productKey)
        out["reason_action"] = detail.reasonAction
        out["timeline"] = detail.timeline.map { [
            "node": $0.nodeRaw,
            "at": JSONPick.value($0.at),
            "period": JSONPick.value($0.period),
        ] }
        out["expected_credit_period"] = JSONPick.value(detail.expectedCreditPeriod)
        out["credit_overdue"] = detail.creditOverdue
        out["actual_fen"] = JSONPick.value(detail.summary.actualFen)
        out["clawback_fen"] = JSONPick.value(detail.summary.clawbackFen)
        out["appeal_pending"] = detail.appealPending
        out["is_price_compare"] = detail.isPriceCompare.map { $0 as Any } ?? NSNull()
        return out
    }

    /// 列表一页的落盘写法（缓存只存第一页，next_cursor 不存）。
    public static func encode(_ data: OrderListData) -> [String: Any] {
        [
            "items": data.items.map { encode($0) },
            "next_cursor": NSNull(),
            "earliest_visible_date": JSONPick.value(data.earliestVisibleDate),
        ]
    }
}
