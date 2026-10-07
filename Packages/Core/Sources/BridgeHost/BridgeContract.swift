import Foundation
import Generated

/// 一个桥方法在契约里的登记（contracts/bridge.schema.json methods.*）。
struct BridgeMethodContract: @unchecked Sendable {
    static let levelL1 = "L1"
    static let levelL2 = "L2"
    static let asyncModel = "async"

    let name: String
    let level: String
    let model: String
    let timeoutMs: Int?
    let sinceIOS: String?
    let gestureRequired: Bool
    /// params 的 JSON Schema（JSONSerialization 的对象，只读）。
    let params: [String: Any]

    /// L2，或非 L2 但 gesture_required（最近 1 秒内有用户点击）。
    var needsGesture: Bool {
        level == Self.levelL2 || gestureRequired
    }

    /// L1、L2 要求登录。
    var needsLogin: Bool {
        level == Self.levelL1 || level == Self.levelL2
    }
}

/// 桥契约（Generated 的 `BridgeSchema.json`，由 gen.py 从快照原样嵌入）。只读，进程内解析一次。
/// 方法表、错误码、signed_paths、not_exposed、events 都只来自这里，本模块不另存方法清单。
final class BridgeContract: @unchecked Sendable {
    static let shared = BridgeContract(json: BridgeSchema.json)

    let version: Int
    let methods: [String: BridgeMethodContract]
    let errors: [Int: String]
    let signedPaths: [(method: String, path: String)]
    let events: Set<String>
    let notExposed: Set<String>
    let defs: [String: Any]
    /// share.open 的分享页路径（share_page_paths.*.path_pattern；null = 未定，TODO(N-22)）。
    let sharePagePatterns: [NSRegularExpression]

    init(json: String) {
        let root = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] ?? [:]
        version = (root["version"] as? NSNumber)?.intValue ?? 1
        let rawMethods = root["methods"] as? [String: Any] ?? [:]
        var methods: [String: BridgeMethodContract] = [:]
        var sharePatterns: [NSRegularExpression] = []
        for (name, value) in rawMethods {
            guard let spec = value as? [String: Any] else { continue }
            methods[name] = BridgeMethodContract(
                name: name,
                level: spec["level"] as? String ?? "",
                model: spec["model"] as? String ?? "",
                timeoutMs: (spec["timeout_ms"] as? NSNumber)?.intValue,
                sinceIOS: (spec["since"] as? [String: Any])?["ios"] as? String,
                gestureRequired: JSONKind.bool(spec["gesture_required"]) ?? false,
                params: spec["params"] as? [String: Any] ?? [:]
            )
            if name == "share.open", let pages = spec["share_page_paths"] as? [String: Any] {
                for (key, page) in pages where !key.hasPrefix("$") {
                    guard let pattern = (page as? [String: Any])?["path_pattern"] as? String,
                          let regex = try? NSRegularExpression(pattern: pattern) else { continue }
                    sharePatterns.append(regex)
                }
            }
        }
        self.methods = methods
        sharePagePatterns = sharePatterns
        var errors: [Int: String] = [:]
        for (key, value) in root["errors"] as? [String: Any] ?? [:] {
            if let code = Int(key), let text = value as? String {
                errors[code] = text
            }
        }
        self.errors = errors
        signedPaths = (root["signed_paths"] as? [Any] ?? []).compactMap { item in
            guard let row = item as? [String: Any], let method = row["method"] as? String,
                  let path = row["path"] as? String else { return nil }
            return (method, path)
        }
        events = Set((root["events"] as? [String: Any] ?? [:]).keys)
        notExposed = Set((root["not_exposed"] as? [Any] ?? []).compactMap { $0 as? String })
        defs = root["$defs"] as? [String: Any] ?? [:]
    }
}

/// JSONSerialization 值的类型判断（NSNumber 要区分布尔、整数与小数）。
enum JSONKind {
    static func isBool(_ value: Any?) -> Bool {
        guard let number = value as? NSNumber else { return false }
        return CFGetTypeID(number) == CFBooleanGetTypeID()
    }

    /// 真正的 JSON 布尔（不把 0 / 1 当布尔）。
    static func bool(_ value: Any?) -> Bool? {
        guard isBool(value), let number = value as? NSNumber else { return nil }
        return number.boolValue
    }

    /// 非布尔的 JSON 数值。
    static func number(_ value: Any?) -> NSNumber? {
        guard let number = value as? NSNumber, !isBool(number) else { return nil }
        return number
    }

    /// 数值是整数（1、1.0 都算；1.5 不算）。
    static func isInteger(_ number: NSNumber) -> Bool {
        guard CFNumberIsFloatType(number) else { return true }
        let double = number.doubleValue
        return double.isFinite && double.rounded() == double
    }

    static func string(_ object: [String: Any], _ key: String) -> String? {
        object[key] as? String
    }

    static func strings(_ object: [String: Any], _ key: String) -> [String] {
        (object[key] as? [Any] ?? []).compactMap { $0 as? String }
    }

    /// JSON 文本（紧凑）；不是 JSON 值时为 nil。顶层可以是标量。
    static func encode(_ value: Any) -> String? {
        guard JSONSerialization.isValidJSONObject([value]),
              let data = try? JSONSerialization.data(withJSONObject: [value], options: [.withoutEscapingSlashes])
        else { return nil }
        guard let text = String(bytes: data, encoding: .utf8) else { return nil }
        // 去掉外层数组的 [ ]（顶层标量也能编码）。
        return String(text.dropFirst().dropLast())
    }

    static func object(_ text: String) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any]
    }
}
