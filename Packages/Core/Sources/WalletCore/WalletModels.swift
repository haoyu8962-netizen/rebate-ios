import Foundation

/// GET /v1/wallet/summary 的 data（13 个字段全部必填；金额不可空，next_credit_period、risk_paused_reason 可空）。
public struct WalletSummary: Equatable, Sendable {
    public let availableFen: Int64
    public let withdrawableFen: Int64
    public let negativeFen: Int64
    public let frozenFen: Int64
    public let estimatedTotalFen: Int64
    public let estimatedFen: Int64
    public let pendingCreditFen: Int64
    public let pendingCreditPausedFen: Int64
    public let nextCreditPeriod: String?
    public let creditOverdue: Bool
    public let withdrawnFen: Int64
    public let riskPausedReason: String?
    public let withdrawEnabled: Bool
}

/// GET /v1/withdrawals/rules 的 data（11 个字段全部必填；est_* 可空）。
public struct WithdrawRules: Equatable, Sendable {
    public let canWithdraw: Bool
    public let blockCode: Int?
    public let blockReason: String?
    public let maxWithdrawableFen: Int64
    public let withdrawableFen: Int64
    public let dailyRemaining: Int64
    public let monthlyRemaining: Int64
    public let estFeeFen: Int64?
    public let estTaxFen: Int64?
    public let estNetFen: Int64?
    public let quickAmountsFen: [Int64]
}

/// 一张提现单（WithdrawalSummary；详情 Withdrawal 只多 `channelOrderId`）。`status`、`payoutChannel` 原样保存：不认识的状态显示「处理中」，
/// 不认识的通道（含 wechat）只显示 payout_channel_name 与脱敏串、不出操作入口（BR-TEXT-06，brief §2.1）。
public struct Withdrawal: Equatable, Sendable {
    public let withdrawalId: String
    public let status: String
    public let reviewMode: String?
    public let amountFen: Int64
    public let feeFen: Int64
    public let taxFen: Int64
    public let netFen: Int64
    public let payoutChannel: String
    public let payoutChannelName: String
    public let maskedAccount: String
    public let reasonCode: String?
    public let failAction: String?
    public let createdAt: String
    public let createdAtMillis: Int64
    /// 只有详情（GET /v1/withdrawals/{id}）有；列表项为 nil 且 `isDetail` = false。
    public let channelOrderId: String?
    public let isDetail: Bool
}

public struct WithdrawalListData: Equatable, Sendable {
    public let items: [Withdrawal]
    public let nextCursor: String?
    /// 必填字段缺失或类型不符被丢弃的条数（只记日志用，不显示）。
    public let dropped: Int
}

/// GET /v1/me/payout-account 的 data：空对象 = 未绑定。
public enum PayoutAccount: Equatable, Sendable {
    case unbound
    case bound(BoundPayoutAccount)
}

public struct BoundPayoutAccount: Equatable, Sendable {
    public let method: String
    public let maskedAccount: String
    public let maskedPayeeName: String
    public let changeRemainingThisMonth: Int64
    /// 银行卡才有。
    public let bankName: String?

    /// 契约里认识的两种（alipay、bank_card）；其余（含 wechat）只显示脱敏串、不出操作入口。
    public var known: Bool {
        method == WalletJSON.alipay || method == WalletJSON.bankCard
    }
}

public struct StepUpData: Equatable, Sendable {
    public let token: String
    public let expireAt: String
    public let expireAtMillis: Int64
}

public struct SendSmsCodeData: Equatable, Sendable {
    public let resendAfterSec: Int64
    public let expiresInSec: Int64
}

/// 钱包类日志（只出脱敏串与条数；BR-ID-33 细则）。测试替换 sink。
public enum WalletLog {
    public nonisolated(unsafe) static var sink: (String) -> Void = { _ in }

    static func warn(_ message: String) {
        sink(message)
    }
}

/// 钱包类接口的手写解析（照 TradeJSON / OrderJSON 的先例）：必填字段缺失或类型不符 → 整条按坏数据（nil），不补默认值，不把缺失当 0。
/// 列表项坏一条只丢弃这一条（`WithdrawalListData.dropped`）。
public enum WalletJSON {
    public static let alipay = "alipay"
    public static let bankCard = "bank_card"

    static let summaryFields = [
        "available_fen", "withdrawable_fen", "negative_fen", "frozen_fen", "estimated_total_fen", "estimated_fen",
        "pending_credit_fen", "pending_credit_paused_fen", "next_credit_period", "credit_overdue", "withdrawn_fen",
        "risk_paused_reason", "withdraw_enabled",
    ]
    static let rulesFields = [
        "can_withdraw", "block_code", "block_reason", "max_withdrawable_fen", "withdrawable_fen", "daily_remaining",
        "monthly_remaining", "est_fee_fen", "est_tax_fen", "est_net_fen", "quick_amounts_fen",
    ]
    static let withdrawalFields = [
        "withdrawal_id", "status", "review_mode", "amount_fen", "fee_fen", "tax_fen", "net_fen", "payout_channel",
        "payout_channel_name", "masked_account", "reason_code", "fail_action", "created_at",
    ]

    /// 外壳 data 的字节 → JSON 值。
    public static func parse(_ data: Data?) -> Any? {
        guard let data, !data.isEmpty else { return nil }
        return try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    }

    public static func summary(_ value: Any?) -> WalletSummary? {
        guard let object = value as? [String: Any], has(object, summaryFields) else { return nil }
        var reader = FieldReader(object)
        let period = reader.optionalString("next_credit_period")
        if let period, !isPeriod(period) {
            return nil
        }
        let summary = WalletSummary(
            availableFen: reader.int("available_fen"), withdrawableFen: reader.int("withdrawable_fen"),
            negativeFen: reader.int("negative_fen"), frozenFen: reader.int("frozen_fen"),
            estimatedTotalFen: reader.int("estimated_total_fen"), estimatedFen: reader.int("estimated_fen"),
            pendingCreditFen: reader.int("pending_credit_fen"),
            pendingCreditPausedFen: reader.int("pending_credit_paused_fen"), nextCreditPeriod: period,
            creditOverdue: reader.bool("credit_overdue"), withdrawnFen: reader.int("withdrawn_fen"),
            riskPausedReason: reader.optionalString("risk_paused_reason"),
            withdrawEnabled: reader.bool("withdraw_enabled")
        )
        return reader.ok ? summary : nil
    }

    public static func encode(_ summary: WalletSummary) -> [String: Any] {
        [
            "available_fen": summary.availableFen, "withdrawable_fen": summary.withdrawableFen,
            "negative_fen": summary.negativeFen, "frozen_fen": summary.frozenFen,
            "estimated_total_fen": summary.estimatedTotalFen, "estimated_fen": summary.estimatedFen,
            "pending_credit_fen": summary.pendingCreditFen,
            "pending_credit_paused_fen": summary.pendingCreditPausedFen,
            "next_credit_period": summary.nextCreditPeriod ?? NSNull(), "credit_overdue": summary.creditOverdue,
            "withdrawn_fen": summary.withdrawnFen, "risk_paused_reason": summary.riskPausedReason ?? NSNull(),
            "withdraw_enabled": summary.withdrawEnabled,
        ]
    }

    public static func rules(_ value: Any?) -> WithdrawRules? {
        guard let object = value as? [String: Any], has(object, rulesFields),
              let quick = object["quick_amounts_fen"] as? [Any]
        else { return nil }
        let amounts = quick.compactMap(int64)
        guard amounts.count == quick.count else { return nil }
        var reader = FieldReader(object)
        let block = reader.optionalInt("block_code")
        let rules = WithdrawRules(
            canWithdraw: reader.bool("can_withdraw"), blockCode: block.flatMap { Int(exactly: $0) },
            blockReason: reader.optionalString("block_reason"),
            maxWithdrawableFen: reader.int("max_withdrawable_fen"), withdrawableFen: reader.int("withdrawable_fen"),
            dailyRemaining: reader.int("daily_remaining"), monthlyRemaining: reader.int("monthly_remaining"),
            estFeeFen: reader.optionalInt("est_fee_fen"), estTaxFen: reader.optionalInt("est_tax_fen"),
            estNetFen: reader.optionalInt("est_net_fen"), quickAmountsFen: amounts
        )
        return reader.ok ? rules : nil
    }

    /// 列表项（WithdrawalSummary）。
    public static func withdrawal(_ value: Any?) -> Withdrawal? {
        withdrawal(value, detail: false)
    }

    /// 详情（Withdrawal，多一个必填可空的 channel_order_id）。
    public static func withdrawalDetail(_ value: Any?) -> Withdrawal? {
        withdrawal(value, detail: true)
    }

    private static func withdrawal(_ value: Any?, detail: Bool) -> Withdrawal? {
        guard let object = value as? [String: Any], has(object, withdrawalFields),
              !detail || object.keys.contains("channel_order_id")
        else { return nil }
        var reader = FieldReader(object)
        let id = reader.string("withdrawal_id")
        let created = reader.string("created_at")
        guard let millis = WalletClock.epochMillis(created), !id.isEmpty else { return nil }
        let item = Withdrawal(
            withdrawalId: id, status: reader.string("status"), reviewMode: reader.optionalString("review_mode"),
            amountFen: reader.int("amount_fen"), feeFen: reader.int("fee_fen"), taxFen: reader.int("tax_fen"),
            netFen: reader.int("net_fen"), payoutChannel: reader.string("payout_channel"),
            payoutChannelName: reader.string("payout_channel_name"), maskedAccount: reader.string("masked_account"),
            reasonCode: reader.optionalString("reason_code"), failAction: reader.optionalString("fail_action"),
            createdAt: created, createdAtMillis: millis,
            channelOrderId: detail ? reader.optionalString("channel_order_id") : nil, isDetail: detail
        )
        return reader.ok ? item : nil
    }

    public static func withdrawalList(_ value: Any?) -> WithdrawalListData? {
        guard let object = value as? [String: Any], let items = object["items"] as? [Any],
              let rawCursor = object["next_cursor"]
        else { return nil }
        let cursor: String?
        if rawCursor is NSNull {
            cursor = nil
        } else if let text = rawCursor as? String {
            cursor = text
        } else {
            return nil
        }
        let parsed = items.map { withdrawal($0) }
        let dropped = parsed.filter { $0 == nil }.count
        if dropped > 0 {
            WalletLog.warn("wallet: dropped \(dropped) malformed withdrawals")
        }
        return WithdrawalListData(items: parsed.compactMap(\.self), nextCursor: cursor, dropped: dropped)
    }

    /// 收款账号：空对象 = 未绑定；字段不全为坏数据；方式不认识但字段齐 → 按「其他收款方式」只显示脱敏串。
    public static func payoutAccount(_ value: Any?) -> PayoutAccount? {
        guard let object = value as? [String: Any] else { return nil }
        if object.isEmpty {
            return .unbound
        }
        var reader = FieldReader(object)
        let method = reader.string("payout_method")
        let account = BoundPayoutAccount(
            method: method, maskedAccount: reader.string("masked_account"),
            maskedPayeeName: reader.string("masked_payee_name"),
            changeRemainingThisMonth: reader.int("change_remaining_this_month"),
            bankName: method == bankCard ? reader.string("bank_name") : nil
        )
        return reader.ok ? .bound(account) : nil
    }

    public static func stepUp(_ value: Any?) -> StepUpData? {
        guard let object = value as? [String: Any] else { return nil }
        var reader = FieldReader(object)
        let token = reader.string("step_up_token")
        let expire = reader.string("expire_at")
        guard reader.ok, !token.isEmpty, let millis = WalletClock.epochMillis(expire) else { return nil }
        return StepUpData(token: token, expireAt: expire, expireAtMillis: millis)
    }

    public static func sendSmsCode(_ value: Any?) -> SendSmsCodeData? {
        guard let object = value as? [String: Any] else { return nil }
        var reader = FieldReader(object)
        let data = SendSmsCodeData(
            resendAfterSec: reader.int("resend_after_sec"),
            expiresInSec: reader.int("expires_in_sec")
        )
        return reader.ok ? data : nil
    }

    static func has(_ object: [String: Any], _ fields: [String]) -> Bool {
        fields.allSatisfy { object.keys.contains($0) }
    }

    static func isPeriod(_ text: String) -> Bool {
        text.range(of: "^[0-9]{4}-(0[1-9]|1[0-2])$", options: .regularExpression) != nil
    }

    /// 真正的 JSON 整数（不把布尔、小数、字符串当整数）。
    public static func int64(_ value: Any?) -> Int64? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let integer = number.int64Value
        return NSNumber(value: integer) == number ? integer : nil
    }

    /// 真正的 JSON 布尔。
    static func bool(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }

    /// JSON 文本（键排序；请求体、摘要用）。
    public static func text(_ object: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        else { return "{}" }
        return String(bytes: data, encoding: .utf8) ?? "{}"
    }
}

/// 逐字段严格读取：任一项缺失或类型不符就把 `ok` 置 false（整条按坏数据），读出的占位值不会被使用。
struct FieldReader {
    private let object: [String: Any]
    private(set) var ok = true

    init(_ object: [String: Any]) {
        self.object = object
    }

    mutating func int(_ key: String) -> Int64 {
        guard let value = WalletJSON.int64(object[key]) else {
            ok = false
            return 0
        }
        return value
    }

    mutating func optionalInt(_ key: String) -> Int64? {
        guard let raw = object[key] else {
            ok = false
            return nil
        }
        if raw is NSNull {
            return nil
        }
        return int(key)
    }

    mutating func string(_ key: String) -> String {
        guard let value = object[key] as? String else {
            ok = false
            return ""
        }
        return value
    }

    mutating func optionalString(_ key: String) -> String? {
        guard let raw = object[key] else {
            ok = false
            return nil
        }
        if raw is NSNull {
            return nil
        }
        return string(key)
    }

    mutating func bool(_ key: String) -> Bool {
        guard let value = WalletJSON.bool(object[key]) else {
            ok = false
            return false
        }
        return value
    }
}

/// +08:00 下的时间工具（提现单月份分组、申请时间；BR-TEXT-11）。
public enum WalletClock {
    static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = TimeZone(secondsFromGMT: 8 * 3600) ?? .current
        return calendar
    }()

    /// ISO 8601（带时区）→ 毫秒；格式不对为 nil。
    public static func epochMillis(_ iso: String?) -> Int64? {
        guard let iso else { return nil }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        for formatter in [plain, fractional] {
            if let date = formatter.date(from: iso) {
                return Int64((date.timeIntervalSince1970 * 1000).rounded(.down))
            }
        }
        return nil
    }

    /// +08:00 下的年月日时分。
    public static func parts(_ epochMillis: Int64) -> DateComponents {
        let seconds = epochMillis >= 0 ? epochMillis / 1000 : -((-epochMillis + 999) / 1000)
        return calendar.dateComponents(
            [.year, .month, .day, .hour, .minute], from: Date(timeIntervalSince1970: TimeInterval(seconds))
        )
    }
}
