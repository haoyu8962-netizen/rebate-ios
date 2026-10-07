import Foundation

/// 桥契约 params 用到的 JSON Schema 子集：type（单值或数组）、enum、$ref（#/$defs/…）、minLength / maxLength（按 Unicode 码点）、
/// pattern（不锚定，按 JSON Schema 语义搜索）、minimum / maximum、properties / required / additionalProperties（false、true 或
/// schema）、items / minItems / maxItems、oneOf（恰好一个）。format、description 等注解不参与校验。契约里出现本子集以外的
/// 校验关键字时一律判不合法（保守，不放行）。值是 JSONSerialization 的结果。
struct JSONSchemaLite {
    private static let defsPrefix = "#/$defs/"
    private static let knownKeywords: Set<String> = [
        "$ref", "type", "enum", "minLength", "maxLength", "pattern", "minimum", "maximum", "properties", "required",
        "additionalProperties", "items", "minItems", "maxItems", "oneOf", "format", "description", "$comment",
    ]

    let defs: [String: Any]

    func valid(_ value: Any, schema: [String: Any]) -> Bool {
        guard let resolved = resolve(schema, depth: 0),
              resolved.keys.allSatisfy(Self.knownKeywords.contains)
        else { return false }
        return typeOK(value, resolved) && enumOK(value, resolved) && stringOK(value, resolved)
            && numberOK(value, resolved) && objectOK(value, resolved) && arrayOK(value, resolved)
            && oneOfOK(value, resolved)
    }

    private func resolve(_ schema: [String: Any], depth: Int) -> [String: Any]? {
        guard let ref = schema["$ref"] as? String else { return schema }
        guard depth < 16, ref.hasPrefix(Self.defsPrefix),
              let target = defs[String(ref.dropFirst(Self.defsPrefix.count))] as? [String: Any]
        else { return nil }
        return resolve(target, depth: depth + 1)
    }

    private func typeOK(_ value: Any, _ schema: [String: Any]) -> Bool {
        let declared: [String]
        switch schema["type"] {
        case nil:
            return true
        case let single as String:
            declared = [single]
        case let many as [Any]:
            declared = many.compactMap { $0 as? String }
        default:
            return false
        }
        return declared.contains { Self.matches(value, type: $0) }
    }

    private func enumOK(_ value: Any, _ schema: [String: Any]) -> Bool {
        guard let options = schema["enum"] else { return true }
        guard let list = options as? [Any] else { return false }
        return list.contains { Self.same($0, value) }
    }

    private func stringOK(_ value: Any, _ schema: [String: Any]) -> Bool {
        guard let text = value as? String else { return true }
        let length = text.unicodeScalars.count
        if let min = Self.int(schema["minLength"]), length < min {
            return false
        }
        if let max = Self.int(schema["maxLength"]), length > max {
            return false
        }
        if let pattern = schema["pattern"] as? String {
            return Self.patternMatches(pattern, text)
        }
        return true
    }

    private func numberOK(_ value: Any, _ schema: [String: Any]) -> Bool {
        guard let number = JSONKind.number(value) else { return true }
        if let min = JSONKind.number(schema["minimum"]), number.doubleValue < min.doubleValue {
            return false
        }
        if let max = JSONKind.number(schema["maximum"]), number.doubleValue > max.doubleValue {
            return false
        }
        return true
    }

    private func objectOK(_ value: Any, _ schema: [String: Any]) -> Bool {
        guard let object = value as? [String: Any] else { return true }
        let properties = schema["properties"] as? [String: Any] ?? [:]
        let required = (schema["required"] as? [Any] ?? []).compactMap { $0 as? String }
        guard required.allSatisfy({ object[$0] != nil }) else { return false }
        return object.allSatisfy { key, child in
            if let property = properties[key] as? [String: Any] {
                return valid(child, schema: property)
            }
            return additionalOK(child, schema["additionalProperties"])
        }
    }

    private func additionalOK(_ child: Any, _ additional: Any?) -> Bool {
        switch additional {
        case nil:
            true
        case let schema as [String: Any]:
            valid(child, schema: schema)
        default:
            JSONKind.bool(additional) == true
        }
    }

    private func arrayOK(_ value: Any, _ schema: [String: Any]) -> Bool {
        guard let array = value as? [Any] else { return true }
        if let min = Self.int(schema["minItems"]), array.count < min {
            return false
        }
        if let max = Self.int(schema["maxItems"]), array.count > max {
            return false
        }
        if let items = schema["items"] as? [String: Any] {
            return array.allSatisfy { valid($0, schema: items) }
        }
        return true
    }

    private func oneOfOK(_ value: Any, _ schema: [String: Any]) -> Bool {
        guard let options = schema["oneOf"] else { return true }
        guard let list = options as? [Any] else { return false }
        return list
            .count(where: { option in (option as? [String: Any]).map { valid(value, schema: $0) } ?? false }) == 1
    }

    // MARK: - 工具

    static func matches(_ value: Any, type: String) -> Bool {
        switch type {
        case "object": value is [String: Any]
        case "array": value is [Any]
        case "null": value is NSNull
        case "string": value is String
        case "boolean": JSONKind.isBool(value)
        case "number": JSONKind.number(value) != nil
        case "integer": JSONKind.number(value).map(JSONKind.isInteger) ?? false
        default: false
        }
    }

    static func same(_ lhs: Any, _ rhs: Any) -> Bool {
        if let left = JSONKind.number(lhs), let right = JSONKind.number(rhs) {
            return left.doubleValue == right.doubleValue
        }
        if JSONKind.isBool(lhs) || JSONKind.isBool(rhs) {
            return JSONKind.bool(lhs) != nil && JSONKind.bool(lhs) == JSONKind.bool(rhs)
        }
        if let left = lhs as? String, let right = rhs as? String {
            return left == right
        }
        if lhs is NSNull, rhs is NSNull {
            return true
        }
        return false
    }

    static func int(_ value: Any?) -> Int? {
        JSONKind.number(value)?.intValue
    }

    static func patternMatches(_ pattern: String, _ text: String) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return false }
        return regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }
}
