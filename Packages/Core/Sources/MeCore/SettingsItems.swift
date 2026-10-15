import Foundation

// MARK: - 设置页

/// 设置页的一行：`id` 稿上的名字（界面经 `MeDraftTexts.settingsKey` 取键），`route` 经 Router 打开的路由（页内子页、半屏为 nil）。
public struct SettingsRow: Equatable, Sendable {
    public let id: String
    public let route: String?
    public let clickable: Bool
    /// 协议选择半屏的两个按钮（route + params.type）。
    public let choices: [SettingsChoice]?
    /// 通知设置子页是否显示服务开关（G02）。
    public let serviceSwitchAvailable: Bool?

    init(_ id: String, _ route: String?, clickable: Bool = true, choices: [SettingsChoice]? = nil,
         serviceSwitchAvailable: Bool? = nil) {
        self.id = id
        self.route = route
        self.clickable = clickable
        self.choices = choices
        self.serviceSwitchAvailable = serviceSwitchAvailable
    }
}

public struct SettingsChoice: Equatable, Sendable {
    public let route: String
    public let type: String
}

public struct SettingsGroup: Equatable, Sendable {
    public let name: String
    public let rows: [SettingsRow]
}

public struct SettingsModel: Equatable, Sendable {
    public let groups: [SettingsGroup]
    public let footer: String
}

/// 设置页条目（brief §2.3，G01、G02、G07、G30、G32）。groups 只描述顶层行（group 空串 = 未分组）；footer：basic → enable_full，guest →
/// login_prompt，member → logout。修改昵称、通知设置、协议选择半屏是页内子页（route 为 nil）。剪贴板开关只在 Android。
public enum SettingsItems {
    public static let idPrivacy = "隐私中心"
    public static let idAgreement = "用户协议与隐私政策"
    public static let idAbout = "关于凑狸"
    public static let idHelp = "帮助中心"
    public static let idClearCache = "清除缓存"
    public static let idClipboard = "打开 App 自动识别剪贴板"
    public static let idNickname = "昵称"
    public static let idPhone = "手机号"
    public static let idAuth = "授权管理"
    public static let idDelete = "注销账号"
    public static let idNotify = "通知设置"
    public static let idResetTip = "重新显示下单须知"
    public static let groupAccount = "账号与安全"
    public static let groupPrivacy = "隐私"
    public static let groupGeneral = "通用"
    public static let footerEnableFull = "enable_full"
    public static let footerLogin = "login_prompt"
    public static let footerLogout = "logout"
    public static let agreement = "Agreement"

    static let agreementRow = SettingsRow(
        idAgreement, nil,
        choices: ["agreement", "privacy"].map { SettingsChoice(route: agreement, type: $0) }
    )

    // swiftlint:disable:next function_parameter_count
    public static func model(
        level: String, platform: String, phoneBound: Bool?, nicknameEditable: Bool, serviceSwitchAvailable: Bool,
        deleteAccountAvailable: Bool
    ) -> SettingsModel {
        let android = platform == MePlatform.android
        if level == MeLevel.basic {
            // 基本模式只有五项（四行 +【开启完整功能】），不显示剪贴板开关（BR-ID-02、BR-ID-16）
            let rows = [
                SettingsRow(idPrivacy, "PrivacyCenter"), agreementRow, SettingsRow(idAbout, "About"),
                SettingsRow(idHelp, "Help"),
            ]
            return SettingsModel(groups: [SettingsGroup(name: "", rows: rows)], footer: footerEnableFull)
        }
        if level != MeLevel.member {
            var rows = [SettingsRow(idPrivacy, "PrivacyCenter"), agreementRow, SettingsRow(idAbout, "About")]
            if android {
                rows.append(SettingsRow(idClipboard, nil))
            }
            rows += [SettingsRow(idClearCache, nil), SettingsRow(idHelp, "Help")]
            return SettingsModel(groups: [SettingsGroup(name: "", rows: rows)], footer: footerLogin)
        }
        // G07：只按 phone_bound；未绑定可点 → BindPhone，已绑定不可点（换手机号不在本任务）
        var account = [
            SettingsRow(idNickname, nil, clickable: nicknameEditable),
            SettingsRow(idPhone, phoneBound == false ? "BindPhone" : nil, clickable: phoneBound == false),
            SettingsRow(idAuth, "AuthManage"),
        ]
        if deleteAccountAvailable {
            account.append(SettingsRow(idDelete, "DeleteAccount"))
        }
        var general = [
            SettingsRow(idNotify, nil, serviceSwitchAvailable: serviceSwitchAvailable), SettingsRow(idResetTip, nil),
        ]
        if android {
            general.append(SettingsRow(idClipboard, nil))
        }
        general += [SettingsRow(idClearCache, nil), SettingsRow(idHelp, "Help"), SettingsRow(idAbout, "About")]
        return SettingsModel(
            groups: [
                SettingsGroup(name: groupAccount, rows: account),
                SettingsGroup(name: groupPrivacy, rows: [SettingsRow(idPrivacy, "PrivacyCenter"), agreementRow]),
                SettingsGroup(name: groupGeneral, rows: general),
            ],
            footer: footerLogout
        )
    }

    // 向量接线。
    // swiftlint:disable:next function_parameter_count
    public static func of(
        level: String, platform: String, phoneBound: Bool?, nicknameEditable: Bool, serviceSwitchAvailable: Bool,
        deleteAccountAvailable: Bool
    ) -> [String: Any] {
        let model = model(
            level: level, platform: platform, phoneBound: phoneBound, nicknameEditable: nicknameEditable,
            serviceSwitchAvailable: serviceSwitchAvailable, deleteAccountAvailable: deleteAccountAvailable
        )
        func row(_ row: SettingsRow) -> [String: Any] {
            var out: [String: Any] = ["id": row.id, "route": row.route ?? NSNull()]
            if row.id == idNickname || row.id == idPhone {
                out["clickable"] = row.clickable
            }
            if let choices = row.choices {
                out["params"] = ["choices": choices.map { ["route": $0.route, "params": ["type": $0.type]] }]
            }
            if let available = row.serviceSwitchAvailable {
                out["params"] = ["serviceSwitchAvailable": available]
            }
            return out
        }
        return [
            "groups": model.groups.map { ["group": $0.name, "items": $0.rows.map(row)] },
            "footer": model.footer,
        ]
    }
}

/// 清除缓存的大小（settings.clear_cache.size 的 {size}）：按 KB / MB 取整（四舍五入；不足 1 MB 用 KB）。
public enum CacheSize {
    public static func text(_ bytes: Int64) -> String {
        let kilo: Int64 = 1024
        let mega = kilo * kilo
        if bytes < mega {
            return "\((max(bytes, 0) + kilo / 2) / kilo)KB"
        }
        return "\((bytes + mega / 2) / mega)MB"
    }
}
