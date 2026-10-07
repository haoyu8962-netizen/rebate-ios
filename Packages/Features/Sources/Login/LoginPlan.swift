import Foundation
import Generated
import Session

// 短信登录主链路的纯逻辑（续）：邀请码、登录后计划、协议版本（APP-05a；三端同名，向量 specs/login-vectors.json）。

// MARK: - 邀请码

/// 邀请码输入框的判定。
public struct InviteDecision: Equatable, Sendable {
    public let showInviteField: Bool
    /// 只判注册页可接受的语法（空值可省略）；不决定能否登录（rule-gaps INVITE-01）。受限登录不判定（nil）。
    public let valid: Bool?
    /// 规范化后的码（空串 = 不带 invite_code）。
    public let normalized: String
    /// 输入框下方的告知句（BR-INV-18 细则）；不显示输入框时为 nil。
    public let noticeKey: String?
}

/// 注册页邀请码（BR-INV-01 字符集 23456789ABCDEFGHJKLMNPQRSTUVWXYZ、长度 6；BR-INV-02 规范化：NFKC → 删空白与零宽 →
/// 大写，不做 O→0 纠错、不删连字符）。受限登录（从强更页进入）不显示邀请码等业务输入（BR-ID-01 细则「受限登录」）。
public enum InviteField {
    public static let noticeKey = "invite.notice_inviter"
    /// openapi LoginBySmsRequest.invite_code maxLength。
    public static let maxWireLength = 32
    static let alphabet = Set("23456789ABCDEFGHJKLMNPQRSTUVWXYZ".unicodeScalars)

    public static func normalize(_ raw: String) -> String {
        var view = String.UnicodeScalarView()
        for scalar in raw.precomposedStringWithCompatibilityMapping.unicodeScalars
            where !scalar.properties.isWhitespace && !PhoneNumber.zeroWidth.contains(scalar.value) {
            view.append(scalar)
        }
        return String(view).uppercased()
    }

    public static func decide(_ raw: String, context: [String: Any]) -> InviteDecision {
        if JSONBool.isTrue(context["restricted"]) {
            return InviteDecision(showInviteField: false, valid: nil, normalized: "", noticeKey: nil)
        }
        let normalized = normalize(raw)
        let valid = normalized.isEmpty
            || (normalized.unicodeScalars.count == 6 && normalized.unicodeScalars.allSatisfy { alphabet.contains($0) })
        return InviteDecision(showInviteField: true, valid: valid, normalized: normalized, noticeKey: noticeKey)
    }

    /// 登录请求里带的 invite_code：受限登录不带；规范化后为空或超过契约长度不带（否则整个登录 20001）。
    /// 语法不对的照样带上，由服务端判（失败只回 invite_bind.failed，不阻止注册，INVITE-01）。
    public static func wireValue(_ raw: String, restricted: Bool) -> String? {
        guard !restricted else { return nil }
        let normalized = normalize(raw)
        guard !normalized.isEmpty, normalized.count <= maxWireLength else { return nil }
        return normalized
    }
}

/// JSON 里的真布尔（不把 1 当 true）。
enum JSONBool {
    static func isTrue(_ value: Any?) -> Bool {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else {
            return (value as? Bool) ?? false
        }
        return number.boolValue
    }
}

// MARK: - 登录后计划

/// 登录成功后的动作（AfterLogin.plan 的元素；三端同名）。
public enum AfterLoginAction {
    /// 会话已由 ApiClient 保存（执行器只在 ApiClient 返回成功后继续，INTEGRATION-01）。
    public static let saveSession = "save_session"
    /// 交给 Router 守卫恢复 pending_action（BR-ID-10）。
    public static let resumePending = "resume_pending"
    /// 受限会话或强更：删除 pending_action，不执行。
    public static let discardPending = "discard_pending"
    public static let enterForceUpdate = "enter_force_update"
    /// 受限会话与强更「受支持」并存（本机结论与服务端不一致，AFTER-02）：结论未定，不动待办；执行器先带本次尝试的归属
    /// 显式复查受限会话，再按最新作用域与强更结论重新计划（APP-05a 共性 4、10）。
    public static let refreshRestricted = "refresh_restricted"
    /// 复查后仍是受限会话：待办保留，关闭登录页，交给 Router 随之后的强更结论决定（三端对齐名）。
    public static let holdPending = "hold_pending"
}

/// AfterLogin.plan 的强更状态取值。
public enum AfterLoginUpdate {
    public static let supported = "supported"
    public static let below = "below"
    public static let unknown = "unknown"
    public static let checking = "checking"
}

/// 登录成功后的会话 / 路由计划（03 §4.2「受限会话」、§4.4；BR-ID-01、BR-ID-10）：
/// - 先 save_session（ApiClient 已保存成功才算登录成功）；
/// - 受限会话（deletion_only）且强更低于 / 未知 / 检查中：丢弃业务 pending_action，进强更页；
/// - 正常会话但强更低于：同样丢弃并进强更页（正常会话不绕过强更）；
/// - 受限会话且强更受支持：refresh_restricted（不删待办，执行器复查后重新计划）；
/// - 其余：有 pending_action 时交给 Router 守卫恢复。邀请绑定结果（invite_bind）不改变计划（AFTER-03）。
public enum AfterLogin {
    public static func plan(response: [String: Any], state: [String: Any]) -> [String] {
        var actions = [AfterLoginAction.saveSession]
        let restricted = (response["session_scope"] as? String) == Session.SessionScope.deletionOnly
        let update = state["update"] as? String
        let pending = JSONBool.isTrue(state["pendingAction"])
        let below = update == AfterLoginUpdate.below
        if (restricted && update != AfterLoginUpdate.supported) || below {
            if pending {
                actions.append(AfterLoginAction.discardPending)
            }
            actions.append(AfterLoginAction.enterForceUpdate)
            return actions
        }
        if restricted {
            actions.append(AfterLoginAction.refreshRestricted)
            return actions
        }
        if pending {
            actions.append(AfterLoginAction.resumePending)
        }
        return actions
    }
}

// MARK: - 协议版本

/// 登录请求上送的协议版本（BR-ID-04；openapi LegalVersions）。
public struct LegalVersions: Equatable, Sendable {
    public let privacy: Int
    public let agreement: Int

    public init(privacy: Int, agreement: Int) {
        self.privacy = privacy
        self.agreement = agreement
    }

    /// 包内当前版本：生成的包内默认配置（DefaultConfig，legal.privacy.version、legal.agreement.version）。读不出时按 1。
    /// TODO(N-26) LEGAL-01：法务定稿随包导出协议副本后，与首启弹窗的政策版本统一来源。
    public static var bundled: LegalVersions {
        parse(DefaultConfig.json)
    }

    public static func parse(_ json: String) -> LegalVersions {
        guard let data = json.data(using: .utf8),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let legal = root["legal"] as? [String: Any]
        else {
            return LegalVersions(privacy: 1, agreement: 1)
        }
        return LegalVersions(privacy: version(legal["privacy"]), agreement: version(legal["agreement"]))
    }

    private static func version(_ raw: Any?) -> Int {
        guard let object = raw as? [String: Any], let value = (object["version"] as? NSNumber)?.intValue, value >= 1
        else {
            return 1
        }
        return value
    }
}
