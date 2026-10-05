import Foundation
import Generated
import XCTest

final class ContractConformanceTests: XCTestCase {
    private typealias JSONObject = [String: Any]

    // 先去掉文件名，再从 GeneratedTests 向上四级到仓库根。
    private var snapshotRoot: URL {
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<4 {
            directory.deleteLastPathComponent()
        }
        return directory.appendingPathComponent("contracts/snapshot", isDirectory: true)
    }

    func testEnumRegistryMatchesEverySnapshotValueInOrder() throws {
        let expected = try enumValues()
        assertDictionary(ContractEnums.all, equals: expected, context: "ContractEnums.all")
    }

    func testConcreteEnumCasesMatchSnapshots() throws {
        let expected = try enumValues()
        XCTAssertEqual(
            Platform.allCases.map(\.rawValue),
            try XCTUnwrap(expected["platform"], "快照缺少枚举 platform"),
            "Platform.allCases 与 platform 的值或顺序不一致"
        )
        XCTAssertEqual(
            ClientPlatform.allCases.map(\.rawValue),
            try XCTUnwrap(expected["client_platform"], "快照缺少枚举 client_platform"),
            "ClientPlatform.allCases 与 client_platform 的值或顺序不一致"
        )
        XCTAssertEqual(
            PlatformSearchStatus.allCases.map(\.rawValue),
            try XCTUnwrap(expected["platform_search_status"], "快照缺少枚举 platform_search_status"),
            "PlatformSearchStatus.allCases 与 platform_search_status 的值或顺序不一致"
        )
        XCTAssertEqual(
            RouteEntry.allCases.map(\.rawValue),
            try XCTUnwrap(expected["route_entry"], "快照缺少枚举 route_entry"),
            "RouteEntry.allCases 与 route_entry 的值或顺序不一致"
        )
        XCTAssertFalse(Platform.allCases.contains(.unknown), "Platform.allCases 不应包含兜底 case")
        XCTAssertFalse(ClientPlatform.allCases.contains(.unknown), "ClientPlatform.allCases 不应包含兜底 case")
        XCTAssertFalse(
            PlatformSearchStatus.allCases.contains(.unknown),
            "PlatformSearchStatus.allCases 不应包含兜底 case"
        )

        // 点检来源：rebate-platform@85af83a contracts/enums/platform.yaml:7。
        XCTAssertEqual(Platform(rawValue: "taobao"), Platform.taobao, "platform.taobao 的 case 映射错误")
        // 点检来源：rebate-platform@85af83a contracts/enums/platform.yaml:44。
        XCTAssertEqual(PlatformSearchStatus.on.rawValue, "on", "platform_search_status.on 的 rawValue 错误")
        XCTAssertEqual(
            PlatformSearchStatus(rawValue: "on"),
            PlatformSearchStatus.on,
            "platform_search_status.on 未映射到对应 case"
        )
    }

    func testPlatformDecoderHandlesUnknownAndKnownValues() throws {
        // 未知值是测试输入；兜底 rawValue 的依据是任务书 §5.1。
        let unknownData = Data("[\"no_such_value\"]".utf8)
        let unknown = try JSONDecoder().decode([Platform].self, from: unknownData)
        XCTAssertEqual(unknown, [.unknown], "platform：未知字符串应解码为 .unknown，且不能抛错")
        XCTAssertEqual(Platform.unknown.rawValue, "__unknown__", "Platform.unknown 的 rawValue 错误")

        let expected = try XCTUnwrap(try enumValues()["platform"], "快照缺少枚举 platform")
        XCTAssertFalse(expected.contains("no_such_value"), "测试用未知值已成为 platform 的有效值")
        let knownData = try JSONSerialization.data(withJSONObject: expected)
        let known = try JSONDecoder().decode([Platform].self, from: knownData)
        XCTAssertEqual(known.map(\.rawValue), expected, "platform：已知值解码后应保留原值及顺序")
    }

    func testErrorCodesMatchSnapshot() throws {
        let root = try snapshot("contracts/error-codes.json")
        let rows = try required(root["codes"], [JSONObject].self, "error-codes.codes")
        XCTAssertFalse(rows.isEmpty, "error-codes.codes 不能为空")
        let codes = try rows.enumerated().map { index, row in
            try required(row["code"], Int.self, "error-codes.codes[\(index)].code")
        }
        assertKeys(Set(ErrorCodes.all.keys), equals: Set(codes), context: "ErrorCodes.all")
        XCTAssertEqual(Set(codes).count, codes.count, "error-codes.codes 存在重复 code：\(codes)")

        for (code, row) in zip(codes, rows) {
            let context = "error-codes[\(code)]"
            let actual = try XCTUnwrap(ErrorCodes.all[code], "\(context)：生成表缺少此码")
            XCTAssertEqual(actual.code, code, "\(context).code")
            XCTAssertEqual(ErrorCodes.info(code), actual, "\(context)：info(code) 与 all 不一致")
            XCTAssertEqual(
                actual.http,
                try required(row["http"], Int.self, "\(context).http"),
                "\(context).http"
            )
            XCTAssertEqual(
                actual.retryKind.rawValue,
                try required(row["retry_kind"], String.self, "\(context).retry_kind"),
                "\(context).retry_kind"
            )
            let reasons = try optional(
                row["retry_kind_by_reason"], [String: String].self, "\(context).retry_kind_by_reason"
            ) ?? [:]
            assertDictionary(
                actual.retryKindByReason.mapValues(\.rawValue),
                equals: reasons,
                context: "\(context).retry_kind_by_reason"
            )
            let deprecated = try optional(row["deprecated"], Bool.self, "\(context).deprecated") ?? false
            let phase = try optional(row["phase"], String.self, "\(context).phase")
            XCTAssertEqual(actual.isDeprecated, deprecated, "\(context).isDeprecated")
            XCTAssertEqual(actual.isP1, phase == "P1", "\(context).isP1")
        }
    }

    func testUnknownErrorCodeReturnsNil() {
        XCTAssertNil(ErrorCodes.info(99_999), "未分配错误码 99999 应返回 nil")
    }

    func testRoutesMatchSnapshotForCurrentBuildConfiguration() throws {
        let root = try snapshot("contracts/routes.json")
        let routes = try required(root["routes"], JSONObject.self, "routes.routes")
        XCTAssertFalse(routes.isEmpty, "routes.routes 不能为空")
        var expectedNames = Set<String>()

        for name in routes.keys.sorted() {
            let context = "routes[\(name)]"
            let row = try required(routes[name], JSONObject.self, context)
            let debugOnly = try optional(row["debug_only"], Bool.self, "\(context).debug_only") ?? false

            #if DEBUG
            // Staging 按任务书 §2.4 为 debug 类型，本地包同样定义 DEBUG。
            let included = true
            #else
            let included = !debugOnly
            #endif

            if !included {
                XCTAssertNil(Routes.all[name], "\(context)：非 DEBUG 构建不得登记调试路由")
                XCTAssertNil(Routes.spec(name), "\(context)：非 DEBUG 构建不得查到调试路由")
                continue
            }

            expectedNames.insert(name)
            let actual = try XCTUnwrap(Routes.all[name], "\(context)：生成表缺少此路由")
            XCTAssertEqual(actual.name, name, "\(context).name")
            XCTAssertEqual(Routes.spec(name), actual, "\(context)：spec(name) 与 all 不一致")
            XCTAssertEqual(
                actual.kind.rawValue,
                try required(row["kind"], String.self, "\(context).kind"),
                "\(context).kind"
            )
            XCTAssertEqual(
                actual.auth,
                try required(row["auth"], String.self, "\(context).auth"),
                "\(context).auth"
            )
            XCTAssertEqual(actual.sinceIOS, try sinceIOS(row, context: context), "\(context).since.ios")
            XCTAssertEqual(
                actual.h5Path,
                try optional(row["h5_path"], String.self, "\(context).h5_path"),
                "\(context).h5_path"
            )
            XCTAssertEqual(actual.debugOnly, debugOnly, "\(context).debug_only")

            let rawEntries = try required(row["entry"], [String].self, "\(context).entry")
            let entries = try rawEntries.map { rawValue in
                try XCTUnwrap(
                    RouteEntry(rawValue: rawValue),
                    "\(context).entry[\(rawValue)]：RouteEntry 缺少对应 case"
                )
            }
            XCTAssertEqual(actual.entries, entries, "\(context).entry：RouteEntry 列表或顺序不一致")
            XCTAssertEqual(actual.entries.map(\.rawValue), rawEntries, "\(context).entry：rawValue 不一致")
        }
        assertKeys(Set(Routes.all.keys), equals: expectedNames, context: "Routes.all")
    }

    func testUnknownRouteReturnsNil() {
        XCTAssertNil(Routes.spec("NoSuchRoute"), "不存在的路由 NoSuchRoute 应返回 nil")
    }

    func testBridgeMethodsMatchSnapshot() throws {
        let root = try snapshot("contracts/bridge.schema.json")
        // 锁定契约中的 methods 是「方法名 → 方法描述」对象，不是数组。
        let methods = try required(root["methods"], JSONObject.self, "bridge.methods")
        XCTAssertFalse(methods.isEmpty, "bridge.methods 不能为空")
        assertKeys(Set(BridgeMethods.all.keys), equals: Set(methods.keys), context: "BridgeMethods.all")

        for name in methods.keys.sorted() {
            let context = "bridge.methods[\(name)]"
            let row = try required(methods[name], JSONObject.self, context)
            let actual = try XCTUnwrap(BridgeMethods.all[name], "\(context)：生成表缺少此方法")
            XCTAssertEqual(actual.name, name, "\(context).name")
            XCTAssertEqual(BridgeMethods.spec(name), actual, "\(context)：spec(name) 与 all 不一致")
            XCTAssertEqual(
                actual.level,
                try required(row["level"], String.self, "\(context).level"),
                "\(context).level"
            )
            XCTAssertEqual(
                actual.timeoutMs,
                try optional(row["timeout_ms"], Int.self, "\(context).timeout_ms"),
                "\(context).timeout_ms：缺省或 null 应为 nil"
            )
            XCTAssertEqual(actual.sinceIOS, try sinceIOS(row, context: context), "\(context).since.ios")
            // 任务书 §5.4：只读取显式字段；缺省为 false，不从 level 推导。
            let gestureRequired = try optional(
                row["gesture_required"], Bool.self, "\(context).gesture_required"
            ) ?? false
            XCTAssertEqual(actual.gestureRequired, gestureRequired, "\(context).gesture_required")
        }
    }

    func testBridgeErrorsMatchSnapshot() throws {
        let root = try snapshot("contracts/bridge.schema.json")
        // 锁定契约中的 errors 是「十进制码字符串 → 含义原文」对象。
        let errors = try required(root["errors"], [String: String].self, "bridge.errors")
        XCTAssertFalse(errors.isEmpty, "bridge.errors 不能为空")
        var expected: [Int: String] = [:]
        for key in errors.keys.sorted() {
            let code = try XCTUnwrap(Int(key), "bridge.errors[\(key)]：错误码不是整数")
            XCTAssertNil(expected[code], "bridge.errors[\(key)]：整数码 \(code) 重复")
            expected[code] = errors[key]
        }
        assertDictionary(BridgeErrors.all, equals: expected, context: "BridgeErrors.all")
    }

    func testDefaultTextsAndFallbacksMatchSnapshot() throws {
        let root = try snapshot("contracts/texts.default.json")
        let texts = try required(root["texts"], [String: String].self, "texts.default.texts")
        let fallbacks = try required(root["fallbacks"], [String: String].self, "texts.default.fallbacks")
        XCTAssertFalse(texts.isEmpty, "texts.default.texts 不能为空")
        let allKeys = DefaultTexts.allKeys
        assertKeys(Set(allKeys), equals: Set(texts.keys), context: "DefaultTexts.allKeys")
        XCTAssertEqual(allKeys.count, Set(allKeys).count, "DefaultTexts.allKeys 存在重复键：\(allKeys)")

        for key in texts.keys.sorted() {
            XCTAssertEqual(DefaultTexts.text(key), texts[key], "texts[\(key)]：默认文案不一致")
        }
        for key in fallbacks.keys.sorted() {
            XCTAssertEqual(DefaultTexts.fallback(key), fallbacks[key], "fallbacks[\(key)]：兜底文案不一致")
        }
        for key in Set(texts.keys).subtracting(fallbacks.keys).sorted() {
            XCTAssertNil(DefaultTexts.fallback(key), "fallbacks[\(key)]：快照没有此兜底文案，应返回 nil")
        }

        var missingKey = "__contract_conformance_missing__"
        while texts[missingKey] != nil || fallbacks[missingKey] != nil {
            missingKey += "_"
        }
        XCTAssertNil(DefaultTexts.text(missingKey), "texts[\(missingKey)]：不存在的键应返回 nil")
        XCTAssertNil(DefaultTexts.fallback(missingKey), "fallbacks[\(missingKey)]：不存在的键应返回 nil")
    }

    func testDesignTokensMatchEverySnapshotLeaf() throws {
        let root = try snapshot("design/design-tokens.json")
        let metadata = try required(root["metadata"], JSONObject.self, "design.metadata")
        XCTAssertEqual(
            DesignTokens.version,
            try required(metadata["version"], String.self, "design.metadata.version"),
            "DesignTokens.version 与 metadata.version 不一致"
        )
        let tokens = try required(root["tokens"], JSONObject.self, "design.tokens")
        let color = try required(tokens["color"], JSONObject.self, "tokens.color")
        let space = try required(tokens["space"], JSONObject.self, "tokens.space")
        let radius = try required(tokens["radius"], JSONObject.self, "tokens.radius")
        let font = try required(tokens["font"], JSONObject.self, "tokens.font")
        let size = try required(font["size"], JSONObject.self, "tokens.font.size")

        // 叶子使用 value；颜色保留源大小写；键只保留各分组以下的完整点分路径。
        assertDictionary(
            DesignTokens.colors,
            equals: try tokenLeaves(color, as: String.self, context: "tokens.color"),
            context: "DesignTokens.colors"
        )
        assertDictionary(
            DesignTokens.spacing,
            equals: try tokenLeaves(space, as: Int.self, context: "tokens.space"),
            context: "DesignTokens.spacing"
        )
        assertDictionary(
            DesignTokens.radius,
            equals: try tokenLeaves(radius, as: Int.self, context: "tokens.radius"),
            context: "DesignTokens.radius"
        )
        assertDictionary(
            DesignTokens.fontSize,
            equals: try tokenLeaves(size, as: Int.self, context: "tokens.font.size"),
            context: "DesignTokens.fontSize"
        )
    }

    private func snapshot(_ relativePath: String) throws -> JSONObject {
        let url = snapshotRoot.appendingPathComponent(relativePath)
        return try readJSON(url).object
    }

    private func readJSON(_ url: URL) throws -> (data: Data, object: JSONObject) {
        do {
            let data = try Data(contentsOf: url)
            let value = try JSONSerialization.jsonObject(with: data)
            let object = try required(value, JSONObject.self, url.path)
            return (data, object)
        } catch {
            throw ContractSnapshotError(description: "\(url.path)：读取或解析快照失败：\(error)")
        }
    }

    private func enumValues() throws -> [String: [String]] {
        let directory = snapshotRoot.appendingPathComponent("contracts/enums", isDirectory: true)
        let files = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        XCTAssertFalse(files.isEmpty, "\(directory.path)：没有枚举 JSON 快照")
        var result: [String: [String]] = [:]

        for url in files {
            let document = try readJSON(url)
            let enums = try required(document.object["enums"], JSONObject.self, "\(url.path).enums")
            XCTAssertFalse(enums.isEmpty, "\(url.path).enums 不能为空")
            let order = try JSONMemberOrder(data: document.data, context: url.path)

            for key in enums.keys.sorted() {
                let context = "\(url.lastPathComponent).enums[\(key)]"
                let definition = try required(enums[key], JSONObject.self, context)
                let values = try required(definition["values"], JSONObject.self, "\(context).values")
                let orderedValues = try XCTUnwrap(
                    order.keysByPath[["enums", key, "values"]],
                    "\(context).values：无法读取原文键顺序"
                )
                assertKeys(Set(orderedValues), equals: Set(values.keys), context: "\(context).values")
                XCTAssertFalse(orderedValues.isEmpty, "\(context).values 不能为空")
                XCTAssertEqual(
                    orderedValues.count, values.count,
                    "\(context).values：原文存在重复键：\(orderedValues)"
                )
                XCTAssertNil(result[key], "\(context)：多个快照重复定义枚举 \(key)")
                result[key] = orderedValues
            }
        }
        return result
    }

    private func sinceIOS(_ object: JSONObject, context: String) throws -> String? {
        guard let since = try optional(object["since"], JSONObject.self, "\(context).since") else {
            return nil
        }
        return try optional(since["ios"], String.self, "\(context).since.ios")
    }

    private func tokenLeaves<Value>(
        _ node: JSONObject,
        as type: Value.Type,
        context: String,
        prefix: String = ""
    ) throws -> [String: Value] {
        if let value = node["value"] {
            XCTAssertFalse(prefix.isEmpty, "\(context)：令牌叶子没有相对路径")
            return [prefix: try required(value, type, "\(context).value")]
        }

        XCTAssertFalse(node.isEmpty, "\(context)：令牌分组不能为空")
        var result: [String: Value] = [:]
        for key in node.keys.sorted() {
            let child = try required(node[key], JSONObject.self, "\(context).\(key)")
            let path = prefix.isEmpty ? key : "\(prefix).\(key)"
            let leaves = try tokenLeaves(child, as: type, context: "\(context).\(key)", prefix: path)
            for (leaf, value) in leaves {
                XCTAssertNil(result[leaf], "\(context)：点分路径 \(leaf) 重复")
                result[leaf] = value
            }
        }
        return result
    }

    private func required<Value>(
        _ value: Any?,
        _ type: Value.Type,
        _ context: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> Value {
        try XCTUnwrap(value as? Value, "\(context)：字段缺失或类型不是 \(type)", file: file, line: line)
    }

    private func optional<Value>(
        _ value: Any?,
        _ type: Value.Type,
        _ context: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> Value? {
        guard let value, !(value is NSNull) else {
            return nil
        }
        return try required(value, type, context, file: file, line: line)
    }

    private func assertKeys<Key: Hashable & Comparable>(
        _ actual: Set<Key>,
        equals expected: Set<Key>,
        context: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(
            actual, expected,
            "\(context)：缺少 \(expected.subtracting(actual).sorted())；多出 \(actual.subtracting(expected).sorted())",
            file: file, line: line
        )
    }

    private func assertDictionary<Key: Hashable & Comparable, Value: Equatable>(
        _ actual: [Key: Value],
        equals expected: [Key: Value],
        context: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        assertKeys(Set(actual.keys), equals: Set(expected.keys), context: context, file: file, line: line)
        for key in expected.keys.sorted() {
            XCTAssertEqual(actual[key], expected[key], "\(context)[\(key)]：值不一致", file: file, line: line)
        }
    }
}

private struct ContractSnapshotError: Error, CustomStringConvertible {
    let description: String
}

// JSONSerialization 负责校验和解析值，但 Dictionary 不保证 JSON 原文中的成员顺序。
// 此读取器只补充对象成员顺序，不能用排序后的键来代替枚举的契约顺序。
private struct JSONMemberOrder {
    private let bytes: [UInt8]
    private let context: String
    private var offset = 0
    private(set) var keysByPath: [[String]: [String]] = [:]

    init(data: Data, context: String) throws {
        bytes = Array(data)
        self.context = context
        try readValue(path: [])
        skipWhitespace()
        guard offset == bytes.count else {
            throw failure("根节点之后仍有内容")
        }
    }

    private mutating func readValue(path: [String]) throws {
        skipWhitespace()
        guard offset < bytes.count else {
            throw failure("意外到达文件末尾")
        }

        switch bytes[offset] {
        case 0x7B: // {
            offset += 1
            var keys: [String] = []
            if !consume(0x7D) {
                repeat {
                    let key = try readString()
                    keys.append(key)
                    try expect(0x3A)
                    try readValue(path: path + [key])
                } while consume(0x2C)
                try expect(0x7D)
            }
            keysByPath[path] = keys
        case 0x5B: // [
            offset += 1
            if !consume(0x5D) {
                var index = 0
                repeat {
                    try readValue(path: path + [String(index)])
                    index += 1
                } while consume(0x2C)
                try expect(0x5D)
            }
        case 0x22: // "
            _ = try readString()
        default:
            // 数字、true、false、null 已由 JSONSerialization 验证。
            let start = offset
            while offset < bytes.count,
                  ![UInt8(0x20), 0x09, 0x0A, 0x0D, 0x2C, 0x5D, 0x7D].contains(bytes[offset]) {
                offset += 1
            }
            guard offset > start else {
                throw failure("无法读取 JSON 值")
            }
        }
    }

    private mutating func readString() throws -> String {
        skipWhitespace()
        let start = offset
        try expect(0x22)
        while offset < bytes.count {
            let byte = bytes[offset]
            offset += 1
            if byte == 0x5C { // 跳过转义字符，防止把 \" 当成字符串结束。
                guard offset < bytes.count else {
                    throw failure("字符串转义不完整")
                }
                offset += 1
            } else if byte == 0x22 {
                let data = Data(bytes[start..<offset])
                let value = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
                guard let string = value as? String else {
                    throw failure("对象键不是字符串")
                }
                return string
            }
        }
        throw failure("字符串未结束")
    }

    private mutating func skipWhitespace() {
        while offset < bytes.count, [UInt8(0x20), 0x09, 0x0A, 0x0D].contains(bytes[offset]) {
            offset += 1
        }
    }

    private mutating func consume(_ byte: UInt8) -> Bool {
        skipWhitespace()
        guard offset < bytes.count, bytes[offset] == byte else {
            return false
        }
        offset += 1
        return true
    }

    private mutating func expect(_ byte: UInt8) throws {
        guard consume(byte) else {
            throw failure("缺少 JSON 分隔符 \(byte)")
        }
    }

    private func failure(_ message: String) -> ContractSnapshotError {
        ContractSnapshotError(description: "\(context)：字节偏移 \(offset)：\(message)")
    }
}
