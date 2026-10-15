import Foundation
import Generated

// MARK: - 关于

/// 复制诊断信息（G23、AC-S1-136）：只含版本与构建号、渠道、系统版本、机型、device_id 后 6 位、推送是否已上报、最近 3 个 trace_id、配置版本、
/// 首页版本；固定英文字段名，每行一项，拿不到的整行省略；不含任何令牌、install_secret、完整 device_id、设备哈希、手机号、uid。
public enum Diagnostics {
    static let tail = 6
    static let traces = 3

    static func clean(_ value: Any?) -> String? {
        guard let text = value as? String else { return nil }
        let single = text.replacingOccurrences(of: "[\\r\\n]+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        return single.isEmpty ? nil : single
    }

    public static func lines(fields: [String: Any]) -> [String] {
        identity(fields) + push(fields) + versions(fields)
    }

    /// 版本与构建号、渠道、系统版本、机型、device_id 后 6 位。
    static func identity(_ fields: [String: Any]) -> [String] {
        var out: [String] = []
        let version = clean(fields["version"])
        let build = clean(fields["build"])
        if let version {
            out.append("app_version: \(version)" + (build.map { " (\($0))" } ?? ""))
        } else if let build {
            out.append("app_build: \(build)")
        }
        let named: [(String, String)] = [
            ("channel", "channel"),
            ("system_version", "os_version"),
            ("model", "device_model"),
        ]
        for (field, name) in named {
            if let value = clean(fields[field]) {
                out.append("\(name): \(value)")
            }
        }
        if let device = clean(fields["device_id"]), device.count >= tail {
            out.append("device_id_tail: " + String(device.suffix(tail)))
        }
        return out
    }

    /// 推送是否已上报（是 / 否；不含令牌）、最近 3 个 trace_id。
    static func push(_ fields: [String: Any]) -> [String] {
        var out: [String] = []
        if let reported = JSONKind.bool(fields["push_reported"]) {
            out.append("push_reported: " + (reported ? "是" : "否"))
        }
        let picked = ((fields["trace_ids"] as? [Any]) ?? []).compactMap(clean).prefix(traces)
        if !picked.isEmpty {
            out.append("recent_trace_ids: " + picked.joined(separator: ", "))
        }
        return out
    }

    /// 配置版本、首页版本。
    static func versions(_ fields: [String: Any]) -> [String] {
        [("config_version", "config_version"), ("home_version", "home_version")].compactMap { field, name in
            clean(fields[field]).map { "\(name): \($0)" }
        }
    }
}

/// 关于页（G22）：AI 公示只显示 agent.filing_text 原文（空串、未配置整节不显示）；备案号行不显示（TODO(N-33)）。
public enum AboutView {
    public static func filing(_ filingText: String?) -> String? {
        guard let filingText, !filingText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return filingText
    }

    public static func of(filingText: String?) -> [String: Any] {
        ["filingSection": filing(filingText) ?? NSNull(), "icpRow": false]
    }
}

// MARK: - 10006 与本机数据

/// 10006 的统一落点（G09）：强更显示中不打开（强更优先）；RiskNotice 已在栈顶不重复打开；其余替换到 RiskNotice。
public enum Route10006 {
    public static let replace = "replace_risk_notice"
    public static let none = "none"
    public static let riskNotice = "RiskNotice"

    public static func decide(topRoute: String, forceUpdateShowing: Bool) -> String {
        forceUpdateShowing || topRoute == riskNotice ? none : replace
    }
}

/// 本任务新增的本机数据何时清（G29）：设备级（引导条关闭时刻、个性化）只在撤回同意时清；会话级（推送上报状态、Me 快照、昵称与申诉草稿）在
/// 退出、换账号、会话失效、撤回同意、切换环境时清；回后台都不清。
public enum MeLocalData {
    public static let deviceItems: Set<String> = ["guide_bar_closed_at", "personalization"]
    public static let sessionItems: Set<String> = ["push_report_state", "me_snapshot", "nickname_draft", "appeal_draft"]
    public static let sessionEvents: Set<String> = [
        "logout", "account_switch", "session_invalid", "consent_revoked", "env_switch",
    ]

    public static func clearsOn(event: String, item: String) -> Bool {
        if deviceItems.contains(item) {
            return event == "consent_revoked"
        }
        if sessionItems.contains(item) {
            return sessionEvents.contains(event)
        }
        return false
    }
}
