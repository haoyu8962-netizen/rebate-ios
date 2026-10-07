#!/usr/bin/env python3
"""契约快照 → Swift 生成物。

只读 contracts/snapshot/，输出到 Packages/Generated/Sources/Generated/（整个目录归生成器所有）。
    python3 tools/codegen/gen.py          # 重新生成
    python3 tools/codegen/gen.py --check  # 在临时目录生成后逐字比较，不一致退出 1

本任务生成：枚举、错误码表、路由表、桥方法表与桥错误码、包内默认文案（资源）、设计令牌原始常量、
商店对照表 AppStores（specs/app-stores.yaml，APP-02c）、GET /v1/app-versions/check 响应示例（App target，#if DEBUG，
调试面板的版本检查假数据，APP-02c）、openapi 操作登记表 ApiOperations（APP-03a：每个 operationId 的方法、路径与
x-auth / x-signed / x-idempotent / x-step-up / x-error-codes / x-session-scopes / x-min-version-gate / x-implementation）。
APP-03b 加：埋点事件构造函数 TrackerEvents（specs/events.yaml；字段名命中禁用规则即报错退出 2，构建失败）、
无效设备哈希种子 DeviceHashSeeds（specs/device-hash.vectors.json）、包内默认配置 DefaultConfig（GET /v1/config 响应示例）。
APP-04 加：桥契约全文 BridgeSchema（contracts/bridge.schema.json）与外跳目标 BridgeAppTargets（contracts/apps.json 的 trade_only）。
不生成：请求 / 响应模型（另立任务）、apps.json 的查询声明与入站片段（APP-06）。
输出不含时间戳，同一快照重复生成逐字一致。只用 Python 3 标准库。

输出目录（两个目录都整个归生成器所有，--check 一起比较）：
  Packages/Generated/Sources/Generated/   契约生成物包
  App/Sources/Generated/                  debug_only 路由表 DebugOnlyRoutes 与版本检查示例 AppVersionCheckExample（#if DEBUG）。放在 App target 是因为
                                          Xcode 对自定义配置名 Staging 按本地包的 Release 编译包、包里看不到 DEBUG，
                                          而 Staging 需要调试路由；App target 在 Debug、Staging 都定义 DEBUG。
                                          包内 Routes.all 仍按 #if DEBUG 登记（Debug 构建与包测试用）。

命名冲突规则（一律在生成时处理，处理不了就报错退出 2，绝不静默覆盖）：
  1. 类型名：枚举键转 UpperCamel；若与 Swift 关键字、Swift 标准库 / Foundation / SwiftUI 常用类型、
     生成器模板直接使用的协议与类型（Decoder、Encoder、Codable、CaseIterable、RawRepresentable…）、
     模块名（Swift、Foundation、SwiftUI、Generated…）冲突，加前缀 Contract（decoder → ContractDecoder）。
     加前缀后仍与生成器手写类型（RESERVED_TYPE_NAMES）或其他枚举的类型名冲突 → 报错。
  2. case 名：取值转 lowerCamel（数字开头加 v，关键字用反引号）。若与生成器给枚举带的成员
     （unknown、allCases、rawValue、hashValue、init、encode、hash、self、Type…，见 RESERVED_CASE_NAMES）
     同名，改成 contract + UpperCamel（all_cases → contractAllCases，unknown → contractUnknown），
     rawValue 保持契约原值。改名后仍与同一枚举里的其他 case 冲突 → 报错。
  3. 输出文件名：每个枚举快照文件输出 Enums+<UpperCamel(文件名)>.swift；任意两个输出路径
     （按大小写不敏感比较，macOS 文件系统不区分大小写）相同 → 报错（如 foo-bar.json 与 foo_bar.json）。
  模板里用到的系统类型与函数一律写模块限定名（Swift.Decoder、Swift.String、Swift.fatalError、Foundation.Bundle、
  Foundation.Data、Foundation.JSONDecoder…），即使将来冲突表漏了某个名字也不会被同名枚举遮蔽；
  tools/codegen/test_gen.py 对全部生成文件（含 DefaultTexts 与 SwiftPM 资源访问器）做 iOS 模拟器类型检查。
"""

from __future__ import annotations

import argparse
import filecmp
import json
import os
import re
import shutil
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
SNAPSHOT = os.path.join(ROOT, "contracts", "snapshot")
OUTPUT = os.path.join(ROOT, "Packages", "Generated", "Sources", "Generated")
APP_OUTPUT = os.path.join(ROOT, "App", "Sources", "Generated")
# 输出根：键是生成结果里的路径前缀。
OUTPUT_ROOTS = {"": OUTPUT, "@app/": APP_OUTPUT}
APP_PREFIX = "@app/"
# debug_only 路由表所在 #if DEBUG 块里的长标记（> 15 字节，不会被内联进指令）。release-scan.sh 查它。
DEBUG_ONLY_ROUTE_MARKER = "COULI_DEBUG_ONLY_ROUTE_TABLE"
# 版本检查假数据（openapi 示例）所在 #if DEBUG 块里的长标记（APP-02c）。release-scan.sh 查它。
UPDATE_EXAMPLE_MARKER = "COULI_UPDATE_CHECK_EXAMPLE_5B7E3D91"
HEADER = "// 生成物，禁止手改；来源 contract.lock\n"

# Swift 关键字：作 case 名时加反引号。
SWIFT_KEYWORDS = {
    "associatedtype", "class", "deinit", "enum", "extension", "fileprivate", "func", "import", "init",
    "inout", "internal", "let", "open", "operator", "private", "precedencegroup", "protocol", "public",
    "rethrows", "static", "struct", "subscript", "typealias", "var", "break", "case", "catch", "continue",
    "default", "defer", "do", "else", "fallthrough", "for", "guard", "if", "in", "repeat", "return",
    "throw", "switch", "where", "while", "as", "false", "is", "nil", "self", "Self", "super", "throws",
    "true", "try", "Any", "await", "async", "consume", "copy", "discard", "each", "borrowing",
    "consuming", "some", "any", "Type", "Protocol",
}

# 类型名冲突：Swift 关键字、标准库，以及调用方必然同时 import 的 Foundation / SwiftUI 常用类型。
# 冲突时加前缀 Contract（如 scene → ContractScene，避免与 SwiftUI.Scene 歧义；j_s_o_n_decoder → ContractJSONDecoder）。
# 生成器模板自己一律写模块限定名（Swift.String、Foundation.JSONDecoder…），这张表是第二道保险，
# 同时保护调用方（Features 等）与 SwiftPM 生成的 resource_bundle_accessor.swift（它用未限定的 Bundle、URL、ProcessInfo）。
TYPE_NAME_CONFLICTS = SWIFT_KEYWORDS | {
    # 模板直接使用的协议与类型。
    "Decoder", "Encoder", "Codable", "Decodable", "Encodable", "CaseIterable", "RawRepresentable",
    "CodingKey", "SingleValueDecodingContainer", "SingleValueEncodingContainer", "KeyedDecodingContainer",
    "KeyedEncodingContainer", "UnkeyedDecodingContainer", "UnkeyedEncodingContainer", "DecodingError",
    "EncodingError", "StaticString", "AnyHashable", "Comparable", "CustomStringConvertible",
    "CustomDebugStringConvertible", "Error", "Hasher",
    # 模块名：同名类型会遮蔽模块限定（Generated.Routes、Swift.String）。
    "Swift", "Foundation", "SwiftUI", "Generated", "Combine", "XCTest", "Testing", "Config", "DesignSystem",
    "Core", "Features", "Security", "UIKit", "Dispatch", "Darwin", "ObjectiveC", "CoreGraphics", "Observation",
    "_Concurrency", "os",
    # 标准库：基础值类型、整数与浮点、集合、可选、错误与结果。
    "Any", "AnyObject", "AnyClass", "Void", "Never", "Bool", "Int", "Int8", "Int16", "Int32", "Int64", "Int128",
    "UInt", "UInt8", "UInt16", "UInt32", "UInt64", "UInt128", "Float", "Float16", "Float32", "Float64", "Float80",
    "Double", "Character", "String", "Substring", "StringProtocol", "Unicode", "Optional", "Array", "ArraySlice",
    "ContiguousArray", "Dictionary", "Set", "Range", "ClosedRange", "Slice", "Result", "Error", "Collection",
    "Sequence", "IteratorProtocol", "MutableCollection", "RandomAccessCollection", "BidirectionalCollection",
    "RangeReplaceableCollection", "OptionSet", "SetAlgebra", "Numeric", "SignedNumeric", "BinaryInteger",
    "FixedWidthInteger", "SignedInteger", "UnsignedInteger", "FloatingPoint", "BinaryFloatingPoint",
    "Strideable", "Equatable", "Hashable", "Identifiable", "Sendable", "Copyable", "Escapable", "Mirror",
    "ObjectIdentifier", "KeyPath", "WritableKeyPath", "ReferenceWritableKeyPath", "PartialKeyPath",
    "AnyKeyPath", "UnsafePointer", "UnsafeMutablePointer", "UnsafeRawPointer", "UnsafeMutableRawPointer",
    "UnsafeBufferPointer", "UnsafeMutableBufferPointer", "OpaquePointer", "Duration", "Clock", "ContinuousClock",
    "SuspendingClock", "Task", "TaskGroup", "ThrowingTaskGroup", "TaskPriority", "Actor", "AnyActor", "MainActor",
    "GlobalActor", "AsyncSequence", "AsyncIteratorProtocol", "AsyncStream", "AsyncThrowingStream",
    "CheckedContinuation", "UnsafeContinuation", "CancellationError", "Codable", "SIMD", "SIMD2", "SIMD4",
    "ExpressibleByStringLiteral", "ExpressibleByIntegerLiteral", "ExpressibleByArrayLiteral",
    "ExpressibleByDictionaryLiteral", "ExpressibleByNilLiteral", "ExpressibleByBooleanLiteral",
    "ExpressibleByFloatLiteral", "LosslessStringConvertible", "TextOutputStream", "TextOutputStreamable",
    # Foundation 常用类型（含 SwiftPM resource_bundle_accessor.swift 用到的 Bundle、URL、ProcessInfo）。
    "JSONDecoder", "JSONEncoder", "JSONSerialization", "PropertyListDecoder", "PropertyListEncoder",
    "PropertyListSerialization", "Bundle", "Data", "Date", "DateFormatter", "DateComponents",
    "DateInterval", "ISO8601DateFormatter", "Decimal", "Locale", "Notification", "NotificationCenter",
    "Operation", "OperationQueue", "Process", "ProcessInfo", "URL", "URLRequest", "URLResponse",
    "HTTPURLResponse", "URLSession", "URLComponents", "URLQueryItem", "UUID", "Calendar", "Measurement",
    "Unit", "Progress", "Scanner", "Stream", "Thread", "Timer", "TimeZone", "TimeInterval", "FileManager",
    "UserDefaults", "IndexPath", "IndexSet", "CharacterSet", "AttributedString", "NSAttributedString",
    "NumberFormatter", "Formatter", "RunLoop", "NSObject", "NSString", "NSNumber", "NSError", "NSLock",
    "NSRange", "NSRecursiveLock", "DispatchQueue", "DispatchGroup", "DispatchTime", "CGFloat", "CGPoint",
    "CGSize", "CGRect", "Selector",
    # SwiftUI 常用类型。
    "Scene", "View", "Text", "Image", "Color", "Font", "App", "Label", "Link", "Menu", "Section",
    "Group", "Form", "List", "Button", "Toggle", "Picker", "Shape", "Path", "Animation", "Transaction",
    "Environment", "State", "Binding", "Namespace", "Layout", "Alignment", "Edge", "Axis", "Gesture",
    "ObservableObject", "Published", "StateObject", "ObservedObject", "EnvironmentObject", "AppStorage",
    "NavigationStack", "NavigationPath", "ForEach", "EmptyView", "AnyView", "LocalizedStringKey",
}

# 生成物里手写的类型，枚举类型名不能与之重名。
RESERVED_TYPE_NAMES = {
    "ContractEnums", "RetryKind", "ErrorCodeInfo", "ErrorCodes", "RouteKind", "RouteSpec", "Routes",
    "RouteParamType", "RouteParamSpec",
    "BridgeMethodSpec", "BridgeMethods", "BridgeErrors", "DefaultTexts", "DesignTokens", "DebugOnlyRoutes",
    "AppStoreSpec", "AppStores", "AppVersionCheckExample",
    "ApiOperation", "ApiOperations", "ApiMinVersionGate",
    "TrackValue", "TrackEvent", "TrackerEvents", "DeviceHashSeeds", "DefaultConfig",
    "BridgeSchema", "BridgeAppTargets",
    # SwiftPM 为带资源的包生成的 resource_bundle_accessor.swift 里的私有类型。
    "BundleFinder",
}

UNKNOWN_CASE = "unknown"
UNKNOWN_RAW = "__unknown__"

# 生成的枚举自带的成员名（以及作 case 名有歧义的关键字），契约 case 不能同名；
# 同名时改成 contract + UpperCamel（unknown → contractUnknown），兜底 case 保持 .unknown。
RESERVED_CASE_NAMES = {
    UNKNOWN_CASE, "allCases", "rawValue", "hashValue", "init", "encode", "hash", "self", "Self", "Type",
    "Protocol", "description", "debugDescription", "AllCases", "RawValue",
}

RETRY_KINDS = ["never", "after_action", "later", "immediate", "not_applicable"]


class GenError(Exception):
    pass


# ---------- 工具 ----------


def load(rel: str):
    path = os.path.join(SNAPSHOT, rel)
    try:
        with open(path, encoding="utf-8") as f:
            return json.load(f)
    except (OSError, ValueError) as exc:
        raise GenError(f"读取快照 {rel} 失败：{exc}") from exc


def swift_string(value: str) -> str:
    out = []
    for ch in value:
        code = ord(ch)
        if ch == "\\":
            out.append("\\\\")
        elif ch == '"':
            out.append('\\"')
        elif ch == "\n":
            out.append("\\n")
        elif ch == "\r":
            out.append("\\r")
        elif ch == "\t":
            out.append("\\t")
        elif code < 0x20 or code == 0x7F:
            out.append("\\u{%X}" % code)
        else:
            out.append(ch)
    return '"' + "".join(out) + '"'


def swift_optional_string(value) -> str:
    if value is None:
        return "nil"
    if not isinstance(value, str):
        raise GenError(f"应为字符串或 null：{value!r}")
    return swift_string(value)


def split_words(raw: str) -> list[str]:
    return [p for p in re.split(r"[^0-9A-Za-z]+", raw) if p]


def upper_camel(raw: str) -> str:
    words = split_words(raw)
    if not words:
        raise GenError(f"无法转成类型名：{raw!r}")
    name = "".join(w[:1].upper() + (w[1:].lower() if w.isupper() else w[1:]) for w in words)
    if name[0].isdigit():
        name = "V" + name
    return name


def lower_camel(raw: str) -> str:
    words = split_words(raw)
    if not words:
        raise GenError(f"无法转成 case 名：{raw!r}")
    first = words[0]
    first = first.lower() if first.isupper() else first[:1].lower() + first[1:]
    rest = "".join(w[:1].upper() + (w[1:].lower() if w.isupper() else w[1:]) for w in words[1:])
    name = first + rest
    if name[0].isdigit():
        name = "v" + name
    return name


def escape_identifier(name: str) -> str:
    return f"`{name}`" if name in SWIFT_KEYWORDS else name


def as_int(value, context: str) -> int:
    if isinstance(value, bool) or not isinstance(value, int):
        raise GenError(f"{context} 应为整数：{value!r}")
    return value


def as_number(value, context: str) -> float:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise GenError(f"{context} 应为数值：{value!r}")
    return float(value)


def as_str(value, context: str) -> str:
    if not isinstance(value, str):
        raise GenError(f"{context} 应为字符串：{value!r}")
    return value


def since_ios(row: dict, context: str):
    since = row.get("since")
    if since is None:
        return None
    if not isinstance(since, dict):
        raise GenError(f"{context}.since 应为对象")
    value = since.get("ios")
    if value is not None and not isinstance(value, str):
        raise GenError(f"{context}.since.ios 应为字符串或 null")
    return value


def put(out: dict[str, str], rel: str, content: str, source: str = "") -> None:
    """登记一个输出文件；路径（大小写不敏感）与已有输出相同即报错，绝不覆盖。"""
    key = rel.lower()
    for existing in out:
        if existing.lower() == key:
            raise GenError(f"输出文件名冲突：{rel}（{source or '生成器'}）与已有输出 {existing} 相同，请改快照文件名")
    out[rel] = content


# ---------- 枚举 ----------


def collect_enums():
    """返回 [(源文件名, [(键, 类型名, [(case 名, rawValue)])])]，保持文件内契约顺序。"""
    enum_dir = os.path.join(SNAPSHOT, "contracts", "enums")
    files = sorted(f for f in os.listdir(enum_dir) if f.endswith(".json"))
    if not files:
        raise GenError("contracts/snapshot/contracts/enums/ 下没有快照")
    result = []
    seen_keys: dict[str, str] = {}
    seen_types: dict[str, str] = {}
    for fname in files:
        doc = load(f"contracts/enums/{fname}")
        enums = doc.get("enums")
        if not isinstance(enums, dict) or not enums:
            raise GenError(f"{fname}: enums 缺失或为空")
        group = []
        for key, definition in enums.items():
            if key in seen_keys:
                raise GenError(f"枚举 {key} 在 {seen_keys[key]} 与 {fname} 重复定义")
            seen_keys[key] = fname
            values = definition.get("values") if isinstance(definition, dict) else None
            if not isinstance(values, dict) or not values:
                raise GenError(f"{fname}: {key}.values 缺失或为空")
            type_name = upper_camel(key)
            if type_name in TYPE_NAME_CONFLICTS:
                type_name = "Contract" + type_name
            if type_name in RESERVED_TYPE_NAMES or type_name in seen_types:
                raise GenError(f"{fname}: {key} 的类型名 {type_name} 与 {seen_types.get(type_name, '生成器保留名')} 冲突")
            seen_types[type_name] = key
            cases = []
            used: dict[str, str] = {UNKNOWN_CASE: UNKNOWN_RAW}
            for raw in values:
                if raw == UNKNOWN_RAW:
                    raise GenError(f"{fname}: {key} 含保留值 {UNKNOWN_RAW}")
                name = lower_camel(raw)
                if name in RESERVED_CASE_NAMES:
                    name = "contract" + name[:1].upper() + name[1:]
                if name in used:
                    raise GenError(f"{fname}: {key} 的取值 {raw!r} 与 {used[name]!r} 都映射到 case {name}")
                used[name] = raw
                cases.append((name, raw))
            group.append((key, type_name, cases))
        result.append((fname, group))
    return result


def render_enum(key: str, type_name: str, cases) -> str:
    lines = [f"/// 契约枚举 `{key}`。未知取值解码为 `.unknown`（不在 `allCases` 里）。"]
    lines.append(f"public enum {type_name}: Swift.String, Swift.Sendable, Swift.CaseIterable, Swift.Codable {{")
    for name, raw in cases:
        ident = escape_identifier(name)
        if name == raw:
            lines.append(f"    case {ident}")
        else:
            lines.append(f"    case {ident} = {swift_string(raw)}")
    lines.append(f"    case {UNKNOWN_CASE} = {swift_string(UNKNOWN_RAW)}")
    lines.append("")
    lines.append(f"    public static let allCases: [{type_name}] = [")
    for name, _ in cases:
        lines.append(f"        .{escape_identifier(name)},")
    lines.append("    ]")
    lines.append("")
    lines.append("    public init(from decoder: any Swift.Decoder) throws {")
    lines.append("        let rawValue = try decoder.singleValueContainer().decode(Swift.String.self)")
    lines.append(f"        self = {type_name}(rawValue: rawValue) ?? .{UNKNOWN_CASE}")
    lines.append("    }")
    lines.append("}")
    return "\n".join(lines) + "\n"


def gen_enums(out: dict[str, str], groups):
    for fname, group in groups:
        stem = fname[: -len(".json")]
        parts = [HEADER, f"// 快照：contracts/enums/{fname}\n"]
        for key, type_name, cases in group:
            parts.append("\n" + render_enum(key, type_name, cases))
        put(out, f"Enums+{upper_camel(stem)}.swift", "".join(parts), f"contracts/enums/{fname}")

    lines = [HEADER.rstrip("\n"), "", "/// 全部契约枚举：键为契约原名（蛇形），值为契约顺序的全部 rawValue（不含 unknown）。",
             "public enum ContractEnums {", "    public static let all: [Swift.String: [Swift.String]] = ["]
    entries = sorted((key, cases) for _, group in groups for key, _, cases in group)
    for key, cases in entries:
        values = ", ".join(swift_string(raw) for _, raw in cases)
        lines.append(f"        {swift_string(key)}: [{values}],")
    lines += ["    ]", "}", ""]
    put(out, "ContractEnums.swift", "\n".join(lines))


# ---------- 错误码 ----------


def gen_error_codes(out: dict[str, str]):
    doc = load("contracts/error-codes.json")
    rows = doc.get("codes")
    if not isinstance(rows, list) or not rows:
        raise GenError("error-codes.codes 缺失或为空")
    lines = [HEADER.rstrip("\n"), "// 快照：contracts/error-codes.json", "",
             "public enum RetryKind: Swift.String, Swift.Sendable, Swift.Codable {"]
    for raw in RETRY_KINDS:
        name = lower_camel(raw)
        lines.append(f"    case {name}" if name == raw else f"    case {name} = {swift_string(raw)}")
    lines += [
        "}",
        "",
        "public struct ErrorCodeInfo: Swift.Sendable, Swift.Equatable {",
        "    public let code: Swift.Int",
        "    public let http: Swift.Int",
        "    public let retryKind: RetryKind",
        "    public let retryKindByReason: [Swift.String: RetryKind]",
        "    public let isDeprecated: Swift.Bool",
        "    public let isP1: Swift.Bool",
        "}",
        "",
        "public enum ErrorCodes {",
        "    /// 表里全部码（含废弃、P1）。",
        "    public static let all: [Swift.Int: ErrorCodeInfo] = [",
    ]
    seen = set()
    for index, row in enumerate(rows):
        ctx = f"error-codes.codes[{index}]"
        code = as_int(row.get("code"), f"{ctx}.code")
        if code in seen:
            raise GenError(f"错误码 {code} 重复")
        seen.add(code)
        http = as_int(row.get("http"), f"{ctx}.http")
        retry = as_str(row.get("retry_kind"), f"{ctx}.retry_kind")
        if retry not in RETRY_KINDS:
            raise GenError(f"{ctx}.retry_kind 未知取值 {retry!r}")
        by_reason = row.get("retry_kind_by_reason") or {}
        if not isinstance(by_reason, dict):
            raise GenError(f"{ctx}.retry_kind_by_reason 应为对象")
        reason_items = []
        for reason, kind in by_reason.items():
            if kind not in RETRY_KINDS:
                raise GenError(f"{ctx}.retry_kind_by_reason.{reason} 未知取值 {kind!r}")
            reason_items.append(f"{swift_string(reason)}: .{lower_camel(kind)}")
        reasons = "[" + ", ".join(reason_items) + "]" if reason_items else "[:]"
        deprecated = row.get("deprecated", False)
        if not isinstance(deprecated, bool):
            raise GenError(f"{ctx}.deprecated 应为布尔")
        phase = row.get("phase")
        lines += [
            f"        {code}: ErrorCodeInfo(",
            f"            code: {code}, http: {http}, retryKind: .{lower_camel(retry)},",
            f"            retryKindByReason: {reasons},",
            f"            isDeprecated: {'true' if deprecated else 'false'}, isP1: {'true' if phase == 'P1' else 'false'}",
            "        ),",
        ]
    lines += [
        "    ]",
        "",
        "    public static func info(_ code: Swift.Int) -> ErrorCodeInfo? {",
        "        all[code]",
        "    }",
        "}",
        "",
    ]
    put(out, "ErrorCodes.swift", "\n".join(lines))


# routes.json 参数 schema 只允许这些关键字；出现别的就报错，不静默丢弃约束。
PARAM_SCHEMA_KEYS = {"type", "additionalProperties", "properties", "required"}
PARAM_PROPERTY_KEYS = {"type", "enum", "minLength", "maxLength", "pattern", "description", "additionalProperties"}
PARAM_TYPES = {"string", "integer", "number", "boolean", "object", "array"}


def route_params(schema, ctx: str, indent: str):
    """返回 (RouteParamSpec 字面量行, required 列表, additionalProperties)。"""
    if not isinstance(schema, dict):
        raise GenError(f"{ctx} 应为对象")
    extra = set(schema) - PARAM_SCHEMA_KEYS
    if extra:
        raise GenError(f"{ctx} 含生成器不支持的关键字 {sorted(extra)}")
    if schema.get("type") != "object":
        raise GenError(f"{ctx}.type 应为 object")
    additional = schema.get("additionalProperties", False)
    if not isinstance(additional, bool):
        raise GenError(f"{ctx}.additionalProperties 应为布尔")
    props = schema.get("properties", {})
    if not isinstance(props, dict):
        raise GenError(f"{ctx}.properties 应为对象")
    required = schema.get("required", [])
    if not isinstance(required, list) or not all(isinstance(r, str) for r in required):
        raise GenError(f"{ctx}.required 应为字符串数组")
    for r in required:
        if r not in props:
            raise GenError(f"{ctx}.required 含未声明的参数 {r!r}")
    lines = []
    for pname in sorted(props):
        pctx = f"{ctx}.properties.{pname}"
        prop = props[pname]
        if not isinstance(prop, dict):
            raise GenError(f"{pctx} 应为对象")
        extra = set(prop) - PARAM_PROPERTY_KEYS
        if extra:
            raise GenError(f"{pctx} 含生成器不支持的关键字 {sorted(extra)}")
        ptype = prop.get("type")
        if ptype not in PARAM_TYPES:
            raise GenError(f"{pctx}.type 未知取值 {ptype!r}")
        args = [f"name: {swift_string(pname)}", f"type: .{ptype}"]
        if "enum" in prop:
            values = prop["enum"]
            if not isinstance(values, list) or not all(isinstance(v, str) for v in values):
                raise GenError(f"{pctx}.enum 应为字符串数组")
            args.append("enumValues: [" + ", ".join(swift_string(v) for v in values) + "]")
        for key, label in (("minLength", "minLength"), ("maxLength", "maxLength")):
            if key in prop:
                value = prop[key]
                if not isinstance(value, int) or isinstance(value, bool) or value < 0:
                    raise GenError(f"{pctx}.{key} 应为非负整数")
                args.append(f"{label}: {value}")
        if "pattern" in prop:
            args.append(f"pattern: {swift_string(as_str(prop['pattern'], pctx + '.pattern'))}")
        lines.append(f"{indent}RouteParamSpec({', '.join(args)}),")
    return lines, required, additional


# ---------- 路由 ----------


def gen_routes(out: dict[str, str], route_entry_cases):
    doc = load("contracts/routes.json")
    routes = doc.get("routes")
    if not isinstance(routes, dict) or not routes:
        raise GenError("routes.routes 缺失或为空")
    entry_case = {raw: name for name, raw in route_entry_cases}

    def spec_literal(name: str, row: dict, indent: str) -> list[str]:
        ctx = f"routes[{name}]"
        kind = as_str(row.get("kind"), f"{ctx}.kind")
        if kind not in ("native", "h5"):
            raise GenError(f"{ctx}.kind 未知取值 {kind!r}")
        auth = as_str(row.get("auth"), f"{ctx}.auth")
        entries = row.get("entry")
        if not isinstance(entries, list):
            raise GenError(f"{ctx}.entry 应为数组")
        entry_names = []
        for raw in entries:
            if raw not in entry_case:
                raise GenError(f"{ctx}.entry 含 route_entry 之外的取值 {raw!r}")
            entry_names.append("." + escape_identifier(entry_case[raw]))
        debug_only = row.get("debug_only", False)
        if not isinstance(debug_only, bool):
            raise GenError(f"{ctx}.debug_only 应为布尔")
        agent_guide = row.get("agent_guide", False)
        if not isinstance(agent_guide, bool):
            raise GenError(f"{ctx}.agent_guide 应为布尔")
        agent_guide_account = row.get("agent_guide_account")
        if agent_guide_account is not None and not isinstance(agent_guide_account, str):
            raise GenError(f"{ctx}.agent_guide_account 应为字符串或缺省")
        if agent_guide and agent_guide_account is not None:
            raise GenError(f"{ctx}：agent_guide_account 路由不得同时 agent_guide=true")
        param_lines, required, additional = route_params(row.get("params"), f"{ctx}.params", indent + "        ")
        return [
            f"{indent}RouteSpec(",
            f"{indent}    name: {swift_string(name)}, kind: .{kind}, auth: {swift_string(auth)},",
            f"{indent}    sinceIOS: {swift_optional_string(since_ios(row, ctx))},",
            f"{indent}    entries: [{', '.join(entry_names)}],",
            f"{indent}    h5Path: {swift_optional_string(row.get('h5_path'))}, debugOnly: {'true' if debug_only else 'false'},",
            f"{indent}    agentGuide: {'true' if agent_guide else 'false'},",
            f"{indent}    agentGuideAccount: {swift_optional_string(agent_guide_account)},",
            f"{indent}    params: [",
            *param_lines,
            f"{indent}    ],",
            f"{indent}    requiredParams: [{', '.join(swift_string(r) for r in required)}],",
            f"{indent}    additionalParams: {'true' if additional else 'false'}",
            f"{indent})",
        ]

    release_names = [n for n in sorted(routes) if not routes[n].get("debug_only", False)]
    debug_names = [n for n in sorted(routes) if routes[n].get("debug_only", False)]

    lines = [
        HEADER.rstrip("\n"),
        "// 快照：contracts/routes.json",
        "",
        "public enum RouteKind: Swift.String, Swift.Sendable {",
        "    case native, h5",
        "}",
        "",
        "public struct RouteSpec: Swift.Sendable, Swift.Equatable {",
        "    public let name: Swift.String",
        "    public let kind: RouteKind",
        "    public let auth: Swift.String",
        "    /// routes.json 的 since.ios；null 表示 iOS 尚未上线该路由。",
        "    public let sinceIOS: Swift.String?",
        "    public let entries: [RouteEntry]",
        "    public let h5Path: Swift.String?",
        "    public let debugOnly: Swift.Bool",
        "    /// routes.json 的 agent_guide（缺省 false）：Agent 页面引导卡与收益卡按钮能否打开该路由。",
        "    public let agentGuide: Swift.Bool",
        "    /// routes.json 的 agent_guide_account（phone / delete / fund，缺省 nil）：Agent 从不引导的账号安全路由。",
        "    public let agentGuideAccount: Swift.String?",
        "    /// routes.json params.properties（按参数名排序）。",
        "    public let params: [RouteParamSpec]",
        "    /// routes.json params.required。",
        "    public let requiredParams: [Swift.String]",
        "    /// routes.json params.additionalProperties（缺省 false）。",
        "    public let additionalParams: Swift.Bool",
        "",
        "    public init(",
        "        name: Swift.String, kind: RouteKind, auth: Swift.String, sinceIOS: Swift.String?,",
        "        entries: [RouteEntry], h5Path: Swift.String?, debugOnly: Swift.Bool,",
        "        agentGuide: Swift.Bool = false, agentGuideAccount: Swift.String? = nil,",
        "        params: [RouteParamSpec] = [], requiredParams: [Swift.String] = [], additionalParams: Swift.Bool = false",
        "    ) {",
        "        self.name = name",
        "        self.kind = kind",
        "        self.auth = auth",
        "        self.sinceIOS = sinceIOS",
        "        self.entries = entries",
        "        self.h5Path = h5Path",
        "        self.debugOnly = debugOnly",
        "        self.agentGuide = agentGuide",
        "        self.agentGuideAccount = agentGuideAccount",
        "        self.params = params",
        "        self.requiredParams = requiredParams",
        "        self.additionalParams = additionalParams",
        "    }",
        "",
        "    public func param(_ name: Swift.String) -> RouteParamSpec? {",
        "        params.first { $0.name == name }",
        "    }",
        "}",
        "",
        "/// 路由参数的 JSON 类型（routes.json params.properties.*.type）。",
        "public enum RouteParamType: Swift.String, Swift.Sendable {",
        "    case string, integer, number, boolean, object, array",
        "}",
        "",
        "/// 一个路由参数的 JSON Schema 约束（只转写 routes.json 用到的关键字）。",
        "public struct RouteParamSpec: Swift.Sendable, Swift.Equatable {",
        "    public let name: Swift.String",
        "    public let type: RouteParamType",
        "    public let enumValues: [Swift.String]?",
        "    public let minLength: Swift.Int?",
        "    public let maxLength: Swift.Int?",
        "    public let pattern: Swift.String?",
        "",
        "    public init(",
        "        name: Swift.String, type: RouteParamType, enumValues: [Swift.String]? = nil,",
        "        minLength: Swift.Int? = nil, maxLength: Swift.Int? = nil, pattern: Swift.String? = nil",
        "    ) {",
        "        self.name = name",
        "        self.type = type",
        "        self.enumValues = enumValues",
        "        self.minLength = minLength",
        "        self.maxLength = maxLength",
        "        self.pattern = pattern",
        "    }",
        "}",
        "",
        "public enum Routes {",
        "    /// 键为路由名。debug_only 路由只在 DEBUG（Debug / Staging）里登记，Release 生成物里没有这些名字。",
        "    public static let all: [Swift.String: RouteSpec] = {",
        "        var table: [Swift.String: RouteSpec] = [:]",
    ]
    for name in release_names:
        body = spec_literal(name, routes[name], "        ")
        body[0] = f"        table[{swift_string(name)}] = " + body[0].lstrip()
        lines += body
    def marker_check(expected_count: int) -> list[str]:
        # 长标记跟 debug_only 表在同一个 #if DEBUG 块里：fatalError 的消息在 -O 下保留在字符串段，
        # 表被引用就一定在（release-scan.sh 查它；短路由名会被内联进指令，strings 看不到）。
        return [
            f"        if table.count != {expected_count} {{",
            f"            Swift.fatalError({swift_string(DEBUG_ONLY_ROUTE_MARKER + ': debug-only route table incomplete')})",
            "        }",
        ]

    if debug_names:
        lines.append("        #if DEBUG")
        for name in debug_names:
            body = spec_literal(name, routes[name], "        ")
            body[0] = f"        table[{swift_string(name)}] = " + body[0].lstrip()
            lines += body
        lines += marker_check(len(release_names) + len(debug_names))
        lines.append("        #endif")
    lines += [
        "        return table",
        "    }()",
        "",
        "    public static func spec(_ name: Swift.String) -> RouteSpec? {",
        "        all[name]",
        "    }",
        "}",
        "",
    ]
    put(out, "Routes.swift", "\n".join(lines))

    # App target 里的 debug_only 路由表（Debug、Staging 编译；Staging 下包内 Routes.all 没有这些路由）。
    app = [
        HEADER.rstrip("\n"),
        "// 快照：contracts/routes.json（debug_only 为 true 的路由）",
        "",
        "#if DEBUG",
        "import Generated",
        "",
        "/// debug_only 路由表：只在 Debug / Staging 编译（App target 定义 DEBUG）。Release 制品里没有这些名字，",
        "/// release-scan.sh 查 `tableMarker`。路由层（APP-02）在 DEBUG 下把它并进 `Routes.all`。",
        "enum DebugOnlyRoutes {",
        f"    static let tableMarker = {swift_string(DEBUG_ONLY_ROUTE_MARKER)}",
        "",
        "    static let all: [Swift.String: Generated.RouteSpec] = {",
        "        var table: [Swift.String: Generated.RouteSpec] = [:]",
    ]
    for name in debug_names:
        body = spec_literal(name, routes[name], "        ")
        body[0] = f"        table[{swift_string(name)}] = " + body[0].lstrip()
        app += body
    app += marker_check(len(debug_names))
    app += ["        return table", "    }()", "}", "#endif", ""]
    put(out, APP_PREFIX + "DebugOnlyRoutes.swift", "\n".join(app))


# ---------- 桥 ----------


def gen_bridge(out: dict[str, str]):
    doc = load("contracts/bridge.schema.json")
    methods = doc.get("methods")
    errors = doc.get("errors")
    if not isinstance(methods, dict) or not methods:
        raise GenError("bridge.methods 缺失或为空")
    if not isinstance(errors, dict) or not errors:
        raise GenError("bridge.errors 缺失或为空")
    lines = [
        HEADER.rstrip("\n"),
        "// 快照：contracts/bridge.schema.json",
        "",
        "public struct BridgeMethodSpec: Swift.Sendable, Swift.Equatable {",
        "    public let name: Swift.String",
        "    public let level: Swift.String",
        "    /// 缺省或 null 为 nil。",
        "    public let timeoutMs: Swift.Int?",
        "    public let sinceIOS: Swift.String?",
        "    /// 只取契约显式字段，缺省为 false。",
        "    public let gestureRequired: Swift.Bool",
        "}",
        "",
        "public enum BridgeMethods {",
        "    public static let all: [Swift.String: BridgeMethodSpec] = [",
    ]
    for name in sorted(methods):
        row = methods[name]
        ctx = f"bridge.methods[{name}]"
        level = as_str(row.get("level"), f"{ctx}.level")
        timeout = row.get("timeout_ms")
        timeout_lit = "nil" if timeout is None else str(as_int(timeout, f"{ctx}.timeout_ms"))
        gesture = row.get("gesture_required", False)
        if gesture is None:
            gesture = False
        if not isinstance(gesture, bool):
            raise GenError(f"{ctx}.gesture_required 应为布尔")
        lines += [
            f"        {swift_string(name)}: BridgeMethodSpec(",
            f"            name: {swift_string(name)}, level: {swift_string(level)}, timeoutMs: {timeout_lit},",
            f"            sinceIOS: {swift_optional_string(since_ios(row, ctx))}, gestureRequired: {'true' if gesture else 'false'}",
            "        ),",
        ]
    lines += [
        "    ]",
        "",
        "    public static func spec(_ name: Swift.String) -> BridgeMethodSpec? {",
        "        all[name]",
        "    }",
        "}",
        "",
        "public enum BridgeErrors {",
        "    /// 桥错误码 → 契约里的含义原文。",
        "    public static let all: [Swift.Int: Swift.String] = [",
    ]
    seen = set()
    for key in sorted(errors, key=lambda k: (len(k), k)):
        if not re.fullmatch(r"[0-9]+", key):
            raise GenError(f"bridge.errors 的键 {key!r} 不是十进制整数")
        code = int(key)
        if code in seen:
            raise GenError(f"bridge.errors 码 {code} 重复")
        seen.add(code)
        lines.append(f"        {code}: {swift_string(as_str(errors[key], f'bridge.errors[{key}]'))},")
    lines += ["    ]", "}", ""]
    put(out, "Bridge.swift", "\n".join(lines))
    gen_bridge_schema(out, doc)


def gen_bridge_schema(out: dict[str, str], doc: dict):
    """APP-04：桥契约全文（BridgeHost 的信封、参数 schema、signed_paths、not_exposed、events 只从这里取）与
    apps.json 的 trade_only 目标（ext.openApp 的白名单拒绝）。紧凑 JSON、保持契约键顺序，原样嵌成字符串常量。"""
    for key in ("envelope", "levels", "errors", "signed_paths", "not_exposed", "events", "methods"):
        if key not in doc:
            raise GenError(f"bridge.schema.json 缺少 {key}")
    text = json.dumps(doc, ensure_ascii=False, separators=(",", ":"))
    apps = load("contracts/apps.json").get("apps")
    if not isinstance(apps, dict) or not apps:
        raise GenError("apps.json 的 apps 缺失或为空")
    trade_only = sorted(name for name, app in apps.items() if isinstance(app, dict) and app.get("trade_only") is True)
    targets = sorted(apps)
    lines = [
        HEADER.rstrip("\n"),
        "// 快照：contracts/bridge.schema.json（全文）与 contracts/apps.json（外跳目标、trade_only）。",
        "",
        "/// 桥契约全文（JSON 文本）。BridgeHost 只从这里取方法表、参数 schema、错误码、signed_paths、not_exposed 与事件白名单。",
        "public enum BridgeSchema {",
        f"    public static let json: Swift.String = {swift_string(text)}",
        "}",
        "",
        "/// apps.json 的外跳目标（ext.openApp 的 target）。",
        "public enum BridgeAppTargets {",
        "    public static let all: Swift.Set<Swift.String> = [" + ", ".join(swift_string(t) for t in targets) + "]",
        "    /// trade_only 的目标：ext.openApp 一律 90403（BR-ATTR-29 细则）。",
        "    public static let tradeOnly: Swift.Set<Swift.String> = [" + ", ".join(swift_string(t) for t in trade_only) + "]",
        "}",
        "",
    ]
    put(out, "BridgeSchema.swift", "\n".join(lines))


# ---------- 文案 ----------


def gen_texts(out: dict[str, str]):
    path = os.path.join(SNAPSHOT, "contracts", "texts.default.json")
    doc = load("contracts/texts.default.json")
    for field in ("texts", "fallbacks"):
        table = doc.get(field)
        if not isinstance(table, dict) or not all(isinstance(v, str) for v in table.values()):
            raise GenError(f"texts.default.{field} 应为字符串字典")
    with open(path, encoding="utf-8") as f:
        put(out, "Resources/texts.default.json", f.read())
    put(out, "DefaultTexts.swift", HEADER + '''// 资源：Resources/texts.default.json（从快照 contracts/texts.default.json 原样复制）

import Foundation

/// 包内默认文案（BR-TEXT-12 的唯一来源）。首次访问时从包资源加载。
public enum DefaultTexts {
    private struct Table: Swift.Decodable, Swift.Sendable {
        let texts: [Swift.String: Swift.String]
        let fallbacks: [Swift.String: Swift.String]
    }

    private static let table: Table = {
        guard let url = Foundation.Bundle.module.url(forResource: "texts.default", withExtension: "json"),
              let data = try? Foundation.Data(contentsOf: url),
              let decoded = try? Foundation.JSONDecoder().decode(Table.self, from: data)
        else {
            Swift.assertionFailure("Generated: texts.default.json missing or invalid")
            return Table(texts: [:], fallbacks: [:])
        }
        return decoded
    }()

    private static let sortedKeys: [Swift.String] = table.texts.keys.sorted()

    /// texts 里的值。
    public static func text(_ key: Swift.String) -> Swift.String? {
        table.texts[key]
    }

    /// fallbacks 里的值。
    public static func fallback(_ key: Swift.String) -> Swift.String? {
        table.fallbacks[key]
    }

    /// texts 的全部键（按字典序）。
    public static var allKeys: [Swift.String] {
        sortedKeys
    }
}
''')


# ---------- 令牌 ----------


def token_leaves(node, kind, ctx: str, prefix: str = "") -> list[tuple[str, object]]:
    if not isinstance(node, dict):
        raise GenError(f"{ctx} 应为对象")
    if "value" in node:
        if not prefix:
            raise GenError(f"{ctx} 叶子没有相对路径")
        value = node["value"]
        if kind is int:
            return [(prefix, as_int(value, f"{ctx}.value"))]
        if kind is float:
            return [(prefix, as_number(value, f"{ctx}.value"))]
        return [(prefix, as_str(value, f"{ctx}.value"))]
    result = []
    for key in sorted(node):
        path = f"{prefix}.{key}" if prefix else key
        result += token_leaves(node[key], kind, f"{ctx}.{key}", path)
    return result


def shadow_layers(node) -> list[tuple[str, list[dict]]]:
    if not isinstance(node, dict):
        raise GenError("tokens.shadow 应为对象")
    result = []
    for key in sorted(node):
        ctx = f"tokens.shadow.{key}"
        value = (node[key] or {}).get("value") if isinstance(node[key], dict) else None
        if not isinstance(value, list):
            raise GenError(f"{ctx}.value 应为数组")
        layers = []
        for index, layer in enumerate(value):
            lctx = f"{ctx}.value[{index}]"
            if not isinstance(layer, dict):
                raise GenError(f"{lctx} 应为对象")
            color = as_str(layer.get("color"), f"{lctx}.color")
            if not re.fullmatch(r"#[0-9A-Fa-f]{6}", color):
                raise GenError(f"{lctx}.color 不是 #RRGGBB：{color!r}")
            layers.append({
                "x": as_int(layer.get("x"), f"{lctx}.x"),
                "y": as_int(layer.get("y"), f"{lctx}.y"),
                "blur": as_int(layer.get("blur"), f"{lctx}.blur"),
                "spread": as_int(layer.get("spread"), f"{lctx}.spread"),
                "color": color,
                "opacity": as_number(layer.get("opacity"), f"{lctx}.opacity"),
            })
        result.append((key, layers))
    return result


def gen_tokens(out: dict[str, str]):
    doc = load("design/design-tokens.json")
    version = as_str((doc.get("metadata") or {}).get("version"), "design.metadata.version")
    tokens = doc.get("tokens")
    if not isinstance(tokens, dict):
        raise GenError("design.tokens 缺失")
    try:
        groups = [
            ("colors", "String", "颜色：去掉 tokens.color. 前缀的点分路径 → \"#RRGGBB\"（保留源大小写）。",
             token_leaves(tokens["color"], str, "tokens.color")),
            ("spacing", "Int", "间距（pt）：\"0\"…\"16\"。", token_leaves(tokens["space"], int, "tokens.space")),
            ("radius", "Int", "圆角（pt）。", token_leaves(tokens["radius"], int, "tokens.radius")),
            ("fontSize", "Int", "字号（pt）：caption … display。",
             token_leaves(tokens["font"]["size"], int, "tokens.font.size")),
            ("interactionTarget", "Int", "命中区（pt）：tokens.interaction.target。",
             token_leaves(tokens["interaction"]["target"], int, "tokens.interaction.target")),
            ("lineHeight", "Double", "行高倍数：caption … display（tokens.font.line-height）。",
             token_leaves(tokens["font"]["line-height"], float, "tokens.font.line-height")),
            ("fontWeight", "Int", "字重：regular … bold（tokens.font.weight）。",
             token_leaves(tokens["font"]["weight"], int, "tokens.font.weight")),
            ("focus", "Int", "焦点环（pt）：width、offset（tokens.focus）。",
             token_leaves(tokens["focus"], int, "tokens.focus")),
            ("component", "Int", "组件尺寸（pt）：点分路径，如 \"button.min-height\"（tokens.component）。",
             token_leaves(tokens["component"], int, "tokens.component")),
        ]
        shadows = shadow_layers(tokens["shadow"])
    except KeyError as exc:
        raise GenError(f"design.tokens 缺少分组 {exc}") from exc
    for prefix, value in groups[0][3]:
        if not re.fullmatch(r"#[0-9A-Fa-f]{6}", value):
            raise GenError(f"tokens.color.{prefix} 不是 #RRGGBB：{value!r}")
    lines = [
        HEADER.rstrip("\n"),
        "// 快照：design/design-tokens.json",
        "",
        "/// 设计令牌原始常量；SwiftUI 映射在 DesignSystem。",
        "public enum DesignTokens {",
        f"    public static let version: Swift.String = {swift_string(version)}",
    ]
    for name, swift_type, doc_line, leaves in groups:
        lines += ["", f"    /// {doc_line}", f"    public static let {name}: [Swift.String: Swift.{swift_type}] = ["]
        for key, value in leaves:
            literal = swift_string(value) if swift_type == "String" else repr(value) if swift_type == "Double" else str(value)
            lines.append(f"        {swift_string(key)}: {literal},")
        lines.append("    ]")
    lines += [
        "",
        "    /// 阴影的一层（tokens.shadow.* 的 value 数组元素）。color 为 \"#RRGGBB\"，opacity 0…1。",
        "    public struct ShadowLayer: Swift.Sendable, Swift.Equatable {",
        "        public let x: Swift.Int",
        "        public let y: Swift.Int",
        "        public let blur: Swift.Int",
        "        public let spread: Swift.Int",
        "        public let color: Swift.String",
        "        public let opacity: Swift.Double",
        "    }",
        "",
        "    /// 阴影：none / card / floating …（tokens.shadow）。",
        "    public static let shadows: [Swift.String: [ShadowLayer]] = [",
    ]
    for key, layers in shadows:
        if not layers:
            lines.append(f"        {swift_string(key)}: [],")
            continue
        lines.append(f"        {swift_string(key)}: [")
        for layer in layers:
            lines.append(
                f"            ShadowLayer(x: {layer['x']}, y: {layer['y']}, blur: {layer['blur']}, "
                f"spread: {layer['spread']}, color: {swift_string(layer['color'])}, opacity: {layer['opacity']!r}),"
            )
        lines.append("        ],")
    lines += ["    ]", "}", ""]
    put(out, "DesignTokens.swift", "\n".join(lines))


# ---------- 商店对照表与版本检查示例（APP-02c） ----------


def gen_app_stores(out: dict[str, str]):
    doc = load("specs/app-stores.json")
    version = as_str(doc.get("version"), "app-stores.version")
    rows = doc.get("stores")
    if not isinstance(rows, list):
        raise GenError("app-stores.stores 应为列表")
    lines = [
        HEADER.rstrip("\n"),
        "// 快照：specs/app-stores.yaml",
        "",
        "/// 商店对照表的一行（specs/app-stores.yaml）。key、openMethod、target 为 nil 的商店一律视为「本机打不开」",
        "/// （APP-02c；needs N-17）。installSourcePackages 只有 Android 会填。",
        "public struct AppStoreSpec: Swift.Sendable, Swift.Equatable {",
        "    public let key: Swift.String?",
        "    public let name: Swift.String",
        "    public let platform: Swift.String",
        "    public let channels: [Swift.String]",
        "    public let installSourcePackages: [Swift.String]",
        "    public let openMethod: Swift.String?",
        "    public let target: Swift.String?",
        "}",
        "",
        "/// 商店对照表（规划/03 §4.1、BR-ID-01）。代码里不写死商店键与打开方式，一律查这张表。",
        "public enum AppStores {",
        f"    public static let version = {swift_string(version)}",
        "",
        "    public static let all: [AppStoreSpec] = [",
    ]
    for index, row in enumerate(rows):
        ctx = f"app-stores.stores[{index}]"
        if not isinstance(row, dict):
            raise GenError(f"{ctx} 应为对象")
        detail = row.get("detail_page")
        if not isinstance(detail, dict):
            raise GenError(f"{ctx}.detail_page 应为对象")
        channels = row.get("channels")
        packages = row.get("install_source_packages")
        if not isinstance(channels, list) or not isinstance(packages, list):
            raise GenError(f"{ctx}.channels / install_source_packages 应为列表")
        channel_list = ", ".join(swift_string(as_str(c, ctx + ".channels")) for c in channels)
        package_list = ", ".join(swift_string(as_str(c, ctx + ".install_source_packages")) for c in packages)
        lines += [
            "        AppStoreSpec(",
            f"            key: {swift_optional_string(row.get('key'))},",
            f"            name: {swift_string(as_str(row.get('name'), ctx + '.name'))},",
            f"            platform: {swift_string(as_str(row.get('platform'), ctx + '.platform'))},",
            f"            channels: [{channel_list}],",
            f"            installSourcePackages: [{package_list}],",
            f"            openMethod: {swift_optional_string(detail.get('open_method'))},",
            f"            target: {swift_optional_string(detail.get('target'))}",
            "        ),",
        ]
    lines += [
        "    ]",
        "",
        "    /// 某一端（client_platform：ios / android / harmony）的商店。",
        "    public static func forPlatform(_ platform: Swift.String) -> [AppStoreSpec] {",
        "        all.filter { $0.platform == platform }",
        "    }",
        "}",
        "",
    ]
    put(out, "AppStores.swift", "\n".join(lines))


def gen_update_check_example(out: dict[str, str]):
    doc = load("contracts/openapi.json")
    try:
        response = doc["paths"]["/v1/app-versions/check"]["get"]["responses"]["200"]
        example = response["content"]["application/json"]["example"]
    except (KeyError, TypeError) as exc:
        raise GenError(f"openapi 里找不到 GET /v1/app-versions/check 的 200 响应示例：{exc}") from exc
    data = example.get("data") if isinstance(example, dict) else None
    if not isinstance(data, dict):
        raise GenError("GET /v1/app-versions/check 的响应示例没有 data 对象")
    text = json.dumps(data, ensure_ascii=False, separators=(",", ":"))
    lines = [
        HEADER.rstrip("\n"),
        "// 快照：contracts/openapi.yaml GET /v1/app-versions/check 200 响应示例的 data（AppVersionCheck），原样转写",
        "",
        "#if DEBUG",
        "/// 调试面板的版本检查假数据（APP-02c）：只在 Debug / Staging 编译（App target 定义 DEBUG），",
        "/// Release 制品里没有，release-scan.sh 查 `marker`。",
        "enum AppVersionCheckExample {",
        f"    static let marker = {swift_string(UPDATE_EXAMPLE_MARKER)}",
        "",
        f"    static let dataJSON = {swift_string(text)}",
        "}",
        "#endif",
        "",
    ]
    put(out, APP_PREFIX + "AppVersionCheckExample.swift", "\n".join(lines))


# ---------- openapi 操作登记表（APP-03a） ----------

HTTP_METHODS = ["get", "post", "put", "patch", "delete"]
# x-min-version-gate：true（受闸门约束）/ false（例外）/ "conditional"（按请求体条件）/ 未标注。
MIN_VERSION_GATES = {"true": "gated", "false": "exempt", "conditional": "conditional", "none": "unspecified"}
OPERATION_EXTENSIONS = {
    "x-auth", "x-signed", "x-idempotent", "x-step-up", "x-error-codes", "x-session-scopes",
    "x-min-version-gate", "x-implementation",
}


def gen_api_operations(out: dict[str, str]):
    doc = load("contracts/openapi.json")
    paths = doc.get("paths")
    if not isinstance(paths, dict) or not paths:
        raise GenError("openapi.json 没有 paths")
    entries: list[str] = []
    seen: set[str] = set()
    for path, item in paths.items():
        if not isinstance(item, dict):
            raise GenError(f"openapi.json paths[{path!r}] 应为对象")
        for method in HTTP_METHODS:
            op = item.get(method)
            if op is None:
                continue
            where = f"openapi.json {method.upper()} {path}"
            if not isinstance(op, dict):
                raise GenError(f"{where} 应为对象")
            op_id = op.get("operationId")
            if not isinstance(op_id, str) or not re.fullmatch(r"[A-Za-z][A-Za-z0-9]*", op_id):
                raise GenError(f"{where} 的 operationId 不合法：{op_id!r}")
            if op_id in seen:
                raise GenError(f"operationId 重复：{op_id}")
            seen.add(op_id)
            unknown = sorted(k for k in op if k.startswith("x-") and k not in OPERATION_EXTENSIONS)
            if unknown:
                raise GenError(f"{where} 有不认识的扩展字段：{unknown}")
            auth = op.get("x-auth")
            if auth not in ("none", "optional", "login", "realname"):
                raise GenError(f"{where} 的 x-auth 不认识：{auth!r}")
            flags = {}
            for key in ("x-signed", "x-idempotent"):
                value = op.get(key, False)
                if not isinstance(value, bool):
                    raise GenError(f"{where} 的 {key} 应为布尔：{value!r}")
                flags[key] = value
            step_up = op.get("x-step-up")
            if step_up is not None and not isinstance(step_up, str):
                raise GenError(f"{where} 的 x-step-up 应为字符串：{step_up!r}")
            codes = op.get("x-error-codes", [])
            if not isinstance(codes, list):
                raise GenError(f"{where} 的 x-error-codes 应为整数列表")
            codes = [as_int(c, where + " x-error-codes") for c in codes]
            # BR-ID-01 细则「受限会话」：未标注时只接受 full。
            scopes = op.get("x-session-scopes", ["full"])
            if not isinstance(scopes, list) or not scopes:
                raise GenError(f"{where} 的 x-session-scopes 应为非空字符串列表")
            scopes = [as_str(v, where + " x-session-scopes") for v in scopes]
            gate = op.get("x-min-version-gate")
            gate_key = "none" if gate is None else (("true" if gate else "false") if isinstance(gate, bool) else str(gate))
            if gate_key not in MIN_VERSION_GATES:
                raise GenError(f"{where} 的 x-min-version-gate 不认识：{gate!r}")
            implementation = op.get("x-implementation")
            if implementation not in (None, "planned"):
                raise GenError(f"{where} 的 x-implementation 不认识：{implementation!r}")
            entries += [
                f"        {swift_string(op_id)}: ApiOperation(",
                f"            operationId: {swift_string(op_id)},",
                f"            method: {swift_string(method.upper())},",
                f"            pathTemplate: {swift_string(path)},",
                f"            auth: {swift_string(auth)},",
                f"            signed: {'true' if flags['x-signed'] else 'false'},",
                f"            idempotent: {'true' if flags['x-idempotent'] else 'false'},",
                f"            stepUp: {swift_optional_string(step_up)},",
                "            errorCodes: [" + ", ".join(str(c) for c in codes) + "],",
                "            sessionScopes: [" + ", ".join(swift_string(v) for v in scopes) + "],",
                f"            minVersionGate: .{MIN_VERSION_GATES[gate_key]},",
                f"            planned: {'true' if implementation == 'planned' else 'false'}",
                "        ),",
            ]
    lines = [
        HEADER.rstrip("\n"),
        "// 快照：contracts/openapi.yaml（只登记方法、路径与扩展字段，不含请求 / 响应模型）",
        "",
        "/// openapi 的 x-min-version-gate（BR-ID-01 细则「最低支持版本的接口层拦截」）。",
        "public enum ApiMinVersionGate: Swift.String, Swift.Sendable, Swift.Equatable {",
        "    /// true：受闸门约束。",
        "    case gated",
        "    /// false：不受约束（例外）。",
        "    case exempt",
        "    /// conditional：按请求体条件（operation 说明里写条件）。",
        "    case conditional",
        "    /// 未标注。",
        "    case unspecified",
        "}",
        "",
        "/// openapi 的一个 operation。sessionScopes 未标注时为 [\"full\"]（BR-ID-01 细则「受限会话」）；",
        "/// planned = x-implementation: planned；stepUp = x-step-up 的 action（不需要二次验证为 nil）。",
        "public struct ApiOperation: Swift.Sendable, Swift.Equatable {",
        "    public let operationId: Swift.String",
        "    /// 大写 HTTP 方法。",
        "    public let method: Swift.String",
        "    public let pathTemplate: Swift.String",
        "    /// x-auth：none / optional / login / realname。",
        "    public let auth: Swift.String",
        "    public let signed: Swift.Bool",
        "    public let idempotent: Swift.Bool",
        "    public let stepUp: Swift.String?",
        "    public let errorCodes: [Swift.Int]",
        "    public let sessionScopes: [Swift.String]",
        "    public let minVersionGate: ApiMinVersionGate",
        "    public let planned: Swift.Bool",
        "",
        "    /// 只读接口（GET）。",
        "    public var isRead: Swift.Bool {",
        "        method == \"GET\"",
        "    }",
        "}",
        "",
        "/// 全部 operation（contracts/openapi.yaml）。",
        "public enum ApiOperations {",
        "    public static let all: [Swift.String: ApiOperation] = [",
    ]
    lines += entries
    lines += [
        "    ]",
        "",
        "    public static func byId(_ operationId: Swift.String) -> ApiOperation? {",
        "        all[operationId]",
        "    }",
        "}",
        "",
    ]
    put(out, "ApiOperations.swift", "\n".join(lines))


# ---------- APP-03b：埋点事件、设备哈希无效种子、包内默认配置 ----------

# events.yaml 头注释：字段名不得含这些分段（按 _ 切分；link_id、pid_scene 例外），也不得含 sub_union_id、custom_parameters。
EVENT_FORBIDDEN_SEGMENTS = {"url", "href", "link", "deeplink", "tpwd", "pid", "adzone", "relation", "promo"}
EVENT_FORBIDDEN_EXCEPTIONS = {"link_id", "pid_scene"}
EVENT_FORBIDDEN_SUBSTRINGS = ["sub_union_id", "custom_parameters"]
EVENT_FIELD_TYPES = {"string", "integer", "boolean", "enum"}
# 生成函数的参数里由调用方给的公共字段（其余公共字段由 Tracker 填）。
EVENT_CALLER_COMMON = {"page": "page", "spm": "spm", "trace_id": "traceId"}
EVENT_NAME_RE = re.compile(r"[a-z0-9_]+(\.[a-z0-9_]+)?")
EVENT_FIELD_RE = re.compile(r"[a-z][a-z0-9_]*")


def forbidden_event_field(name: str):
    """命中禁用规则时返回原因，否则 None（events.yaml 头注释的字段名规则）。"""
    if name in EVENT_FORBIDDEN_EXCEPTIONS:
        return None
    for sub in EVENT_FORBIDDEN_SUBSTRINGS:
        if sub in name:
            return f"含 {sub}"
    for seg in name.split("_"):
        if seg in EVENT_FORBIDDEN_SEGMENTS:
            return f"含禁用分段 {seg}"
    return None


def event_field_spec(name: str, spec, where: str) -> dict:
    if not isinstance(name, str) or not EVENT_FIELD_RE.fullmatch(name):
        raise GenError(f"{where} 字段名不合法：{name!r}")
    reason = forbidden_event_field(name)
    if reason:
        raise GenError(f"{where} 字段名 {name} {reason}（events.yaml：事件字段不带推广 URL、口令、推广位或渠道标识）")
    if not isinstance(spec, dict):
        raise GenError(f"{where}.{name} 应为对象")
    kind = spec.get("type")
    if kind not in EVENT_FIELD_TYPES:
        raise GenError(f"{where}.{name} 的 type 不认识：{kind!r}")
    values = None
    if kind == "enum":
        values = spec.get("values")
        if not isinstance(values, list) or not values or not all(isinstance(v, str) for v in values):
            raise GenError(f"{where}.{name} 是 enum，values 应为非空字符串列表")
        if len(set(values)) != len(values):
            raise GenError(f"{where}.{name} 的 values 有重复")
    elif "values" in spec:
        raise GenError(f"{where}.{name} 不是 enum，不应有 values")
    required = spec.get("required", False)
    when = spec.get("required_when")
    if not isinstance(required, bool):
        raise GenError(f"{where}.{name} 的 required 应为布尔")
    if when is not None:
        if required:
            raise GenError(f"{where}.{name} 不能同时 required 与 required_when")
        if not isinstance(when, dict) or len(when) != 1:
            raise GenError(f"{where}.{name} 的 required_when 应为只有一项的 {{字段: 取值}}")
        (when_field, when_value), = when.items()
        if not isinstance(when_value, str):
            raise GenError(f"{where}.{name} 的 required_when 取值应为字符串")
        when = (when_field, when_value)
    return {"name": name, "type": kind, "values": values, "required": required, "when": when}


def swift_track_value(kind: str, expr: str) -> str:
    if kind == "enum":
        return f".string({expr}.rawValue)"
    if kind == "string":
        return f".string({expr})"
    if kind == "integer":
        return f".integer({expr})"
    return f".boolean({expr})"


def swift_track_literal(kind: str, raw: str, where: str) -> str:
    if kind in ("enum", "string"):
        return f".string({swift_string(raw)})"
    if kind == "integer":
        try:
            return f".integer({int(raw)})"
        except ValueError as exc:
            raise GenError(f"{where} 的条件取值不是整数：{raw!r}") from exc
    if raw not in ("true", "false"):
        raise GenError(f"{where} 的条件取值不是布尔：{raw!r}")
    return f".boolean({raw})"


def gen_events(out: dict[str, str]):
    doc = load("specs/events.json")
    common = doc.get("common_fields")
    events = doc.get("events")
    if not isinstance(common, dict) or not common:
        raise GenError("events.yaml 缺 common_fields")
    if not isinstance(events, dict):
        raise GenError("events.yaml 缺 events")
    common_specs = [event_field_spec(k, v, "events.yaml common_fields") for k, v in common.items()]
    common_names = [c["name"] for c in common_specs]
    for name in ("event_id", "name", "client_at", "session_id", "device_id", "platform", "app_version", "page"):
        if name not in common_names:
            raise GenError(f"events.yaml common_fields 缺 {name}")
    platform = next(c for c in common_specs if c["name"] == "platform")
    lines = [
        HEADER.rstrip("\n"),
        "// 快照：specs/events.yaml（03 §4.7；TECH-21：业务代码只能调用这里的生成函数）",
        "",
        "/// 埋点字段的值（JSON 标量）。",
        "public enum TrackValue: Swift.Sendable, Swift.Equatable {",
        "    case string(Swift.String)",
        "    case integer(Swift.Int)",
        "    case boolean(Swift.Bool)",
        "}",
        "",
        "/// 一条埋点事件：只能由 `TrackerEvents` 的生成函数构造（初始化方法不公开）。公共字段里 page、spm、trace_id",
        "/// 由调用方给出，其余（event_id、client_at、session_id、device_id、user_id、platform、app_version、channel）由 Tracker 填。",
        "public struct TrackEvent: Swift.Sendable, Swift.Equatable {",
        "    public let name: Swift.String",
        "    public let page: Swift.String",
        "    public let spm: Swift.String?",
        "    public let traceId: Swift.String?",
        "    /// 事件自身的字段（不含公共字段）；没给的可选字段不出现。",
        "    public let fields: [Swift.String: TrackValue]",
        "    /// 按 required_when 应该给却没给的字段名；非空时 Tracker 拒收。",
        "    public let missingRequired: [Swift.String]",
        "",
        "    init(",
        "        name: Swift.String,",
        "        page: Swift.String,",
        "        spm: Swift.String?,",
        "        traceId: Swift.String?,",
        "        fields: [Swift.String: TrackValue],",
        "        missingRequired: [Swift.String]",
        "    ) {",
        "        self.name = name",
        "        self.page = page",
        "        self.spm = spm",
        "        self.traceId = traceId",
        "        self.fields = fields",
        "        self.missingRequired = missingRequired",
        "    }",
        "}",
        "",
        "/// events.yaml 的事件构造函数。",
        "public enum TrackerEvents {",
        f"    /// events.yaml 的 version。",
        f"    public static let version = {swift_string(str(doc.get('version', '')))}",
        "    /// 公共字段名（契约顺序）。",
        "    public static let commonFields: [Swift.String] = [" + ", ".join(swift_string(n) for n in common_names) + "]",
        "    /// 必填的公共字段名。",
        "    public static let requiredCommonFields: [Swift.String] = ["
        + ", ".join(swift_string(c["name"]) for c in common_specs if c["required"]) + "]",
        "    /// platform 公共字段的取值。",
        "    public static let platformValues: [Swift.String] = ["
        + ", ".join(swift_string(v) for v in (platform["values"] or [])) + "]",
        "    /// 全部事件名。",
        "    public static let allNames: [Swift.String] = [" + ", ".join(swift_string(n) for n in events) + "]",
    ]
    seen_funcs: dict[str, str] = {}
    for event_name, event in events.items():
        where = f"events.yaml events.{event_name}"
        if not isinstance(event_name, str) or not EVENT_NAME_RE.fullmatch(event_name):
            raise GenError(f"{where}：事件名不合法")
        if not isinstance(event, dict):
            raise GenError(f"{where} 应为对象")
        fields = event.get("fields") or {}
        if not isinstance(fields, dict):
            raise GenError(f"{where}.fields 应为对象")
        specs = [event_field_spec(k, v, where + ".fields") for k, v in fields.items()]
        by_name = {s["name"]: s for s in specs}
        for s in specs:
            if s["name"] in common_names:
                raise GenError(f"{where} 字段 {s['name']} 与公共字段同名")
            if s["when"] and s["when"][0] not in by_name:
                raise GenError(f"{where}.{s['name']} 的 required_when 引用了不存在的字段 {s['when'][0]}")
        func = lower_camel(event_name)
        type_name = upper_camel(event_name)
        if func.lower() in seen_funcs:
            raise GenError(f"{where} 的生成名 {func} 与 {seen_funcs[func.lower()]} 冲突")
        seen_funcs[func.lower()] = event_name
        enum_fields = [s for s in specs if s["type"] == "enum"]
        lines.append("")
        if enum_fields:
            lines.append(f"    /// {event_name} 的枚举字段取值。")
            lines.append(f"    public enum {type_name} {{")
            for s in enum_fields:
                lines.append(f"        public enum {upper_camel(s['name'])}Value: Swift.String, Swift.Sendable, Swift.CaseIterable {{")
                cases = set()
                for raw in s["values"]:
                    case = lower_camel(raw)
                    if case in RESERVED_CASE_NAMES:
                        case = "contract" + upper_camel(raw)
                    if case in cases:
                        raise GenError(f"{where}.{s['name']} 的取值 {raw} 生成的 case 名 {case} 重复")
                    cases.add(case)
                    lines.append(f"            case {escape_identifier(case)} = {swift_string(raw)}")
                lines.append("        }")
            lines.append("    }")
            lines.append("")
        description = str(event.get("description", "")).replace("\n", " ")
        lines.append(f"    /// {event_name}：{description}")
        params = ["page: Swift.String"]
        for s in specs:
            pname = escape_identifier(lower_camel(s["name"]))
            swift_type = {
                "string": "Swift.String", "integer": "Swift.Int", "boolean": "Swift.Bool",
                "enum": f"{type_name}.{upper_camel(s['name'])}Value",
            }[s["type"]]
            params.append(f"{pname}: {swift_type}" if s["required"] else f"{pname}: {swift_type}? = nil")
        params += ["spm: Swift.String? = nil", "traceId: Swift.String? = nil"]
        lines.append(f"    public static func {escape_identifier(func)}(")
        lines += [f"        {p}," for p in params[:-1]] + [f"        {params[-1]}"]
        lines.append("    ) -> TrackEvent {")
        if specs:
            lines.append("        var fields: [Swift.String: TrackValue] = [:]")
            for s in specs:
                pname = escape_identifier(lower_camel(s["name"]))
                if s["required"]:
                    lines.append(f"        fields[{swift_string(s['name'])}] = {swift_track_value(s['type'], pname)}")
                else:
                    bound = lower_camel(s["name"]) + "Value"
                    lines.append(f"        if let {bound} = {pname} {{")
                    lines.append(f"            fields[{swift_string(s['name'])}] = {swift_track_value(s['type'], bound)}")
                    lines.append("        }")
        else:
            lines.append("        let fields: [Swift.String: TrackValue] = [:]")
        conditional = [s for s in specs if s["when"]]
        if conditional:
            lines.append("        var missing: [Swift.String] = []")
            for s in conditional:
                when_field, when_value = s["when"]
                literal = swift_track_literal(by_name[when_field]["type"], when_value, where + "." + s["name"])
                lines.append(
                    f"        if fields[{swift_string(when_field)}] == {literal}, fields[{swift_string(s['name'])}] == nil {{"
                )
                lines.append(f"            missing.append({swift_string(s['name'])})")
                lines.append("        }")
        else:
            lines.append("        let missing: [Swift.String] = []")
        lines += [
            "        return TrackEvent(",
            f"            name: {swift_string(event_name)}, page: page, spm: spm, traceId: traceId, fields: fields,",
            "            missingRequired: missing",
            "        )",
            "    }",
        ]
    lines += ["}", ""]
    put(out, "TrackerEvents.swift", "\n".join(lines))


HEX64_RE = re.compile(r"[0-9a-f]{64}")


def gen_device_hash_seeds(out: dict[str, str]):
    doc = load("specs/device-hash.vectors.json")
    seeds = doc.get("invalid_hash_seeds")
    if not isinstance(seeds, list) or not seeds:
        raise GenError("device-hash.vectors.json 缺 invalid_hash_seeds")
    hashes = []
    for i, row in enumerate(seeds):
        value = row.get("device_hash") if isinstance(row, dict) else None
        if not isinstance(value, str) or not HEX64_RE.fullmatch(value):
            raise GenError(f"device-hash.vectors.json invalid_hash_seeds[{i}].device_hash 应为 64 位小写十六进制")
        hashes.append(value)
    lines = [
        HEADER.rstrip("\n"),
        "// 快照：specs/device-hash.vectors.json 的 invalid_hash_seeds（BR-ID-09 细则「设备标识的无效值」）",
        "",
        "/// 无效设备哈希的种子（config device.invalid_hashes 的初值）：客户端求哈希后命中即视为取不到，不注册、不上报。",
        "public enum DeviceHashSeeds {",
        "    public static let invalidHashes: Swift.Set<Swift.String> = [",
    ]
    lines += [f"        {swift_string(h)}," for h in sorted(set(hashes))]
    lines += ["    ]", "}", ""]
    put(out, "DeviceHashSeeds.swift", "\n".join(lines))


# 包内默认配置里去掉的地址类字段：示例里是 example.test 占位地址，不能进包（Release 不含非 prod 地址）。
DEFAULT_CONFIG_DROPPED_KEYS = ["h5_base_url", "share_domains", "kf"]


def gen_default_config(out: dict[str, str]):
    doc = load("contracts/openapi.json")
    try:
        example = doc["paths"]["/v1/config"]["get"]["responses"]["200"]["content"]["application/json"]["example"]
    except (KeyError, TypeError) as exc:
        raise GenError(f"openapi 里找不到 GET /v1/config 的 200 响应示例：{exc}") from exc
    data = example.get("data") if isinstance(example, dict) else None
    if not isinstance(data, dict):
        raise GenError("GET /v1/config 的响应示例没有 data 对象")
    data = json.loads(json.dumps(data))
    for key in DEFAULT_CONFIG_DROPPED_KEYS:
        data.pop(key, None)
    patterns = data.get("link_patterns")
    if isinstance(patterns, dict):
        patterns["rules"] = []
    text = json.dumps(data, ensure_ascii=False, sort_keys=True, separators=(",", ":"))
    if re.search(r"https?://|example\.test", text):
        raise GenError("包内默认配置里仍有地址：" + text)
    lines = [
        HEADER.rstrip("\n"),
        "// 快照：contracts/openapi.yaml GET /v1/config 200 响应示例的 data（03 §4.3 包内 default_config.json）。",
        "// 去掉了地址类字段（" + "、".join(DEFAULT_CONFIG_DROPPED_KEYS) + "）并清空 link_patterns.rules：示例里是",
        "// example.test 占位地址，不能进包。",
        "// TODO(N-21): 发布构建时改为从生产配置当时的值生成（03 §4.3：features.search_status 等取生产值）。",
        "",
        "/// 包内默认配置（`ConfigStore` 没有当前配置与 LKG 时的最后一层）。",
        "public enum DefaultConfig {",
        f"    public static let json: Swift.String = {swift_string(text)}",
        "}",
        "",
    ]
    put(out, "DefaultConfig.swift", "\n".join(lines))


# ---------- 主流程 ----------


def generate() -> dict[str, str]:
    out: dict[str, str] = {}
    groups = collect_enums()
    gen_enums(out, groups)
    route_entry = next((cases for _, g in groups for key, _, cases in g if key == "route_entry"), None)
    if route_entry is None:
        raise GenError("快照缺少枚举 route_entry（路由表需要）")
    gen_error_codes(out)
    gen_routes(out, route_entry)
    gen_bridge(out)
    gen_texts(out)
    gen_tokens(out)
    gen_app_stores(out)
    gen_update_check_example(out)
    gen_api_operations(out)
    gen_events(out)
    gen_device_hash_seeds(out)
    gen_default_config(out)
    return out


def split_roots(files: dict[str, str]) -> dict[str, dict[str, str]]:
    """按输出根拆分：{输出目录: {相对路径: 内容}}。"""
    result: dict[str, dict[str, str]] = {directory: {} for directory in OUTPUT_ROOTS.values()}
    for rel, content in files.items():
        prefix = APP_PREFIX if rel.startswith(APP_PREFIX) else ""
        result[OUTPUT_ROOTS[prefix]][rel[len(prefix):]] = content
    return result


def write_tree(files: dict[str, str], directory: str):
    for rel, content in files.items():
        path = os.path.join(directory, rel)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w", encoding="utf-8", newline="\n") as f:
            f.write(content)


def list_tree(directory: str) -> set[str]:
    result = set()
    if not os.path.isdir(directory):
        return result
    for dirpath, _, names in os.walk(directory):
        for name in names:
            if name == ".DS_Store":
                continue
            result.add(os.path.relpath(os.path.join(dirpath, name), directory).replace(os.sep, "/"))
    return result


def check(files: dict[str, str]) -> list[str]:
    """返回漂移的文件（相对仓库根）。"""
    drift = []
    for directory, tree in split_roots(files).items():
        with tempfile.TemporaryDirectory() as tmp:
            write_tree(tree, tmp)
            expected = list_tree(tmp)
            actual = list_tree(directory)
            changed = expected ^ actual
            for rel in expected & actual:
                if not filecmp.cmp(os.path.join(tmp, rel), os.path.join(directory, rel), shallow=False):
                    changed.add(rel)
        drift += [os.path.relpath(os.path.join(directory, rel), ROOT) for rel in changed]
    return sorted(drift)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--check", action="store_true", help="只检查生成物是否与快照一致")
    args = parser.parse_args()
    try:
        files = generate()
    except GenError as exc:
        print(f"gen.py: {exc}", file=sys.stderr)
        return 2

    if args.check:
        drift = check(files)
        if drift:
            print("gen.py --check: 生成物与快照不一致，请运行 python3 tools/codegen/gen.py：", file=sys.stderr)
            for rel in drift:
                print(f"  {rel}", file=sys.stderr)
            return 1
        print(f"gen.py --check: 一致（{len(files)} 个文件）")
        return 0

    for directory, tree in split_roots(files).items():
        if os.path.isdir(directory):
            shutil.rmtree(directory)
        write_tree(tree, directory)
        print(f"gen.py: 已生成 {len(tree)} 个文件到 {os.path.relpath(directory, ROOT)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
