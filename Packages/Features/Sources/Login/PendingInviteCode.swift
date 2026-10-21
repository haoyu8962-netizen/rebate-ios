import Combine
import Foundation

/// 游客的待绑定码（APP-17c；BR-INV-04 正文 ④ 与细则「游客的待绑定码」、BR-INV-06；HM-13 decision G18–G21）。
/// - 来源：游客点了确认的剪贴板邀请提示条，或邀请链接拉起 App（`InviteLinkDispatcher`）；新码替换旧码。
/// - 存放：只在内存，有效期为本次进程；不持久化、不上传，也没有静态共享——App 只构造一份（AppLogin），剪贴板、登录页、
///   登录请求、以后的一键登录都用这一份（G21）。离开登录页不丢（Q1）。
/// - 写入时规范化并按 BR-INV-01 字符集校验 6 位；不合格的不写入，原码不动（F-HM-52：避免带上超长值让整次登录 20001）。
/// - 清除：登录页【移除】（`remove`）；随短信 / 一键登录请求带上时当场取走（`consumeForRequest`，之后不论结果都不再带，G18）；
///   撤回同意、基本模式、切换环境（`clear`，App 接线）。第三方登录与绑手机不碰它（留给 InviteBackfill 预填，APP-17b）。
@MainActor
public final class PendingInviteCode: ObservableObject {
    @Published private var code: String?

    public init() {}

    /// 记下待绑定码（替换旧值）；格式不符的不写入。
    public func set(_ value: String) {
        let normalized = InviteField.normalize(value)
        guard !normalized.isEmpty, InviteField.decide(normalized, context: [:]).valid == true else { return }
        code = normalized
    }

    /// 只读，不取走（登录页小字行、InviteBackfill 预填用）。
    public func peek() -> String? {
        code
    }

    /// 登录页小字行的【移除】：丢弃。
    public func remove() {
        code = nil
    }

    /// 取出并清空：只给短信（以后一键）登录请求在本地校验全部通过、即将发出时调用。
    public func consumeForRequest() -> String? {
        defer { code = nil }
        return code
    }

    /// 撤回同意、基本模式、切换环境时清除。
    public func clear() {
        code = nil
    }
}

/// 登录页顶部待绑定码小字行的视图模型（BR-TEXT-14 `login.pending_invite` / `.remove`）。2026-10-19 起旁边不显示告知句
/// （AC-S1-182 ①），所以不带告知句键；邀请奖励活动的 `invite.reward.tip` 不在本任务。
public struct PendingInviteRow: Equatable, Sendable {
    public static let textKey = "login.pending_invite"
    public static let removeKey = "login.pending_invite.remove"

    public let code: String
    public let textKey: String
    public let removeKey: String

    public init(code: String) {
        self.code = code
        textKey = Self.textKey
        removeKey = Self.removeKey
    }

    /// 现读容器（读取不消费）；受限登录不显示（G20），没有码也不显示。
    @MainActor
    static func of(_ pending: PendingInviteCode?, restricted: Bool) -> PendingInviteRow? {
        guard !restricted, let code = pending?.peek() else { return nil }
        return PendingInviteRow(code: code)
    }
}
