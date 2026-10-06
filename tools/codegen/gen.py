#!/usr/bin/env python3
"""契约快照 → Swift 生成物。

只读 contracts/snapshot/，输出到 Packages/Generated/Sources/Generated/（整个目录归生成器所有）。
    python3 tools/codegen/gen.py          # 重新生成
    python3 tools/codegen/gen.py --check  # 在临时目录生成后逐字比较，不一致退出 1

本任务生成：枚举、错误码表、路由表、桥方法表与桥错误码、包内默认文案（资源）、设计令牌原始常量。
不生成：OpenAPI 客户端、事件（specs/events.yaml）、apps.json 片段（分别归 APP-03、APP-03、APP-04/06）。
输出不含时间戳，同一快照重复生成逐字一致。只用 Python 3 标准库。

输出目录（两个目录都整个归生成器所有，--check 一起比较）：
  Packages/Generated/Sources/Generated/   契约生成物包
  App/Sources/Generated/                  debug_only 路由表 DebugOnlyRoutes（#if DEBUG）。放在 App target 是因为
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
    "BridgeMethodSpec", "BridgeMethods", "BridgeErrors", "DefaultTexts", "DesignTokens", "DebugOnlyRoutes",
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
        return [
            f"{indent}RouteSpec(",
            f"{indent}    name: {swift_string(name)}, kind: .{kind}, auth: {swift_string(auth)},",
            f"{indent}    sinceIOS: {swift_optional_string(since_ios(row, ctx))},",
            f"{indent}    entries: [{', '.join(entry_names)}],",
            f"{indent}    h5Path: {swift_optional_string(row.get('h5_path'))}, debugOnly: {'true' if debug_only else 'false'}",
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
        "",
        "    public init(",
        "        name: Swift.String, kind: RouteKind, auth: Swift.String, sinceIOS: Swift.String?,",
        "        entries: [RouteEntry], h5Path: Swift.String?, debugOnly: Swift.Bool",
        "    ) {",
        "        self.name = name",
        "        self.kind = kind",
        "        self.auth = auth",
        "        self.sinceIOS = sinceIOS",
        "        self.entries = entries",
        "        self.h5Path = h5Path",
        "        self.debugOnly = debugOnly",
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
