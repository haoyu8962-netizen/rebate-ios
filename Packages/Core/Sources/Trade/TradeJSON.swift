import Foundation

/// JSON 对象（JSONSerialization 的结果）。
public typealias TradeObject = [String: Any]

/// JSON 取值的小工具：类型不对一律当缺失；金额只认真正的 JSON 整数（布尔、小数、字符串都按未知），不补 0。
enum TJSON {
    static func string(_ value: Any?) -> String? {
        value as? String
    }

    static func object(_ value: Any?) -> TradeObject? {
        value as? TradeObject
    }

    static func objects(_ value: Any?) -> [TradeObject] {
        (value as? [Any])?.compactMap { $0 as? TradeObject } ?? []
    }

    static func strings(_ value: Any?) -> [String] {
        (value as? [Any])?.compactMap { $0 as? String } ?? []
    }

    /// 真正的 JSON 布尔（不把 0 / 1 当布尔）。
    static func bool(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }

    static func flag(_ value: Any?) -> Bool {
        bool(value) == true
    }

    /// 整数分；null、缺失、布尔、小数、字符串都按未知（nil），不补 0。
    static func fen(_ value: Any?) -> Int64? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let integral = number.int64Value
        return NSNumber(value: integral) == number ? integral : nil
    }

    static func parse(_ data: Data?) -> TradeObject? {
        guard let data, !data.isEmpty else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? TradeObject
    }

    static func parse(_ text: String) -> TradeObject? {
        parse(Data(text.utf8))
    }

    /// 稳定的 JSON 文本（键排序；请求体与重放用同一份字节）。
    static func encode(_ object: TradeObject) -> String {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        else { return "{}" }
        return String(bytes: data, encoding: .utf8) ?? "{}"
    }
}
