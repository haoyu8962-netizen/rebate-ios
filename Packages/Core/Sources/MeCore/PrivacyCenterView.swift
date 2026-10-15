import Foundation

// MARK: - 隐私中心

/// 系统权限一节的一行。
public struct PermissionRow: Equatable, Sendable {
    public let type: String
    public let purposeKey: String?
    public let statusKey: String
}

public struct PrivacyCenterModel: Equatable, Sendable {
    public let lists: [String]
    public let personalizationSwitch: Bool
    public let withdrawButton: Bool
    public let enableFullButton: Bool
    public let permissionSection: Bool
    public let permissionRows: [PermissionRow]
    public let forceUpdate: Bool
}

/// 隐私中心分节（brief §2.4，G26）：两份清单；basic 只读（无个性化开关、无【撤回同意】，原位显示【开启完整功能】）；「系统权限」一节的条目
/// 只来自锁定契约的 specs/system-permissions.json 里本端的条目（iOS：通知、相册）。`forceUpdate`（03 §4.1「强更页的次要入口」，鸿蒙
/// R2-05）：从强更页进入时只显示两份清单、协议与【撤回同意】（已同意才有），不显示个性化开关、系统权限一节与【开启完整功能】。
public enum PrivacyCenterView {
    public static let listCollect = "个人信息收集清单"
    public static let listShare = "第三方共享清单"

    /// PermissionRequester 的状态 → 系统权限一节的状态（granted / denied / not_asked）。
    public static func statusOf(_ raw: String) -> String {
        switch raw {
        case "granted": "granted"
        case "denied", "permanently_denied": "denied"
        default: "not_asked"
        }
    }

    public static func model(
        level: String, platform: String, permissionEntries: [[String: Any]], permissionStatus: [String: String],
        forceUpdate: Bool = false
    ) -> PrivacyCenterModel {
        let basic = level == MeLevel.basic
        let rows: [PermissionRow] = forceUpdate ? [] : permissionEntries.compactMap { entry in
            guard let type = entry["type"] as? String, entry["platform"] as? String == platform else { return nil }
            return PermissionRow(
                type: type, purposeKey: entry["purpose_key"] as? String,
                statusKey: "privacy.system_permissions.status." + statusOf(permissionStatus[type] ?? "not_asked")
            )
        }
        return PrivacyCenterModel(
            lists: [listCollect, listShare],
            personalizationSwitch: !basic && !forceUpdate,
            withdrawButton: !basic,
            enableFullButton: basic && !forceUpdate,
            permissionSection: !forceUpdate,
            permissionRows: rows,
            forceUpdate: forceUpdate
        )
    }

    /// 向量接线：`permissionEntries` 是 system-permissions.json 的 permissions。
    public static func of(
        level: String, platform: String, permissionEntries: [[String: Any]], permissionStatus: [String: Any]
    ) -> [String: Any] {
        let status = permissionStatus.compactMapValues { $0 as? String }
        let model = model(level: level, platform: platform, permissionEntries: permissionEntries,
                          permissionStatus: status)
        return [
            "lists": model.lists,
            "personalizationSwitch": model.personalizationSwitch,
            "withdrawButton": model.withdrawButton,
            "enableFullButton": model.enableFullButton,
            "permissionSection": model.permissionSection,
            "permissionRows": model.permissionRows.map {
                ["type": $0.type, "purposeKey": $0.purposeKey ?? NSNull(), "statusKey": $0.statusKey] as [String: Any]
            },
        ]
    }
}

/// 个性化推荐开关（G03）：本机存、按设备；切换后记 recordConsent（channel=privacy_center）；关闭期间请求带 X-Personalization: off。
/// 基本模式没有开关、不记、不带头。
public enum Personalization {
    public static let headerName = "X-Personalization"
    public static let headerOff = "off"

    public static func consentBody(on: Bool, legalPrivacyVersion: Int, nowMs: Int64, level: String) -> [String: Any]? {
        guard level != MeLevel.basic else { return nil }
        return [
            "type": "personalization", "version": legalPrivacyVersion, "accepted": on, "channel": "privacy_center",
            "client_at": MeTime.shanghaiIso(nowMs),
        ]
    }

    public static func header(on: Bool, level: String) -> String? {
        level != MeLevel.basic && !on ? headerOff : nil
    }
}

/// 撤回同意（G24、G25）：设备已注册才发设备级 recordConsent(privacy, accepted=false)；无论结果（成功、失败、超时、未发）都做本地撤回、
/// 停推送上报、进入基本模式。
public enum PrivacyWithdrawFlow {
    public static func request(deviceRegistered: Bool, consentedVersion: Int, nowMs: Int64) -> [String: Any]? {
        guard deviceRegistered else { return nil }
        return [
            "type": "privacy", "version": consentedVersion, "accepted": false, "channel": "privacy_center",
            "client_at": MeTime.shanghaiIso(nowMs),
        ]
    }

    /// 结果一律不影响本地撤回（G24）；参数留给三端同一签名。
    public static func after(result _: [String: Any]) -> [String: Any] {
        ["localWithdraw": true, "enterBasicMode": true, "stopPushReport": true]
    }
}
