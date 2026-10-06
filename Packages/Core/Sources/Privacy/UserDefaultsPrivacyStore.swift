import Config
import Foundation

/// 本机隐私决定存在 UserDefaults 本 App 命名空间里的**一条**记录（`AppNamespace.privacyRecordKey`，字典）。
/// 每次改写（单个字段的 setter，或 `commit*` 的组合改写）都是先读出整条记录、改好后对这一个键写一次：
/// 撤回同意的「基本模式 + 清除同意记录 + 待清理标记」因此是同一次持久化写入，中断不会只落一半（第 2 轮评审）。
/// 切换环境时这条记录保留（理由见 `AppNamespace.privacyDecisionKeys`）。
public final class UserDefaultsPrivacyStore: PrivacyStore {
    private enum Field {
        static let decision = "decision"
        static let consentedVersion = "consented_version"
        static let consentedAt = "consented_at_ms"
        static let basicMode = "basic_mode"
        static let cleanupPending = "withdrawal_cleanup_pending"
    }

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    private var record: [String: Any] {
        defaults.dictionary(forKey: AppNamespace.privacyRecordKey) ?? [:]
    }

    /// 读出整条记录、改写、对同一个键写一次。
    private func update(_ change: (inout [String: Any]) -> Void) {
        var next = record
        change(&next)
        defaults.set(next, forKey: AppNamespace.privacyRecordKey)
    }

    public var decisionRaw: String {
        get { record[Field.decision] as? String ?? PrivacyDecision.notDecided.rawValue }
        set { update { $0[Field.decision] = newValue } }
    }

    public var consentedVersion: String? {
        get { record[Field.consentedVersion] as? String }
        set { update { $0[Field.consentedVersion] = newValue } }
    }

    public var consentedAtMillis: Int64? {
        get { (record[Field.consentedAt] as? NSNumber)?.int64Value }
        set { update { $0[Field.consentedAt] = newValue.map { NSNumber(value: $0) } } }
    }

    public var basicMode: Bool {
        get { record[Field.basicMode] as? Bool ?? false }
        set { update { $0[Field.basicMode] = newValue } }
    }

    public var withdrawalCleanupPending: Bool {
        record[Field.cleanupPending] as? Bool ?? false
    }

    public func commitConsent(version: String, atMillis: Int64) {
        update {
            $0[Field.decision] = PrivacyDecision.consented.rawValue
            $0[Field.consentedVersion] = version
            $0[Field.consentedAt] = NSNumber(value: atMillis)
            $0[Field.basicMode] = false
        }
    }

    public func commitBasicMode() {
        update {
            $0[Field.decision] = PrivacyDecision.basicMode.rawValue
            $0[Field.basicMode] = true
        }
    }

    public func commitWithdrawal() {
        update {
            $0[Field.decision] = PrivacyDecision.basicMode.rawValue
            $0[Field.basicMode] = true
            $0[Field.consentedVersion] = nil
            $0[Field.consentedAt] = nil
            $0[Field.cleanupPending] = true
        }
    }

    public func clearWithdrawalPending() {
        update { $0[Field.cleanupPending] = nil }
    }
}

/// 内存存储（预览与单测用）。
public final class MemoryPrivacyStore: PrivacyStore {
    public var decisionRaw = PrivacyDecision.notDecided.rawValue
    public var consentedVersion: String?
    public var consentedAtMillis: Int64?
    public var basicMode = false
    public var withdrawalCleanupPending = false

    public init() {}

    public func commitWithdrawal() {
        consentedVersion = nil
        consentedAtMillis = nil
        decisionRaw = PrivacyDecision.basicMode.rawValue
        basicMode = true
        withdrawalCleanupPending = true
    }

    public func clearWithdrawalPending() {
        withdrawalCleanupPending = false
    }
}
