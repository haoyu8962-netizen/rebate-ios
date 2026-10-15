import Foundation

/// 登录页用到的文案键（BR-TEXT-14；三端同名）。契约 texts.default.json 已有的键（error.*、invite.notice_inviter、
/// login.help_entry）直接取；其余是 App 草稿表 LoginDraftTexts 里「待定稿，不得提审」的键（TODO(N-26) TEXT-01）。
/// 本模块不出现中文，文案一律经 `LoginTexts` 取。
public enum LoginKeys {
    public static let brand = "login.brand"
    public static let close = "login.close"
    public static let back = "login.back"
    public static let settings = "login.settings"
    public static let title = "login.title"
    public static let phoneLabel = "login.phone.label"
    public static let phonePrefix = "login.phone.prefix"
    public static let phonePlaceholder = "login.phone.placeholder"
    public static let phoneClear = "login.phone.clear"
    public static let agreePrefix = "login.agree.prefix"
    public static let agreeAgreement = "login.agree.agreement"
    public static let agreeAnd = "login.agree.and"
    public static let agreePrivacy = "login.agree.privacy"
    public static let agreeSuffix = "login.agree.suffix"
    public static let agreeHint = "login.agree.hint"
    public static let getCode = "login.get_code"
    public static let inviteEntry = "login.invite.entry"
    public static let otherMethods = "login.other_methods"
    public static let apple = "login.apple"
    /// 微信按钮的读屏名称（「微信登录」）与按钮下方的短名（「微信」）。
    public static let wechat = "login.wechat"
    public static let wechatShort = "login.wechat.short"
    /// {provider_name} 的取值（error.50305、error.30411.mergeable）。
    public static func providerName(_ provider: String) -> String {
        "login.provider.\(provider)"
    }

    public static let confirmTitle = "login.agree_confirm.title"
    public static let confirmBodyPrefix = "login.agree_confirm.body_prefix"
    public static let confirmBodySuffix = "login.agree_confirm.body_suffix"
    public static let confirmCancel = "login.agree_confirm.cancel"
    public static let confirmOK = "login.agree_confirm.ok"
    public static let codeTitle = "login.code.title"
    public static let codeSentTo = "login.code.sent_to"
    public static let codeLabel = "login.code.label"
    public static let codeCountdown = "login.code.countdown"
    public static let codeResend = "login.code.resend"
    public static let codeContinue = "login.code.continue"
    public static let inviteLabel = "login.invite.label"
    public static let invitePlaceholder = "login.invite.placeholder"
    public static let inviteClear = "login.invite.clear"
    public static let submit = "login.submit"
    public static let help = "login.help_entry"
    public static let riskBlockedDesc = "login.risk_blocked.desc"
    public static let riskBlockedOK = "login.risk_blocked.ok"
    public static let appeal = "cs.appeal_entry"
    public static let deletionTitle = "error.10007"
    public static let deletionBody = "login.deletion.body"
    public static let deletionCS = "login.deletion.cs"
    public static let deletionOK = "login.deletion.ok"
    public static let sessionExpired = "error.10404"
    public static let generic = "error.50001"
}

/// 文案来源（App 实现：DefaultTexts → 草稿表）。缺键返回空串。
@MainActor
public protocol LoginTexts {
    func text(_ key: String) -> String
    /// 带变量：{name} 替换为 vars[name]；带占位而没给值时用 fallback 文案。
    func format(_ key: String, _ vars: [String: String]) -> String
}

/// 页面的出口（App 接 Router 与 App 能力）。
@MainActor
public final class LoginPageConfig {
    public let service: LoginService
    public let texts: LoginTexts
    /// 从强更页进入的受限登录（APP-02c 内部来源标记 `fromForceUpdatePage`，不进路由参数，rule-gaps ROUTE-01）：
    /// 不显示设置、登录遇到问题、邀请码与第三方登录。
    public var restricted = false
    /// 刷新失败清会话后进入（LoginSessionExpired）：进入时提示 error.10404。
    public var sessionExpired = false
    /// 第三方登录（APP-05b）：nil = 不显示第三方区。按钮是否显示由它按适配器与平台判定（正式微信恒不可用 → 不显示）。
    public var oauth: OAuthLoginService?
    public var onClose: () -> Void = {}
    public var onSettings: () -> Void = {}
    public var onHelp: () -> Void = {}
    /// 协议链接：type = agreement / privacy（routes.json Agreement.type）。
    public var onAgreement: (String) -> Void = { _ in }
    public var onCustomerService: () -> Void = {}
    /// 登录成功（页面已由执行器关闭）：App 显示邀请绑定结果等。
    public var onLoggedIn: (LoginOutcome) -> Void = { _ in }
    /// 10405（受限登录查不到账号 no_account 等）：App 提示先更新（文案键），关闭登录页回到强更页。
    public var onForceUpdate: (String?) -> Void = { _ in }
    /// 游客在剪贴板邀请提示点了确认（APP-07，G16）：进入验证码页时取一次预填的邀请码（取走即丢弃，之后以用户输入为准）。
    public var takeInvitePrefill: () -> String? = { nil }
    /// 邀请码行【粘贴】（APP-07，LoginCodeInvite）：系统粘贴控件交回的文本由 App 只抽码；nil = 不显示。
    public var invitePaste: LoginInvitePaste?

    public init(service: LoginService, texts: LoginTexts) {
        self.service = service
        self.texts = texts
    }
}

/// 邀请码【粘贴】的结果：填入的码、要轻提示的文字（「未识别到邀请码」、限流），或什么都不做。
public enum LoginInvitePasteOutcome: Equatable, Sendable {
    case code(String)
    case message(String)
    case ignored
}

/// 邀请码行【粘贴】的状态与处理（App 给）：`enabled` 跟随 42901 禁用期（共性第 6 条，执行层另拦）。`begin` 在用户点系统粘贴控件的那一刻
/// 调用，绑定此刻的登录页实例与前台轮次，返回系统稍后交付文本时的处理（交付时复核，失效 .ignored；APP-07 共性第 28 条）；只抽码，不清空已有输入。
@MainActor
public final class LoginInvitePaste: ObservableObject {
    @Published public var enabled = true
    public let begin: () -> ((String?) -> LoginInvitePasteOutcome)?

    public init(begin: @escaping () -> ((String?) -> LoginInvitePasteOutcome)?) {
        self.begin = begin
    }

    /// 点击与交付在同一时刻。
    public func handle(_ text: String?) -> LoginInvitePasteOutcome {
        begin()?(text) ?? .ignored
    }
}

/// 页面弹窗。
public enum LoginDialog: Equatable {
    case agreeConfirm
    /// LoginCodeBlocked（标题键）。
    case blocked(String)
    /// 第三方登录 44001（risk_blocked）：标题键；不套用短信注册专用说明（APP-05b 共性第 5 条），只给【知道了】与【联系客服申诉】。
    case oauthBlocked(String)
    case deletionProcessing
}
