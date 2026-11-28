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
    /// TODO(FU-IOS-TB-WEBCODE-A 实现)：返回关联值里的 state。
    public var state: String {
        ""
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

    /// 解析一条回跳地址（会话 completion 的 `URL.absoluteString`，或 onOpenURL 收到的地址）。
    /// TODO(FU-IOS-TB-WEBCODE-A 实现)：按上面的规则逐条判定。
    public static func parse(_: String) -> WebCodeCallback? {
        nil
    }
}
