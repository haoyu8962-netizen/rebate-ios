import Foundation

/// JSON 值的类型判别（JSONSerialization 给 NSNumber：布尔与数字要分开，整数分不接受小数；三端同口径）。
enum JSONKind {
    static func isBool(_ value: Any?) -> Bool {
        guard let number = value as? NSNumber else { return false }
        return CFGetTypeID(number) == CFBooleanGetTypeID()
    }

    static func bool(_ value: Any?) -> Bool? {
        guard isBool(value), let number = value as? NSNumber else { return nil }
        return number.boolValue
    }

    /// 整数（不接受布尔与小数）。
    static func int64(_ value: Any?) -> Int64? {
        guard let number = value as? NSNumber, !isBool(number), !CFNumberIsFloatType(number) else { return nil }
        return number.int64Value
    }

    static func string(_ value: Any?) -> String? {
        value as? String
    }

    static func isNull(_ value: Any?) -> Bool {
        value is NSNull
    }

    /// 字段存在且是字符串或 null。
    static func nullableString(_ object: [String: Any], _ key: String) -> Bool {
        guard let value = object[key] else { return false }
        return value is NSNull || value is String
    }

    /// 字段存在且是可解析的时刻或 null。
    static func nullableInstant(_ object: [String: Any], _ key: String) -> Bool {
        guard let value = object[key] else { return false }
        if value is NSNull {
            return true
        }
        guard let text = value as? String else { return false }
        return MeTime.instant(text) != nil
    }
}

/// 「我的」、封禁说明与申诉的手写解析（brief §2.1；照 WalletJSON 的先例，模型未生成）。
/// - 必填字段缺失或类型不符：整条按坏数据（nil）——页面显示加载失败态与【重试】；不补默认值，不把缺失当 0、当「未绑定」、当 normal；
/// - 不认识的 risk.state 也按坏数据（不猜是正常还是受限）；不认识的 appeal.status 按「处理中」显示（`AppealView`）；
/// - 列表里坏的一条丢弃（只记个数）。
public enum MeJson {
    /// contracts enums identity.risk_state。
    public static let riskStates: Set<String> = ["normal", "frozen", "appealing", "banned"]

    /// Me 的 13 个必填字段（openapi Me.required）。
    public static let fields: [String] = [
        "user_id", "nickname", "avatar_url", "invite_code", "inviter_bound", "invite_backfill", "identity_level",
        "phone_bound", "balance", "union_bindings", "realname_status", "need_reconsent", "risk",
    ]

    static let appealFields = ["appeal_id", "target_type", "target_id", "status", "content", "created_at", "closed_at"]

    /// GET /v1/me 的 data → 只含 13 个契约字段的副本；坏数据为 nil。
    public static func parse(json value: Any?) -> [String: Any]? {
        guard let object = value as? [String: Any], fields.allSatisfy({ object[$0] != nil }) else { return nil }
        guard let userId = object["user_id"] as? String, !userId.isEmpty,
              object["nickname"] is String, object["avatar_url"] is String,
              JSONKind.nullableString(object, "invite_code"),
              JSONKind.isBool(object["inviter_bound"]), object["identity_level"] is String,
              JSONKind.isBool(object["phone_bound"]), object["realname_status"] is String,
              JSONKind.isBool(object["need_reconsent"]), object["union_bindings"] is [Any]
        else { return nil }
        guard let backfill = object["invite_backfill"] as? [String: Any], JSONKind.isBool(backfill["eligible"]),
              JSONKind.nullableInstant(backfill, "deadline_at")
        else { return nil }
        guard let balance = object["balance"] as? [String: Any],
              ["available_fen", "withdrawable_fen", "estimated_total_fen"].allSatisfy({
                  JSONKind.int64(balance[$0]) != nil
              })
        else { return nil }
        guard risk(object["risk"]) != nil else { return nil }
        var copy: [String: Any] = [:]
        for key in fields {
            copy[key] = object[key]
        }
        return copy
    }

    /// risk：state 必须是契约四值之一，reason_category 字符串或 null，frozen_until 可解析的时刻或 null。
    public static func risk(_ value: Any?) -> [String: Any]? {
        guard let risk = value as? [String: Any], let state = risk["state"] as? String, riskStates.contains(state),
              JSONKind.nullableString(risk, "reason_category"), JSONKind.nullableInstant(risk, "frozen_until")
        else { return nil }
        return risk
    }

    /// 已校验的 Me 的强类型视图（页面用）；`parse` 通过后一定成功。
    public static func me(_ value: Any?) -> MeProfile? {
        guard let raw = parse(json: value), let balance = raw["balance"] as? [String: Any],
              let risk = raw["risk"] as? [String: Any]
        else { return nil }
        return MeProfile(
            raw: raw,
            userId: raw["user_id"] as? String ?? "",
            nickname: raw["nickname"] as? String ?? "",
            inviteCode: raw["invite_code"] as? String,
            inviterBound: JSONKind.bool(raw["inviter_bound"]) ?? false,
            phoneBound: JSONKind.bool(raw["phone_bound"]) ?? false,
            withdrawableFen: JSONKind.int64(balance["withdrawable_fen"]) ?? 0,
            estimatedTotalFen: JSONKind.int64(balance["estimated_total_fen"]) ?? 0,
            riskState: risk["state"] as? String ?? "",
            reasonCategory: risk["reason_category"] as? String,
            frozenUntil: risk["frozen_until"] as? String
        )
    }

    /// 一条申诉（openapi Appeal 七个必填字段）；坏数据为 nil。status 只要求是字符串（不认识的按「处理中」显示）。
    public static func appeal(_ value: Any?) -> [String: Any]? {
        guard let object = value as? [String: Any], appealFields.allSatisfy({ object[$0] != nil }),
              let id = object["appeal_id"] as? String, !id.isEmpty, object["target_type"] is String,
              JSONKind.nullableString(object, "target_id"), object["status"] is String, object["content"] is String,
              let created = object["created_at"] as? String, MeTime.instant(created) != nil,
              JSONKind.nullableInstant(object, "closed_at")
        else { return nil }
        return object
    }

    /// GET /v1/me/appeals 的 data {items, next_cursor}：外壳坏了为 nil（整页加载失败）；坏的一条丢弃（`AppealList.dropped` 只记个数）。
    public static func appealList(_ value: Any?) -> AppealList? {
        guard let object = value as? [String: Any], let items = object["items"] as? [Any],
              JSONKind.nullableString(object, "next_cursor")
        else { return nil }
        let parsed = items.map(appeal)
        return AppealList(items: parsed.compactMap(\.self), dropped: parsed.filter { $0 == nil }.count)
    }

    /// 响应 data（原始字节）→ JSON 值。
    public static func object(_ data: Data?) -> Any? {
        guard let data, !data.isEmpty else { return nil }
        return try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    }

    /// JSON 值 → 紧凑文本（请求体）。
    public static func text(_ object: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        else { return "{}" }
        return String(bytes: data, encoding: .utf8) ?? "{}"
    }
}

/// 申诉列表（新的在前）；`dropped` 是丢弃的坏条目个数（日志只记个数）。
public struct AppealList {
    public let items: [[String: Any]]
    public let dropped: Int
}

/// 已校验的 Me 快照（页面用；只放本任务显示的字段，`raw` 是 13 个契约字段）。
public struct MeProfile {
    public let raw: [String: Any]
    public let userId: String
    public let nickname: String
    public let inviteCode: String?
    public let inviterBound: Bool
    public let phoneBound: Bool
    public let withdrawableFen: Int64
    public let estimatedTotalFen: Int64
    public let riskState: String
    public let reasonCategory: String?
    public let frozenUntil: String?

    public var risk: [String: Any] {
        raw["risk"] as? [String: Any] ?? [:]
    }

    /// 昵称保存成功后的快照（只换昵称）。
    public func renamed(_ nickname: String) -> MeProfile {
        var raw = raw
        raw["nickname"] = nickname
        return MeProfile(
            raw: raw, userId: userId, nickname: nickname, inviteCode: inviteCode, inviterBound: inviterBound,
            phoneBound: phoneBound, withdrawableFen: withdrawableFen, estimatedTotalFen: estimatedTotalFen,
            riskState: riskState, reasonCategory: reasonCategory, frozenUntil: frozenUntil
        )
    }
}

/// 时刻与时间文本（BR-TEXT-11；上海时区）。与 DesignSystem `CouliFormat.timeListFuture` / `timeMinute` 同一写法（Core 不依赖
/// DesignSystem，向量测试逐字比对，鸿蒙 H02 同口径）。
public enum MeTime {
    static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? TimeZone(secondsFromGMT: 8 * 3600) ?? .current
        return calendar
    }()

    /// ISO 8601 时刻 → 毫秒；不可解析为 nil。
    public static func instant(_ text: String) -> Int64? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) {
            return Int64((date.timeIntervalSince1970 * 1000).rounded())
        }
        formatter.formatOptions = [.withInternetDateTime]
        guard let date = formatter.date(from: text) else { return nil }
        return Int64((date.timeIntervalSince1970 * 1000).rounded())
    }

    private static func parts(_ epochMillis: Int64) -> DateComponents {
        // 向下取整到秒：分钟只截断，不进位（与 CouliFormat 同）。
        let seconds = epochMillis >= 0 ? epochMillis / 1000 : -((-epochMillis + 999) / 1000)
        return calendar.dateComponents(
            [.year, .month, .day, .hour, .minute], from: Date(timeIntervalSince1970: TimeInterval(seconds))
        )
    }

    private static func pad2(_ value: Int?) -> String {
        let number = value ?? 0
        return number < 10 ? "0\(number)" : "\(number)"
    }

    /// 未来时间（预计恢复）：与上海今天同年「MM-DD HH:mm」，否则「YYYY-MM-DD HH:mm」。
    public static func futureText(_ epochMillis: Int64, now: Int64) -> String {
        let time = parts(epochMillis)
        let today = parts(now)
        let hm = "\(pad2(time.hour)):\(pad2(time.minute))"
        if time.year == today.year {
            return "\(pad2(time.month))-\(pad2(time.day)) \(hm)"
        }
        return "\(time.year ?? 0)-\(pad2(time.month))-\(pad2(time.day)) \(hm)"
    }

    /// 「YYYY-MM-DD HH:mm」（申诉时间线与处理时间，H11）。
    public static func minuteText(_ epochMillis: Int64) -> String {
        let time = parts(epochMillis)
        return "\(time.year ?? 0)-\(pad2(time.month))-\(pad2(time.day)) \(pad2(time.hour)):\(pad2(time.minute))"
    }

    /// 客户端时刻（client_at）：上海时区的 ISO 8601（「2026-10-10T12:00:00+08:00」）。
    public static func shanghaiIso(_ epochMillis: Int64) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = calendar.timeZone
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: Date(timeIntervalSince1970: TimeInterval(epochMillis) / 1000))
    }
}
