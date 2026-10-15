import Foundation
import Generated

// MARK: - 封禁 / 冻结说明

/// 原因类别字典（G08：BR-TEXT-23 细则表的五类；表外与 null 不显示原因行，不显示原始编码）。
public enum RiskReasonText {
    public static let categories = ["malicious_rights", "fraud_invite", "abnormal_trade", "account_security", "other"]

    public static func key(category: String?) -> String? {
        guard let category, categories.contains(category) else { return nil }
        return "risk_reason.\(category)"
    }
}

/// RiskNotice 的版式。
public enum RiskLayout {
    public static let banned = "banned"
    public static let bannedAppealing = "banned_appealing"
    public static let bannedUpheld = "banned_upheld"
    public static let frozen = "frozen"
    public static let frozenAppealing = "frozen_appealing"
    public static let frozenUpheld = "frozen_upheld"
    public static let normal = "normal"

    public static func isFrozen(_ layout: String) -> Bool {
        [frozen, frozenAppealing, frozenUpheld].contains(layout)
    }

    public static func isBanned(_ layout: String) -> Bool {
        [banned, bannedAppealing, bannedUpheld].contains(layout)
    }
}

public struct RiskNoticeModel: Equatable, Sendable {
    public let layoutRaw: String
    public let reasonKey: String?
    public let frozenUntilText: String?
    public let showBack: Bool
    public let primaryRaw: String
    public let footer: [String]
    public let upheldLine: Bool
}

/// 封禁 / 冻结说明（G08、G09、G10、G30）：状态只按服务端 risk.state；appealing 时按「本次运行是否因 10006 进入」选封禁或冻结版式（只决定
/// 版式）；最近一次账户申诉 upheld 且仍受限时附「最近一次申诉：维持原处理结果」。不显示处理时限；注销按 G30 不显示。
public enum RiskNoticeView {
    public static let submit = "submit_appeal"
    public static let viewProgress = "view_progress"
    public static let backHome = "back_home"
    public static let contactCs = "contact_cs"
    public static let logout = "logout"

    public static func model(
        risk: [String: Any], enteredBy10006: Bool, latestAccountAppeal: [String: Any]?, nowMs: Int64
    ) -> RiskNoticeModel {
        let state = risk["state"] as? String ?? "normal"
        let upheld = latestAccountAppeal?["status"] as? String == "upheld"
        let layout: String = switch state {
        case "banned": upheld ? RiskLayout.bannedUpheld : RiskLayout.banned
        case "frozen": upheld ? RiskLayout.frozenUpheld : RiskLayout.frozen
        case "appealing": enteredBy10006 ? RiskLayout.bannedAppealing : RiskLayout.frozenAppealing
        default: RiskLayout.normal
        }
        if layout == RiskLayout.normal {
            return RiskNoticeModel(
                layoutRaw: layout, reasonKey: nil, frozenUntilText: nil, showBack: true, primaryRaw: backHome,
                footer: [], upheldLine: false
            )
        }
        var until: String?
        if RiskLayout.isFrozen(layout), let text = risk["frozen_until"] as? String, let millis = MeTime.instant(text) {
            until = MeTime.futureText(millis, now: nowMs)
        }
        let banned = RiskLayout.isBanned(layout)
        return RiskNoticeModel(
            layoutRaw: layout,
            reasonKey: RiskReasonText.key(category: risk["reason_category"] as? String),
            frozenUntilText: until,
            showBack: !banned,
            primaryRaw: state == "appealing" ? viewProgress : submit,
            footer: banned ? [contactCs, logout] : [],
            upheldLine: upheld
        )
    }

    public static func of(
        risk: [String: Any], enteredBy10006: Bool, latestAccountAppeal: [String: Any]?, nowMs: Int64
    ) -> [String: Any] {
        let model = model(risk: risk, enteredBy10006: enteredBy10006, latestAccountAppeal: latestAccountAppeal,
                          nowMs: nowMs)
        var out: [String: Any] = [
            "layoutRaw": model.layoutRaw, "showsDeadline": false, "reasonKey": model.reasonKey ?? NSNull(),
            "frozenUntilText": model.frozenUntilText ?? NSNull(), "primaryRaw": model.primaryRaw,
        ]
        if model.layoutRaw != RiskLayout.normal {
            out["showBack"] = model.showBack
            out["footer"] = model.footer
            out["upheldLine"] = model.upheldLine
        }
        return out
    }
}

/// 进行中的提现（G16）：只取 PENDING_REVIEW、APPROVED、PAYING。
public enum PendingWithdrawals {
    public static let statuses: Set<String> = ["PENDING_REVIEW", "APPROVED", "PAYING"]

    public static func filter(items: [[String: Any]]) -> [String] {
        items.compactMap { item in
            guard let id = item["withdrawal_id"] as? String, let status = item["status"] as? String,
                  statuses.contains(status)
            else { return nil }
            return id
        }
    }
}
