import Foundation

/// 淘宝 web_code 授权回跳（FU-IOS-TB-WEBCODE-A；D10-2717 定值：`couli://auth/taobao?code=<c>&state=<s>`，出错时
/// `couli://auth/taobao?state=<s>&error=1`，一律按授权未完成）。只在内存里流转，不保存、不进日志；`description` /
/// `debugDescription` / `customMirror` 不带 code、state 原文。
public enum WebCodeCallback: Sendable, Equatable {
    /// 授权完成：带回授权码。
    case code(code: String, state: String)
    /// 中转页回跳了 error=1：授权未完成（按授权失败处理）。
    case incomplete(state: String)

    /// 回跳带的 state（收件箱、授权器按它的 sha256 认领）。
    public var state: String {
        switch self {
        case let .code(_, state), let .incomplete(state):
            state
        }
    }
}

extension WebCodeCallback: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    /// 只有类型名，不带原文。
    public var description: String {
        "WebCodeCallback"
    }

    public var debugDescription: String {
        "WebCodeCallback"
    }

    /// 不给子项（`dump` / 反射看不到 code、state）。
    public var customMirror: Mirror {
        Mirror(self, children: [:])
    }
}

/// 回跳的接收方（生产为进程内的 `WebCodeInbox`；iOS 乙的 onOpenURL 分流器当场交给它）。
@MainActor
public protocol WebCodeCallbackSink: AnyObject {
    func deliver(_ callback: WebCodeCallback)
}

/// 回跳解析（纯 Swift，不用 URLComponents 的宽松解码；规则同安卓甲 `WebCodeCallbackParser`，D10-2717 定值）：非法输入一律为 nil。
/// - 前缀必须逐字是 `couli://auth/taobao?`（scheme、host、path 精确匹配，因此不会有端口、userinfo、多余的 path 段）；不得有
///   fragment；整串 ≤ `maxLength`。
/// - 查询串按 `&` 分段、`=` 分键值；任一键出现两次、百分号编码非法：整串作废。只认 code、state、error，其他键忽略。
/// - 取值（解码后）只认 `[A-Za-z0-9_-]`；state 1...`stateMaxLength`、code 1...`codeMaxLength`（契约 BindUnionByWebCode）。
/// - 带 error：只有 `error=1` → `.incomplete`，其他取值为 nil；带 error 时一律不当成 `.code`。
/// - 没有 error：code 合法 → `.code`，否则 nil。
/// 「state 与本机记录不符」「同一 state 第二次回跳」不归这里判（见 `WebCodeInbox` 与授权器）。
public enum WebCodeCallbackParser {
    public static let scheme = "couli"
    public static let host = "auth"
    public static let path = "/taobao"
    /// 逐字前缀 `couli://auth/taobao?`。
    public static let prefix = "\(scheme)://\(host)\(path)?"
    public static let maxLength = 8192
    public static let stateMaxLength = 128
    public static let codeMaxLength = 4096

    private static let codeKey = "code"
    private static let stateKey = "state"
    private static let errorKey = "error"
    /// error 的唯一定值（D10-2717）。
    private static let errorIncomplete = "1"

    /// 解析一条回跳地址（会话 completion 的 `URL.absoluteString`，或 onOpenURL 收到的地址）。
    /// 长度按 UTF-16 计（与安卓 `String.length` 同口径）；前缀、分段按 UTF-8 字节比（不受字符合并、规范等价影响）。
    public static func parse(_ raw: String) -> WebCodeCallback? {
        let bytes = Array(raw.utf8)
        let head = Array(prefix.utf8)
        guard raw.utf16.count <= maxLength, bytes.starts(with: head), !bytes.contains(ascii("#")),
              let fields = queryFields(bytes[head.count...]),
              let state = fields[stateKey], (1...stateMaxLength).contains(state.utf16.count)
        else { return nil }
        if let error = fields[errorKey] {
            return error == errorIncomplete ? .incomplete(state: state) : nil
        }
        guard let code = fields[codeKey], (1...codeMaxLength).contains(code.utf16.count) else { return nil }
        return .code(code: code, state: state)
    }

    /// 查询串 → 键值（只留 code / state / error）。空段跳过；任一键（含不认的键）重复、编码非法、认的键取值不在白名单：nil。
    private static func queryFields(_ query: ArraySlice<UInt8>) -> [String: String]? {
        var seen: Set<String> = []
        var kept: [String: String] = [:]
        for segment in query.split(separator: ascii("&"), omittingEmptySubsequences: true) {
            let equals = segment.firstIndex(of: ascii("="))
            guard let key = percentDecoded(segment[segment.startIndex..<(equals ?? segment.endIndex)]),
                  let value = percentDecoded(equals.map { segment[segment.index(after: $0)...] } ?? []),
                  seen.insert(key).inserted
            else { return nil }
            if key == codeKey || key == stateKey || key == errorKey {
                guard value.utf8.allSatisfy(isAllowedValueByte) else { return nil }
                kept[key] = value
            }
        }
        return kept
    }

    /// 百分号解码（`+` 原样，不当空格）；`%` 后不足两位、不是十六进制、解出的字节不是合法 UTF-8：nil。
    private static func percentDecoded(_ text: ArraySlice<UInt8>) -> String? {
        var decoded: [UInt8] = []
        decoded.reserveCapacity(text.count)
        var index = text.startIndex
        while index < text.endIndex {
            let byte = text[index]
            guard byte == ascii("%") else {
                decoded.append(byte)
                index += 1
                continue
            }
            guard index + 2 < text.endIndex, let high = hexValue(text[index + 1]), let low = hexValue(text[index + 2])
            else { return nil }
            decoded.append(high << 4 | low)
            index += 3
        }
        return strictUtf8(decoded)
    }

    /// 严格 UTF-8 解码：遇到非法或残缺序列返回 nil（不替换成 U+FFFD）。
    private static func strictUtf8(_ bytes: [UInt8]) -> String? {
        var scalars = String.UnicodeScalarView()
        var iterator = bytes.makeIterator()
        var decoder = UTF8()
        while true {
            switch decoder.decode(&iterator) {
            case let .scalarValue(scalar):
                scalars.append(scalar)
            case .emptyInput:
                return String(scalars)
            case .error:
                return nil
            }
        }
    }

    private static func hexValue(_ byte: UInt8) -> UInt8? {
        switch byte {
        case ascii("0")...ascii("9"): byte - ascii("0")
        case ascii("a")...ascii("f"): byte - ascii("a") + 10
        case ascii("A")...ascii("F"): byte - ascii("A") + 10
        default: nil
        }
    }

    /// 取值白名单 `[A-Za-z0-9_-]`（与中转页同一白名单）。
    private static func isAllowedValueByte(_ byte: UInt8) -> Bool {
        switch byte {
        case ascii("A")...ascii("Z"), ascii("a")...ascii("z"), ascii("0")...ascii("9"), ascii("_"), ascii("-"): true
        default: false
        }
    }

    private static func ascii(_ character: Unicode.Scalar) -> UInt8 {
        UInt8(ascii: character)
    }
}
