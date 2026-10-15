import Combine
import DesignSystem
import Foundation

/// 登录页状态与动作（UiState / Action，03 §3.2）。一个路由 Login，两步：手机号 → 验证码。
@MainActor
public final class LoginViewModel: ObservableObject {
    public enum Step: Equatable {
        case phone
        case code
    }

    public static let agreementType = "agreement"
    public static let privacyType = "privacy"

    @Published public var step: Step = .phone
    @Published public internal(set) var phoneText = ""
    @Published public internal(set) var codeText = ""
    @Published public var inviteText = ""
    @Published public var inviteOpen = false
    @Published public internal(set) var agreed = false
    @Published public internal(set) var sending = false
    @Published public internal(set) var submitting = false
    @Published public var phoneError = ""
    @Published public var codeError = ""
    @Published public internal(set) var sentTo = ""
    @Published public internal(set) var now: Int64 = 0
    @Published public var dialog: LoginDialog?
    @Published public var toast: CouliToastMessage?
    /// 正在进行的第三方登录（provider；APP-05b）。
    @Published public internal(set) var oauthProvider: String?

    public let config: LoginPageConfig
    var agreement: AgreementState
    /// 登录按钮的 42901 禁用截止（共性 11）。发码的倒计时与限流不在这里：一律读 LoginService 按规范化号码记的截止时间
    /// （共性 21）。
    var limits = LoginRateLimits()
    /// 确认框同意后要继续的动作。
    var afterConfirm: (() -> Void)?
    var ticker: Task<Void, Never>?

    public init(config: LoginPageConfig) {
        self.config = config
        let service = config.service
        agreement = AgreementState(clock: { MainActor.assumeIsolated { service.now } })
        now = service.now
    }

    var service: LoginService {
        config.service
    }

    /// 剪贴板邀请确认后的预填（APP-07，G16）：进入验证码页时取一次，取走即丢弃；已有输入时不覆盖。
    func applyInvitePrefill() {
        guard !config.restricted, let code = config.takeInvitePrefill(), inviteText.isEmpty else { return }
        inviteText = code
        inviteOpen = true
    }

    func text(_ key: String) -> String {
        config.texts.text(key)
    }

    func format(_ key: String, _ name: String, _ value: String) -> String {
        config.texts.format(key, [name: value])
    }

    // MARK: - 计时

    /// 验证码页「N 秒后可重新获取」：当前号码（规范化后）在 LoginService 里的发码截止时间——成功发码的倒计时或 42901 的
    /// 禁用期（共性 21）。换号即换成新号码的截止，换回旧号码时旧限制照样生效。
    public var resendCountdown: Int {
        service.sendRemainingSec(phoneText, now: now)
    }

    /// 当前号码处于发码 42901 限流期（只禁用发码入口，共性 11、21）。
    public var sendRateLimited: Bool {
        service.sendRateLimited(phoneText, now: now)
    }

    public var loginRateLimited: Bool {
        limits.loginBlocked(now: now)
    }

    public var canSubmit: Bool {
        CodeInput.accept(codeText).complete && !loginRateLimited && !submitting
    }

    func startTicking() {
        now = service.now
        guard ticker == nil else { return }
        ticker = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self else { return }
                now = service.now
                if !countdownActive {
                    ticker = nil
                    return
                }
            }
        }
    }

    /// 还有没走完的倒计时（当前号码的发码截止或登录限流）。
    var countdownActive: Bool {
        resendCountdown > 0 || limits.loginBlocked(now: now) || oauthLimitedAny
    }

    /// 页面消失（兜底）：停计时、作废本次尝试。确定出栈的同步出口在 RouterLoginHost.watchLoginPage（共性 9）。
    public func disappeared() {
        ticker?.cancel()
        ticker = nil
        service.invalidateAttempt()
    }

    // MARK: - 输入

    public func setPhone(_ value: String) {
        guard value != phoneText else { return }
        phoneText = value
        phoneError = ""
        // 换号：作废在途发码（旧号的结果不再改页面）。
        service.invalidateAttempt()
        // 显示状态切到新号码的截止时间（共性 21）：按当前时钟重算，新号码还在倒计时 / 限流期就让计时走起来。
        now = service.now
        if countdownActive {
            startTicking()
        }
    }

    public func clearPhone() {
        setPhone("")
    }

    public func setCode(_ value: String) {
        let clean = CodeInput.sanitize(value)
        if clean != codeText {
            codeText = clean
            codeError = ""
        }
    }

    public var inviteDecision: InviteDecision {
        InviteField.decide(inviteText, context: ["restricted": config.restricted])
    }

    // MARK: - 协议

    public func toggleAgreement() {
        if agreement.checked {
            agreement.uncheck()
        } else {
            agreement.check()
        }
        agreed = agreement.checked
    }

    /// 未勾选时弹 LoginAgreeConfirm；同意后记下点击时刻并继续 next。
    func withAgreement(_ next: @escaping () -> Void) {
        agreement.tapLogin()
        if agreement.consumeProceed() {
            next()
            return
        }
        afterConfirm = next
        dialog = .agreeConfirm
    }

    public func confirmAgreement() {
        agreement.confirm(nowMillis: service.now)
        agreed = true
        dialog = nil
        let next = afterConfirm
        afterConfirm = nil
        if agreement.consumeProceed() {
            next?()
        }
    }

    public func cancelAgreement() {
        agreement.cancel()
        afterConfirm = nil
        dialog = nil
    }

    /// 确认框里的协议链接（共性 8）：关闭确认框（不算同意）并打开协议正文。
    public func openAgreementFromConfirm(_ type: String) {
        cancelAgreement()
        config.onAgreement(type)
    }

    // MARK: - 导航

    /// 左上角：验证码步回手机号步（作废本次尝试）；手机号步关闭登录页。
    public func closeOrBack() {
        if step == .code {
            backToPhone()
        } else {
            config.onClose()
        }
    }

    public func backToPhone() {
        service.invalidateAttempt()
        step = .phone
        codeText = ""
        codeError = ""
    }

    func showToast(_ key: String?, _ trace6: String) {
        let message = format(key ?? LoginKeys.generic, "trace6", trace6)
        if !message.isEmpty {
            toast = CouliToastMessage(message)
        }
    }

    /// 页面出现（含从协议页等返回）：立即按当前时钟与截止时间重算倒计时与限流状态；还有没走完的就重启计时（共性 20）。
    public func appeared() {
        now = service.now
        if countdownActive {
            startTicking()
        }
        if config.sessionExpired {
            config.sessionExpired = false
            toast = CouliToastMessage(text(LoginKeys.sessionExpired))
        }
    }
}
