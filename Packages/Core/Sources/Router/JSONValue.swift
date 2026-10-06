import Foundation

/// 路由参数与 pending_action 参数用的 JSON 值（可 Sendable、可比较）。
/// 对外仍提供 `[String: Any]` 视图（`anyObject`），与 JSONSerialization 互通。
public enum JSONValue: Sendable, Hashable {
    case null
    case bool(Bool)
    case integer(Int64)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    /// 从 JSONSerialization / Swift 字面量得到的值转换；不是 JSON 值时返回 nil。
    public init?(any value: Any) {
        switch value {
        case is NSNull:
            self = .null
        case let string as String:
            self = .string(string)
        case let number as NSNumber:
            guard let converted = JSONValue(number: number) else { return nil }
            self = converted
        case let array as [Any]:
            let items = array.compactMap(JSONValue.init(any:))
            guard items.count == array.count else { return nil }
            self = .array(items)
        case let object as [String: Any]:
            guard let converted = JSONValue.object(from: object) else { return nil }
            self = .object(converted)
        default:
            return nil
        }
    }

    /// NSNumber 区分布尔、浮点与整数（JSONSerialization 的数字都是 NSNumber）。
    private init?(number: NSNumber) {
        if CFGetTypeID(number) == CFBooleanGetTypeID() {
            self = .bool(number.boolValue)
        } else if CFNumberIsFloatType(number) {
            guard number.doubleValue.isFinite else { return nil }
            self = .number(number.doubleValue)
        } else {
            self = .integer(number.int64Value)
        }
    }

    /// `[String: Any]` → `[String: JSONValue]`；任一值不是 JSON 值时返回 nil。
    public static func object(from dictionary: [String: Any]) -> [String: JSONValue]? {
        var result: [String: JSONValue] = [:]
        for (key, value) in dictionary {
            guard let converted = JSONValue(any: value) else { return nil }
            result[key] = converted
        }
        return result
    }

    /// 与 JSONSerialization 兼容的值。
    public var anyValue: Any {
        switch self {
        case .null: NSNull()
        case let .bool(value): value
        case let .integer(value): value
        case let .number(value): value
        case let .string(value): value
        case let .array(values): values.map(\.anyValue)
        case let .object(values): values.mapValues(\.anyValue)
        }
    }

    public var stringValue: String? {
        if case let .string(value) = self {
            return value
        }
        return nil
    }

    public var objectValue: [String: JSONValue]? {
        if case let .object(value) = self {
            return value
        }
        return nil
    }
}
