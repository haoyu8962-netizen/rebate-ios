import Config
import Foundation

/// pending_action 的持久化后端：只存 1 条原始记录。
public protocol PendingActionBackend: AnyObject {
    func read() -> String?
    func write(_ record: String)
    func delete()
}

/// 内存后端（单测与预览用）。
public final class MemoryPendingBackend: PendingActionBackend {
    private var record: String?

    public init() {}

    public func read() -> String? {
        record
    }

    public func write(_ record: String) {
        self.record = record
    }

    public func delete() {
        record = nil
    }
}

/// UserDefaults 后端。键在本 App 命名空间下（`AppNamespace.userDefaultsPrefix`），
/// 切换环境时由 `UserDefaultsNamespaceCleaner` 一并清除（03 §3.6「切换环境」）。
public final class UserDefaultsPendingBackend: PendingActionBackend {
    public static let key = AppNamespace.userDefaultsPrefix + "router.pending_action"

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func read() -> String? {
        defaults.string(forKey: Self.key)
    }

    public func write(_ record: String) {
        defaults.set(record, forKey: Self.key)
    }

    public func delete() {
        defaults.removeObject(forKey: Self.key)
    }
}

/// 一条待恢复的动作。
public struct PendingAction: Sendable, Equatable {
    public let action: String
    public let paramValues: [String: JSONValue]
    /// 计时起点（毫秒）：保存时刻，或最近一次完成前置步骤的时刻。
    public let timerStartedAt: Int64
    /// 登记时请求的原始来源（`RouteSource` 原始值，如 agent_card）；旧记录或未给出时为 nil。
    public let origin: String?

    public init(action: String, paramValues: [String: JSONValue], timerStartedAt: Int64, origin: String? = nil) {
        self.action = action
        self.paramValues = paramValues
        self.timerStartedAt = timerStartedAt
        self.origin = origin
    }

    public var params: [String: Any] {
        paramValues.mapValues(\.anyValue)
    }
}

/// pending_action 存取与计时（BR-ID-10 正文与细则，03 §4.4）。
/// - 10 分钟有效：距计时起点超过 600 秒即删除，正好 600 秒仍保留；读取不重置计时。
/// - 每完成一个前置步骤（`markStepDone`）把计时起点重置为当前时刻；已超时的不能续活。
/// - 只存 1 条，新的覆盖旧的。
/// - params 不得含令牌、验证码等敏感值：检测到敏感键（含嵌套）拒绝保存，返回 false。
/// - 退出登录、切换账号时调用方调 `clear()`。
public final class PendingActionStore {
    public static let ttlMillis: Int64 = 600_000

    /// 敏感键（小写比较）；另外凡以 `_token` 结尾的键都按令牌处理。
    /// TODO(N-14): 敏感字段的完整别名表规划未定（rule-gaps G14）。
    public static let sensitiveKeys: Set<String> = [
        "token", "access_token", "refresh_token", "step_up_token", "h5_token", "id_token",
        "install_secret", "verification_code", "sms_code", "otp", "password", "captcha",
    ]

    private let backend: any PendingActionBackend
    private let clock: () -> Int64

    public init(backend: any PendingActionBackend, clock: @escaping () -> Int64 = PendingActionStore.wallClockMillis) {
        self.backend = backend
        self.clock = clock
    }

    public static func wallClockMillis() -> Int64 {
        Int64((Date().timeIntervalSince1970 * 1000).rounded(.down))
    }

    /// 当前时刻（注入的时钟）。
    public var now: Int64 {
        clock()
    }

    @discardableResult
    public func save(action: String, params: [String: Any], now: Int64) -> Bool {
        guard let values = JSONValue.object(from: params) else {
            return false
        }
        return save(action: action, values: values, now: now)
    }

    /// 保存（覆盖唯一的一条）。含敏感键或写不出记录时返回 false，已有记录不动。
    /// TODO(N-14): 拒绝保存时是否保留既有记录规划未定（rule-gaps G14），这里不动既有记录。
    @discardableResult
    public func save(action: String, values: [String: JSONValue], now: Int64, origin: String? = nil) -> Bool {
        guard !action.isEmpty, !Self.containsSensitiveKey(.object(values)) else {
            return false
        }
        let record = Record(action: action, params: values, timerStartedAt: now, origin: origin)
        guard let text = record.encoded() else {
            return false
        }
        backend.write(text)
        return true
    }

    /// 读取；已超时或记录损坏时删除并返回 nil。读取不重置计时。
    public func load(now: Int64) -> PendingAction? {
        guard let record = validRecord(now: now) else {
            return nil
        }
        return PendingAction(
            action: record.action,
            paramValues: record.params,
            timerStartedAt: record.timerStartedAt,
            origin: record.origin
        )
    }

    /// 完成了一个前置步骤：未超时的记录把计时起点重置为 now；已超时的删除。
    public func markStepDone(now: Int64) {
        guard let record = validRecord(now: now),
              let text = Record(
                  action: record.action,
                  params: record.params,
                  timerStartedAt: now,
                  origin: record.origin
              ).encoded()
        else {
            return
        }
        backend.write(text)
    }

    public func clear() {
        backend.delete()
    }

    public static func containsSensitiveKey(_ value: JSONValue) -> Bool {
        switch value {
        case let .object(object):
            for (key, nested) in object {
                let lower = key.lowercased()
                if sensitiveKeys.contains(lower) || lower.hasSuffix("_token") || containsSensitiveKey(nested) {
                    return true
                }
            }
            return false
        case let .array(items):
            return items.contains(where: containsSensitiveKey)
        default:
            return false
        }
    }

    private func validRecord(now: Int64) -> Record? {
        guard let text = backend.read() else {
            return nil
        }
        guard let record = Record(decoding: text) else {
            backend.delete()
            return nil
        }
        // TODO(N-14): 时间回拨（now 早于计时起点）规划未定（rule-gaps G14），这里不视为超时。
        if now - record.timerStartedAt > Self.ttlMillis {
            backend.delete()
            return nil
        }
        return record
    }

    /// 存储格式：`{"v":1,"action":…,"params":{…},"timer_started_at":毫秒[,"origin":来源]}`。
    private struct Record {
        let action: String
        let params: [String: JSONValue]
        let timerStartedAt: Int64
        let origin: String?

        init(action: String, params: [String: JSONValue], timerStartedAt: Int64, origin: String?) {
            self.action = action
            self.params = params
            self.timerStartedAt = timerStartedAt
            self.origin = origin
        }

        init?(decoding text: String) {
            guard let data = text.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  (object["v"] as? NSNumber)?.intValue == 1,
                  let action = object["action"] as? String,
                  let rawParams = object["params"] as? [String: Any],
                  let params = JSONValue.object(from: rawParams),
                  let started = JSONValue(any: object["timer_started_at"] ?? NSNull()),
                  case let .integer(timerStartedAt) = started
            else {
                return nil
            }
            let origin = object["origin"]
            guard origin == nil || origin is String else {
                return nil
            }
            self.init(action: action, params: params, timerStartedAt: timerStartedAt, origin: origin as? String)
        }

        func encoded() -> String? {
            var object: [String: Any] = [
                "v": 1,
                "action": action,
                "params": params.mapValues(\.anyValue),
                "timer_started_at": timerStartedAt,
            ]
            if let origin {
                object["origin"] = origin
            }
            guard JSONSerialization.isValidJSONObject(object),
                  let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            else {
                return nil
            }
            return String(data: data, encoding: .utf8)
        }
    }
}
