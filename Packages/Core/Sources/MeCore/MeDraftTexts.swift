import Foundation
import Generated

/// 「我的」类页面取文案的接口（BR-TEXT-12：页面不写中文，只取键）。生产由 App 组合（契约字典 → `MeDraftTexts` → App 已有草稿表）。
public protocol MeTexts: Sendable {
    /// 缺键为空串；带 {变量} 的按 fallback（BR-TEXT-14），没有 fallback 时去掉未填的占位。
    func text(_ key: String) -> String
    /// 填 {变量}；仍有没填上的变量时用契约 fallback，没有 fallback 时去掉未填的占位。
    func format(_ key: String, _ vars: [String: String]) -> String
}

/// 「我的」、设置、隐私中心、关于、封禁 / 冻结说明、申诉、通知设置、修改昵称与客服半屏里契约 texts.default.json 还没有的文案键（rule-gaps G08、
/// G35；照 N-26、N-30、N-31、N-32 的集中草稿表做法）。原文逐字取 规划/08 BR-TEXT-14 表 C（invite.copy_code.done、cs.copy_link.done）、
/// BR-TEXT-23 细则表（risk_reason.*）或设计稿（Me、Settings*、NotifySettings*、PrivacyCenter*、About、RiskNotice*、Appeal*、Cs* 画板）；
/// 规划与设计稿都没有的标「代拟」。三端同名（与 Android / 鸿蒙 MeDraftTexts 逐键一致，iOS 追加的键在表尾单列）。已在契约字典
/// （privacy.*、perm.*、settings.clear_cache.*、about.copy_diagnostics*、cs.wechat_unavailable / .copy_link /
/// .go_help、amount_mask.*、
/// error.*）与 App 已有草稿表（LoginDraftTexts：settings.logout.*、cs.appeal_entry）里的键不在这里重复建。
///
/// 整张表都是「待定稿，不得提审」：TODO(N-33) 契约补键后改为字典优先、本表兜底；提审前（QA-07）必须替换。
/// 代拟：me.load_failed、me.network_error、me.copy_failed、settings.phone.bound /
/// .unbound（G07）、nickname.empty、nickname.too_long、
/// notify.switch_failed、privacy_center.withdraw_failed、privacy_center.personalization_failed、risk.refresh_failed、
/// settings.refresh_failed（R1-05）、
/// risk.normal.*（G09）、
/// risk.frozen.note_no_until、risk.frozen_upheld.note、appeal.submitted、appeal.next.logout（去掉了 G30
/// 不显示的注销）、cs.help_only.desc、
/// me.switch.*、me.retry、me.close、me.back、appeal.lifted.title.history、appeal.lifted.desc.history、appeal.note.neutral、
/// appeal.state_appealing、me.unfinished、me.loading。设计稿自拟的：nickname.saved（flow-map
/// §23.1.7）、settings.reset_tip.done（§23.2.7）。
public struct MeDraftTexts: MeTexts {
    public init() {}

    /// TODO(N-33) 待定稿，不得提审。键 → 草稿文字（表在 MeDraftTable.swift）。
    public static var drafts: [String: String] {
        MeDraftTable.entries
    }

    /// 宫格名（MeView 的 item，设计稿原文）→ 文案键。
    static let gridKeys: [String: String] = [
        "我的订单": "me.grid.orders", "钱包": "me.grid.wallet", "余额流水": "me.grid.ledger",
        "找回订单": "me.grid.find_order", "邀请好友": "me.grid.invite", "收益看板": "me.grid.earnings",
        "帮助中心": "me.grid.help", "联系客服": "me.grid.cs", "授权管理": "me.grid.auth", "设置": "me.grid.settings",
    ]

    /// 设置行 / 分组名（SettingsItems 的 id，设计稿原文）→ 文案键。
    static let settingsKeys: [String: String] = [
        SettingsItems.idPrivacy: "settings.privacy_center",
        SettingsItems.idAgreement: "settings.agreement",
        SettingsItems.idAbout: "settings.about",
        SettingsItems.idHelp: "settings.help",
        SettingsItems.idClearCache: "settings.clear_cache",
        SettingsItems.idNickname: "settings.nickname",
        SettingsItems.idPhone: "settings.phone",
        SettingsItems.idAuth: "me.grid.auth",
        SettingsItems.idNotify: "settings.notify",
        SettingsItems.idResetTip: "settings.reset_tip",
        SettingsItems.groupAccount: "settings.group.account",
        SettingsItems.groupPrivacy: "settings.group.privacy",
        SettingsItems.groupGeneral: "settings.group.general",
    ]

    /// 宫格名 → 文案键；不认识的为 nil（不显示该格）。
    public static func gridKey(_ item: String) -> String? {
        gridKeys[item]
    }

    /// 设置行 / 分组名 → 文案键；不认识的为 nil。
    public static func settingsKey(_ id: String) -> String? {
        settingsKeys[id]
    }

    /// 宫格格子的稳定标识（测试与 UI 测试用；与更早任务的 me.wallet / me.authManage / me.settings 同名）。
    public static func gridIdentifier(_ item: String) -> String {
        switch gridKeys[item] {
        case "me.grid.wallet": "me.wallet"
        case "me.grid.auth": "me.authManage"
        case "me.grid.settings": "me.settings"
        case let key?: key
        default: "me.grid.unknown"
        }
    }

    /// 契约字典 → 本表；都没有为 nil（App 再查已有草稿表）。
    public static func raw(_ key: String) -> String? {
        DefaultTexts.text(key) ?? MeDraftTable.entries[key]
    }

    public func text(_ key: String) -> String {
        guard let raw = Self.raw(key) else { return DefaultTexts.fallback(key) ?? "" }
        return Self.fill(raw, key: key, vars: [:])
    }

    public func format(_ key: String, _ vars: [String: String]) -> String {
        Self.fill(Self.raw(key) ?? "", key: key, vars: vars)
    }

    /// 填变量；仍有未填占位时用契约 fallback，没有 fallback 时去掉占位并收掉多余空白与括号。
    public static func fill(_ template: String, key: String, vars: [String: String]) -> String {
        var text = template
        for (name, value) in vars where !value.isEmpty {
            text = text.replacingOccurrences(of: "{\(name)}", with: value)
        }
        guard text.range(of: "\\{[a-z0-9_]+\\}", options: .regularExpression) != nil else { return text }
        if let fallback = DefaultTexts.fallback(key) {
            return fallback
        }
        return text.replacingOccurrences(
            of: "\\s*[（(]?\\{[a-z0-9_]+\\}[）)]?\\s*",
            with: "",
            options: .regularExpression
        )
        .trimmingCharacters(in: .whitespaces)
    }
}
