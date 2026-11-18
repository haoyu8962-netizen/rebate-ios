import Foundation

/// 一条注销申请（openapi Deletion；BR-ID-27）。字段全部必填（可空的三项要出现、值可为 null）；`canCancel` 只由服务端判定，客户端不按本机时钟推算。
public struct Deletion: Equatable, Sendable {
    public static let cooling = "cooling"
    public static let processing = "processing"
    public static let done = "done"
    public static let cancelled = "cancelled"
    public static let statuses: Set<String> = [cooling, processing, done, cancelled]
    public static let reasonUser = "user"
    public static let reasonNegative = "negative_balance"

    public let status: String
    public let applyAtMillis: Int64
    public let coolingUntilMillis: Int64
    public let canCancel: Bool
    public let cancelledAtMillis: Int64?
    /// 认识的撤销原因（user / negative_balance）；不认识的只当作 cancelled，不显示原因（brief §2.1）。
    public let cancelReason: String?
    public let processedAtMillis: Int64?

    public init(status: String, applyAtMillis: Int64, coolingUntilMillis: Int64, canCancel: Bool,
                cancelledAtMillis: Int64? = nil, cancelReason: String? = nil, processedAtMillis: Int64? = nil) {
        self.status = status
        self.applyAtMillis = applyAtMillis
        self.coolingUntilMillis = coolingUntilMillis
        self.canCancel = canCancel
        self.cancelledAtMillis = cancelledAtMillis
        self.cancelReason = cancelReason
        self.processedAtMillis = processedAtMillis
    }

    /// 撤回成功（用户撤回）：cancelled 且不是系统按负余额撤销（共性第 14 条，撤回未知后的核对）。
    public var cancelledByUser: Bool {
        status == Self.cancelled && cancelReason != Self.reasonNegative
    }
}

/// getDeletion 的读取结论：从未申请（data = null）、一条申请、坏数据（必填缺失、类型不符、不认识的 status：按读取失败，不当初始态）。
public enum DeletionRead: Equatable, Sendable {
    case none
    case record(Deletion)
    case bad

    public var deletion: Deletion? {
        if case let .record(deletion) = self {
            return deletion
        }
        return nil
    }
}

/// 注销页资金区只用钱包摘要的三个字段（G11：不相加、不推算，不显示冻结中）。整数分。
public struct DeletionFunds: Equatable, Sendable {
    public let withdrawableFen: Int64
    public let estimatedFen: Int64
    public let negativeFen: Int64

    public init(withdrawableFen: Int64, estimatedFen: Int64, negativeFen: Int64) {
        self.withdrawableFen = withdrawableFen
        self.estimatedFen = estimatedFen
        self.negativeFen = negativeFen
    }
}

/// 注销相关接口的手写解析（照 WalletJSON 先例）：必填字段缺失或类型不符整条按坏数据，不补默认值。
public enum DeletionJson {
    static let required = [
        "status", "apply_at", "cooling_until", "can_cancel", "cancelled_at", "cancel_reason", "processed_at",
    ]

    /// 外壳 data 的字节 → 读取结论。没有 data 或 data 为 null = 从未申请。
    public static func read(_ data: Data?) -> DeletionRead {
        guard let data, !data.isEmpty else { return .none }
        guard let value = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
            return .bad
        }
        return read(value: value)
    }

    /// 已解析的 JSON 值 → 读取结论（null → 从未申请；对象 → 解析；其余 → 坏数据）。
    public static func read(value: Any?) -> DeletionRead {
        guard let value, !(value is NSNull) else { return .none }
        guard let object = value as? [String: Any] else { return .bad }
        return deletion(object).map(DeletionRead.record) ?? .bad
    }

    /// 一条 Deletion（写请求成功的 data、作废得到 completed 的 original.data 也用它）。
    public static func deletion(_ value: Any?) -> Deletion? {
        guard let object = value as? [String: Any], required.allSatisfy({ object[$0] != nil }),
              let status = object["status"] as? String, Deletion.statuses.contains(status),
              let applyAt = time(object["apply_at"]), let coolingUntil = time(object["cooling_until"]),
              let canCancel = bool(object["can_cancel"])
        else { return nil }
        guard let cancelledAt = optionalTime(object["cancelled_at"]),
              let processedAt = optionalTime(object["processed_at"])
        else { return nil }
        let reasonValue = object["cancel_reason"]
        var reason: String?
        if let text = reasonValue as? String {
            reason = [Deletion.reasonUser, Deletion.reasonNegative].contains(text) ? text : nil
        } else if !(reasonValue is NSNull) {
            return nil
        }
        return Deletion(
            status: status, applyAtMillis: applyAt, coolingUntilMillis: coolingUntil, canCancel: canCancel,
            cancelledAtMillis: cancelledAt.value, cancelReason: reason, processedAtMillis: processedAt.value
        )
    }

    /// getWalletSummary 的 data → 三个资金字段（缺任一项或不是整数 → nil，按读取失败）。
    public static func funds(_ value: Any?) -> DeletionFunds? {
        guard let object = value as? [String: Any], let withdrawable = int64(object["withdrawable_fen"]),
              let estimated = int64(object["estimated_total_fen"]), let negative = int64(object["negative_fen"])
        else { return nil }
        return DeletionFunds(withdrawableFen: withdrawable, estimatedFen: estimated, negativeFen: negative)
    }

    /// getMe 的 phone_bound（缺失或不是布尔为 nil = 未知）。
    public static func phoneBound(_ value: Any?) -> Bool? {
        bool((value as? [String: Any])?["phone_bound"])
    }

    /// 30416 的 data.amount_fen（缺失、不是正整数为 nil：用 fallbacks 里不带金额的句子，共性第 10 条）。
    public static func amountFen(_ data: Data?) -> Int64? {
        guard let data, let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let amount = int64(object["amount_fen"]), amount > 0
        else { return nil }
        return amount
    }

    static func int64(_ value: Any?) -> Int64? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let double = number.doubleValue
        guard double.rounded() == double, abs(double) < 9.0e15 else { return nil }
        return number.int64Value
    }

    static func bool(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }

    /// 可空时间：null → 有值的 nil；字符串 → 解析；其余（类型不符、解析不了）→ nil（整条坏数据）。
    struct OptionalTime {
        let value: Int64?
    }

    static func optionalTime(_ value: Any?) -> OptionalTime? {
        if value is NSNull {
            return OptionalTime(value: nil)
        }
        return time(value).map { OptionalTime(value: $0) }
    }

    /// RFC 3339 date-time（带时区偏移，可带小数秒）→ 毫秒。
    static func time(_ value: Any?) -> Int64? {
        guard let text = value as? String else { return nil }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        if let date = plain.date(from: text) {
            return Int64((date.timeIntervalSince1970 * 1000).rounded())
        }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: text).map { Int64(($0.timeIntervalSince1970 * 1000).rounded()) }
    }
}
