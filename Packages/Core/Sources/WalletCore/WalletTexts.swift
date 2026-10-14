import Foundation
import Generated

/// 钱包类页面取文案的接口（BR-TEXT-12：页面不写中文，只取键）。生产为 `WalletDraftTexts`（契约字典优先，草稿兜底）。
public protocol WalletTexts: Sendable {
    /// 不带变量的文案；带 {变量} 的文案按 fallback（BR-TEXT-14）；缺键为空串。
    func text(_ key: String) -> String
    /// 填 {变量}；值为空或仍有没填上的变量时用 fallback；没有 fallback 时去掉未填的占位。
    func format(_ key: String, _ vars: [String: String]) -> String
    /// 键是否存在（契约或草稿表）。
    func has(_ key: String) -> Bool
}

/// 钱包、提现、二次验证、提现记录、实名、收款账号、劳务协议里契约 texts.default.json 还没有的文案键（rule-gaps G08、G09）。原文逐字取
/// BR-TEXT-06 / 07 / 08 与 BR-TEXT-14 表 C（wallet.help.*、withdraw.risk_blocked.desc、cs.appeal_entry），其余逐字取设计稿；设计稿也没有的
/// 标「代拟」。契约里已有的键（withdraw.*、withdraw_detail.*、pending_confirm.*、amount_mask.hide / show、net.stale_data、error.*）一律读
/// DefaultTexts，不放这里。三端同名（Android / 鸿蒙 WalletDraftTexts）。
///
/// TODO(N-32) 整张表都是「待定稿，不得提审」：契约补键（/v1/dict 或 texts.default.json）后删除本表、改读字典。
public struct WalletDraftTexts: WalletTexts {
    public init() {}

    /// TODO(N-32) 待定稿，不得提审。键 → 草稿文字（分几段维护，见 WalletDraftTable*.swift）。
    public static let drafts: [String: String] = walletPage
        .merging(withdrawPage) { first, _ in first }
        .merging(recordsPage) { first, _ in first }
        .merging(identityPages) { first, _ in first }

    /// 草稿的 fallback（变量缺失时；BR-TEXT-14 缺变量回退）。
    static let draftFallbacks: [String: String] = [
        "wallet.draft.risk_paused_reason": "提现已暂停",
        "withdraw.sla_text": "人工审核，工作日 24 小时内处理，节假日顺延",
    ]

    private static func raw(_ key: String) -> String? {
        DefaultTexts.text(key) ?? drafts[key]
    }

    private static func fallback(_ key: String) -> String? {
        DefaultTexts.fallback(key) ?? draftFallbacks[key]
    }

    public func has(_ key: String) -> Bool {
        Self.raw(key) != nil
    }

    public func text(_ key: String) -> String {
        guard let raw = Self.raw(key) ?? Self.fallback(key) else { return "" }
        guard Self.hasPlaceholder(raw) else { return raw }
        return Self.fallback(key) ?? Self.stripPlaceholders(raw)
    }

    public func format(_ key: String, _ vars: [String: String]) -> String {
        guard var text = Self.raw(key) else { return text(key) }
        for (name, value) in vars where !value.isEmpty {
            text = text.replacingOccurrences(of: "{\(name)}", with: value)
        }
        guard Self.hasPlaceholder(text) else { return text }
        return Self.fallback(key) ?? Self.stripPlaceholders(text)
    }

    static func hasPlaceholder(_ text: String) -> Bool {
        text.range(of: "\\{[a-z0-9_]+\\}", options: .regularExpression) != nil
    }

    static func stripPlaceholders(_ text: String) -> String {
        text.replacingOccurrences(of: "\\{[a-z0-9_]+\\}", with: "", options: .regularExpression)
    }
}

/// 一行带变量的文案（键 + 变量；金额变量是整数分，渲染时才交给 DesignSystem 的 CouliFormat，Core 不格式化金额）。
public struct TextLine: Equatable, Sendable {
    public let key: String
    public let amounts: [String: Int64]
    public let strings: [String: String]

    public init(_ key: String, amounts: [String: Int64] = [:], strings: [String: String] = [:]) {
        self.key = key
        self.amounts = amounts
        self.strings = strings
    }

    /// 渲染：金额按调用方给的格式化函数（页面传 CouliFormat.money）。
    public func render(_ texts: WalletTexts, money: (Int64) -> String) -> String {
        var vars = strings
        for (name, fen) in amounts {
            vars[name] = money(fen)
        }
        return texts.format(key, vars)
    }
}
