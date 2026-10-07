import DesignSystem
import Foundation

/// 登录页的发码与登录动作。
extension LoginViewModel {
    // MARK: - 发码

    /// 【获取验证码】/【重新获取】。
    public func requestCode() {
        let phone = PhoneNumber.normalize(phoneText)
        guard let normalized = phone.normalized else {
            phoneError = text("error.20001.phone_invalid")
            return
        }
        phoneError = ""
        let remaining = service.resendRemainingSec(phoneText)
        if step == .phone, service.hasReceivedCode(phoneText), remaining > 0 || sendRateLimited {
            // 共性 5：这个号码成功发码的倒计时还没到（例如从验证码页返回、号码没改）：不再发码，回验证码步继续输入已收到的码。
            // 共性 12：发码处于限流期，但这个号码在有效期内收到过码：照样进验证码步，只是不能再发码。
            enterCodeStep(normalized)
            return
        }
        guard !sendRateLimited else { return }
        if remaining > 0 {
            // 这个号码的发码闸门还没过（如另一次进入登录页时 42901）：不发出，LoginService 直接给出闸门结果，不必先同意协议。
            sendCode()
            return
        }
        withAgreement { [weak self] in
            self?.sendCode()
        }
    }

    /// 进验证码步。倒计时读 LoginService 里这个号码的截止时间（共性 21），这里只启动计时。
    func enterCodeStep(_ normalized: String) {
        sentTo = PhoneNumber.masked(normalized)
        codeText = ""
        codeError = ""
        step = .code
        startTicking()
    }

    func sendCode() {
        guard !sending else { return }
        sending = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            let outcome = await service.sendCode(phoneText)
            sending = false
            handleSend(outcome)
        }
    }

    func handleSend(_ outcome: SendCodeOutcome) {
        switch outcome.stateRaw {
        case SmsCountdown.stateSent, SendCodeOutcome.countdownActive:
            if step == .code {
                codeError = ""
                startTicking()
            } else {
                enterCodeStep(outcome.phone ?? "")
            }
        case SmsCountdown.stateRateLimited:
            // 共性 11：只禁用发码入口；登录按钮照常（仍有效的验证码可以提交）。禁用截止已由 LoginService 按号码记下（共性 21）。
            startTicking()
            showToast(outcome.textKey, outcome.trace6)
            if step == .phone, outcome.hasReceivedCode, let phone = outcome.phone {
                enterCodeStep(phone)
            }
        case LoginOutcome.stale, LoginOutcome.busy:
            break
        default:
            showToastOrFieldError(outcome)
            // 共性 16：结果不确定（50401）时号码已记为「可能收到」，照样进验证码步，用户可输入实际收到的码。
            if step == .phone, outcome.hasReceivedCode, let phone = outcome.phone {
                enterCodeStep(phone)
            }
        }
    }

    private func showToastOrFieldError(_ outcome: SendCodeOutcome) {
        guard outcome.field == "phone" else {
            showToast(outcome.textKey, outcome.trace6)
            return
        }
        phoneError = text(outcome.textKey ?? "error.20001")
        if step == .code {
            showToast(outcome.textKey, outcome.trace6)
        }
    }

    /// 「继续输入验证码」（共性 16）：独立入口，不以能否重发为条件；这个号码在有效期内收到过（或可能收到过）验证码时出现。
    public var canContinueCode: Bool {
        step == .phone && service.hasReceivedCode(phoneText)
    }

    public func continueCode() {
        guard let normalized = PhoneNumber.normalize(phoneText).normalized, canContinueCode else { return }
        enterCodeStep(normalized)
    }

    // MARK: - 登录

    public func submit() {
        guard canSubmit else { return }
        withAgreement { [weak self] in
            self?.login()
        }
    }

    func login() {
        submitting = true
        let restricted = config.restricted
        Task { @MainActor [weak self] in
            guard let self else { return }
            let outcome = await service.login(
                phone: phoneText, code: codeText, consentAtMillis: agreement.consentAtMillis,
                invite: restricted ? "" : inviteText, restricted: restricted
            )
            submitting = false
            handleLogin(outcome)
        }
    }

    func handleLogin(_ outcome: LoginOutcome) {
        switch outcome.stateRaw {
        case LoginOutcome.loggedIn:
            ticker?.cancel()
            ticker = nil
            config.onLoggedIn(outcome)
        case LoginOutcome.stale, LoginOutcome.busy, LoginOutcome.agreementRequired, LoginOutcome.codeIncomplete:
            break
        case "code_error", "code_expired", "field_error":
            handleFieldError(outcome)
        case SmsCountdown.stateRateLimited:
            // 共性 11：登录收到 42901 只禁用登录按钮。
            limits.limitLogin(now: service.now, millis: outcome.disableMillis)
            startTicking()
            showToast(outcome.textKey, outcome.trace6)
        case "registration_blocked":
            // LoginCodeBlocked：不建号，手机号保留，验证码清空需重新获取（BR-ID-05、BR-TEXT-14 login.risk_blocked.desc）。
            codeText = ""
            dialog = .blocked(outcome.textKey ?? "error.44001")
        case "deletion_processing":
            dialog = .deletionProcessing
        case "force_update":
            // 10405：网络层已进强更状态；App 提示先更新，关闭登录页回到强更页。
            ticker?.cancel()
            ticker = nil
            config.onForceUpdate(outcome.textKey)
        default:
            showToast(outcome.textKey, outcome.trace6)
        }
    }

    /// 验证码错误 / 失效、字段错误：在对应字段旁提示。
    func handleFieldError(_ outcome: LoginOutcome) {
        switch (outcome.stateRaw, outcome.field) {
        case ("code_error", _):
            codeError = text(outcome.textKey ?? "error.20002")
        case ("code_expired", _):
            codeError = text(outcome.textKey ?? "error.20003")
            codeText = ""
        case (_, "phone"):
            backToPhone()
            phoneError = text(outcome.textKey ?? "error.20001")
        case (_, "code"):
            codeError = text(outcome.textKey ?? "error.20001")
        default:
            showToast(outcome.textKey, outcome.trace6)
        }
    }
}
