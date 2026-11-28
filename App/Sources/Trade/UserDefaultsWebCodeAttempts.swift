import Config
import Foundation
import Trade

/// 本机尝试记录的 UserDefaults 实现（同安卓甲 `SharedPreferencesWebCodeAttempts`；设计稿 §3.1、§8）：只写 sha256(state)（小写十六进制）
/// 与发起时间（毫秒）；不写 state 原文、不写 code。只存 1 条，新的覆盖旧的。键在本 App 命名空间下（`AppNamespace.userDefaultsPrefix`），
/// 切换环境时由 `UserDefaultsNamespaceCleaner` 一并清除。登出 / 换号时的清理由 iOS 乙接到 AppTrade 的会话变化订阅上。
@MainActor
final class UserDefaultsWebCodeAttempts: WebCodeAttemptStore {
    /// sha256(state) 的键（值是 64 位小写十六进制字符串）。
    static let stateSha256Key = AppNamespace.userDefaultsPrefix + "trade.webcode_attempt.state_sha256"
    /// 发起时间的键（值是毫秒 Int64）。
    static let startedAtKey = AppNamespace.userDefaultsPrefix + "trade.webcode_attempt.started_at"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// TODO(FU-IOS-TB-WEBCODE-A 实现)：先删旧记录，再写 `webCodeStateSha256(state)` 与 `nowMillis`。
    func record(state _: String, nowMillis _: Int64) {}

    /// TODO(FU-IOS-TB-WEBCODE-A 实现)：两个键都在、哈希是 64 位小写十六进制才返回记录，否则 nil。
    func current() -> WebCodeAttempt? {
        nil
    }

    /// TODO(FU-IOS-TB-WEBCODE-A 实现)：删两个键。
    func clear() {}

    /// TODO(FU-IOS-TB-WEBCODE-A 实现)：`current()?.stateSha256 == stateSha256` 时才 `clear()`。
    func clearIfCurrent(stateSha256 _: String) {}
}
