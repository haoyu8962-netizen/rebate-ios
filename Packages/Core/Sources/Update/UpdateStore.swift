import Config
import Foundation

/// UpdateGate 落盘的东西（字段与格式不是业务契约，rule-gaps G12）。
public struct UpdateRecord: Sendable, Equatable, Codable {
    /// 最近一次成功检查的结果。
    public var lastResult: UpdateCheckResult?
    /// 最近一次成功检查的时刻（毫秒）；回前台复查的间隔从这里算，失败与请求发起不重置。
    public var lastSuccessAt: Int64?
    /// 「暂不更新」记下的 latest_version（03 §4.1）。
    public var dismissedLatest: String?
    /// 接口层 10405 带来的最低支持版本（下一次成功检查覆盖）。
    public var forcedMinimum: String?

    public init(
        lastResult: UpdateCheckResult? = nil,
        lastSuccessAt: Int64? = nil,
        dismissedLatest: String? = nil,
        forcedMinimum: String? = nil
    ) {
        self.lastResult = lastResult
        self.lastSuccessAt = lastSuccessAt
        self.dismissedLatest = dismissedLatest
        self.forcedMinimum = forcedMinimum
    }
}

/// UpdateGate 的持久化。
public protocol UpdateStore: AnyObject {
    func load() -> UpdateRecord
    func save(_ record: UpdateRecord)
}

/// 内存实现（测试与预览）；同一实例可供重建后的 Gate 复用（模拟冷启动）。
public final class MemoryUpdateStore: UpdateStore {
    public private(set) var record: UpdateRecord

    public init(record: UpdateRecord = UpdateRecord()) {
        self.record = record
    }

    public func load() -> UpdateRecord {
        record
    }

    public func save(_ record: UpdateRecord) {
        self.record = record
    }
}

/// UserDefaults 实现：整条记录 JSON 编码后写在本 App 命名空间的一个键里（默认 `AppNamespace.updateRecordKey`；
/// Debug / Staging 的调试假结果用 App 侧另一把键，不写进 Release 读取的这一把）。
/// 切换环境时随命名空间一起清掉（新环境的版本配置不同，重新检查）；「清除缓存」不清（03 §4.3）。
/// 读不出或解码失败按空记录（强更未知），不当作「不低于」。
public final class UserDefaultsUpdateStore: UpdateStore {
    private let defaults: UserDefaults
    public let key: String

    public init(defaults: UserDefaults = .standard, key: String = AppNamespace.updateRecordKey) {
        self.defaults = defaults
        self.key = key
    }

    public func load() -> UpdateRecord {
        guard let data = defaults.data(forKey: key),
              let record = try? JSONDecoder().decode(UpdateRecord.self, from: data)
        else {
            return UpdateRecord()
        }
        return record
    }

    public func save(_ record: UpdateRecord) {
        // 编码失败不写（保留上一次的记录）；UpdateRecord 只含字符串与整数，实际不会失败。
        guard let data = try? JSONEncoder().encode(record) else { return }
        defaults.set(data, forKey: key)
    }
}
