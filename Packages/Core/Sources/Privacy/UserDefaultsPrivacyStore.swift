import Config
import Foundation

/// 本机隐私决定存在 UserDefaults 本 App 命名空间里的**一条**记录（`AppNamespace.privacyRecordKey`，字典）。
/// 每次改写（单个字段的 setter，或 `commit*` 的组合改写）都是先读出整条记录、改好后对这一个键写一次：
/// 撤回同意的「基本模式 + 清除同意记录 + 待清理标记」因此是同一次持久化写入，中断不会只落一半（第 2 轮评审）。
/// 切换环境时这条记录保留（理由见 `AppNamespace.privacyDecisionKeys`）。
///
/// 撤回同意另有一个能确认落盘结果的持久标记（`WithdrawalMarker`，生产是原子写入并 fsync 的文件，R1-02、F-ALL-05）：
/// UserDefaults 的 set 只更新内存缓存、异步落盘且不报告失败，读回同一缓存证明不了已落盘。标记在期间，无论 UserDefaults
/// 里读到什么（包括进程重启后读回旧的 consented 记录），一律按基本模式、清除同意记录处理；标记写不进去时
/// `commitWithdrawalVerified` 返回 false，由调用方在内存里按基本模式并持续重试。标记只在重新同意时删除。
public final class UserDefaultsPrivacyStore: PrivacyStore {
    private enum Field {
        static let decision = "decision"
        static let consentedVersion = "consented_version"
        static let consentedAt = "consented_at_ms"
        static let basicMode = "basic_mode"
        static let cleanupPending = "withdrawal_cleanup_pending"
    }

    private let defaults: UserDefaults
    private let marker: any WithdrawalMarker

    /// marker 缺省按 defaults 取：`UserDefaults.standard` 用 App 的标记文件（`FileWithdrawalMarker.standard`）；
    /// 其他实例（单测的 suite）用挂在该实例上的内存标记，同一个 defaults 的各个存储实例共用。
    public init(defaults: UserDefaults = .standard, marker: (any WithdrawalMarker)? = nil) {
        self.defaults = defaults
        self.marker = marker ?? WithdrawalMarkers.marker(for: defaults)
    }

    private var record: [String: Any] {
        defaults.dictionary(forKey: AppNamespace.privacyRecordKey) ?? [:]
    }

    /// 撤回标记在：按已撤回处理（覆盖 UserDefaults 里的结论与同意记录）。
    private var withdrawn: Bool {
        marker.read() != nil
    }

    /// 读出整条记录、改写、对同一个键写一次。
    private func update(_ change: (inout [String: Any]) -> Void) {
        var next = record
        change(&next)
        defaults.set(next, forKey: AppNamespace.privacyRecordKey)
    }

    public var decisionRaw: String {
        get {
            withdrawn ? PrivacyDecision.basicMode.rawValue
                : record[Field.decision] as? String ?? PrivacyDecision.notDecided.rawValue
        }
        set {
            update { $0[Field.decision] = newValue }
            if newValue == PrivacyDecision.consented.rawValue {
                try? marker.remove()
            }
        }
    }

    public var consentedVersion: String? {
        get { withdrawn ? nil : record[Field.consentedVersion] as? String }
        set { update { $0[Field.consentedVersion] = newValue } }
    }

    public var consentedAtMillis: Int64? {
        get { withdrawn ? nil : (record[Field.consentedAt] as? NSNumber)?.int64Value }
        set { update { $0[Field.consentedAt] = newValue.map { NSNumber(value: $0) } } }
    }

    public var basicMode: Bool {
        get { withdrawn || record[Field.basicMode] as? Bool ?? false }
        set { update { $0[Field.basicMode] = newValue } }
    }

    public var withdrawalCleanupPending: Bool {
        record[Field.cleanupPending] as? Bool ?? false || marker.read()?.cleanupPending == true
    }

    /// 重新同意：写记录后删除撤回标记（删不掉时仍按基本模式，同意不生效，见 PrivacyGate.agree）。
    public func commitConsent(version: String, atMillis: Int64) {
        update {
            $0[Field.decision] = PrivacyDecision.consented.rawValue
            $0[Field.consentedVersion] = version
            $0[Field.consentedAt] = NSNumber(value: atMillis)
            $0[Field.basicMode] = false
        }
        try? marker.remove()
    }

    public func commitBasicMode() {
        update {
            $0[Field.decision] = PrivacyDecision.basicMode.rawValue
            $0[Field.basicMode] = true
        }
    }

    public func commitWithdrawal() {
        writeWithdrawalRecord()
        try? marker.write(WithdrawalMarkerState(cleanupPending: true))
    }

    /// 清理成功：记录与标记里都只删「待清理」（标记本身保留，表示已撤回）。标记写不进去时仍是待清理，下次启动再清。
    public func clearWithdrawalPending() {
        update { $0[Field.cleanupPending] = nil }
        if marker.read() != nil {
            try? marker.write(WithdrawalMarkerState(cleanupPending: false))
        }
    }

    /// 撤回同意的合并写入，以撤回标记的确认写入为准（标记写入失败、或读回不一致即视为没落盘）。
    public func commitWithdrawalVerified() -> Bool {
        writeWithdrawalRecord()
        let expected = WithdrawalMarkerState(cleanupPending: true)
        do {
            try marker.write(expected)
        } catch {
            return false
        }
        return marker.read() == expected
    }

    /// 调试预置（全新安装 / 已同意 / 基本模式）：连同撤回标记一起丢掉。
    public func discardWithdrawalMarker() {
        try? marker.remove()
    }

    private func writeWithdrawalRecord() {
        update {
            $0[Field.decision] = PrivacyDecision.basicMode.rawValue
            $0[Field.basicMode] = true
            $0[Field.consentedVersion] = nil
            $0[Field.consentedAt] = nil
            $0[Field.cleanupPending] = true
        }
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

    /// true 时撤回记录写不进去（模拟持久化失败）。
    public var failWithdrawalWrites = false

    public func commitWithdrawalVerified() -> Bool {
        guard !failWithdrawalWrites else {
            return false
        }
        commitWithdrawal()
        return true
    }
}
