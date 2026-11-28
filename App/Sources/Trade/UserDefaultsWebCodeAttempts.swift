import Config
import Foundation
import Trade

/// 本机尝试记录的 UserDefaults 实现（同安卓甲 `SharedPreferencesWebCodeAttempts`；设计稿 §3.1、§8）：只写 sha256(state)（小写十六进制）
/// 与发起时间（毫秒）；不写 state 原文、不写 code。只存 1 条，新的覆盖旧的。键在本 App 命名空间下（`AppNamespace.userDefaultsPrefix`），
/// 切换环境时由 `UserDefaultsNamespaceCleaner` 一并清除。登出 / 换号时不清（备用路径，暂不做，D10-3709 ④）：记录只在下次发起时被覆盖。
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

    /// 先删旧记录，再写 `webCodeStateSha256(state)` 与 `nowMillis`（`state` 原文不落盘）。
    func record(state: String, nowMillis: Int64) {
        clear()
        defaults.set(webCodeStateSha256(state), forKey: Self.stateSha256Key)
        defaults.set(NSNumber(value: nowMillis), forKey: Self.startedAtKey)
    }

    /// 两个键都在、哈希是 64 位小写十六进制字符串、时间是数值才返回记录，否则 nil。
    func current() -> WebCodeAttempt? {
        guard let hash = defaults.object(forKey: Self.stateSha256Key) as? String, Self.isWellFormedHash(hash),
              let started = defaults.object(forKey: Self.startedAtKey) as? NSNumber
        else { return nil }
        return WebCodeAttempt(stateSha256: hash, startedAtMillis: started.int64Value)
    }

    /// 删两个键。
    func clear() {
        defaults.removeObject(forKey: Self.stateSha256Key)
        defaults.removeObject(forKey: Self.startedAtKey)
    }

    /// 当前记录的哈希等于 `stateSha256` 时才删（两次尝试并存时，先结束的那次不删后一次的记录）。
    func clearIfCurrent(stateSha256: String) {
        guard current()?.stateSha256 == stateSha256 else { return }
        clear()
    }

    private static func isWellFormedHash(_ text: String) -> Bool {
        text.utf8.count == 64 && text.utf8.allSatisfy { (0x30...0x39).contains($0) || (0x61...0x66).contains($0) }
    }
}
