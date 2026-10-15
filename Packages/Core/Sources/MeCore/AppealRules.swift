import Foundation
import Generated

// MARK: - 申诉

/// 申诉页版式（G15）：只看列表里 target_type=account 的最新一条（列表新的在前）。
public enum AppealView {
    public static let submit = "submit"
    public static let progress = "progress"
    public static let resultUpheld = "result_upheld"
    public static let resultLifted = "result_lifted"

    public static func latestAccount(_ appeals: [[String: Any]]) -> [String: Any]? {
        appeals.first { $0["target_type"] as? String == "account" }
    }

    public static func layout(_ appeals: [[String: Any]]) -> String {
        guard let latest = latestAccount(appeals) else { return submit }
        switch latest["status"] as? String {
        case "upheld": return resultUpheld
        case "revoked": return resultLifted
        default: return progress
        }
    }

    /// 冻结 / 封禁版式只决定文案组，不影响版式选择（G10）；参数留给三端同一签名。
    public static func of(appeals: [[String: Any]], frozenLayout _: Bool) -> [String: Any] {
        guard let latest = latestAccount(appeals) else { return ["layoutRaw": submit] }
        return ["layoutRaw": layout(appeals), "appealId": latest["appeal_id"] as? String ?? NSNull()]
    }
}

/// 申诉页里凡涉及「当前是否受限 / 已恢复」的标题、说明、提示条与按钮（鸿蒙 R2-01，共性第 12 条）：一律按本次 getMe.risk.state；申诉记录
/// （revoked / upheld）只作历史结论文字，版式（G10 的冻结 / 封禁）只决定文案组，不推断当前限制。
public enum AppealCopy {
    public static func restored(_ state: String?) -> Bool {
        state == "normal"
    }

    public static func restricted(_ state: String?) -> Bool {
        state == "banned" || state == "frozen" || state == "appealing"
    }

    public static func liftedTitle(frozenLayout: Bool, state: String?) -> String {
        if !restored(state) {
            return "appeal.lifted.title.history"
        }
        return frozenLayout ? "appeal.lifted.title.frozen" : "appeal.lifted.title.banned"
    }

    public static func liftedDesc(_ state: String?) -> String {
        restored(state) ? "appeal.lifted.desc" : "appeal.lifted.desc.history"
    }

    public static func liftedNote(frozenLayout: Bool, state: String?) -> String? {
        if frozenLayout {
            return "appeal.lifted.note.frozen"
        }
        return restored(state) ? "appeal.lifted.note.banned" : nil
    }

    public static func liftedActions(frozenLayout: Bool, state: String?) -> [String] {
        if frozenLayout {
            return ["go_wallet"]
        }
        return restored(state) ? ["start", "view_messages"] : ["contact_cs"]
    }

    public static func submitNote(frozenLayout: Bool, state: String?) -> String {
        if !restricted(state) {
            return "appeal.note.neutral"
        }
        return frozenLayout ? "appeal.note.frozen" : "appeal.note.banned"
    }

    public static func processingDesc(frozenLayout: Bool, state: String?) -> String? {
        guard restricted(state) else { return nil }
        return frozenLayout ? "appeal.timeline.processing_desc.frozen" : "appeal.timeline.processing_desc.banned"
    }

    public static func upheldFrozenNext(frozenLayout: Bool, state: String?) -> Bool {
        frozenLayout && (state == "frozen" || state == "appealing")
    }

    /// 「当前状态」一行（只按本次 risk.state）。
    public static func currentStateKey(_ state: String?) -> String? {
        switch state {
        case "banned": "risk.banned.title"
        case "frozen": "risk.frozen.title"
        case "appealing": "appeal.state_appealing"
        case "normal": "appeal.state_normal"
        default: nil
        }
    }
}

/// 申诉提交表单（G11、G14）：说明去首尾空白后非空才可提交；请求体 {target_type: account, content}，不带 target_id。
public enum AppealForm {
    public static func body(_ content: String) -> [String: Any]? {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        // TODO(N-33) vectors gaps「未定_申诉正文空白」：最终 content 是否去首尾空白未定，按去掉后的正文提交（与鸿蒙、Android 一致）
        return ["target_type": "account", "content": trimmed]
    }

    public static func check(content: String) -> [String: Any] {
        guard let body = body(content) else { return ["enabled": false] }
        return ["enabled": true, "body": body]
    }
}

/// 申诉提交结果分流（G13、G14）：成功 → 进度态；表外码走统一错误消息函数。
public enum AppealOutcome {
    public static func model(result: [String: Any]) -> WriteOutcome {
        if result["kind"] as? String == "ok" {
            return WriteOutcome(WriteOutcome.progress)
        }
        if let common = MeCodes.common(result) {
            return common
        }
        let code = MeCodes.code(result)
        if code == 20001 {
            return WriteOutcome(WriteOutcome.fieldError, textKey: "error.20001", keepInput: true)
        }
        return WriteOutcome(WriteOutcome.showError, textKey: MeCodes.codeTextKey(code), keepInput: true)
    }

    public static func of(result: [String: Any]) -> [String: Any] {
        model(result: result).json
    }
}
