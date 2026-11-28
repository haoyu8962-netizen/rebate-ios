import CryptoKit
import Foundation

/// 本机发起过的一次 web_code 尝试：只有 sha256(state)（小写十六进制）与发起时间（毫秒墙钟），没有 state 原文、没有 code。
public struct WebCodeAttempt: Sendable, Equatable {
    public let stateSha256: String
    public let startedAtMillis: Int64

    public init(stateSha256: String, startedAtMillis: Int64) {
        self.stateSha256 = stateSha256
        self.startedAtMillis = startedAtMillis
    }
}

/// 本机尝试记录（同安卓甲 `WebCodeAttemptStore`；设计稿 §3.1、§5.5 第 1 条）：只存 1 条，新的覆盖旧的；只落 sha256(state) 与时间。
/// 实现放 App（`UserDefaultsWebCodeAttempts`，键在 `AppNamespace.userDefaultsPrefix` 下，切换环境随命名空间清理）。
@MainActor
public protocol WebCodeAttemptStore: AnyObject {
    /// 记下一次尝试：存 sha256(`state`) 与 `nowMillis`，覆盖旧记录；`state` 原文不落盘。
    func record(state: String, nowMillis: Int64)
    /// 当前记录；没有、或存的内容不完整 / 不合格式 → nil。
    func current() -> WebCodeAttempt?
    /// 删除记录。
    func clear()
    /// 只在当前记录的哈希等于 `stateSha256` 时删除（两次尝试并存时，先结束的那次不删后一次的记录；scope-ios #29 前移到甲）。
    func clearIfCurrent(stateSha256: String)
}

/// sha256(`state`)：UTF-8 字节的小写十六进制，64 个字符（尝试记录、收件箱认领共用同一算法；与安卓 `webCodeStateSha256` 一致）。
/// 写法同 ClipboardRules.sha256（CryptoKit `SHA256`）。
public func webCodeStateSha256(_ state: String) -> String {
    SHA256.hash(data: Data(state.utf8)).map { String(format: "%02x", $0) }.joined()
}
